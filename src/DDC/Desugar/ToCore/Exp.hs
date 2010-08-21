
-- | Conversion of desugared expressions to core.
module DDC.Desugar.ToCore.Exp
	( toCoreS
	, toCoreX
	, toCoreA
	, toCoreG
	, toCoreW )
where
import DDC.Desugar.ToCore.Base
import DDC.Desugar.ToCore.Lambda
import DDC.Desugar.ToCore.Literal
import DDC.Desugar.ToCore.VarInst
import DDC.Main.Pretty
import DDC.Main.Error
import DDC.Base.Literal
import DDC.Base.DataFormat
import DDC.Base.SourcePos
import DDC.Var
import Shared.VarPrim
import Control.Monad
import Control.Monad.State
import Data.Maybe
import Util
import Desugar.Pretty				()
import Shared.VarUtil				(isDummy, varPos)
import qualified DDC.Type			as T
import qualified DDC.Desugar.Exp		as D
import qualified DDC.Core.Exp			as C
import qualified Core.Util			as C
import qualified Desugar.Plate.Trans		as D
import qualified Data.Map			as Map
import qualified Debug.Trace

stage		= "DDC.Desugar.ToCore.Exp"
debug		= False
trace ss x	= if debug then Debug.Trace.trace (pprStrPlain ss) x else x

-- Stmt --------------------------------------------------------------------------------------------
-- | Convert a desugared statement to the core language.
toCoreS	:: D.Stmt Annot	
	-> CoreM (Maybe C.Stmt)
		
toCoreS (D.SBind _ Nothing x)
 = do	x'		<- toCoreX x
	return $ Just $ C.SBind Nothing x'

toCoreS (D.SBind _ (Just v) x) 
 = do	-- lookup the generalised type of this binding.
	Just tScheme	<- lookupType v

 	-- convert the right to core.
	xCore	<- toCoreX x

	-- add type abstractions.
	xLam	<- fillLambdas v tScheme xCore

	-- add a type annotation to the innermost body of the set of abstractions
	-- this makes it easy to determine the type of the whole binding later.
	let xLam_annot = C.dropXTau xLam Map.empty tScheme

	return $ Just $ C.SBind (Just v) xLam_annot

-- we don't need separate type sigs in the core language.
toCoreS	D.SSig{}
 = return Nothing

toCoreS ss
 	= panic stage 	
	$ "no match for " % show ss
	% " should have been eliminated by original source desugaring."


-- Exp ---------------------------------------------------------------------------------------------
-- | Expressions
toCoreX	:: D.Exp Annot -> CoreM C.Exp
toCoreX xx
 =  case xx of

	D.XLambdaTEC 
		_ v x (T.TVar kV (T.UVar vTV)) eff clo
	 | kV == T.kValue
	 -> do	
		-- Strip contexts off argument types, if we need the associated witnesses then these
		--	will be passed into the outer function.
		Just tArg1	<- lookupType vTV
		let  tArg	= T.stripToBodyT tArg1

		-- If the effect/closures were vars then look them up from the graph
		effAnnot	<- loadEffAnnot eff
		cloAnnot	<- loadCloAnnot clo
		x'		<- toCoreX x
		
		-- carry down set of quant type vars
		-- sink annot var. If it's in the quant set we have to add a more-than constraint.
		-- otherwise just add the effects.
		
		return	
		 $ trace (vcat 
			[ ppr "toCoreX: XLam"
			, "eff      = " % eff
			, "effAnnot = " % effAnnot
			, "clo      = " % clo	
			, "cloAnnot = " % cloAnnot ])
		 $ C.XLam v tArg x'
			(T.packType $ effAnnot)
			(T.packType $ cloAnnot)


	D.XApp	_ x1 x2
	 -> do
	 	x1'	<- toCoreX x1
		x2'	<- toCoreX x2
		return	$ C.XApp x1' x2'


	-- case match on a var
	D.XMatch _ (Just (D.XVar _ varX)) alts
	 -> do	alts'		<- mapM (toCoreA (Just (varX, T.TNil))) alts
		
		return	$ C.XDo	[ C.SBind Nothing (C.XMatch alts') ]

	-- case match on an exp
	D.XMatch _ (Just x) alts
	 -> do	x'	<- toCoreX x
		varX	<- newVarN NameValue
		
		alts'	<- mapM (toCoreA (Just (varX, T.TNil))) alts
		
		return	$ C.XDo	[ C.SBind (Just varX) x'
				, C.SBind Nothing (C.XMatch alts') ]
			
	-- regular  match
	D.XMatch _ Nothing alts
	 -> do	alts'	<- mapM (toCoreA Nothing) alts
		
		return	$ C.XDo	[ C.SBind Nothing (C.XMatch alts') ]
		
	-- primitive constants
	D.XLit (Just (T.TVar kV (T.UVar vT), _)) _
	 | kV	== T.kValue
	 -> do	
	 	Just t		<- lookupType vT
	 	let t_flat	= T.stripToBodyT 
				$ T.flattenT t
	
		return		$ toCoreXLit t_flat xx

 
	-- We need the last statement in a do block to be a non-binding because of an
	--	interaction between the way we annotate generalised schemes with their types.
	--
	-- 	In this example:
	--		f () = do { a1 = 2; g () = a1 + 3; };
	--
	-- 	We infer:
	--          f :: forall %r1 %r2. () -> () -($c1)> Int %r1
	--   	      :- $c1 = a1 :: Int %r2
	--
	-- 	But in the core we reconstruct:
	--          g :: forall %r1. () -($c1)> Int %r1
	--            :- $c1 = a :: Int %r2
	--      and
	--          f :: forall %r2. () -> forall %r1. -($c1)> Int %r1
	--
	--	Forcing the last element of the XDo to be a value, ie
	--		f () = do { a1 = 2; g () = a1 + 3; g; }
	--	provides an instantiation of g, so its no longer directly quantified.
	--
	--	We could perhaps make the ToCore transform cleverer, but forcing the last statement
	--	to be a value seems a reasonable request, so we'll just run with that.
	--
	D.XDo 	_ stmts
	 -> do	stmts'	<- liftM catMaybes
	 		$  mapM toCoreS stmts
	
		case takeLast stmts' of
		 Just stmt@(C.SBind (Just _) _)
		  -> panic stage
		  	$ "toCoreX: last statement of a do block cannot be a binding.\n"
			% "    offending statement:\n"	%> stmt	% "\n"
		 
		 _ -> return	$ C.XDo stmts'
			
			
	D.XIfThenElse _ e1 e2 e3
	 -> do
		v	<- newVarN NameValue

		e1'	<- toCoreX e1
		e2'	<- toCoreA (Just (v, T.TNil)) (D.AAlt Nothing [D.GCase Nothing (D.WConLabel Nothing primTrue  [])] e2)
		e3'	<- toCoreA (Just (v, T.TNil)) (D.AAlt Nothing [D.GCase Nothing (D.WConLabel Nothing primFalse [])] e3)
		
		return	$ C.XDo	[ C.SBind (Just v) e1'
				, C.SBind Nothing (C.XMatch [ e2', e3' ]) ]
	
	-- projections
	D.XProjTagged 
		(Just 	( T.TVar kV _
			, T.TVar kE _))
		vTagInst _ x2 _
	 | kV == T.kValue
	 , kE == T.kEffect
	 -> do
		x2'		<- toCoreX x2
		
		-- lookup the var for the projection function to use
		projResolve	<- gets coreProjResolve

		let vProj
		 	= case Map.lookup vTagInst projResolve of
				Nothing	-> panic stage
					$ "No projection function for " % vTagInst % "\n"
					% " exp = " % xx % "\n\n"

				Just v	-> v
							
		x1'	<- toCoreVarInst vProj vTagInst
			
		return	$ C.XApp x1' x2'

	D.XProjTaggedT
		(Just 	( T.TVar kV _
			, T.TVar kE _))
		vTagInst _ _
	 | kV == T.kValue
	 , kE == T.kEffect
	 -> do
		-- lookup the var for the projection function to use
		projResolve	<- gets coreProjResolve
		let Just vProj	= Map.lookup vTagInst projResolve
		
		x1'	<- toCoreVarInst vProj vTagInst
		return	$ x1' 



	-- variables
	D.XVarInst 
		(Just (T.TVar kV (T.UVar vT), _))
		v
	 | kV == T.kValue
	 -> 	toCoreVarInst v vT

	_ 
	 -> panic stage
		$ "toCoreX: cannot convert expression to core.\n" 
		% "    exp = " %> (D.transformN (\_ -> (Nothing :: Maybe ())) xx) % "\n"


-- Alt ---------------------------------------------------------------------------------------------
-- | Case Alternatives
toCoreA	:: Maybe (Var, T.Type)
	-> D.Alt Annot -> CoreM C.Alt
		
toCoreA mObj alt
 = case alt of
	D.AAlt _ gs x
	 -> do	
	 	gs'	<- mapM (toCoreG mObj) gs
		x'	<- toCoreX x
		
		return	$ C.AAlt gs' x'
	
	
-- Guards ------------------------------------------------------------------------------------------
-- | Guards
toCoreG :: Maybe (Var, T.Type)
	-> D.Guard Annot
	-> CoreM C.Guard

toCoreG mObj gg
	| D.GCase _ w		<- gg
	, Just (objV, objT)	<- mObj
	= do	(w', mustUnbox)	<- toCoreW w

		let x		= C.XVar objV objT
		case mustUnbox of
		 Just r		-> return $ C.GExp w' (C.XPrim C.MUnbox [C.XPrimType r, C.XPrim C.MForce [x]])
		 Nothing	-> return $ C.GExp w' x
		
	| D.GExp _ w x		<- gg
	= do	(w', mustUnbox)	<- toCoreW w
	 	x'		<- toCoreX x
		
		-- All literal matching in core is unboxed, so we must unbox the match object if need be.
		case mustUnbox of
		 Just r		-> return $ C.GExp w' (C.XPrim C.MUnbox [C.XPrimType r, C.XPrim C.MForce [x']])
		 Nothing	-> return $ C.GExp w' x'

 	| otherwise
	= panic stage 
		$ "no match for " % show gg
		% " should have been eliminated by original source desugaring."


-- Patterns ----------------------------------------------------------------------------------------
-- | Patterns
toCoreW :: D.Pat Annot
	-> CoreM 
		( C.Pat
		, Maybe T.Type)	-- whether to unbox the RHS, and from what region
	
toCoreW ww
	| D.WConLabel _ v lvs	<- ww
	= do	let vlist	= filter (not . isDummy) $ v : map snd lvs
		let spos	= if length vlist == 0
					then SourcePos ("?", 0, 0)
					else varPos $ head vlist 
		lvts		<- mapM toCoreA_LV lvs
		return	( C.WCon spos v lvts
			, Nothing)
	 
	-- match against a boxed literal
	--	All matches in the core language are against unboxed literals, 
	--	so we need to rewrite the literal in the pattern as well as the guard expression.
	| D.WLit (Just	( T.TVar kV (T.UVar vT)
			, _))
			(LiteralFmt lit fmt) <- ww
	, kV == T.kValue

	, dataFormatIsBoxed fmt
	= do	mT	<- liftM (liftM T.stripToBodyT)
	 		$  lookupType vT
	 
		-- work out what region the value to match against is in
		--	we pass this back up to toCoreG so it knows to do the unboxing.
	 	let Just tLit		= mT
		let Just (_, _, r : _)	= T.takeTData tLit

		-- get the unboxed version of this data format.
	 	let Just fmt_unboxed	= dataFormatUnboxedOfBoxed fmt
	
	 	return	( C.WLit (varPos vT) (LiteralFmt lit fmt_unboxed)
			, Just r)
	
	-- match against unboxed literal
	--	we can do this directly.
	| D.WLit
		(Just 	( T.TVar kV (T.UVar vT)
			, _ )) 
		litFmt@(LiteralFmt _ fmt)	<- ww
	, kV == T.kValue
	, dataFormatIsUnboxed fmt
	= do	return	( C.WLit (varPos vT) litFmt
			, Nothing)


	-- match against a variable
	| D.WVar (Just 	(T.TVar kV _
			, _))
		var		<- ww
	, kV == T.kValue
	= do
		return	( C.WVar var
			, Nothing)

	| otherwise
	= panic stage
		$ "tCoreW: no match for " % show ww % "\n"
	 

toCoreA_LV (D.LIndex _ i, v)
 = do	Just t		<- lookupType v
 	let t_flat	= (T.flattenT . T.stripToBodyT) t
	return	(C.LIndex i, v, t_flat)

toCoreA_LV (D.LVar _ vField, v)
 = do	Just t		<- lookupType v
 	let t_flat	= (T.flattenT . T.stripToBodyT) t
 	return	(C.LVar vField, v, t_flat)
