{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module Unison.Codebase.Branch2 where

-- import qualified Unison.Codebase.Branch as Branch

import           Prelude                  hiding (head,read,subtract)

import           Control.Lens            hiding ( children )
--import           Control.Monad.Extra            ( whenM )
-- import           Data.GUID                (genText)
--import           Data.List                      ( intercalate )
import qualified Data.Map                      as Map
import           Data.Map                       ( Map )
import           Data.Text                      ( Text )
--import qualified Data.Text                     as Text
import           Data.Foldable                  ( for_ )
import qualified Unison.Codebase.Causal2       as Causal
import           Unison.Codebase.Causal2        ( Causal
                                                , Causal0(..)
                                                )
--import           Unison.Codebase.TermEdit       ( TermEdit )
--import           Unison.Codebase.TypeEdit       ( TypeEdit )
import           Unison.Codebase.Path           ( NameSegment
                                                , Path(Path)
                                                )
import qualified Unison.Codebase.Path          as Path
--import           Unison.Hash                    ( Hash )
import           Unison.Hashable                ( Hashable )
import qualified Unison.Hashable               as H
import           Unison.Reference               ( Reference )
import           Unison.Referent                ( Referent )
import qualified Unison.Util.Relation          as R
import           Unison.Util.Relation           ( Relation )

data RepoRef
  = Local
  | Github { username :: Text, repo :: Text, commit :: Text }
  deriving (Eq, Ord, Show)

-- type EditGuid = Text
data RepoLink a = RepoLink RepoRef a
  deriving (Eq, Ord, Show)

newtype Branch m = Branch { _history :: Causal m Raw (Branch0 m) }
  deriving (Eq, Ord)

head :: Branch m -> Branch0 m
head (Branch c) = Causal.head c

headHash :: Branch m -> Hash
headHash (Branch c) = Causal.currentHash c

type Hash = Causal.C0Hash Raw

data Branch0 m = Branch0
  { _terms :: Relation NameSegment Referent
  , _types :: Relation NameSegment Reference
  -- Q: How will we handle merges and conflicts for `children`?
  --    Should this be a relation?
  --    What is the UX to resolve conflicts?
  -- The hash we use to identify branches is the hash of their Causal node.
  , _children :: Map NameSegment (Hash, Branch m)
  }

-- The raw Branch
data Raw = Raw
  { _termsR :: Relation NameSegment Referent
  , _typesR :: Relation NameSegment Reference
  , _childrenR :: Map NameSegment Hash
  }

makeLenses ''Raw
makeLenses ''Branch0
makeLenses ''Branch

instance Eq (Branch0 m) where
  a == b = view terms a == view terms b
        && view types a == view types b
        && view children a == view children b

data ForkFailure = SrcNotFound | DestExists

-- Question: How does Deserialize throw a not-found error?

read
  :: forall m
   . Monad m
  => Causal.Deserialize m Raw Raw
  -> Hash
  -> m (Branch m)
read deserializeRaw h = Branch <$> Causal.read d h
 where
  fromRaw :: Raw -> m (Branch0 m)
  fromRaw Raw {..} = Branch0 _termsR _typesR <$> (traverse go _childrenR)
  go h = (h, ) <$> read deserializeRaw h
  d :: Causal.Deserialize m Raw (Branch0 m)
  d h = deserializeRaw h >>= \case
    One0 raw      -> One0 <$> fromRaw raw
    Cons0  raw h  -> flip Cons0 h <$> fromRaw raw
    Merge0 raw hs -> flip Merge0 hs <$> fromRaw raw

-- serialize a `Branch m` indexed by the hash of its corresponding Raw
sync :: forall m. Monad m
     => (Hash -> m Bool)
     -> Causal.Serialize m Raw Raw
     -> Branch m
     -> m ()
sync exists serializeRaw b = do
  for_ (view children (head b)) (sync exists serializeRaw . snd)
  Causal.sync exists serialize0 (view history b)
  where
  toRaw :: Branch0 m -> Raw
  toRaw Branch0{..} = Raw _terms _types (fst <$> _children)
  serialize0 :: Causal.Serialize m Raw (Branch0 m)
  serialize0 h = \case
    One0 b0 -> serializeRaw h $ One0 (toRaw b0)
    Cons0 b0 h -> serializeRaw h $ Cons0 (toRaw b0) h
    Merge0 b0 hs -> serializeRaw h $ Merge0 (toRaw b0) hs

  -- this has to serialize the branch0 and its descendants in the tree,
  -- and then serialize the rest of the history of the branch as well



-- copy a path to another path
fork
  :: Monad m
  => Branch m
  -> Path
  -> Path
  -> m (Either ForkFailure (Branch m))
fork root src dest = do
  -- descend from root to src to get a Branch srcBranch
  getAt root src >>= \case
    Nothing -> pure $ Left SrcNotFound
    Just src' -> setIfNotExists root dest src' >>= \case
      Nothing -> pure $ Left DestExists
      Just root' -> pure $ Right root'

-- Move the node at src to dest.
-- It's okay if `dest` is inside `src`, just create empty levels.
-- Try not to `step` more than once at each node.
move :: Monad m
     => Branch m
     -> Path
     -> Path
     -> m (Either ForkFailure (Branch m))
move root src dest = do
  getAt root src >>= \case
    Nothing -> pure $ Left SrcNotFound
    Just src' ->
      -- make sure dest doesn't already exist
      getAt root dest >>= \case
        Just _destExists -> pure $ Left DestExists
        Nothing ->
        -- find and update common ancestor of `src` and `dest`:
          Right <$> modifyAtM root ancestor go
          where
          (ancestor, relSrc, relDest) = Path.relativeToAncestor src dest
          go b = do
            b <- setAt b relDest src'
            deleteAt b relSrc
            -- todo: can we combine these into one update?

setIfNotExists
  :: Monad m => Branch m -> Path -> Branch m -> m (Maybe (Branch m))
setIfNotExists root dest b =
  getAt root dest >>= \case
    Just _destExists -> pure Nothing
    Nothing -> Just <$> setAt root dest b

setAt :: Monad m => Branch m -> Path -> Branch m -> m (Branch m)
setAt root dest b = modifyAt root dest (const b)

deleteAt :: Monad m => Branch m -> Path -> m (Branch m)
deleteAt root path = modifyAt root path $ const empty


-- returns `Nothing` if no Branch at `path`
getAt :: Monad m
      => Branch m
      -> Path
      -> m (Maybe (Branch m))
-- todo: return Nothing if exists but is empty
getAt root path = case Path.toList path of
  [] -> pure $ Just root
  seg : path -> case Map.lookup seg (_children $ head root) of
    Nothing -> pure Nothing
    Just (_h, b) -> getAt b (Path path)

empty :: Branch m
empty = Branch $ Causal.one empty0

empty0 :: Branch0 m
empty0 = Branch0 mempty mempty mempty

isEmpty :: Branch0 m -> Bool
isEmpty = (== empty0)

-- Modify the branch0 at the head of at `path` with `f`,
-- after creating it if necessary.  Preserves history.
stepAt :: Monad m
       => Branch m
       -> Path
       -> (Branch0 m -> Branch0 m)
       -> m (Branch m)
stepAt b path f = stepAtM b path (pure . f)

-- Modify the branch0 at the head of at `path` with `f`,
-- after creating it if necessary.  Preserves history.
stepAtM
  :: Monad m => Branch m -> Path -> (Branch0 m -> m (Branch0 m)) -> m (Branch m)
stepAtM b path f =
  modifyAtM b path (fmap Branch . Causal.stepM f . view history)

-- Modify the Branch at `path` with `f`, after creating it if necessary.
-- Because it's a `Branch`, it overwrites the history at `path`.
modifyAt :: Monad m
  => Branch m -> Path -> (Branch m -> Branch m) -> m (Branch m)
modifyAt b path f = modifyAtM b path (pure . f)

-- Modify the Branch at `path` with `f`, after creating it if necessary.
-- Because it's a `Branch`, it overwrites the history at `path`.
modifyAtM
  :: Monad m
  => Branch m
  -> Path
  -> (Branch m -> m (Branch m))
  -> m (Branch m)
modifyAtM b path f = case Path.toList path of
  [] -> f b
  seg : path ->
    let recurse b@(Branch c) = do
          b' <- modifyAtM b (Path path) f
          let c' = flip Causal.step c . over children $ if isEmpty (head b')
                then Map.delete seg
                else Map.insert seg (headHash b', b')
          pure (Branch c')
    in  case Map.lookup seg (_children $ head b) of
          Nothing -> recurse empty
          Just (_h, b)  -> recurse b

instance Hashable (Branch0 m) where
  tokens b =
    [ H.accumulateToken . R.toList $ (_terms b)
    , H.accumulateToken . R.toList $ (_types b)
    , H.accumulateToken (fst <$> _children b)
    ]

-- getLocalBranch :: Hash -> IO Branch
-- getGithubBranch :: RemotePath -> IO Branch
-- getLocalEdit :: GUID -> IO Edits

-- makeLenses ''Namespace
-- makeLenses ''Edits
