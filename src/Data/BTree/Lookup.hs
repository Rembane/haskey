{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}

module Data.BTree.Lookup where

import Data.BTree.Alloc.Class
import Data.BTree.Primitives

import qualified Data.Map as M

--------------------------------------------------------------------------------

lookupRec :: forall m height key val. (AllocM m, Key key, Value val)
    => key
    -> Height height
    -> NodeId height key val
    -> m (Maybe val)
lookupRec k = fetchAndGo
  where
    fetchAndGo :: forall hgt.
        Height hgt ->
        NodeId hgt key val ->
        m (Maybe val)
    fetchAndGo hgt nid =
        readNode hgt nid >>= go hgt

    go :: forall hgt.
        Height hgt ->
        Node hgt key val ->
        m (Maybe val)
    go hgt (Idx children) = do
        let (_ctx,childId) = valView k children
        fetchAndGo (decrHeight hgt) childId
    go _hgt (Leaf items) =
        return $! M.lookup k items

--------------------------------------------------------------------------------

lookupTree :: forall m key val. (AllocM m, Key key, Value val)
    => key
    -> Tree key val
    -> m (Maybe val)
lookupTree k tree
    | Tree
      { treeHeight = height
      , treeRootId = Just rootId
      } <- tree
    = lookupRec k height rootId
    | Tree
      { treeRootId = Nothing
      } <- tree
    = return Nothing

--------------------------------------------------------------------------------