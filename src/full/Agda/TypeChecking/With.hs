{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternGuards #-}

module Agda.TypeChecking.With where

import Control.Applicative
import Control.Monad
import Control.Monad.State

import Data.List
import Data.Maybe
import qualified Data.Traversable as Trav (traverse)

import Agda.Syntax.Common as Common
import Agda.Syntax.Internal as I
import Agda.Syntax.Internal.Pattern
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Abstract.Views
import Agda.Syntax.Info
import Agda.Syntax.Position

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Datatypes
import Agda.TypeChecking.EtaContract
import Agda.TypeChecking.Patterns.Abstract
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Records
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope

import Agda.TypeChecking.Abstract
import Agda.TypeChecking.Rules.LHS.Implicit

import Agda.Utils.Functor
import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Permutation
import Agda.Utils.Size

#include "undefined.h"
import Agda.Utils.Impossible

withFunctionType :: Telescope -> [Term] -> [Type] -> Telescope -> Type -> TCM Type
withFunctionType delta1 vs as delta2 b = {-dontEtaContractImplicit $-} do
  (vas, b) <- addCtxTel delta1 $ do
    reportSLn "tc.with.abstract" 20 $ "preparing for with-abstraction"
    vs <- etaContract =<< normalise vs
    reportSDoc "tc.with.abstract" 20 $ text "  vs = " <+> prettyTCM vs
    as <- etaContract =<< normalise as
    reportSDoc "tc.with.abstract" 20 $ text "  as = " <+> prettyTCM as
    b <- return $ telePi_ delta2 b
    reportSDoc "tc.with.abstract" 30 $ text "normalizing b = " <+> prettyTCM b
    b  <- normalise b
    reportSDoc "tc.with.abstract" 30 $ text "eta-contracting b = " <+> prettyTCM b
    b  <- etaContract b
    reportSDoc "tc.with.abstract" 20 $ text "  b  = " <+> prettyTCM b
    reportSDoc "tc.with.abstract" 40 $
      sep [ text "abstracting"
          , nest 2 $ vcat $
            [ text "vs = " <+> prettyTCM vs
            , text "as = " <+> prettyTCM as
            , text "b  = " <+> prettyTCM b ]
          ]
    reportSLn "tc.with.abstract" 50 $ "  raw vs = " ++ show vs ++ "\n  raw b  = " ++ show b
    return (zip vs as, b)
  return $ telePi_ delta1 $ foldr (uncurry piAbstractTerm) b vas

-- | Compute the clauses for the with-function given the original patterns.
buildWithFunction
  :: QName                -- ^ Name of the with-function.
  -> Type                 -- ^ Types of the parent function.
  -> [I.NamedArg Pattern] -- ^ Parent patterns.
  -> Permutation          -- ^ Final permutation.
  -> Nat                  -- ^ Number of needed vars.
  -> Nat                  -- ^ Number of with expressions.
  -> [A.SpineClause]      -- ^ With-clauses.
  -> TCM [A.SpineClause]  -- ^ With-clauses flattened wrt. parent patterns.
buildWithFunction aux t qs perm n1 n cs = mapM buildWithClause cs
  where
    buildWithClause (A.Clause (A.SpineLHS i _ ps wps) rhs wh catchall) = do
      let (wps0, wps1) = genericSplitAt n wps
          ps0          = map defaultNamedArg wps0
      rhs <- buildRHS rhs
      (ps1, ps2)  <- genericSplitAt n1 <$> stripWithClausePatterns aux t qs perm ps
      let result = A.Clause (A.SpineLHS i aux (ps1 ++ ps0 ++ ps2) wps1) rhs wh catchall
      reportSDoc "tc.with" 20 $ vcat
        [ text "buildWithClause returns" <+> prettyA result
        ]
      return result

    buildRHS rhs@(A.RHS _)               = return rhs
    buildRHS rhs@A.AbsurdRHS             = return rhs
    buildRHS (A.WithRHS q es cs)         = A.WithRHS q es <$>
      mapM (A.spineToLhs <.> buildWithClause . A.lhsToSpine) cs
    buildRHS (A.RewriteRHS qes rhs wh) = flip (A.RewriteRHS qes) wh <$> buildRHS rhs

{-| @stripWithClausePatterns f t qs π ps = ps'@

    @Δ@   - context bound by lhs of original function (not an argument)

    @f@   - name of with-function

    @t@   - type of the original function

    @qs@  - internal patterns for original function

    @π@   - permutation taking @vars(qs)@ to @support(Δ)@

    @ps@  - patterns in with clause (eliminating type @t@)

    @ps'@ - patterns for with function (presumably of type @Δ@)

Example:
@
record Stream (A : Set) : Set where
  coinductive
  constructor delay
  field       force : A × Stream A

record SEq (s t : Stream A) : Set where
  coinductive
  field
    ~force : let a , as = force s
                 b , bs = force t
             in  a ≡ b × SEq as bs

test : (s : Nat × Stream Nat) (t : Stream Nat) → SEq (delay s) t → SEq t (delay s)
~force (test (a     , as) t p) with force t
~force (test (suc n , as) t p) | b , bs = {!!}

With function:

  f : (t : Stream Nat) (w : Nat × Stream Nat) (a : Nat) (as : Stream Nat)
      (p : SEq (delay (a , as)) t) → (fst w ≡ a) × SEq (snd w) as

  Δ  = t a as p   -- reorder to bring with-relevant (= needed) vars first
  π  = a as t p → Δ
  qs = (a     , as) t p ~force
  ps = (suc n , as) t p ~force
  ps' = (suc n) as t p

Resulting with-function clause is:

  f t (b , bs) (suc n) as t p

Note: stripWithClausePatterns factors ps through qs, thus

  ps = qs[ps']

where [..] is to be understood as substitution.
The projection patterns have vanished from ps' (as they are already in qs).
@
-}
stripWithClausePatterns
  :: QName                      -- ^ @f@
  -> Type                       -- ^ @t@
  -> [I.NamedArg Pattern]       -- ^ @qs@
  -> Permutation                -- ^ @π@
  -> [A.NamedArg A.Pattern]     -- ^ @ps@
  -> TCM [A.NamedArg A.Pattern] -- ^ @ps'@
stripWithClausePatterns f t qs perm ps = do
  -- Andreas, 2014-03-05 expand away pattern synoyms (issue 1074)
  ps <- expandPatternSynonyms ps
  psi <- insertImplicitPatternsT ExpandLast ps t
  reportSDoc "tc.with.strip" 10 $ vcat
    [ text "stripping patterns"
    , nest 2 $ text "t   = " <+> prettyTCM t
    , nest 2 $ text "psi = " <+> fsep (punctuate comma $ map prettyA psi)
    , nest 2 $ text "qs  = " <+> fsep (punctuate comma $ map (prettyTCM . namedArg) qs)
    ]
  ps' <- strip (Def f []) t psi $ numberPatVars perm qs
  let psp = permute perm ps'
  reportSDoc "tc.with.strip" 10 $ vcat
    [ nest 2 $ text "ps' = " <+> fsep (punctuate comma $ map prettyA ps')
    , nest 2 $ text "psp = " <+> fsep (punctuate comma $ map prettyA $ psp)
    ]
  -- Andreas, 2014-03-05 Issue 142:
  -- In some cases, permute throws away some dot patterns of ps'
  -- which are then never checked.
  if True then return psp else do
    -- Andreas, 2014-03-05 Disabled the fix for issue 142, the following is dead code:
    forM_ (permute (droppedP perm) ps') $ \ p -> setCurrentRange p $ do
      reportSDoc "tc.with.strip" 10 $ text "warning: dropped pattern " <+> prettyA p
      reportSDoc "tc.with.strip" 60 $ text $ show p
      case namedArg p of
        A.DotP info e -> case unScope e of
          A.Underscore{} -> return ()
          -- Dot patterns without a range are Agda-generated from a user dot pattern
          -- so we only complain if there is a range.
          e | getRange info /= noRange -> typeError $ GenericError $
            "This inaccessible pattern is never checked, so only _ allowed here"
          _ -> return ()
        _ -> return ()
    return psp
  where

    strip
      :: Term                         -- ^ Self.
      -> Type                         -- ^ The type to be eliminated.
      -> [A.NamedArg A.Pattern]       -- ^ With-clause patterns.
      -> [I.NamedArg DeBruijnPattern] -- ^ Parent-clause patterns with de Bruijn indices relative to Δ.
      -> TCM [A.NamedArg A.Pattern]   -- ^ With-clause patterns decomposed by parent-clause patterns.

    -- Case: out of with-clause patterns.
    strip self t [] qs@(_ : _) = do
      -- Andreas, 2015-06-11, issue 1551:
      -- As the type t develops, we need to insert more implicit patterns,
      -- due to copatterns / flexible arity.
      ps <- insertImplicitPatternsT ExpandLast [] t
      if null ps then
        typeError $ GenericError $ "Too few arguments given in with-clause"
       else strip self t ps qs

    -- Case: out of parent-clause patterns.
    -- This is only ok if all remaining with-clause patterns
    -- are implicit patterns (we inserted too many).
    strip _ _ ps      []      = do
      let implicit (A.ImplicitP{}) = True
          implicit (A.ConP ci _ _) = patImplicit ci
          implicit _               = False
      unless (all (implicit . namedArg) ps) $
        typeError $ GenericError $ "Too many arguments given in with-clause"
      return []

    -- Case: both parent-clause pattern and with-clause pattern present.
    -- Make sure they match, and decompose into subpatterns.
    strip self t ps0@(p0 : ps) qs0@(q : qs) = do
      p <- expandLitPattern p0
      reportSDoc "tc.with.strip" 15 $ vcat
        [ text "strip"
        , nest 2 $ text "ps0 =" <+> fsep (punctuate comma $ map prettyA ps0)
        , nest 2 $ text "exp =" <+> prettyA p
        , nest 2 $ text "qs0 =" <+> fsep (punctuate comma $ map (prettyTCM . namedArg) qs0)
        , nest 2 $ text "t   =" <+> prettyTCM t
        ]
      case namedArg q of
        ProjP d -> case A.isProjP p of
          Just d' | d == d' -> do
            t <- reduce t
            (self1, t1) <- fromMaybe __IMPOSSIBLE__ <$> projectTyped self t d
            strip self1 t1 ps qs
          _ -> mismatch

        VarP (i, _x)  -> do
          ps <- intro1 t $ \ t -> strip (self `apply1` var i) t ps qs
          return $ p : ps

        DotP v  -> case namedArg p of
          A.DotP _ _    -> ok p
          A.ImplicitP _ -> ok p
          -- Andreas, 2013-03-21 in case the implicit A.pattern has already been eta-expanded
          -- we just fold it back.  This fixes issues 665 and 824.
          A.ConP ci _ _ | patImplicit ci -> ok $ updateNamedArg (const $ A.ImplicitP patNoRange) p

          p@(A.PatternSynP pi' c' [ps']) -> do
             reportSDoc "impossible" 10 $
               text "stripWithClausePatterns: encountered pattern synonym " <+> prettyA p
             __IMPOSSIBLE__

          _ -> do
            d <- prettyA p
            typeError $ GenericError $
                "Inaccessible (dotted) patterns from the parent clause must " ++
                "also be inaccessible in the with clause, when checking the " ++
                "pattern " ++ show d ++ ","
          where
            ok p = do
              t' <- piApply1 t v
              (p :) <$> strip (self `apply1` v) t' ps qs

        ConP c ci qs' -> do
         reportSDoc "tc.with.strip" 60 $
           text "parent pattern is constructor " <+> prettyTCM c
         (a, b) <- mustBePi t
         case namedArg p of

          -- Andreas, 2013-03-21 if we encounter an implicit pattern in the with-clause
          -- that has been expanded in the parent clause, we expand it and restart
          A.ImplicitP _ | Just True <- conPRecord ci -> do
            maybe __IMPOSSIBLE__ (\ p -> strip self t (p : ps) qs0) =<<
              -- Andreas, Ulf, 2015-06-03 unfix issue 473
              -- expandImplicitPattern' (unDom a) p
              return (Just p)

          A.ConP _ (A.AmbQ cs') ps' -> do
            c <- (`withRangeOf` c) <$> do getConForm $ conName c
            cs' <- mapM getConForm cs'
            unless (elem c cs') mismatch

            -- The type is a datatype
            Def d es <- ignoreSharing <$> normalise (unEl $ unDom a)
            let us = fromMaybe __IMPOSSIBLE__ $ allApplyElims es

            -- Compute the argument telescope for the constructor
            Defn {defType = ct, theDef = Constructor{conPars = np}}  <- getConInfo c
            let ct' = ct `apply` genericTake np us
            TelV tel' _ <- telView ct'

            reportSDoc "tc.with.strip" 20 $
              vcat [ text "ct  = " <+> prettyTCM ct
                   , text "ct' = " <+> prettyTCM ct'
                   , text "np  = " <+> text (show np)
                   , text "us  = " <+> prettyList (map prettyTCM us)
                   , text "us' = " <+> prettyList (map prettyTCM $ genericTake np us)
                   ]

            -- Compute the new type
            let v     = Con c [ Arg info (var i) | (i, Arg info _) <- zip (downFrom $ size qs') qs' ]
                t' = tel' `abstract` absApp (raise (size tel') b) v

            reportSDoc "tc.with.strip" 15 $ sep
              [ text "inserting implicit"
              , nest 2 $ prettyList $ map prettyA (ps' ++ ps)
              , nest 2 $ text ":" <+> prettyTCM t'
              ]

            -- Insert implicit patterns (just for the constructor arguments)
            psi' <- insertImplicitPatterns ExpandLast ps' tel'
            unless (size psi' == size tel') $ typeError $
              WrongNumberOfConstructorArguments (conName c) (size tel') (size psi')

            -- Keep going
            strip (self `apply1` v) t' (psi' ++ ps) (qs' ++ qs)

          p@(A.PatternSynP pi' c' ps') -> do
             reportSDoc "impossible" 10 $
               text "stripWithClausePatterns: encountered pattern synonym " <+> prettyA p
             __IMPOSSIBLE__

          p -> do
           reportSDoc "tc.with.strip" 60 $
             text $ "with clause pattern is  " ++ show p
           mismatch

        LitP lit -> case namedArg p of
          A.LitP lit' | lit == lit' -> do
            (a, b) <- mustBePi t
            let v = Lit lit
            strip (self `apply1` v) (b `absApp` v) ps qs

          p@(A.PatternSynP pi' c' [ps']) -> do
             reportSDoc "impossible" 10 $
               text "stripWithClausePatterns: encountered pattern synonym " <+> prettyA p
             __IMPOSSIBLE__

          _ -> mismatch
      where
        mismatch = typeError $
          WithClausePatternMismatch (namedArg p0) (snd <$> namedArg q)

-- | Construct the display form for a with function. It will display
--   applications of the with function as applications to the original function.
--   For instance, @aux a b c@ as @f (suc a) (suc b) | c@
--
--   @n@ is the number of with arguments.
withDisplayForm
  :: QName       -- ^ The name of parent function.
  -> QName       -- ^ The name of the with-function.
  -> Telescope   -- ^ The arguments of the with function before the with exprs.
  -> Telescope   -- ^ The arguments of the with function after the with exprs.
  -> Nat         -- ^ The number of with expressions.
  -> [I.NamedArg Pattern] -- ^ The parent patterns.
  -> Permutation -- ^ Permutation to split into needed and unneeded vars.
  -> Permutation -- ^ Permutation reordering the variables in parent patterns.
  -> TCM DisplayForm
withDisplayForm f aux delta1 delta2 n qs perm@(Perm m _) lhsPerm = do

  -- Compute the arity of the display form.
  let arity0 = n + size delta1 + size delta2
  -- The currently free variables have to be added to the front.
  topArgs <- raise arity0 <$> getContextArgs
  let top    = length topArgs
      arity  = arity0 + top

  -- Build the rhs of the display form.
  wild <- freshNoName_ <&> \ x -> Def (qualify_ x) []
  let -- Convert the parent patterns to terms.
      tqs0       = patsToElims lhsPerm qs
      -- Build a substitution to replace the parent pattern vars
      -- by the pattern vars of the with-function.
      (ys0, ys1) = splitAt (size delta1) $ permute perm $ downFrom m
      ys         = reverse $ map Just ys0 ++ replicate n Nothing ++ map Just ys1
      rho        = sub top ys wild
      tqs        = applySubst rho tqs0
      -- Build the arguments to the with function.
      es         = map (Apply . fmap DTerm) topArgs ++ tqs
      withArgs   = map var $ take n $ downFrom $ size delta2 + n
      dt         = DWithApp (DDef f es) (map DTerm withArgs) []

  -- Build the lhs of the display form and finish.
  -- @var 0@ is the pattern variable (hole).
  let display = Display arity (replicate arity $ var 0) dt

  -- Debug printing.
  let addFullCtx = addCtxTel delta1
                 . flip (foldr addContext) (for [1..n] $ \ i -> "w" ++ show i)
                 . addCtxTel delta2
  reportSDoc "tc.with.display" 20 $ vcat
    [ text "withDisplayForm"
    , nest 2 $ vcat
      [ text "f      =" <+> text (show f)
      , text "aux    =" <+> text (show aux)
      , text "delta1 =" <+> prettyTCM delta1
      , text "delta2 =" <+> do addCtxTel delta1 $ prettyTCM delta2
      , text "n      =" <+> text (show n)
      , text "perm   =" <+> text (show perm)
      , text "top    =" <+> do addFullCtx $ prettyTCM topArgs
      , text "qs     =" <+> text (show qs)
      , text "dt     =" <+> do addFullCtx $ prettyTCM dt
      , text "ys     =" <+> text (show ys)
      , text "raw    =" <+> text (show display)
      , text "qsToTm =" <+> prettyTCM tqs0 -- ctx would be permuted form of delta1 ++ delta2
      , text "sub qs =" <+> prettyTCM tqs
      ]
    ]

  return display
  where
    -- Ulf, 2014-02-19: We need to rename the module parameters as well! (issue1035)
    sub top ys wild = map term [0 .. m - 1] ++# raiseS (length qs)
      where
        term i = maybe wild var $ findIndex (Just i ==) ys
    -- OLD
    -- sub top rho wild = parallelS $ map term [0 .. m - 1] ++ topTerms
    --   where
    --     -- Ulf, 2014-02-19: We need to rename the module parameters as well! (issue1035)
    --     newVars  = length qs
    --     topTerms = [ var (i + newVars) | i <- [0..top - 1] ]
    --     -- thinking required.. but ignored
    --     -- dropping the reverse seems to work better
    --     -- Andreas, 2010-09-09: I DISAGREE.
    --     -- Ulf, 2011-09-02: Thinking done. Neither was correct.
    --     -- We had the wrong permutation and we used it incorrectly. Should work now.
    --     term i = maybe wild var $ findIndex (Just i ==) rho

-- Andreas, 2014-12-05 refactored using numberPatVars
-- Andreas, 2013-02-28 modeled after Coverage/Match/buildMPatterns
-- The permutation is the one of the original clause.
patsToElims :: Permutation -> [I.NamedArg Pattern] -> [I.Elim' DisplayTerm]
patsToElims perm ps = toElims $ numberPatVars perm ps
  where
    toElims :: [I.NamedArg DeBruijnPattern] -> [I.Elim' DisplayTerm]
    toElims = map $ toElim . fmap namedThing

    toElim :: I.Arg DeBruijnPattern -> I.Elim' DisplayTerm
    toElim (Common.Arg ai p) = case p of
      ProjP d -> I.Proj d
      p       -> I.Apply $ Common.Arg ai $ toTerm p

    toTerms :: [I.NamedArg DeBruijnPattern] -> [I.Arg DisplayTerm]
    toTerms = map $ fmap $ toTerm . namedThing

    toTerm :: DeBruijnPattern -> DisplayTerm
    toTerm p = case p of
      ProjP d     -> DDef d [] -- WRONG. TODO: convert spine to non-spine ... DDef d . defaultArg
      VarP (i, x) -> DTerm  $ var i
      DotP t      -> DDot   $ t
      ConP c _ ps -> DCon c $ toTerms ps
      LitP l      -> DTerm  $ Lit l
