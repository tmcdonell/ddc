
-- | Capture avoiding substitution of expressions in expressions.
--
--   If a binder would capture a variable then it is anonymized
--   to deBruijn form.
--
module DDC.Core.Transform.SubstituteXX
        ( SubstituteXX(..)
        , substituteXX
        , substituteXXs
        , substituteXArg
        , substituteXArgs)
where
import DDC.Core.Exp.Annot.Exp
import DDC.Core.Collect
import DDC.Core.Transform.BoundX
import DDC.Core.Transform.SubstituteWX
import DDC.Core.Transform.SubstituteTX
import DDC.Type.Transform.SubstituteT
import DDC.Type.Transform.Rename
import DDC.Type.Exp.Simple
import Data.Maybe
import qualified DDC.Type.Env   as Env
import qualified Data.Set       as Set
import Control.Monad


-- | Wrapper for `substituteWithX` that determines the set of free names in the
--   expression being substituted, and starts with an empty binder stack.
substituteXX 
        :: (Ord n, SubstituteXX c)
        => Bind n -> Exp a n -> c a n -> c a n

substituteXX b xArg xx
 | Just u       <- takeSubstBoundOfBind b
 = substituteWithXX xArg
        ( Sub 
        { subBound      = u

          -- Rewrite level-1 binders that have the same name as any
          -- of the free variables in the expression to substitute, 
          -- or any level-1 binders that expression binds itself.
        , subConflict1  
                = Set.fromList
                $  (mapMaybe takeNameOfBound $ Set.toList $ freeT Env.empty xArg) 
                ++ (mapMaybe takeNameOfBind  $ fst $ collectBinds xArg)

          -- Rewrite level-0 binders that have the same name as any
          -- of the free variables in the expression to substitute.
        , subConflict0
                = Set.fromList
                $ mapMaybe takeNameOfBound 
                $ Set.toList 
                $ freeX Env.empty xArg
                
        , subStack1     = BindStack [] [] 0 0
        , subStack0     = BindStack [] [] 0 0
        , subShadow0    = False })
        xx

 | otherwise    = xx


-- | Wrapper for `substituteX` to substitute multiple expressions.
substituteXXs 
        :: (Ord n, SubstituteXX c)
        => [(Bind n, Exp a n)] -> c a n -> c a n
substituteXXs bts x
        = foldr (uncurry substituteXX) x bts


-- | Substitute the argument of an application into an expression.
--   Perform type substitution for an `XType` 
--    and witness substitution for an `XWitness`
substituteXArg 
        :: (Ord n, SubstituteXX c, SubstituteWX c, SubstituteTX (c a))
        => Bind n -> Arg a n -> c a n -> c a n

substituteXArg b arg x
 = case arg of
        RType     t    -> substituteTX   b t    x
        RWitness  w    -> substituteWX   b w    x
        RTerm     xArg -> substituteXX   b xArg x
        RImplicit a    -> substituteXArg b a    x


-- | Wrapper for `substituteXArgs` to substitute multiple arguments.
substituteXArgs
        :: (Ord n, SubstituteXX c, SubstituteWX c, SubstituteTX (c a))
        => [(Bind n, Arg a n)] -> c a n -> c a n

substituteXArgs bas x
        = foldr (uncurry substituteXArg) x bas


-------------------------------------------------------------------------------
class SubstituteXX (c :: * -> * -> *) where
 substituteWithXX 
        :: forall a n. Ord n 
        => Exp a n -> Sub n -> c a n -> c a n 


instance SubstituteXX Exp where 
 substituteWithXX xArg sub xx
  = {-# SCC substituteWithXX #-}
    let down s x   = substituteWithXX xArg s x
        into s x   = renameWith s x
    in case xx of
        XVar a u
         -> case substX xArg sub u of
                Left  u' -> XVar a u'
                Right x  -> x

        XPrim{}         -> xx
        XCon{}          -> xx

        XApp a x1 x2
         -> XApp a (down sub x1) (down sub x2)

        XAbs a (MType b) x
         -> let (sub1, b')      = bind1 sub b
                x'              = down  sub1 x
            in  XAbs a (MType b') x'

        XAbs a (MTerm b) x
         -> let (sub1, b')      = bind0 sub  b
                x'              = down  sub1 x
            in  XAbs a (MTerm b') x'

        XAbs a (MImplicit b) x
         -> let (sub1, b')      = bind0 sub  b
                x'              = down  sub1 x
            in  XAbs a (MImplicit b') x'

        XLet a (LLet b x1) x2
         -> let x1'             = down  sub  x1
                (sub1, b')      = bind0 sub  b
                x2'             = down  sub1 x2
            in  XLet a (LLet b' x1') x2'

        XLet a (LRec bxs) x2
         -> let (bs, xs)        = unzip  bxs
                (sub1, bs')     = bind0s sub bs
                xs'             = map (down sub1) xs
                x2'             = down sub1 x2
            in  XLet a (LRec (zip bs' xs')) x2'

        XLet a (LPrivate b mT bs) x2
         -> let mT'             = liftM (into sub) mT
                (sub1, b')      = bind1s sub  b
                (sub2, bs')     = bind0s sub1 bs
                x2'             = down   sub2 x2
            in  XLet a (LPrivate b' mT' bs') x2'

        XCase     a x1 alts
         -> XCase a (down sub x1) (map (down sub) alts)

        XCast     a cc x1 
         -> XCast a (down sub cc) (down sub x1)


instance SubstituteXX Arg where
 substituteWithXX xArg sub aa
  = let down s x   = substituteWithXX xArg s x
        into s x   = renameWith s x
    in case aa of
        RType t         -> RType     (into sub t)
        RTerm x         -> RTerm     (down sub x)
        RWitness w      -> RWitness  (into sub w)
        RImplicit x     -> RImplicit (down sub x)


instance SubstituteXX Alt where
 substituteWithXX xArg sub aa
  = let down s x = substituteWithXX xArg s x
    in case aa of
        AAlt PDefault xBody
         -> AAlt PDefault $ down sub xBody
        
        AAlt (PData uCon bs) x
         -> let (sub1, bs')     = bind0s sub bs
                x'              = down   sub1 x
            in  AAlt (PData uCon bs') x'


instance SubstituteXX Cast where
 substituteWithXX _xArg sub cc
  = let into s x = renameWith s x
    in case cc of
        CastWeakenEffect eff    -> CastWeakenEffect  (into sub eff)
        CastPurify w            -> CastPurify (into sub w)
        CastBox                 -> CastBox
        CastRun                 -> CastRun


-- | Rewrite or substitute into an expression variable.
substX  :: Ord n => Exp a n -> Sub n -> Bound n 
        -> Either (Bound n) (Exp a n)

substX xArg sub u
  = case substBound (subStack0 sub) (subBound sub) u of
        Left  u'                -> Left u'
        Right n  
         | not $ subShadow0 sub -> Right (liftX n xArg)
         | otherwise            -> Left  u


