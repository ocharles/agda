{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

{- | Sparse matrices.

We assume the matrices to be very sparse, so we just implement them as
sorted association lists.

Most operations are linear in the number of non-zero elements.

An exception is transposition, which needs to sort the association
list again; it has the complexity of sorting: @n log n@ where @n@ is
the number of non-zero elements.

Another exception is matrix multiplication, of course.

 -}

module Agda.Termination.SparseMatrix
  ( -- * Basic data types
    Matrix
  , matrixInvariant
  , Size(..)
  , sizeInvariant
  , MIx (..)
  , mIxInvariant
    -- * Generating and creating matrices
  , fromLists
  , fromIndexList
  , toLists
--  , Agda.Termination.Matrix.zipWith
  , matrix
  , matrixUsingRowGen
    -- * Combining and querying matrices
  , size
  , square
  , isEmpty
  , isSingleton
  , zipMatrices
  , add, intersectWith
  , mul
  , transpose
  , Diagonal(..)
    -- * Modifying matrices
  , addRow
  , addColumn
    -- * Tests
  , Agda.Termination.SparseMatrix.tests
  ) where

import Data.Array
import Data.Function
import qualified Data.List as List
import Data.Maybe

import Data.Foldable (Foldable)
import Data.Traversable (Traversable)

import qualified Text.PrettyPrint.Boxes as Boxes

import Agda.Termination.Semiring (HasZero(..), Semiring)
import qualified Agda.Termination.Semiring as Semiring

import Agda.Utils.Functor
import Agda.Utils.List
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Pretty hiding (isEmpty)
import Agda.Utils.QuickCheck
import Agda.Utils.TestHelpers
import Agda.Utils.Tuple

#include "undefined.h"
import Agda.Utils.Impossible

------------------------------------------------------------------------
-- * Basic data types
------------------------------------------------------------------------

-- | Size of a matrix.

data Size i = Size
  { rows :: i  -- ^ Number of rows,    @>= 0@.
  , cols :: i  -- ^ Number of columns, @>= 0@.
  }
  deriving (Eq, Ord, Show)

-- | Type of matrix indices (row, column).

data MIx i = MIx
  { row :: i  -- ^ Row index,   @1 <= row <= rows@.
  , col :: i  -- ^ Column index @1 <= col <= cols@.
  }
  deriving (Eq, Ord, Show, Ix)

-- | Convert a 'Size' to a set of bounds suitable for use with
--   the matrices in this module.

toBounds :: Num i => Size i -> (MIx i, MIx i)
toBounds sz = (MIx { row = 1, col = 1 }, MIx { row = rows sz, col = cols sz })

-- | Type of matrices, parameterised on the type of values.
--
--   Sparse matrices are implemented as an ordered association list,
--   mapping coordinates to values.

data Matrix i b = Matrix
  { size :: Size i        -- ^ Dimensions of the matrix.
  , unM  :: [(MIx i, b)]  -- ^ Association of indices to values.
  }
  deriving (Eq, Ord, Functor, Foldable, Traversable)

------------------------------------------------------------------------
-- * Operations and query on matrix size.
------------------------------------------------------------------------

-- | 'True' iff the matrix is square.

square :: Ix i => Matrix i b -> Bool
square m = rows (size m) == cols (size m)

-- | Returns 'True' iff the matrix is empty.

isEmpty :: (Num i, Ix i) => Matrix i b -> Bool
isEmpty m = rows sz <= 0 || cols sz <= 0
  where sz = size m

-- | Compute the matrix size of the union of two matrices.

supSize :: Ord i => Matrix i a -> Matrix i b -> Size i
supSize (Matrix (Size r1 c1) _) (Matrix (Size r2 c2) _) =
  Size (max r1 r2) (max c1 c2)

-- | Compute the matrix size of the intersection of two matrices.

infSize :: Ord i => Matrix i a -> Matrix i b -> Size i
infSize (Matrix (Size r1 c1) _) (Matrix (Size r2 c2) _) =
  Size (min r1 r2) (min c1 c2)

------------------------------------------------------------------------
-- * Creating matrices and converging to lists.
------------------------------------------------------------------------

-- | Constructs a matrix from a list of @(index, value)@-pairs.
--   @O(n)@ where @n@ is size of the list.
--
--   Precondition: indices are unique.

fromIndexList :: (Ord i, HasZero b) => Size i -> [(MIx i, b)] -> Matrix i b
fromIndexList sz = Matrix sz
                 . List.sortBy (compare `on` fst)
                 . filter ((zeroElement /=) . snd)

-- | @'fromLists' sz rs@ constructs a matrix from a list of lists of
--   values (a list of rows).
--   @O(size)@ where @size = rows × cols@.
--
--   Precondition:
--   @'length' rs '==' 'rows' sz@ and
--   @'all' (('cols' sz '==') . 'length') rs@.

fromLists :: (Ord i, Num i, Enum i, HasZero b) => Size i -> [[b]] -> Matrix i b
fromLists sz bs = fromIndexList sz $ zip ([ MIx i j | i <- [1..rows sz]
                                                    , j <- [1..cols sz]]) (concat bs)

-- | Converts a sparse matrix to a sparse list of rows.
--   @O(n)@ where @n@ is the number of non-zero entries of the matrix.
--
--   Only non-empty rows are generated.
--

toSparseRows :: (Eq i) => Matrix i b -> [(i,[(i,b)])]
toSparseRows (Matrix _ []) = []
toSparseRows (Matrix _ ((MIx i j, b) : m)) = aux i [(j,b)] m
  where aux i' []  [] = []
        aux i' row [] = [(i', reverse row)]
        aux i' row ((MIx i j, b) : m)
          | i' == i   = aux i' ((j,b):row) m
          | otherwise = (i', reverse row) : aux i [(j,b)] m

-- | Alternative implementation, serves as specification.

toSparseRows' :: (Eq i) => Matrix i b -> [(i,[(i,b)])]
toSparseRows' (Matrix _ m) =
  -- group list by row index
  for (List.groupBy ((==) `on` (row . fst)) m) $ \ ((MIx i j, b) : vs) ->
  -- turn each group into a sparse row
    (i, (j,b) : map (mapFst col) vs)

prop_toSparseRows :: TM -> Bool
prop_toSparseRows m = toSparseRows m == toSparseRows' m

-- | Turn a sparse vector into a vector by inserting a fixed element
--   at the missing positions.
--   @O(size)@ where @size@ is the dimension of the vector.

blowUpSparseVec :: (Integral i) => b -> i -> [(i,b)] -> [b]
blowUpSparseVec zero n l = aux 1 l
  where aux i []           = List.genericReplicate (n + 1 - i) zero
        aux i l@((j,b):l')
          | i > j || i > n = __IMPOSSIBLE__
          | i == j         = b    : aux (i + 1) l'
          | otherwise      = zero : aux (i + 1) l

-- Older implementation without replicate.
blowUpSparseVec' :: (Show i, Ord i, Num i, Enum i) => b -> i -> [(i,b)] -> [b]
blowUpSparseVec' zero n l = aux 1 l
  where aux i [] | i > n = []
                 | otherwise = zero : aux (i+1) []
        aux i ((j,b):l) | i <= n && j == i = b : aux (succ i) l
        aux i ((j,b):l) | i <= n && j >= i = zero : aux (succ i) ((j,b):l)
        aux i l = __IMPOSSIBLE__
          -- error $ "blowUpSparseVec (n = " ++ show n ++ ") aux i=" ++ show i ++ " j=" ++ show (fst (head l)) ++ " length l = " ++ show (length l)

-- | Converts a matrix to a list of row lists.
--   @O(size)@ where @size = rows × cols@.

toLists :: (Integral i, HasZero b) => Matrix i b -> [[b]]
toLists m@(Matrix size@(Size nrows ncols) _) =
    blowUpSparseVec emptyRow nrows $
      map (mapSnd (blowUpSparseVec zeroElement ncols)) $ toSparseRows m
  where
    emptyRow = List.genericReplicate ncols zeroElement

------------------------------------------------------------------------
-- * Combining and querying matrices
------------------------------------------------------------------------

-- | Returns 'Just b' iff it is a 1x1 matrix with just one entry 'b'.
--   @O(1)@.

isSingleton :: (Eq i, Num i, HasZero b) => Matrix i b -> Maybe b
isSingleton (Matrix (Size 1 1) [(_,b)]) = Just b
isSingleton (Matrix (Size 1 1) []     ) = Just zeroElement
isSingleton (Matrix (Size 1 1) _      ) = __IMPOSSIBLE__
isSingleton _ = Nothing

-- | @'diagonal' m@ extracts the diagonal of @m@.
--
--   For non-square matrices, the length of the diagonal is
--   the minimum of the dimensions of the matrix.

class Diagonal m e | m -> e where
  diagonal :: m -> [e]

-- | Diagonal of sparse matrix.
--
--   @O(n)@ where @n@ is the number of non-zero elements in the matrix.

instance (Integral i, HasZero b) => Diagonal (Matrix i b) b where
  diagonal (Matrix (Size r c) m) =
    blowUpSparseVec zeroElement (min r c) $
      mapMaybe (\ ((MIx i j), b) -> if i==j then Just (i,b) else Nothing) m

-- | Transposable things.

class Transpose a where
  transpose :: a -> a

-- | Size of transposed matrix.

instance Transpose (Size i) where
  transpose (Size n m) = Size m n

-- | Transposing coordinates.

instance Transpose (MIx i) where
  transpose (MIx i j) = MIx j i

-- | Matrix transposition.
--
--   @O(n log n)@ where @n@ is the number of non-zero elements in the matrix.

instance Ord i => Transpose (Matrix i b) where
  transpose (Matrix size m) =
    Matrix (transpose size) $
      List.sortBy (compare `on` fst) $
        map (mapFst transpose) m


-- | General pointwise combination function for association lists.
--   @O(n1 + n2)@ where @ni@ is the number of non-zero element in matrix @i@.
--
--   In @zipAssocWith fs gs f g h l l'@,
--
--   @fs@ is possibly more efficient version of
--   @'mapMaybe' (\ (i, a) -> (i,) <$> f a)@, and same for @gs@ and @g@.

zipAssocWith :: (Ord i)
  => ([(i,a)] -> [(i,c)]) -- ^ Only left map remaining.
  -> ([(i,b)] -> [(i,c)]) -- ^ Only right map remaining.
  -> (a -> Maybe c)       -- ^ Element only present in left map.
  -> (b -> Maybe c)       -- ^ Element only present in right map.
  -> (a -> b -> Maybe c)  -- ^ Element present in both maps.
  -> [(i,a)] -> [(i,b)] -> [(i,c)]
zipAssocWith fs gs f g h = merge
  where
    merge m1 [] = mapMaybe (\ (i, a) -> (i,) <$> f a) m1
    merge [] m2 = mapMaybe (\ (i, b) -> (i,) <$> g b) m2
    merge m1@((i,a):m1') m2@((j,b):m2') =
      case compare i j of
        LT -> mcons ((i,) <$> f a)   $ merge m1' m2
        GT -> mcons ((j,) <$> g b)   $ merge m1  m2'
        EQ -> mcons ((i,) <$> h a b) $ merge m1' m2'

-- | Instance of 'zipAssocWith' which keeps longer assoc lists.
--   @O(n1 + n2)@.

unionAssocWith  :: (Ord i)
  => (a -> Maybe c)       -- ^ Element only present in left map.
  -> (b -> Maybe c)       -- ^ Element only present in right map.
  -> (a -> b -> Maybe c)  -- ^ Element present in both maps.
  -> [(i,a)] -> [(i,b)] -> [(i,c)]
unionAssocWith f g h = zipAssocWith (map_ f) (map_ g) f g h
  where
    map_ f = mapMaybe (\ (i, a) -> (i,) <$> f a)

-- | General pointwise combination function for sparse matrices.
--   @O(n1 + n2)@.

zipMatrices :: forall a b c i . (Ord i)
  => (a -> c)       -- ^ Element only present in left matrix.
  -> (b -> c)       -- ^ Element only present in right matrix.
  -> (a -> b -> c)  -- ^ Element present in both matrices.
  -> (c -> Bool)    -- ^ Result counts as zero?
  -> Matrix i a -> Matrix i b -> Matrix i c
zipMatrices f g h zero m1 m2 = Matrix (supSize m1 m2) $
  unionAssocWith (drop0 . f) (drop0 . g) (\ a -> drop0 . h a) (unM m1) (unM m2)
  where
    drop0 = filterMaybe (not . zero)

-- | @'add' (+) m1 m2@ adds @m1@ and @m2@, using @(+)@ to add values.
--   @O(n1 + n2)@.
--
--   Returns a matrix of size @'supSize' m1 m2@.

add :: (Ord i, HasZero a) => (a -> a -> a) -> Matrix i a -> Matrix i a -> Matrix i a
add plus = zipMatrices id id plus (== zeroElement)

-- | @'intersectWith' f m1 m2@ build the pointwise conjunction @m1@ and @m2@.
--   Uses @f@ to combine non-zero values.
--   @O(n1 + n2)@.
--
--   Returns a matrix of size @infSize m1 m2@.

intersectWith :: (Ord i) => (a -> a -> a) -> Matrix i a -> Matrix i a -> Matrix i a
intersectWith f m1 m2 = Matrix (infSize m1 m2) $ interAssocWith f (unM m1) (unM m2)

-- | Association list intersection.
--   @O(n1 + n2)@.
--
--   @interAssocWith f l l' = { (i, f a b) | (i,a) ∈ l and (i,b) ∈ l' }@
--
--   Used to combine sparse matrices, it might introduce zero elements
--   if @f@ can return zero for non-zero arguments.

interAssocWith :: (Ord i) => (a -> a -> a) -> [(i,a)] -> [(i,a)] -> [(i,a)]
interAssocWith f [] m = []
interAssocWith f l [] = []
interAssocWith f l@((i,a):l') m@((j,b):m')
    | i < j = interAssocWith f l' m
    | i > j = interAssocWith f l m'
    | otherwise = (i, f a b) : interAssocWith f l' m'

interAssocWith2 :: (Ord i, HasZero a) => (a -> a -> a) -> [(i,a)] -> [(i,a)] -> [(i,a)]
interAssocWith2 f = zipAssocWith (const []) (const []) (const Nothing) (const Nothing) (\ a -> Just . f a)

prop_interAssocWith_correct2 :: [(Int,Int)] -> [(Int,Int)] -> Bool
prop_interAssocWith_correct2 xs ys =
  interAssocWith (*) xs ys == interAssocWith2 (*) xs ys
  where
    l  = List.sortBy (compare `on` fst) xs
    l' = List.sortBy (compare `on` fst) ys

-- | @'mul' semiring m1 m2@ multiplies matrices @m1@ and @m2@.
--   Uses the operations of the semiring @semiring@ to perform the
--   multiplication.
--
--   @O(n1 + n2 log n2 + Σ(i <= r1) Σ(j <= c2) d(i,j))@ where
--   @r1@ is the number of non-empty rows in @m1@ and
--   @c2@ is the number of non-empty columns in @m2@ and
--   @d(i,j)@  is the bigger one of the following two quantifies:
--   the length of sparse row @i@ in @m1@ and
--   the length of sparse column @j@ in @m2@.
--
--   Given dimensions @m1 : r1 × c1@ and @m2 : r2 × c2@,
--   a matrix of size @r1 × c2@ is returned.
--   It is not necessary that @c1 == r2@, the matrices are implicitly
--   patched with zeros to match up for multiplication.
--   For sparse matrices, this patching is a no-op.

mul :: (Enum i, Num i, Ix i, Eq a)
    => Semiring a -> Matrix i a -> Matrix i a -> Matrix i a
mul semiring m1 m2 = Matrix (Size { rows = rows (size m1), cols = cols (size m2) }) $
  [ (MIx i j, b)
    | (i,v) <- toSparseRows m1
    , (j,w) <- toSparseRows $ transpose m2
    , let b = inner v w
    , b /= zero
  ]
  where
     zero  = Semiring.zero semiring
     plus  = Semiring.add  semiring
     times = Semiring.mul  semiring
     inner v w = List.foldl' plus zero $
                   map snd $ interAssocWith times v w

------------------------------------------------------------------------
-- Modifying matrices

-- | @'addColumn' x m@ adds a new column to @m@, after the columns
-- already existing in the matrix. All elements in the new column get
-- set to @x@.

addColumn :: (Num i, HasZero b) => b -> Matrix i b -> Matrix i b
addColumn x m | x == zeroElement = m { size = (size m) { cols = cols (size m) + 1 }}
              | otherwise = __IMPOSSIBLE__

prop_addColumn :: TM -> Bool
prop_addColumn m =
  matrixInvariant m'
  &&
  map init (toLists m') == toLists m
  where
  m' = addColumn zeroElement m

-- | @'addRow' x m@ adds a new row to @m@, after the rows already
-- existing in the matrix. All elements in the new row get set to @x@.

addRow :: (Num i, HasZero b) => b -> Matrix i b -> Matrix i b
addRow x m | x == zeroElement = m { size = (size m) { rows = rows (size m) + 1 }}
           | otherwise = __IMPOSSIBLE__

prop_addRow :: TM -> Bool
prop_addRow m =
  matrixInvariant m'
  &&
  init (toLists m') == toLists m
  where
  m' = addRow zeroElement m

------------------------------------------------------------------------
-- * Printing
------------------------------------------------------------------------

instance (Integral i, HasZero b, Show i, Show b) => Show (Matrix i b) where
  showsPrec _ m =
    showString "Agda.Termination.SparseMatrix.fromLists " . shows (size m) .
    showString " " . shows (toLists m)

instance (Integral i, HasZero b, Pretty b) =>
         Pretty (Matrix i b) where
--  pretty = vcat . map (hsep . map pretty) . toLists
  pretty = vcat
         . map text
         . lines
         . Boxes.render
         . Boxes.hsep 1 Boxes.right
         . map ( Boxes.vcat Boxes.right
               . map ( Boxes.alignHoriz Boxes.right 2
                     . Boxes.text . render . pretty
                     )
               )
         . toLists
         . transpose
-- ADAPTED FROM:
-- http://www.tedreed.info/programming/2012/06/02/how-to-use-textprettyprintboxes/
-- print_table :: [[String]] -> IO ()
-- print_table rows = printBox $ hsep 2 left (map (vcat left . map text) (transpose rows))



------------------------------------------------------------------------
-- * Generators, properties and tests
------------------------------------------------------------------------

-- ** Size
------------------------------------------------------------------------

instance (Arbitrary i, Integral i) => Arbitrary (Size i) where
  arbitrary = do
    r <- natural
    c <- natural
    return $ Size { rows = fromInteger r, cols = fromInteger c }

instance CoArbitrary i => CoArbitrary (Size i) where
  coarbitrary (Size rs cs) = coarbitrary rs . coarbitrary cs

-- | Size invariant: dimensions are non-negative.

sizeInvariant :: (Ord i, Num i) => Size i -> Bool
sizeInvariant sz = rows sz >= 0 && cols sz >= 0

prop_Arbitrary_Size :: Size Integer -> Bool
prop_Arbitrary_Size = sizeInvariant

prop_size :: TM -> Bool
prop_size m = sizeInvariant (size m)

-- ** Matrix indices
------------------------------------------------------------------------

instance (Arbitrary i, Integral i) => Arbitrary (MIx i) where
  arbitrary = MIx <$> positive <*> positive

instance CoArbitrary i => CoArbitrary (MIx i) where
  coarbitrary (MIx r c) = coarbitrary r . coarbitrary c

-- | Indices must be positive, @>= 1@.

mIxInvariant :: (Ord i, Num i) => MIx i -> Bool
mIxInvariant i = row i >= 1 && col i >= 1

prop_Arbitrary_MIx :: MIx Integer -> Bool
prop_Arbitrary_MIx = mIxInvariant

-- ** Matrices
------------------------------------------------------------------------

-- | Matrix indices are lexicographically sorted with no duplicates.
--   All indices must be within bounds.
matrixInvariant :: (Num i, Ix i, HasZero b) => Matrix i b -> Bool
matrixInvariant (Matrix size@Size{ rows, cols} m) =
  sizeInvariant size
  && all inBounds m
  && all nonZero  m
  && strictlySorted (MIx 0 0) m
  where
    inBounds (MIx i j, _) = 1 <= i && i <= rows
                         && 1 <= j && j <= cols
    nonZero (_, b) = b /= zeroElement

-- | Check whether an association list is ordered and
--   deterministic, a partial function from @i@ to @b@.
strictlySorted :: (Ord i) => i -> [(i, b)] -> Bool
strictlySorted i []            = True
strictlySorted i ((i', _) : l) = i < i' && strictlySorted i' l
-- Ord MIx should be the lexicographic order already (Haskell report).

-- | Generates a matrix of the given size, using the given generator
-- to generate the rows.

matrixUsingRowGen :: (Arbitrary i, Integral i, Arbitrary b, HasZero b)
  => Size i
  -> (i -> Gen [b])
     -- ^ The generator is parameterised on the size of the row.
  -> Gen (Matrix i b)
matrixUsingRowGen sz rowGen = do
  rows <- vectorOf (fromIntegral $ rows sz) (rowGen $ cols sz)
  return $ fromLists sz rows

-- | Generates a matrix of the given size.

matrix :: (Arbitrary i, Integral i, Arbitrary b, HasZero b)
  => Size i -> Gen (Matrix i b)
matrix sz = matrixUsingRowGen sz (\n -> vectorOf (fromIntegral n) arbitrary)

prop_matrix :: Size Int -> Property
prop_matrix sz = forAll (matrix sz :: Gen TM) $ \ m -> size m == sz

-- | Generate a matrix of arbitrary size.

instance (Arbitrary i, Num i, Integral i, Arbitrary b, HasZero b)
         => Arbitrary (Matrix i b) where
  arbitrary     = matrix =<< arbitrary

instance (Show i, Ord i, Integral i, Enum i, Ix i, CoArbitrary b, HasZero b) => CoArbitrary (Matrix i b) where
  coarbitrary m = coarbitrary (toLists m)

-- | This matrix type is used for tests.

type TM = Matrix Int Int

prop_Arbitrary_Matrix :: TM -> Bool
prop_Arbitrary_Matrix = matrixInvariant

-- ** Matrix operations

-- | 'fromIndexList' is identity on well-formed sparse matrices.

prop_fromIndexList :: TM -> Bool
prop_fromIndexList m@(Matrix size vs) = fromIndexList size vs == m

-- | Converting a matrix to a list of lists and back is the identity.

prop_fromLists_toLists :: TM -> Bool
prop_fromLists_toLists m = fromLists (size m) (toLists m) == m

-- | Any 1x1 matrix is a singleton.

prop_isSingleton :: Int -> Bool
prop_isSingleton b = Just b == (isSingleton (fromLists (Size 1 1) [[b]] :: TM))

-- | The length of the diagonal is the minimum of the number of
--   rows and columns of the matrix.

prop_diagonal :: TM -> Bool
prop_diagonal m@(Matrix (Size r c) _) =
    length (diagonal m) == min r c

-- prop_diagonal' n =
--   forAll natural $ \n ->
--   forAll (matrix (Size n n) :: Gen TM) $ \m ->
--     length (diagonal m) == n

-- | Transposing twice is the identity.

prop_transpose :: TM -> Bool
prop_transpose m = matrixInvariant m' && m == transpose m'
  where m' = transpose m

-- ** Matrix addition


-- | Old implementation of 'zipMatrices'.

zipMatrices' :: forall a b c i . (Ord i)
  => (a -> c)       -- ^ Element only present in left matrix.
  -> (b -> c)       -- ^ Element only present in right matrix.
  -> (a -> b -> c)  -- ^ Element present in both matrices.
  -> (c -> Bool)    -- ^ Result counts as zero?
  -> Matrix i a -> Matrix i b -> Matrix i c
zipMatrices' f g h zero m1 m2 = Matrix (supSize m1 m2) (merge (unM m1) (unM m2))
  where
    merge :: [(MIx i,a)] -> [(MIx i,b)] -> [(MIx i,c)]
    merge [] m2 = filter (not . zero . snd) $ map (mapSnd g) m2
    merge m1 [] = filter (not . zero . snd) $ map (mapSnd f) m1
    merge m1@((i,a):m1') m2@((j,b):m2') =
      case compare i j of
        LT -> if zero c then r else (i,c) : r where c = f a   ; r = merge m1' m2
        GT -> if zero c then r else (j,c) : r where c = g b   ; r = merge m1  m2'
        EQ -> if zero c then r else (i,c) : r where c = h a b ; r = merge m1' m2'

-- | Verify 'zipMatrices' against older implementation

prop_zipMatrices_correct :: TM -> TM -> Bool
prop_zipMatrices_correct m1 m2 =
  zipMatrices id id (+) (== 0) m1 m2 == zipMatrices' id id (+) (== 0) m1 m2


-- | Matrix addition is well-defined, associative and commutative.

prop_add :: Size Int -> Property
prop_add sz =
  forAll (three (matrix sz :: Gen TM)) $ \(m1, m2, m3) ->
    let m' = add (+) m1 m2 in
      associative (add (+)) m1 m2 m3 &&
      commutative (add (+)) m1 m2 &&
      matrixInvariant m' &&
      size m' == size m1

-- | Verify addition against an older implementation.
--
--   The older implementation did not fully preserve sparsity,
--   i.e., introduced zeros.  Thus, we need to convert to lists to
--   obtain equal results.

prop_add_correct :: TM -> TM -> Bool
prop_add_correct m1 m2 = toLists (add (+) m1 m2) == toLists (add' (+) m1 m2)
  where
    add' :: (Ord i) => (a -> a -> a) -> Matrix i a -> Matrix i a -> Matrix i a
    add' plus m1 m2 = Matrix (supSize m1 m2) $ mergeAssocWith plus (unM m1) (unM m2)
      where
        mergeAssocWith :: (Ord i) => (a -> a -> a) -> [(i,a)] -> [(i,a)] -> [(i,a)]
        mergeAssocWith f [] m = m
        mergeAssocWith f l [] = l
        mergeAssocWith f l@((i,a):l') m@((j,b):m')
            | i < j = (i,a) : mergeAssocWith f l' m
            | i > j = (j,b) : mergeAssocWith f l m'
            | otherwise = (i, f a b) : mergeAssocWith f l' m'

-- ** Matrix multiplication

-- | Specification of 'interAssocWith'.

interAssocWith' :: (Eq i) => (a -> a -> a) -> [(i,a)] -> [(i,a)] -> [(i,a)]
interAssocWith' f l l' = [ (i, f a b) | (i,a) <- l, (j,b) <- l', i == j ]

-- | Efficient implementation of 'interAssocWith' matches its specification.

prop_interAssocWith_correct :: [(Int,Int)] -> [(Int,Int)] -> Bool
prop_interAssocWith_correct xs ys =
  interAssocWith (*) l l' == interAssocWith' (*) l l'
  where
    l  = List.sortBy (compare `on` fst) xs
    l' = List.sortBy (compare `on` fst) ys

-- | Matrix multiplication is well-defined and associative.

prop_mul :: Size Int -> Property
prop_mul sz =
  mapSize (`div` 2) $
  forAll (two natural) $ \(c2, c3) ->
  forAll (matrix sz :: Gen TM) $ \m1 ->
  forAll (matrix (Size { rows = cols sz, cols = c2 })) $ \m2 ->
  forAll (matrix (Size { rows = c2, cols = c3 })) $ \m3 ->
    let m' = mult m1 m2 in
      associative mult m1 m2 m3 &&
      matrixInvariant m' &&
      size m' == Size { rows = rows sz, cols = c2 }
  where mult = mul Semiring.intSemiring

------------------------------------------------------------------------
-- All tests

tests :: IO Bool
tests = runTests "Agda.Termination.SparseMatrix"
  [ quickCheck' prop_transpose
  , quickCheck' prop_Arbitrary_Size
  , quickCheck' prop_Arbitrary_Matrix
  , quickCheck' prop_Arbitrary_MIx
  , quickCheck' prop_fromIndexList
  , quickCheck' prop_matrix
  , quickCheck' prop_size
  , quickCheck' prop_toSparseRows
  , quickCheck' prop_fromLists_toLists
  , quickCheck' prop_isSingleton
  , quickCheck' prop_zipMatrices_correct
  , quickCheck' prop_add
  , quickCheck' prop_add_correct
  , quickCheck' prop_mul
  , quickCheck' prop_diagonal
  , quickCheck' prop_addColumn
  , quickCheck' prop_addRow
  ]
