{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts, RankNTypes, RecordWildCards #-}

module Unison.Codebase.Serialization.V1 where

-- import qualified Data.Text as Text
import qualified Unison.PatternP               as Pattern
import           Unison.PatternP                ( Pattern )
import           Control.Applicative            ( liftA2
                                                , liftA3
                                                )
import           Control.Monad                  ( replicateM )
import           Data.Bits                      ( Bits )
import           Data.Bytes.Get
import           Data.Bytes.Put
import           Data.Bytes.Serial              ( serialize
                                                , deserialize
                                                , serializeBE
                                                , deserializeBE
                                                )
import           Data.Bytes.Signed              ( Unsigned )
import           Data.Bytes.VarInt              ( VarInt(..) )
import           Data.Foldable                  ( traverse_ )
import           Data.Int                       ( Int64 )
import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import           Data.List                      ( elemIndex
                                                , foldl'
                                                )
import           Data.Text                      ( Text )
import           Data.Text.Encoding             ( encodeUtf8
                                                , decodeUtf8
                                                )
import           Data.Word                      ( Word64 )
import           Unison.Codebase.Branch2        ( Branch0(..) )
import qualified Unison.Codebase.Branch2        as Branch
import           Unison.Codebase.Causal2        ( Causal0(..)
                                                , C0Hash(..)
                                                , unc0hash
                                                )
import           Unison.Codebase.Path           ( NameSegment )
import           Unison.Codebase.Path           as Path
import           Unison.Codebase.Path           as NameSegment
import           Unison.Codebase.TermEdit       ( TermEdit )
import           Unison.Codebase.TypeEdit       ( TypeEdit )
import           Unison.Hash                    ( Hash )
import           Unison.Kind                    ( Kind )
import           Unison.Reference               ( Reference )
import           Unison.Symbol                  ( Symbol(..) )
import           Unison.Term                    ( AnnotatedTerm )
import qualified Data.ByteString               as B
import qualified Data.Sequence                 as Sequence
import qualified Data.Set                      as Set
import qualified Unison.ABT                    as ABT
import qualified Unison.Codebase.TermEdit      as TermEdit
import qualified Unison.Codebase.TypeEdit      as TypeEdit
import qualified Unison.Codebase.Serialization as S
import qualified Unison.Hash                   as Hash
import qualified Unison.Kind                   as Kind
import           Unison.Name                   (Name)
import qualified Unison.Name                   as Name
import qualified Unison.Reference              as Reference
import           Unison.Referent               (Referent)
import qualified Unison.Referent               as Referent
import qualified Unison.Term                   as Term
import qualified Unison.Type                   as Type
import           Unison.Util.Relation           ( Relation )
import qualified Unison.Util.Relation          as Relation
import qualified Unison.DataDeclaration        as DataDeclaration
import           Unison.DataDeclaration         ( DataDeclaration'
                                                , EffectDeclaration'
                                                )
import qualified Unison.Var                    as Var

-- ABOUT THIS FORMAT:
--
-- A serialization format for uncompiled Unison syntax trees.
--
-- Finalized: No
--
-- If Finalized: Yes, don't modify this file in a way that affects serialized form.
-- Instead, create a new file, V(n + 1).
-- This ensures that we have a well-defined serialized form and can read
-- and write old versions.

unknownTag :: (MonadGet m, Show a) => String -> a -> m x
unknownTag msg tag =
  fail $ "unknown tag " ++ show tag ++
         " while deserializing: " ++ msg

putCausal0 :: MonadPut m => (a -> m ()) -> Causal0 h a -> m ()
putCausal0 putA = \case
  One0 a -> putWord8 0 >> putA a
  Cons0 a t -> putWord8 1 >> (putHash.unc0hash) t >> putA a
  Merge0 a ts -> putWord8 2 >> putFoldable (putHash.unc0hash) ts >> putA a

getCausal0 :: MonadGet m => m a -> m (Causal0 h a)
getCausal0 getA = getWord8 >>= \case
  0 -> One0 <$> getA
  1 -> flip Cons0 <$> (C0Hash <$> getHash) <*> getA
  2 -> flip Merge0 . Set.fromList <$> getList (C0Hash <$> getHash) <*> getA
  x -> unknownTag "Causal0" x

-- Like getCausal, but doesn't bother to read the actual value in the causal,
-- it just reads the hashes.  Useful for more efficient implementation of
-- `Causal.before`.
-- getCausal00 :: MonadGet m => m Causal00
-- getCausal00 = getWord8 >>= \case
--   0 -> pure One00
--   1 -> Cons00 <$> getHash
--   2 -> Merge00 . Set.fromList <$> getList getHash

-- 1. Can no longer read a causal using just MonadGet;
--    need a way to construct the loader that forms its tail.
--    Same problem with loading Branch0 with monadic tails.
-- 2. Without the monadic tail, need external info to know how to
--    load the tail.  When modifying a nested structure, we
--    need a way to save the intermediate nodes. (e.g. zipper?)
-- 3. We ran into trouble trying to intermingle the marshalling monad
--    (put/get) with the loading/saving monad (io).
-- 4. PutT was weird because we don't think we want the Codebase monad to
--    randomly be able to accumulate bytestrings (put) that don't even reset.
-- 5. We could specialize `Causal m e` to a particular monad that tries to do
--    the right things wrt caching?
-- putCausal0 :: MonadPut m => Causal a -> (a -> m ()) -> m ()
-- putCausal0 = undefined

-- This loads the tail in order to write it?
-- May be crucial to do so, if "loading" tail from `pure`, but
-- otherwise weird.  We'd like to skip writing the tail if it already
-- exists, but how can we tell?
-- Also, we're not even supposed to be writing the tail into the same buffer
-- as head.  We should be writing the hash of the tail though, so we can
-- know which file we need to load it from; loading another file is also
-- something we can't do in this model.
----
-- putCausal :: (MonadPut m, Monad n) => Causal n a -> (a -> m ()) -> n (m ())
-- putCausal (Causal.One hash a) putA =
--   pure $ putWord8 1 *> putHash hash *> putA a
-- putCausal (Causal.ConsN m) putA = do
--   (conss, tail) <- m
--   pure (putWord8 2 *> putFoldable conss (putPair' putHash putA))
--     *> putCausal tail putA
-- putCausal (Causal.Merge hash a tails) putA = do
--   pure (putWord8 3 *> putHash hash *> putA a)
--   putFoldableN (Map.toList tails) $ putPair'' putHash (>>= (`putCausal` putA))
-- putCausal (Causal.Cons _ _ _) _ =
--   error "deserializing 'Causal': the ConsN pattern should have matched here!"


-- getCausal :: MonadGet m => m a -> m (Causal a)
-- getCausal getA = getWord8 >>= \case
--   1 -> Causal.One <$> getHash <*> getA
--   2 -> Causal.consN <$> getList (getPair getHash getA) <*> getCausal getA
--   3 -> Causal.Merge <$> getHash <*> getA <*>
--           (Map.fromList <$> getList (getPair getHash $ getCausal getA))
--   x -> unknownTag "causal" x

-- getCausal ::

putLength ::
  (MonadPut m, Integral n, Integral (Unsigned n),
   Bits n, Bits (Unsigned n))
  => n -> m ()
putLength = serialize . VarInt

getLength ::
  (MonadGet m, Integral n, Integral (Unsigned n),
   Bits n, Bits (Unsigned n))
  => m n
getLength = unVarInt <$> deserialize

putText :: MonadPut m => Text -> m ()
putText text = do
  let bs = encodeUtf8 text
  putLength $ B.length bs
  putByteString bs

getText :: MonadGet m => m Text
getText = do
  len <- getLength
  bs <- getBytes len
  pure $ decodeUtf8 bs

putFloat :: MonadPut m => Double -> m ()
putFloat = serializeBE

getFloat :: MonadGet m => m Double
getFloat = deserializeBE

putNat :: MonadPut m => Word64 -> m ()
putNat = putWord64be

getNat :: MonadGet m => m Word64
getNat = getWord64be

putInt :: MonadPut m => Int64 -> m ()
putInt n = serializeBE n

getInt :: MonadGet m => m Int64
getInt = deserializeBE

putBoolean :: MonadPut m => Bool -> m ()
putBoolean False = putWord8 0
putBoolean True  = putWord8 1

getBoolean :: MonadGet m => m Bool
getBoolean = go =<< getWord8 where
  go 0 = pure False
  go 1 = pure True
  go t = unknownTag "Boolean" t

putHash :: MonadPut m => Hash -> m ()
putHash h = do
  let bs = Hash.toBytes h
  putLength (B.length bs)
  putByteString bs

getHash :: MonadGet m => m Hash
getHash = do
  len <- getLength
  bs <- getBytes len
  pure $ Hash.fromBytes bs

putReference :: MonadPut m => Reference -> m ()
putReference r = case r of
  Reference.Builtin name -> do
    putWord8 0
    putText name
  Reference.Derived hash i n -> do
    putWord8 1
    putHash hash
    putLength i
    putLength n
  _ -> error "unpossible"

getReference :: MonadGet m => m Reference
getReference = do
  tag <- getWord8
  case tag of
    0 -> Reference.Builtin <$> getText
    1 -> Reference.DerivedId <$> (Reference.Id <$> getHash <*> getLength <*> getLength)
    _ -> unknownTag "Reference" tag

putReferent :: MonadPut m => Referent -> m ()
putReferent r = case r of
  Referent.Ref r -> do
    putWord8 0
    putReference r
  Referent.Con r i -> do
    putWord8 1
    putReference r
    putLength i

getReferent :: MonadGet m => m Referent
getReferent = do
  tag <- getWord8
  case tag of
    0 -> Referent.Ref <$> getReference
    1 -> Referent.Con <$> getReference <*> getLength
    _ -> unknownTag "getReferent" tag

putMaybe :: MonadPut m => Maybe a -> (a -> m ()) -> m ()
putMaybe Nothing _ = putWord8 0
putMaybe (Just a) putA = putWord8 1 *> putA a

getMaybe :: MonadGet m => m a -> m (Maybe a)
getMaybe getA = getWord8 >>= \tag -> case tag of
  0 -> pure Nothing
  1 -> Just <$> getA
  _ -> unknownTag "Maybe" tag

putFoldable
  :: (Foldable f, MonadPut m) => (a -> m ()) -> f a -> m ()
putFoldable putA as = do
  putLength (length as)
  traverse_ putA as


-- putFoldableN
--   :: forall f m n a
--    . (Traversable f, MonadPut m, Applicative n)
--   => f a
--   -> (a -> n (m ()))
--   -> n (m ())
-- putFoldableN as putAn =
--   pure (putLength @m (length as)) *> (fmap sequence_ $ traverse putAn as)

getFolded :: MonadGet m => (b -> a -> b) -> b -> m a -> m b
getFolded f z a =
  foldl' f z <$> getList a

getList :: MonadGet m => m a -> m [a]
getList a = getLength >>= (`replicateM` a)

putABT
  :: (MonadPut m, Foldable f, Functor f, Ord v)
  => (v -> m ())
  -> (a -> m ())
  -> (forall x . (x -> m ()) -> f x -> m ())
  -> ABT.Term f v a
  -> m ()
putABT putVar putA putF abt =
  putFoldable putVar fvs *> go (ABT.annotateBound'' abt)
  where
    fvs = Set.toList $ ABT.freeVars abt
    go (ABT.Term _ (a, env) abt) = putA a *> case abt of
      ABT.Var v      -> putWord8 0 *> putVarRef env v
      ABT.Tm f       -> putWord8 1 *> putF go f
      ABT.Abs v body -> putWord8 2 *> putVar v *> go body
      ABT.Cycle body -> putWord8 3 *> go body

    putVarRef env v = case v `elemIndex` env of
      Just i  -> putWord8 0 *> putLength i
      Nothing -> case v `elemIndex` fvs of
        Just i -> putWord8 1 *> putLength i
        Nothing -> error $ "impossible: var not free or bound"

getABT
  :: (MonadGet m, Foldable f, Functor f, Ord v)
  => m v
  -> m a
  -> (forall x . m x -> m (f x))
  -> m (ABT.Term f v a)
getABT getVar getA getF = getList getVar >>= go [] where
  go env fvs = do
    a <- getA
    tag <- getWord8
    case tag of
      0 -> do
        tag <- getWord8
        case tag of
          0 -> ABT.annotatedVar a . (env !!) <$> getLength
          1 -> ABT.annotatedVar a . (fvs !!) <$> getLength
          _ -> unknownTag "getABT.Var" tag
      1 -> ABT.tm' a <$> getF (go env fvs)
      2 -> do
        v <- getVar
        body <- go (v:env) fvs
        pure $ ABT.abs' a v body
      3 -> ABT.cycle' a <$> go env fvs
      _ -> unknownTag "getABT" tag

putKind :: MonadPut m => Kind -> m ()
putKind k = case k of
  Kind.Star      -> putWord8 0
  Kind.Arrow i o -> putWord8 1 *> putKind i *> putKind o

getKind :: MonadGet m => m Kind
getKind = getWord8 >>= \tag -> case tag of
  0 -> pure Kind.Star
  1 -> Kind.Arrow <$> getKind <*> getKind
  _ -> unknownTag "getKind" tag

putType :: (MonadPut m, Ord v)
        => (v -> m ()) -> (a -> m ())
        -> Type.AnnotatedType v a
        -> m ()
putType putVar putA typ = putABT putVar putA go typ where
  go putChild t = case t of
    Type.Ref r       -> putWord8 0 *> putReference r
    Type.Arrow i o   -> putWord8 1 *> putChild i *> putChild o
    Type.Ann t k     -> putWord8 2 *> putChild t *> putKind k
    Type.App f x     -> putWord8 3 *> putChild f *> putChild x
    Type.Effect e t  -> putWord8 4 *> putChild e *> putChild t
    Type.Effects es  -> putWord8 5 *> putFoldable putChild es
    Type.Forall body -> putWord8 6 *> putChild body

getType :: (MonadGet m, Ord v)
        => m v -> m a -> m (Type.AnnotatedType v a)
getType getVar getA = getABT getVar getA go where
  go getChild = getWord8 >>= \tag -> case tag of
    0 -> Type.Ref <$> getReference
    1 -> Type.Arrow <$> getChild <*> getChild
    2 -> Type.Ann <$> getChild <*> getKind
    3 -> Type.App <$> getChild <*> getChild
    4 -> Type.Effect <$> getChild <*> getChild
    5 -> Type.Effects <$> getList getChild
    6 -> Type.Forall <$> getChild
    _ -> unknownTag "getType" tag

putSymbol :: MonadPut m => Symbol -> m ()
putSymbol v@(Symbol id _) = putLength id *> putText (Var.name v)

getSymbol :: MonadGet m => m Symbol
getSymbol = Symbol <$> getLength <*> (Var.User <$> getText)

putPattern :: MonadPut m => (a -> m ()) -> Pattern a -> m ()
putPattern putA p = case p of
  Pattern.Unbound a
    -> putWord8 0 *> putA a
  Pattern.Var a
    -> putWord8 1 *> putA a
  Pattern.Boolean a b
    -> putWord8 2 *> putA a *> putBoolean b
  Pattern.Int a n
    -> putWord8 3 *> putA a *> putInt n
  Pattern.Nat a n
    -> putWord8 4 *> putA a *> putNat n
  Pattern.Float a n
    -> putWord8 5 *> putA a *> putFloat n
  Pattern.Constructor a r cid ps
    -> putWord8 6 *> putA a *> putReference r *> putLength cid
                  *> putFoldable (putPattern putA) ps
  Pattern.As a p
    -> putWord8 7 *> putA a *> putPattern putA p
  Pattern.EffectPure a p
    -> putWord8 8 *> putA a *> putPattern putA p
  Pattern.EffectBind a r cid args k
    -> putWord8 9 *> putA a *> putReference r *> putLength cid
                  *> putFoldable (putPattern putA) args *> putPattern putA k
  _ -> error $ "unknown pattern: " ++ show p

getPattern :: MonadGet m => m a -> m (Pattern a)
getPattern getA = getWord8 >>= \tag -> case tag of
  0 -> Pattern.Unbound <$> getA
  1 -> Pattern.Var <$> getA
  2 -> Pattern.Boolean <$> getA <*> getBoolean
  3 -> Pattern.Int <$> getA <*> getInt
  4 -> Pattern.Nat <$> getA <*> getNat
  5 -> Pattern.Float <$> getA <*> getFloat
  6 -> Pattern.Constructor <$> getA <*> getReference <*> getLength <*> getList (getPattern getA)
  7 -> Pattern.As <$> getA <*> getPattern getA
  8 -> Pattern.EffectPure <$> getA <*> getPattern getA
  9 -> Pattern.EffectBind <$> getA <*> getReference <*> getLength <*> getList (getPattern getA) <*> getPattern getA
  _ -> unknownTag "Pattern" tag

putTerm :: (MonadPut m, Ord v)
        => (v -> m ()) -> (a -> m ())
        -> AnnotatedTerm v a
        -> m ()
putTerm putVar putA typ = putABT putVar putA go typ where
  go putChild t = case t of
    Term.Int n
      -> putWord8 0 *> putInt n
    Term.Nat n
      -> putWord8 1 *> putNat n
    Term.Float n
      -> putWord8 2 *> putFloat n
    Term.Boolean b
      -> putWord8 3 *> putBoolean b
    Term.Text t
      -> putWord8 4 *> putText t
    Term.Blank _
      -> error $ "can't serialize term with blanks"
    Term.Ref r
      -> putWord8 5 *> putReference r
    Term.Constructor r cid
      -> putWord8 6 *> putReference r *> putLength cid
    Term.Request r cid
      -> putWord8 7 *> putReference r *> putLength cid
    Term.Handle h a
      -> putWord8 8 *> putChild h *> putChild a
    Term.App f arg
      -> putWord8 9 *> putChild f *> putChild arg
    Term.Ann e t
      -> putWord8 10 *> putChild e *> putType putVar putA t
    Term.Sequence vs
      -> putWord8 11 *> putFoldable putChild vs
    Term.If cond t f
      -> putWord8 12 *> putChild cond *> putChild t *> putChild f
    Term.And x y
      -> putWord8 13 *> putChild x *> putChild y
    Term.Or x y
      -> putWord8 14 *> putChild x *> putChild y
    Term.Lam body
      -> putWord8 15 *> putChild body
    Term.LetRec _ bs body
      -> putWord8 16 *> putFoldable putChild bs *> putChild body
    Term.Let _ b body
      -> putWord8 17 *> putChild b *> putChild body
    Term.Match s cases
      -> putWord8 18 *> putChild s *> putFoldable (putMatchCase putA putChild) cases

  putMatchCase :: MonadPut m => (a -> m ()) -> (x -> m ()) -> Term.MatchCase a x -> m ()
  putMatchCase putA putChild (Term.MatchCase pat guard body) =
    putPattern putA pat *> putMaybe guard putChild *> putChild body

getTerm :: (MonadGet m, Ord v)
        => m v -> m a -> m (Term.AnnotatedTerm v a)
getTerm getVar getA = getABT getVar getA go where
  go getChild = getWord8 >>= \tag -> case tag of
    0 -> Term.Int <$> getInt
    1 -> Term.Nat <$> getNat
    2 -> Term.Float <$> getFloat
    3 -> Term.Boolean <$> getBoolean
    4 -> Term.Text <$> getText
    5 -> Term.Ref <$> getReference
    6 -> Term.Constructor <$> getReference <*> getLength
    7 -> Term.Request <$> getReference <*> getLength
    8 -> Term.Handle <$> getChild <*> getChild
    9 -> Term.App <$> getChild <*> getChild
    10 -> Term.Ann <$> getChild <*> getType getVar getA
    11 -> Term.Sequence . Sequence.fromList <$> getList getChild
    12 -> Term.If <$> getChild <*> getChild <*> getChild
    13 -> Term.And <$> getChild <*> getChild
    14 -> Term.Or <$> getChild <*> getChild
    15 -> Term.Lam <$> getChild
    16 -> Term.LetRec False <$> getList getChild <*> getChild
    17 -> Term.Let False <$> getChild <*> getChild
    18 -> Term.Match <$> getChild
                     <*> getList (Term.MatchCase <$> getPattern getA <*> getMaybe getChild <*> getChild)
    _ -> unknownTag "getTerm" tag

putPair :: MonadPut m => (a -> m ()) -> (b -> m ()) -> (a,b) -> m ()
putPair putA putB (a,b) = putA a *> putB b

putPair''
  :: (MonadPut m, Monad n)
  => (a -> m ())
  -> (b -> n (m ()))
  -> (a, b)
  -> n (m ())
putPair'' putA putBn (a, b) = do
  pure (putA a) *> putBn b

getPair :: MonadGet m => m a -> m b -> m (a,b)
getPair = liftA2 (,)

putTuple3'
  :: MonadPut m
  => (a -> m ())
  -> (b -> m ())
  -> (c -> m ())
  -> (a, b, c)
  -> m ()
putTuple3' putA putB putC (a, b, c) = putA a *> putB b *> putC c

getTuple3 :: MonadGet m => m a -> m b -> m c -> m (a,b,c)
getTuple3 = liftA3 (,,)

putRelation :: MonadPut m => (a -> m ()) -> (b -> m ()) -> Relation a b -> m ()
putRelation putA putB r = putFoldable (putPair putA putB) (Relation.toList r)

getRelation :: (MonadGet m, Ord a, Ord b) => m a -> m b -> m (Relation a b)
getRelation getA getB = Relation.fromList <$> getList (getPair getA getB)

putMap :: MonadPut m => (a -> m ()) -> (b -> m ()) -> Map a b -> m ()
putMap putA putB m = putFoldable (putPair putA putB) (Map.toList m)

getMap :: (MonadGet m, Ord a) => m a -> m b -> m (Map a b)
getMap getA getB = Map.fromList <$> getList (getPair getA getB)

putTermEdit :: MonadPut m => TermEdit -> m ()
putTermEdit (TermEdit.Replace r typing) =
  putWord8 1 *> putReference r *> case typing of
    TermEdit.Same -> putWord8 1
    TermEdit.Subtype -> putWord8 2
    TermEdit.Different -> putWord8 3
putTermEdit TermEdit.Deprecate = putWord8 2

getTermEdit :: MonadGet m => m TermEdit
getTermEdit = getWord8 >>= \case
  1 -> TermEdit.Replace <$> getReference <*> (getWord8 >>= \case
    1 -> pure TermEdit.Same
    2 -> pure TermEdit.Subtype
    3 -> pure TermEdit.Different
    t -> unknownTag "TermEdit.Replace" t
    )
  2 -> pure TermEdit.Deprecate
  t -> unknownTag "TermEdit" t

putTypeEdit :: MonadPut m => TypeEdit -> m ()
putTypeEdit (TypeEdit.Replace r) = putWord8 1 *> putReference r
putTypeEdit TypeEdit.Deprecate = putWord8 2

getTypeEdit :: MonadGet m => m TypeEdit
getTypeEdit = getWord8 >>= \case
  1 -> TypeEdit.Replace <$> getReference
  2 -> pure TypeEdit.Deprecate
  t -> unknownTag "TypeEdit" t

putBranch0 :: MonadPut m => Branch0 n -> m ()
putBranch0 b = do
  putRelation putNameSegment putReferent (Branch._terms b)
  putRelation putNameSegment putReference (Branch._types b)
  putFoldable (putPair putNameSegment (putHash . unc0hash . fst))
              (Map.toList (Branch._children b))

-- getBranch0 :: MonadGet m => m (Branch00)

putLink :: MonadPut m => (Hash, mb) -> m ()
putLink (h, _) = do
  -- 0 means local; later we may have remote links with other ids
  putWord8 0
  putHash h

putName :: MonadPut m => Name -> m ()
putName = putText . Name.toText

getName :: MonadGet m => m Name
getName = Name.unsafeFromText <$> getText

putNameSegment :: MonadPut m => NameSegment -> m ()
putNameSegment = putText . NameSegment.toText

getNameSegment :: MonadGet m => m NameSegment
getNameSegment = NameSegment <$> getText

putRawBranch :: MonadPut m => Branch.Raw -> m ()
putRawBranch (Branch.Raw terms types children) =
  putRelation putNameSegment putReferent terms >>
  putRelation putNameSegment putReference types >>
  putMap putNameSegment (putHash . unc0hash) children

getRawBranch :: MonadGet m => m Branch.Raw
getRawBranch =
  Branch.Raw
    <$> getRelation getNameSegment getReferent
    <*> getRelation getNameSegment getReference
    <*> getMap getNameSegment (C0Hash <$> getHash)

putDataDeclaration :: (MonadPut m, Ord v)
                   => (v -> m ()) -> (a -> m ())
                   -> DataDeclaration' v a
                   -> m ()
putDataDeclaration putV putA decl = do
  putModifier $ DataDeclaration.modifier decl
  putA $ DataDeclaration.annotation decl
  putFoldable putV (DataDeclaration.bound decl)
  putFoldable (putTuple3' putA putV (putType putV putA)) (DataDeclaration.constructors' decl)

getDataDeclaration :: (MonadGet m, Ord v) => m v -> m a -> m (DataDeclaration' v a)
getDataDeclaration getV getA = DataDeclaration.DataDeclaration <$>
  getModifier <*>
  getA <*>
  getList getV <*>
  getList (getTuple3 getA getV (getType getV getA))

putModifier :: MonadPut m => DataDeclaration.Modifier -> m ()
putModifier DataDeclaration.Structural   = putWord8 0
putModifier (DataDeclaration.Unique txt) = putWord8 1 *> putText txt

getModifier :: MonadGet m => m DataDeclaration.Modifier
getModifier = getWord8 >>= \case
  0 -> pure DataDeclaration.Structural
  1 -> DataDeclaration.Unique <$> getText
  tag -> unknownTag "DataDeclaration.Modifier" tag

putEffectDeclaration ::
  (MonadPut m, Ord v) => (v -> m ()) -> (a -> m ()) -> EffectDeclaration' v a -> m ()
putEffectDeclaration putV putA (DataDeclaration.EffectDeclaration d) =
  putDataDeclaration putV putA d

getEffectDeclaration :: (MonadGet m, Ord v) => m v -> m a -> m (EffectDeclaration' v a)
getEffectDeclaration getV getA =
  DataDeclaration.EffectDeclaration <$> getDataDeclaration getV getA

putEither :: (MonadPut m) => (a -> m ()) -> (b -> m ()) -> Either a b -> m ()
putEither putL _ (Left a) = putWord8 0 *> putL a
putEither _ putR (Right b) = putWord8 1 *> putR b

getEither :: MonadGet m => m a -> m b -> m (Either a b)
getEither getL getR = getWord8 >>= \case
  0 -> Left <$> getL
  1 -> Right <$> getR
  tag -> unknownTag "Either" tag

formatSymbol :: S.Format Symbol
formatSymbol = S.Format getSymbol putSymbol
