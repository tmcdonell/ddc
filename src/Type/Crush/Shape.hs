-- | Handles crushing of shape constraints.

module Type.Crush.Shape
	( crushShape )
where


import Type.Feed
import Type.Location
import Type.Exp
import Type.Pretty
import Type.Util
import Type.State
import Type.Class
import Type.Plate.FreeVars
import Type.Plate.Collect

import Type.Crush.Unify

import Shared.Error
import Shared.VarPrim
import Shared.Var	(Var, NameSpace(..))
import qualified Shared.VarBind	as Var
import qualified Shared.Var	as Var

import qualified Data.Map	as Map
import Data.Map			(Map)

import qualified Data.Set	as Set
import Data.Set			(Set)

import Util

-----
debug	= False
trace s	= when debug $ traceM s

-----
-- crushShape
--	Try and crush the Shape constraint in this class.
--	If any of the nodes in the constraint contains a type constructor then add a similar constructor
--	to the other nodes and remove the constraint from the graph.
--
--	TODO: Add more shape fetters recursively.
--
--	returns whether we managed to crush this fetter.
--
crushShape :: ClassId -> SquidM Bool
crushShape cidShape
 = do 	
	-- Grab the Shape fetter from the class and extract the list of cids to be merged.
	Just shapeC@ClassFetter
		{ classFetter	= fShape@(FConstraint v shapeTs)
		, classSource	= srcShape }	
			<- lookupClass cidShape

	-- All the cids constrained by the Shape constraint.
	let mergeCids	= map (\(TClass k cid) -> cid) shapeTs

	trace	$ "*   Crush.crushShape " 	% cidShape 	% "\n"
		% "    fetter      = "	 	% fShape	% "\n"
		% "    mergeCids   = "		% mergeCids 	% "\n"

 	-- Make sure that all the classes to be merged are unified.
	--	We're expecting a maximum of one constructor per class queue.
 	mapM crushUnifyClass mergeCids
 
	-- Lookup all the nodes.
 	csMerge		<- liftM (map (\(Just c) -> c)) 
 			$  mapM lookupClass mergeCids

	-- See if any of the nodes contain information that needs
	--	to be propagated to the others.
	let mData	= map (\c -> case classType c of
					Just t@TApp{}	-> Just t
					Just t@TCon{}	-> Just t
					_		-> Nothing)
			$ csMerge
	
	trace	$ "    classTypes   = " % map classType  csMerge % "\n"
	
	-- If we have to propagate the constraint we'll use the first constructor as a template.
	let mTemplate	= takeFirstJust mData
	trace	$ "    mData       = "	% mData		% "\n"
		% "    mTemplate    = "	% mTemplate	% "\n"
		% "\n"

	let result
		-- If the constrained equivalence class is of effect or closure kind
		--	then we can just delete the constraint
		| TClass k _ : _	<- shapeTs
		, k == kClosure || k == kEffect
		= do	delClass cidShape
			return True

		-- none of the nodes contain data constructors, so there's no template to work from
		| Nothing	<- mTemplate
		= return False
		
		-- we've got a template
		--	we can now merge the sub-classes and remove the shape constraint.
		| Just tTemplate	<- mTemplate
		= do	crushShape2 cidShape fShape srcShape tTemplate csMerge
			delClass cidShape
			
			return True
	
	result		


crushShape2 
	:: ClassId		-- the classId of the fetter being crushed
	-> Fetter		-- the shape fetter being crushed
	-> TypeSource		-- the source of the shape fetter
	-> Type			-- the template type"
	-> [Class]		-- the classes being merged
	-> SquidM ()

crushShape2 cidShape fShape srcShape tTemplate csMerge
 = do
 	trace  	( "*   Crush.crushShape2\n"
	 	% "    cidShape  = " % cidShape		% "\n"
		% "    fShape    = " % fShape		% "\n"
		% "    srcShape  = " % srcShape		% "\n"
		% "    tTemplate = " % tTemplate	% "\n")

	let srcCrushed	= TSI $ SICrushedFS cidShape fShape srcShape

	-- push the template into classes which don't already have a ctor
	mtsPushed	<- mapM (pushTemplate tTemplate srcCrushed) csMerge
	
	let result
		| Just tsPushed		<- sequence mtsPushed
		= do	
			let takeRec tt 
				| TApp t1 t2		<- tt
				= [t1, t2]
				
				| otherwise
				= []
					
			let tssMerged	= map takeRec tsPushed
	
			let tssMergeRec	= transpose tssMerged
		
			trace	( "    tssMergeRec = " % tssMergeRec		% "\n")

			-- add shape constraints to constraint the args as well
			mapM_ (addShapeFetter srcCrushed) tssMergeRec

		  	return ()
		
		-- If adding the template to another class would result in a type error
		--	then stop now. We don't want to change the graph anymore if it
		--	already has errors.
		| otherwise
		= return ()

	result

addShapeFetter :: TypeSource -> [Type] -> SquidM ()
addShapeFetter src ts@(t1 : _)

	-- shape fetters don't constrain regions.
 	| kindOfType_orDie t1 == kRegion
	= return ()
	
	| otherwise
	= do	addFetterSource src (FConstraint (primFShape (length ts)) ts)
		return ()

-- | Add a template type to a class.
pushTemplate 
	:: Type			-- the template type
	-> TypeSource		-- the source of the shape fetter doing the pushing
	-> Class		-- the class to push the template into.
	-> SquidM (Maybe Type)
	
pushTemplate tTemplate srcShape cMerge

	-- if this class does not have a constructor then we 
	--	can push the template into it.
	| Class { classType = Just (TBot k) }	<- cMerge
	= do	
		tPush	<- freshenType tTemplate
		trace 	$ "  - merge class\n"
			% "    tPush = " % tPush	% "\n"		

		addToClass (classId cMerge) srcShape tPush
		return $ Just tPush		

	-- If adding the template will result in a type error then add the error to
	-- 	the solver state, and return Nothing.
	--	This prevents the caller, crushShape2 recursively adding more errornous
	--	Shape constraints to the graph.
	--	
	| Class { classType = Just t}		<- cMerge
	= if isShallowConflict t tTemplate
	   then	
	    do	let cError	= cMerge { classNodes = (tTemplate, srcShape) : classNodes cMerge }
	 	addErrorConflict (classId cError) cError
		return Nothing

	   else return (Just t)
	
 	
	
-- | replace all the free vars in this type with new ones
freshenType :: Type -> SquidM Type
freshenType tt
 = do	let cidsFree	= collectClassIds tt
 	cidsFresh	<- mapM freshenCid cidsFree
	let sub		= Map.fromList $ zip cidsFree cidsFresh

	return	$ subCidCid sub tt

freshenCid :: ClassId -> SquidM ClassId
freshenCid cid
 = do	Just Class { classKind = k }	
 		<- lookupClass cid
 
 	cid'	<- allocClass (Just k)
	updateClass cid'
		(classInit cid' k)
			{ classType = Just (TBot k) }

	return	cid'
 
