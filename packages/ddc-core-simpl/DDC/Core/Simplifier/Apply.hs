
-- | Application of simplifiers to modules and expressions.
module DDC.Core.Simplifier.Apply
        ( applySimplifier
        , applyTransform

        , applySimplifierX
        , applyTransformX)
where
import DDC.Base.Pretty
import DDC.Core.Module
import DDC.Core.Exp
import DDC.Core.Simplifier.Base
import DDC.Core.Transform.AnonymizeX
import DDC.Core.Transform.Snip
import DDC.Core.Transform.Flatten
import DDC.Core.Transform.Beta
import DDC.Core.Transform.Forward
import DDC.Core.Transform.Inline
import DDC.Core.Transform.Namify
import DDC.Core.Transform.Rewrite
import Control.Monad.State.Strict
import qualified DDC.Base.Pretty	as P
import Data.Typeable (Typeable)


-- Modules --------------------------------------------------------------------
-- | Apply a simplifier to a module.
--
--   The state monad holds a fresh name generator.
applySimplifier 
        :: (Show a, Ord n, Show n, Pretty n) 
        => Simplifier s a n     -- ^ Simplifier to apply.
        -> Module a n           -- ^ Module to simplify.
        -> State s (Module a n)

applySimplifier spec mm
 = case spec of
        Seq t1 t2
         -> do  mm'     <- applySimplifier t1 mm
                applySimplifier t2 mm'

        Trans t1
         -> applyTransform t1 mm
	
	Fix _ _
	 -> error "applySimplifier: finish fix"


-- | Apply a transform to a module.
applyTransform
        :: (Show a, Ord n, Show n, Pretty n)
        => Transform s a n      -- ^ Transform to apply.
        -> Module a n           -- ^ Module to simplify.
        -> State s (Module a n)

applyTransform spec mm
 = case spec of
        Id               -> return mm
        Anonymize        -> return $ anonymizeX mm
        Snip             -> return $ snip mm
        Flatten          -> return $ flatten mm
        Beta             -> return $ betaReduce mm
        Forward          -> return $ forwardModule mm
        Namify namK namT -> namifyUnique namK namT mm
        Inline getDef    -> return $ inline getDef mm
        _                -> error "applyTransform: finish me"


-- Expressions ----------------------------------------------------------------
-- | Apply a simplifier to an expression.
--
--   The state monad holds a fresh name generator.
applySimplifierX 
        :: (Show a, Show n, Ord n, Pretty n)
        => Simplifier s a n     -- ^ Simplifier to apply.
        -> Exp a n              -- ^ Exp to simplify.
        -> State s (TransformResult a n)

applySimplifierX spec xx
 = case spec of
        Seq t1 t2
         -> do  tx  <- applySimplifierX t1 xx
                tx' <- applySimplifierX t2 (resultExp tx)

		let info =
			case (resultInfo tx, resultInfo tx') of
			(TransformInfo i1, TransformInfo i2) -> SeqInfo i1 i2
		
		return TransformResult
		    { resultExp	     = resultExp tx'
		    , resultProgress = resultProgress tx || resultProgress tx'
		    , resultInfo     = TransformInfo info }

	Fix i s
	 -> do	tx <- applyFixpointX i s xx
		let info =
			case resultInfo tx of
			TransformInfo info1 -> FixInfo i info1
		
		return TransformResult
		    { resultExp	     = resultExp tx
		    , resultProgress = resultProgress tx
		    , resultInfo     = TransformInfo info }
		
        Trans t1
         -> applyTransformX  t1 xx


-- | Apply a simplifier until it stops progressing, or a maximum number of times
applyFixpointX
        :: (Show a, Show n, Ord n, Pretty n)
        => Int			-- ^ Maximum number of times to apply
	-> Simplifier s a n     -- ^ Simplifier to apply.
        -> Exp a n              -- ^ Exp to simplify.
        -> State s (TransformResult a n)
applyFixpointX i' s xx'
 = go i' xx'
 where
  go 0 xx = applySimplifierX s xx
  go i xx = do
    tx <- applySimplifierX s xx
    case resultProgress tx of
	False ->
	    return tx
	True  -> do
	    tx' <- go (i-1) (resultExp tx)
	    let info =
		    case (resultInfo tx, resultInfo tx') of
		    (TransformInfo i1, TransformInfo i2) -> SeqInfo i1 i2
	    
	    return TransformResult
		{ resultExp	 = resultExp tx'
		, resultProgress = resultProgress tx'
		, resultInfo     = TransformInfo info }

    

data SeqInfo
    = forall i1 i2.
    (Typeable i1, Typeable i2, Pretty i1, Pretty i2)
    => SeqInfo i1 i2
    deriving Typeable


instance Pretty SeqInfo where
    ppr (SeqInfo i1 i2) = ppr i1 P.<> text ";" <$> ppr i2


data FixInfo
    = forall i1.
    (Typeable i1, Pretty i1)
    => FixInfo Int i1
    deriving Typeable


instance Pretty FixInfo where
    ppr (FixInfo num i1) =
	text "fix" <+> int num P.<> text ":"
	    <$> indent 4 (ppr i1)


-- | Apply a transform to an expression.
applyTransformX 
        :: (Show a, Show n, Ord n, Pretty n)
        => Transform s a n      -- ^ Transform to apply.
        -> Exp a n              -- ^ Exp  to transform.
        -> State s (TransformResult a n)

applyTransformX spec xx
 = case spec of
        Id                -> return $ resultSimple xx
        Anonymize         -> return $ resultSimple $ anonymizeX xx
        Snip              -> return $ resultSimple $ snip xx
        Flatten           -> return $ resultSimple $ flatten xx
        Inline  getDef    -> return $ resultSimple $ inline getDef xx
        Beta              -> return $ resultSimple $ betaReduce xx
        Forward           -> return $ resultSimple $ forwardX xx
        Namify  namK namT -> namifyUnique namK namT xx >>= return.resultSimple
        Rewrite rules     -> return $ rewrite rules xx

