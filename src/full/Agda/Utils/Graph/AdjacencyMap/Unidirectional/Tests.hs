{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Properties for graph library.

module Agda.Utils.Graph.AdjacencyMap.Unidirectional.Tests (tests) where

import Prelude hiding (null)

#if __GLASGOW_HASKELL__ <= 708
import Control.Applicative ((<$>), (<*>))
#endif

import Data.Function
import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Test.QuickCheck.All

import Agda.Utils.Function (iterateUntil)
import Agda.Utils.Functor (for)
import Agda.Utils.Graph.AdjacencyMap.Unidirectional as Graph
import Agda.Utils.Null
import Agda.Utils.SemiRing
import Agda.Utils.QuickCheck as QuickCheck
import Agda.Utils.TestHelpers

------------------------------------------------------------------------
-- * Generating random graphs
------------------------------------------------------------------------

instance (Arbitrary s, Arbitrary t, Arbitrary e) => Arbitrary (Edge s t e) where
  arbitrary = Edge <$> arbitrary <*> arbitrary <*> arbitrary

instance (CoArbitrary s, CoArbitrary t, CoArbitrary e) => CoArbitrary (Edge s t e) where
  coarbitrary (Edge s t e) = coarbitrary s . coarbitrary t . coarbitrary e

instance (Ord n, SemiRing e, Arbitrary n, Arbitrary e) =>
         Arbitrary (Graph n n e) where
  arbitrary = do
    nodes <- sized $ \ n -> resize (isqrt n) arbitrary
    edges <- mapM (\ (n1, n2) -> Edge n1 n2 <$> arbitrary) =<<
                  listOfElements ((,) <$> nodes <*> nodes)
    return (fromList edges `union` fromNodes nodes)
    where
    isqrt :: Int -> Int
    isqrt = round . sqrt . fromIntegral

  shrink g =
    [ removeNode n g     | n <- Set.toList $ nodes g ] ++
    [ removeEdge n1 n2 g | Edge n1 n2 _ <- edges g ]

-- | Generates a node from the graph. (Unless the graph is empty.)

nodeIn :: (Ord n, Arbitrary n) => Graph n n e -> Gen n
nodeIn g = elementsUnlessEmpty (Set.toList $ nodes g)

-- | Generates an edge from the graph. (Unless the graph contains no
-- edges.)

edgeIn :: (Ord n, Arbitrary n, Arbitrary e) =>
          Graph n n e -> Gen (Edge n n e)
edgeIn g = elementsUnlessEmpty (edges g)

-- | Sample graph type used to test 'transitiveClosure' and 'transitiveClosure1'.

type G = Graph N N E

-- | Sample node type used to test 'transitiveClosure' and 'transitiveClosure1'.

newtype N = N (Positive Int)
  deriving (Arbitrary, Eq, Ord)

n :: Int -> N
n = N . Positive

instance Show N where
  show (N (Positive n)) = "n " ++ show n

-- | Sample edge type used to test 'transitiveClosure' and 'transitiveClosure1'.

newtype E = E Bool
  deriving (Arbitrary, CoArbitrary, Eq, Show)

instance SemiRing E where
  oplus  (E x) (E y) = E (x || y)
  otimes (E x) (E y) = E (x && y)

instance Null E where
  empty = E False -- neutral for oplus

------------------------------------------------------------------------
-- * Graph properties
------------------------------------------------------------------------

-- prop_neighbours :: (Ord s, Ord t, Eq e) => s -> Graph s t e -> Bool
prop_neighbours :: N -> G -> Bool
prop_neighbours s g =
  neighbours s g == map (\ (Edge s t e) -> (t, e)) (edgesFrom g [s])

-- prop_nodes_fromNodes :: Ord n => [n] -> Bool
prop_nodes_fromNodes :: [N] -> Bool
prop_nodes_fromNodes ns = sourceNodes (fromNodes ns) == Set.fromList ns

prop_clean_discrete :: G -> Bool
prop_clean_discrete g =
  discrete g == (null . graph . clean) g

-- prop_insertWith :: (Eq e, Ord s, Ord t) =>
--                    (e -> e -> e) -> s -> t -> e -> Graph s t e -> Bool
prop_insertWith :: (E -> E -> E) -> N -> N -> E -> G -> Bool
prop_insertWith f s t e g =
  insertWith f s t e g == unionWith (flip f) g (singleton s t e)

-- -- This property only holds only if the edge is new.
-- prop_insert ::  (Ord s, Ord t) => s -> t -> e -> Graph s t e -> Bool
-- prop_insert s t e g = insert s t e g == union g (singleton s t e)

-- | Computes the transitive closure of the graph.
--
-- Note that this algorithm is not guaranteed to be correct (or
-- terminate) for arbitrary semirings.
--
-- This function operates on the entire graph at once.

transitiveClosure1 :: (Eq e, SemiRing e, Ord n) =>
                      Graph n n e -> Graph n n e
transitiveClosure1 = completeUntilWith (==) otimes oplus

-- | Computes the transitive closure of the graph.
--
-- Note that this algorithm is not guaranteed to be correct (or
-- terminate) for arbitrary semirings.
--
-- This function operates on the entire graph at once.

completeUntilWith :: (Ord n) => (Graph n n e -> Graph n n e -> Bool) ->
  (e -> e -> e) -> (e -> e -> e) -> Graph n n e -> Graph n n e
completeUntilWith done otimes oplus = iterateUntil done growGraph  where

  -- @growGraph g@ unions @g@ with @(s --> t) `compose` g@ for each
  -- edge @s --> t@ in @g@
  growGraph g = List.foldl' (unionWith oplus) g $ for (edges g) $ \ (Edge s t e) ->
    case Map.lookup t (graph g) of
      Just es -> Graph $ Map.singleton s $ Map.map (otimes e) es
      Nothing -> Graph.empty


-- | Correctness of the optimized algorithm that proceeds by SCC.

-- prop_transitiveClosure :: (Eq e, SemiRing e, Ord n) => Graph n n e -> Property
prop_transitiveClosure :: G -> Property
prop_transitiveClosure g = QuickCheck.label sccInfo $
  transitiveClosure g == transitiveClosure1 g
  where
  sccInfo =
    (if noSCCs <= 3 then "   " ++ show noSCCs
                    else ">= 4") ++
    " strongly connected component(s)"
    where noSCCs = length (sccs g)

-- | Equality modulo empty edges.
(~~) :: (Eq e, Ord s, Ord t, Null e) => Graph s t e -> Graph s t e -> Bool
(~~) = (==) `on` clean

-- prop_complete :: (Null e, Eq e, SemiRing e, Ord n) => Graph n n e -> Property
prop_complete :: G -> Bool
prop_complete g =
  complete g ~~ transitiveClosure1 g

------------------------------------------------------------------------
-- * All tests
------------------------------------------------------------------------

-- Template Haskell hack to make the following $quickCheckAll work
-- under ghc-7.8.
return [] -- KEEP!

-- | All tests as collected by 'quickCheckAll'.
--
--   Using 'quickCheckAll' is convenient and superior to the manual
--   enumeration of tests, since the name of the property is
--   added automatically.

tests :: IO Bool
tests = do
  putStrLn "Agda.Utils.Graph.AdjacencyMap.Unidirectional"
  $quickCheckAll


-- Abbreviations for testing in interpreter

tc :: (Eq e, Ord n, SemiRing e) => Graph n n e -> Graph n n e
tc = transitiveClosure

g1, g2, g3, g4 :: Graph N N E
g1 = Graph $ Map.fromList
  [ (n 1, Map.fromList [(n 2,E False)])
  , (n 2, Map.fromList [(n 1,E False)])
  ]

g2 = Graph $ Map.fromList
  [ (n 1, Map.fromList [(n 2,E True)])
  , (n 2, Map.fromList [(n 1,E True)])
  ]

g3 = Graph $ Map.fromList
  [ (n 1, Map.fromList [(n 2,E True)])
  , (n 2, Map.fromList [])
  , (n 4, Map.fromList [(n 1,E True)])
  ]

g4 = Graph $ Map.fromList
  [ (n 1, Map.fromList [(n 6,E False)])
  , (n 6, Map.fromList [(n 8,E True )])
   ,(n 8, Map.fromList [(n 3,E False)])
  ]
