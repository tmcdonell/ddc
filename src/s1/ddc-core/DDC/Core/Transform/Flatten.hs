
-- | Flattening nested let and case expressions.
module DDC.Core.Transform.Flatten
        (flatten)
where
import DDC.Core.Transform.TransformUpX
import DDC.Core.Transform.AnonymizeX
import DDC.Core.Transform.BoundX
import DDC.Core.Exp.Annot
import Data.Functor.Identity


-- | Flatten binding structure in a thing.
--
--   Flattens nested let-expressions,
--   and single alternative let-case expressions.
--
flatten :: Ord n
        => (TransformUpMX Identity c)
        => c a n -> c a n
flatten
 = {-# SCC flatten #-}
   transformUpX' flatten1


-- | Flatten a single nested let-expression.
flatten1
        :: Ord n
        => Exp a n
        -> Exp a n

-- Run ----------------------------------------------------
flatten1 (XCast a1 CastRun (XLet a2 lts x2))
 = XLet a2 lts $ flatten1 (XCast a1 CastRun x2)


-- Let ----------------------------------------------------
-- Special case when nested let is (let b = x in b):
-- @
--      let b1 = (let ^ = def2 in ^0) in
--      x1
--
--  ==> let b1 = def2 in
--      x1
-- @
--
flatten1 (XLet a1 (LLet b1
            (XLet _ (LLet (BAnon _) def2) (XVar _ (UIx 0))))
               x1)
 = flatten1
        $ XLet a1 (LLet b1 def2)
               x1

-- Let ----------------------------------------------------
-- Flatten Nested Lets.
-- @
--      let b1 = (let b2 = eBind2 in eBody2) in eBody1
--
--   => let bF = eBind2 in
--      let b1 = eBody2 in   !(for fresh xF)
--      eBody1[bF/b2]
-- @
--
flatten1 (XLet a1 (LLet b1
            inner@(XLet a2 (LLet b2 def2) x2))  x1)

 | isBName b2
 = flatten1
        $ XLet a1 (LLet b1 (anonymizeX inner)) x1

 | otherwise
 = let  x1'       = liftAcrossX [b1] [b2] x1
   in   XLet a2 (LLet b2 def2)
      $ flatten1
      $ XLet a1 (LLet b1 x2)
             x1'


-- Flatten single-alt case expressions.
-- @
--     let b1 = case x1 of
--                P -> x2
--     in x3
--
--  => case x1 of
--       P -> let b1 = x2
--            in x3
-- @
--
-- * binding must be strict because we force evaluation of x1.
--
flatten1 (XLet  a1 (LLet b1
             inner@(XCase a2 x1 [AAlt p x2]))
                   x3)
 | any isBName $ bindsOfPat p
 = flatten1
        $ XLet  a1 (LLet b1
                   (anonymizeX inner))
                   x3

 | otherwise
 = let  x3'     = liftAcrossX [b1] (bindsOfPat p) x3
   in   XCase a2 x1
           [AAlt p ( flatten1
                   $ XLet a1 (LLet b1 x2)
                             (anonymizeX x3'))]


-- Any let, its bound expression doesn't contain a strict non-recursive
-- let so just flatten the body
flatten1 (XLet a1 llet1 x1)
 = XLet a1 llet1 (flatten1 x1)


-- Case ---------------------------------------------------
-- Flatten all the alternatives in a case-expression.
flatten1 (XCase a x1 alts)
 = XCase a (flatten1 x1)
           [AAlt p (flatten1 x) | AAlt p x <- alts ]

flatten1 x = x


liftAcrossX :: [Bind n] -> [Bind n] -> Exp a n -> Exp a n
liftAcrossX bsDepth bsLevels x
 = let  depth   = length [b | b@(BAnon _) <- bsDepth]
        levels  = length [b | b@(BAnon _) <- bsLevels]
   in   liftAtDepthX levels depth x


