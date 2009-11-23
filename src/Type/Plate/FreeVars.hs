{-# OPTIONS -fwarn-incomplete-patterns #-}

module Type.Plate.FreeVars
	(FreeVars(..))

where

import Shared.Error
import Shared.FreeVars
import Type.Exp

import qualified Data.Set	as Set
import Data.Set			(Set, (\\), empty, union, unions, fromList, singleton)


-- Var ---------------------------------------------------------------------------------------------
instance FreeVars Var where
 freeVars v	= singleton v
 
-- Type --------------------------------------------------------------------------------------------
instance FreeVars Type where
 freeVars tt
  = case tt of
	TNil
	 -> empty

	TForall (BVar v) k t
	 -> (unions 
	 	[ freeVars k
		, freeVars t]) 	\\ singleton v

	TForall (BMore v t1) k t2
	 -> (unions 
	 	[ freeVars t1
		, freeVars k
		, freeVars t2])	\\ singleton v
	 
	TContext k t
	 -> union (freeVars k) (freeVars t)

	TFetters t fs
	 -> union (freeVars fs) (freeVars t)
	 	\\ (fromList [ v | FWhere (TVar k v) _ <- fs])
		
	TSum k ts	-> freeVars ts
	 
	TApp t1 t2	-> union (freeVars t1) (freeVars t2)
	
	TCon tycon	-> freeVars tycon
	
 	TVar k v	-> singleton v

	TTop k	-> empty
	TBot k	-> empty

	-- data
{-	TFun t1 t2 eff clo
	 -> unions
	 	[ freeVars t1
		, freeVars t2
		, freeVars eff
		, freeVars clo ]

	TData k v ts	
	 -> union (singleton v) (freeVars ts)
-}	
	-- effect
	TEffect v ts
	 -> union (singleton v) (freeVars ts)
	 
	-- closure
	TFree v t	-> freeVars t

	TDanger t1 t2	
	 -> unions 
	 	[ freeVars t1
		, freeVars t2]

	-- used in solver
	TClass{}	-> empty
	TError{}	-> empty
	TFetter f	-> freeVars f
	 
	-- sugar
	TElaborate ee t	-> freeVars t
	
	-- core stuff
	TVarMore k v t
	 -> unions
	 	[ Set.singleton v
		, freeVars t]
	
	TWitJoin ts
	 -> unions $ map freeVars ts

	TIndex{}	-> empty
	

-- TyCon -------------------------------------------------------------------------------------------
instance FreeVars TyCon where
 freeVars tt
  = case tt of
  	TyConFun{}			-> Set.empty
	TyConData  { tyConName }	-> Set.singleton tyConName
	TyConClass { }			-> Set.empty

{-
instance FreeVars TyCon where
 freeVars tycon
 	= singleton $ tyConName tycon
-}  
-- Kind --------------------------------------------------------------------------------------------
instance FreeVars Kind where
 freeVars kk	= empty
	

-- Fetter ------------------------------------------------------------------------------------------
instance FreeVars Fetter where
 freeVars f
  = case f of
	FConstraint v ts	
	 -> union (singleton v) (freeVars ts)

	FWhere (TVar k v) t2
	 -> freeVars t2
	 	\\ singleton v

	FWhere t1 t2
	 -> union (freeVars t1) (freeVars t2)
		
	FMore t1 t2
	 -> union (freeVars t1) (freeVars t2)

	FProj pj v tDict tBind
	 -> unions
	 	[ singleton v
		, freeVars tDict
		, freeVars tBind]




