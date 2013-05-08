
module DDC.Core.Flow.Transform.Extract
        (extractModule)
where
import DDC.Core.Flow.Compounds
import DDC.Core.Flow.Exp.Procedure
import DDC.Core.Flow.Prim
import DDC.Core.Module
import DDC.Core.Exp


-- | Extract a core module from some stream procedures.
--   This produces vanilla core code again.
extractModule    :: Module () Name -> [Procedure] -> Module () Name
extractModule orig procs
        = orig
        { moduleBody    = extractTop procs }


extractTop       :: [Procedure] -> Exp () Name
extractTop procs
 = XLet () (LRec (map extractProcedure procs)) (xUnit ())


-- | Extract code for a whole procedure.
extractProcedure  :: Procedure -> (Bind Name, Exp () Name)
extractProcedure (Procedure n bsParam xsParam nest stmts xResult tResult)
 = let  tBody   = foldr tFunPE  tResult $ map typeOfBind xsParam
        tQuant  = foldr TForall tBody   $ bsParam
   in   ( BName n tQuant
        ,   xLAMs () bsParam
          $ xLams () xsParam
          $ extractNest nest stmts xResult )


-------------------------------------------------------------------------------
-- | Extract code for a loop nest.
extractNest 
        :: [Loop]               -- ^ Loops to run in sequence.
        -> [Lets () Name]       -- ^ Baseband statements from the source program
                                --   that run after the loop operators.
        -> Exp () Name          -- ^ Final result of procedure.
        -> Exp () Name

extractNest loops stmts xResult
 = let stmts'   = concatMap extractLoop loops ++ stmts
   in  xLets () stmts' xResult


-------------------------------------------------------------------------------
-- | Extract code for a possibly nested loop.
extractLoop      :: Loop -> [Lets () Name]
extractLoop (Loop (Context tRate) starts bodys _nested ends _result)
 = let  
        -- Starting statements.
        lsStart = concatMap extractStmtStart starts

        -- The loop itself.
        lLoop   = LLet LetStrict 
                        (BNone tUnit)
                        (xApps () (XVar  () (UPrim (NameOpLoop OpLoopLoop) 
                                                   (typeOpLoop OpLoopLoop)))
                                [ XType tRate           -- loop rate
                                , xBody ])              -- loop body

        -- The worker passed to the loop# combinator.
        xBody   = XLam  () (BAnon tNat)                 -- loop counter.
                $ xLets () lsBody
                           (xUnit ())

        -- Process the elements.
        lsBody  = concatMap extractStmtBody bodys

        -- Ending statements.
        lsEnd   = concatMap extractStmtEnd ends

   in   lsStart ++ [lLoop] ++ lsEnd


-------------------------------------------------------------------------------
-- | Extract loop starting code.
--   This comes before the main loop.
extractStmtStart :: StmtStart -> [Lets () Name]
extractStmtStart ss
 = case ss of

        -- Initialise the accumulator for a reduction operation.
        StartAcc n t x    
         -> [LLet LetStrict (BName n (tRef t)) 
                  (xNew t x)]        


-------------------------------------------------------------------------------
-- | Extract loop body code.
extractStmtBody  
        :: StmtBody  
        -> [Lets () Name]

extractStmtBody sb
 = case sb of
        BodyStmt b x
         -> [ LLet LetStrict b x ]

        -- Read from an accumulator.
        BodyAccRead  n t bVar
         -> [ LLet LetStrict bVar
                   (xRead t (XVar () (UName n))) ]

        -- Accumulate an element from a stream.
        BodyAccWrite nAcc tElem xWorker    
         -> [ LLet LetStrict (BNone tUnit)
                   (xWrite tElem (XVar () (UName nAcc)) xWorker)]


-------------------------------------------------------------------------------
-- | Extract loop ending code.
--   This comes after the main loop.
extractStmtEnd   :: StmtEnd   -> [Lets () Name]
extractStmtEnd se
 = case se of
        EndStmts ss     
         -> map extractStmt ss

        -- Read the accumulator of a reduction operation.
        EndAcc n t nAcc 
         -> [LLet LetStrict (BName n t) 
                  (xRead t (XVar () (UName nAcc))) ]


-------------------------------------------------------------------------------
-- | Extract code for a generic statement.
extractStmt       :: Stmt -> Lets () Name
extractStmt (Stmt b x)
 = LLet LetStrict b x
 
