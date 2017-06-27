{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Data.BTree.Primitives.Index where

import           Data.BTree.Internal

import           Control.Applicative ((<$>))
import           Control.Monad.Identity (runIdentity)

import qualified Data.ByteString.Lazy as BL
import           Data.Binary (Binary, encode)
import           Data.Foldable (Foldable)
import qualified Data.Map as M
import           Data.Traversable (Traversable)
import           Data.Monoid
import           Data.Vector (Vector)
import qualified Data.Vector as V
import           Data.Vector.Binary ()

import GHC.Generics (Generic)

--------------------------------------------------------------------------------

{-| The 'Index' encodes the internal structure of an index node.

    The index is abstracted over the type 'node' of sub-trees. The keys and
    nodes are stored in separate 'Vector's and the keys are sorted in strictly
    increasing order. There should always be one more sub-tree than there are
    keys. Hence structurally the smallest 'Index' has one sub-tree and no keys,
    but a valid B+-tree index node will have at least two sub-trees and one key.
 -}
data Index key node = Index !(Vector key) !(Vector node)
  deriving (Eq, Functor, Foldable, Generic, Show, Traversable)

instance (Binary k, Binary n) => Binary (Index k n) where

{-| Return the number of keys in this 'Index.
-}
indexNumKeys :: Index key val -> Int
indexNumKeys (Index keys _vals) = V.length keys

{-| Return the number of values stored in this 'Index.
-}
indexNumVals :: Index key val -> Int
indexNumVals (Index _keys vals) = V.length vals

{-| Validate the key/node count invariant of an index.  -}
validIndex :: Ord key => Index key node -> Bool
validIndex (Index keys nodes) =
    V.length keys + 1 == V.length nodes &&
    isStrictlyIncreasing keys

{-| Validate the size of an index. -}
validIndexSize :: Ord key => Int -> Int -> Index key node -> Bool
validIndexSize minIdxKeys maxIdxKeys idx@(Index keys _) =
    validIndex idx && V.length keys >= minIdxKeys && V.length keys <= maxIdxKeys

{-| Split an index node.

    This function splits an index node into two new nodes at the given key
    position @numLeftKeys@ and returns the resulting indices and the key
    separating them. Eventually this should take the binary size of serialized
    keys and sub-tree pointers into account. See also 'splitLeaf' in
    "Data.BTree.Primitives.Leaf".
-}
splitIndexAt :: Int -> Index key val -> (Index key val, key, Index key val)
splitIndexAt numLeftKeys (Index keys vals)
    | (leftKeys, middleKeyAndRightKeys) <- V.splitAt numLeftKeys     keys
    , (leftVals, rightVals)             <- V.splitAt (numLeftKeys+1) vals
    = case vecUncons middleKeyAndRightKeys of
        Just (middleKey,rightKeys) ->
            (Index leftKeys leftVals, middleKey, Index rightKeys rightVals)
        Nothing -> error "splitIndex: empty Index"

{-| Split an index many times.

    This function splits an 'Index' node into smaller pieces. Each resulting
    sub-'Index' has between @maxIdxKeys/2@ and @maxIdxKeys@ inclusive values and
    is additionally applied to the function @f@.

    This is the dual of a monadic bind and is also known as the `extended`
    function of extendable functors. See "Data.Functor.Extend" in the
    "semigroupoids" package.

    prop> bindIndex (extendedIndex n id idx) id == idx
-}
extendedIndex :: Int -> (Index k b -> a) -> Index k b -> Index k a
extendedIndex maxIdxKeys f = go
  where
    maxIdxVals = maxIdxKeys + 1

    go index
        | numVals <= maxIdxVals
        = singletonIndex (f index)
        | numVals <= 2*maxIdxVals
        = case splitIndexAt (div numVals 2 - 1) index of
            (leftIndex, middleKey, rightIndex) ->
                indexFromList [middleKey] [f leftIndex, f rightIndex]
        | otherwise
        = case splitIndexAt maxIdxKeys index of
            (leftIndex, middleKey, rightIndex) ->
              mergeIndex (singletonIndex (f leftIndex))
                middleKey (go rightIndex)
      where
        numVals = indexNumVals index

extendIndexPred :: (a -> Bool) ->
  (Index k b -> a) -> Index k b -> Maybe (Index k a)
extendIndexPred p f = go
  where
    go index
        | let indexEnc = f index
        , p indexEnc
        = Just (singletonIndex indexEnc)
        | otherwise
        = do
            let numKeys = indexNumKeys index
            (leftEnc, (middleKey, right)) <- safeLast $
                takeWhile (p . fst)
                [ (leftEnc, (middleKey, right))
                | i <- [1..numKeys-1]
                , let (left,middleKey,right) = splitIndexAt i index
                      leftEnc                = f left
                ]
            rightEnc <- go right
            return $! mergeIndex (singletonIndex leftEnc) middleKey rightEnc

extendIndexBinary :: Binary a
    => Int
    -> (Index k b -> a)
    -> Index k b
    -> Maybe (Index k a)
extendIndexBinary maxSize =
    extendIndexPred (\n -> BL.length (encode n) <= fromIntegral maxSize)

{-| Merge two indices.

    Merge two indices 'leftIndex', 'rightIndex' given a discriminating key
    'middleKey', i.e. such that '∀ (k,v) ∈ leftIndex. k < middleKey' and
    '∀ (k,v) ∈ rightIndex. middleKey <= k'.

    'mergeIndex' is a partial inverse of splitIndex, i.e.
    prop> splitIndex is == (left,mid,right) => mergeIndex left mid right == is
-}
mergeIndex :: Index key val -> key -> Index key val -> Index key val
mergeIndex (Index leftKeys leftVals) middleKey (Index rightKeys rightVals) =
    Index
      (leftKeys <> V.singleton middleKey <> rightKeys)
      (leftVals <> rightVals)

{-| Create an index from key-value lists.

    The internal invariants of the 'Index' data structure apply. That means
    there is one more value than there are keys and keys are ordered in strictly
    increasing order.
-}
indexFromList :: [key] -> [val] -> Index key val
indexFromList ks vs = Index (V.fromList ks) (V.fromList vs)

{-| Create an index with a single value.
-}
singletonIndex :: val -> Index key val
singletonIndex = Index V.empty . V.singleton

{-| Test if the index consists of a single value.

    Returns the element if the index is a singleton. Otherwise fails.

    prop> fromSingletonIndex (singletonIndex val) == Just val
-}
fromSingletonIndex :: Index key val -> Maybe val
fromSingletonIndex (Index _keys vals) =
    if V.length vals == 1 then Just $! V.unsafeHead vals else Nothing

--------------------------------------------------------------------------------

{-| Bind an index

    prop> bindIndex idx singletonIndex == idx
-}
bindIndex :: Index k a -> (a -> Index k b) -> Index k b
bindIndex idx f = runIdentity $ bindIndexM idx (return . f)

bindIndexM :: (Functor m, Monad m)
    => Index k a
    -> (a -> m (Index k b))
    -> m (Index k b)
bindIndexM (Index ks vs) f = case vecUncons vs of
    Just (v, vtail) -> do
        i <- f v
        V.foldM' g i (V.zip ks vtail)
      where
        g acc (k , w) = mergeIndex acc k <$> f w
    Nothing ->
        error "bindIndexM: empty Index"

--------------------------------------------------------------------------------

{-| Representation of one-hole contexts of 'Index'.

    Just one val removes. All keys are present.

    V.length leftVals  == V.length lefyKeys
    V.length rightVals == V.length rightKeys
-}
data IndexCtx key val = IndexCtx
    { indexCtxLeftKeys  :: !(Vector key)
    , indexCtxRightKeys :: !(Vector key)
    , indexCtxLeftVals  :: !(Vector val)
    , indexCtxRightVals :: !(Vector val)
    }
  deriving (Functor, Foldable, Show, Traversable)

putVal :: IndexCtx key val -> val -> Index key val
putVal ctx val =
    Index
      (indexCtxLeftKeys ctx <> indexCtxRightKeys ctx)
      (indexCtxLeftVals ctx <> V.singleton val <> indexCtxRightVals ctx)

putIdx :: IndexCtx key val -> Index key val -> Index key val
putIdx ctx (Index keys vals) =
    Index
      (indexCtxLeftKeys ctx <> keys <> indexCtxRightKeys ctx)
      (indexCtxLeftVals ctx <> vals <> indexCtxRightVals ctx)

valView :: Ord key => key -> Index key val -> (IndexCtx key val, val)
valView key (Index keys vals)
    | (leftKeys,rightKeys)       <- V.span (<=key) keys
    , n                          <- V.length leftKeys
    , (leftVals,valAndRightVals) <- V.splitAt n vals
    , Just (val,rightVals)       <- vecUncons valAndRightVals
    = ( IndexCtx
        { indexCtxLeftKeys  = leftKeys
        , indexCtxRightKeys = rightKeys
        , indexCtxLeftVals  = leftVals
        , indexCtxRightVals = rightVals
        },
        val
      )
    | otherwise
    = error "valView: empty Index"

{-| Distribute a map of key-value pairs over an index. -}
distribute :: Ord k => M.Map k v -> Index k node -> Index k (M.Map k v, node)
distribute kvs (Index keys nodes)
    | a <- V.imap rangeTail          (Nothing `V.cons` V.map Just keys)
    , b <- V.map (uncurry rangeHead) (V.zip (V.map Just keys `V.snoc` Nothing) a)
    = Index keys b
  where
    rangeTail idx Nothing    = (kvs, nodes V.! idx)
    rangeTail idx (Just key) = (takeWhile' (>= key) kvs, nodes V.! idx)
    rangeHead Nothing (tail', node)    = (tail', node)
    rangeHead (Just key) (tail', node)  = (takeWhile' (< key) tail', node)

    takeWhile' :: (k -> Bool) -> M.Map k v -> M.Map k v
    takeWhile' p = fst . M.partitionWithKey (\k _ -> p k)

leftView :: IndexCtx key val -> Maybe (IndexCtx key val, val, key)
leftView ctx = do
  (leftVals, leftVal) <- vecUnsnoc (indexCtxLeftVals ctx)
  (leftKeys, leftKey) <- vecUnsnoc (indexCtxLeftKeys ctx)
  return (ctx { indexCtxLeftKeys = leftKeys
              , indexCtxLeftVals = leftVals
              }, leftVal, leftKey)

rightView :: IndexCtx key val -> Maybe (key, val, IndexCtx key val)
rightView ctx = do
  (rightVal, rightVals) <- vecUncons (indexCtxRightVals ctx)
  (rightKey, rightKeys) <- vecUncons (indexCtxRightKeys ctx)
  return (rightKey, rightVal,
          ctx { indexCtxRightKeys = rightKeys
              , indexCtxRightVals = rightVals
              })

--------------------------------------------------------------------------------
