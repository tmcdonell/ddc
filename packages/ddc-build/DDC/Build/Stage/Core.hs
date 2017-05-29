
module DDC.Build.Stage.Core
        ( coreLoad
        , ConfigCoreLoad (..)

        , coreCheck
        , coreReCheck
        , coreResolve
        , coreSimplify)
where
import Control.Monad.State.Strict
import Control.Monad.Trans.Except
import Control.DeepSeq

import DDC.Data.Pretty
import DDC.Data.Name
import qualified DDC.Control.Parser                     as Parser

import qualified DDC.Data.SourcePos                     as SP

import qualified DDC.Build.Pipeline.Sink                as B
import qualified DDC.Build.Pipeline.Error               as B

import qualified DDC.Core.Fragment                      as C
import qualified DDC.Core.Check                         as C
import qualified DDC.Core.Module                        as C
import qualified DDC.Core.Exp                           as C
import qualified DDC.Core.Parser                        as C
import qualified DDC.Core.Lexer                         as C
import qualified DDC.Core.Simplifier                    as C
import qualified DDC.Core.Env.Soup                      as C

import qualified DDC.Core.Transform.Reannotate          as CReannotate
import qualified DDC.Core.Transform.Resolve             as CResolve
import qualified DDC.Core.Transform.SpreadX             as CSpread


---------------------------------------------------------------------------------------------------
data ConfigCoreLoad
        = ConfigCoreLoad
        { configSinkTokens      :: B.Sink       -- ^ Sink for source tokens.
        , configSinkParsed      :: B.Sink       -- ^ Sink after parsing.
        , configSinkChecked     :: B.Sink       -- ^ Sink after type checking.
        , configSinkTrace       :: B.Sink       -- ^ Sink for type checker trace.
        }

-- | Load a closed core module from text.
coreLoad
        :: (Ord n, Show n, Pretty n, Pretty (err (C.AnTEC SP.SourcePos n)))
        => String                       -- ^ Name of compiler stage.
        -> C.Fragment n err             -- ^ Language fragment to check.
        -> C.Mode n                     -- ^ Checker mode.
        -> String                       -- ^ Name of source file.
        -> Int                          -- ^ Line of source file.
        -> String                       -- ^ Textual core code.
        -> ConfigCoreLoad               -- ^ Sinked config.
        -> ExceptT [B.Error] IO (C.Module (C.AnTEC SP.SourcePos n) n)

coreLoad !_stage !fragment !mode !srcName !srcLine !str !config 
 = do   
        -- Parse the module.
        mm_core    <- coreParse fragment srcName srcLine 
                        (configSinkTokens config)
                        str

        liftIO $ B.pipeSink (renderIndent $ ppr mm_core) 
                            (configSinkParsed config)

        -- Type check the module.
        mm_checked <- coreCheck "CoreLoad" fragment mode
                        (configSinkTrace   config)
                        (configSinkChecked config)  
                        mempty mm_core

        return mm_checked


---------------------------------------------------------------------------------------------------
-- | Parse a text file as core code.
coreParse 
        :: (Ord n, Pretty n, Show n)
        => C.Fragment n err             -- ^ Language fragment.
        -> String                       -- ^ Name of source file.
        -> Int                          -- ^ Line number in source file.
        -> B.Sink                       -- ^ Sink for tokens.
        -> String                       -- ^ Text of source file.
        -> ExceptT [B.Error] IO (C.Module SP.SourcePos n)

coreParse fragment srcName srcLine sinkTokens str
 = do   
        -- Lex the input text into tokens.
        let tokens = C.fragmentLexModule fragment srcName srcLine str

        -- Dump tokens to file.
        liftIO $ B.pipeSink 
                        (unlines $ map (show . SP.valueOfLocated) $ tokens)
                        sinkTokens

        -- Parse the tokens into a Core Tetra module.
        let profile = C.fragmentProfile fragment
        let context = C.contextOfProfile profile

        -- Parse core module.
        mm_parsed <- case Parser.runTokenParser 
                                C.describeToken srcName (C.pModule context) tokens of
                        Left err -> throwE [B.ErrorLoad err]
                        Right mm -> return mm

        -- Detect names of primitives values and types in parsed code.
        let kenv      = C.profilePrimKinds profile
        let tenv      = C.profilePrimTypes profile
        let mm_spread = CSpread.spreadX kenv tenv mm_parsed

        return mm_spread


---------------------------------------------------------------------------------------------------
-- | Type check a module.
coreCheck
        :: ( Pretty a, Show a
           , Pretty (err (C.AnTEC a n))
           , Ord n, Show n, Pretty n)
        => String                       -- ^ Name of compiler stage.
        -> C.Fragment n err             -- ^ Language fragment to check.
        -> C.Mode n                     -- ^ Checker mode.
        -> B.Sink                       -- ^ Sink for checker trace.
        -> B.Sink                       -- ^ Sink for checked core code.
        -> C.Soup   n                   -- ^ Top-level soup for the module.
        -> C.Module a n                 -- ^ Core module to check.
        -> ExceptT [B.Error] IO (C.Module (C.AnTEC a n) n)

coreCheck !stage !fragment !mode !sinkTrace !sinkChecked !soup !mm
 = {-# SCC "coreCheck" #-}
   do
        let profile  = C.fragmentProfile fragment
        let config   = C.configOfProfile profile

        -- Type check the module with the generic core type checker.
        mm_checked      
         <- case C.checkModule config soup mm mode of
                (Left err,  C.CheckTrace doc) 
                 -> do  liftIO $  B.pipeSink (renderIndent doc) sinkTrace
                        throwE $ [B.ErrorLint stage "PipeCoreCheck/Check" err]
                        
                (Right mm', C.CheckTrace doc) 
                 -> do  liftIO $ B.pipeSink (renderIndent doc)  sinkTrace
                        return mm'

        liftIO $ B.pipeSink (renderIndent $ ppr mm_checked) sinkChecked


        -- Check that the module compiles with the language profile.
        mm_complies
         <- case C.complies profile mm_checked of
                Just err -> throwE [B.ErrorLint stage "PipeCoreCheck/Complies" err]
                Nothing  -> return mm_checked


        -- Check that the module satisfies fragment specific checks.
        mm_fragment
         <- case C.fragmentCheckModule fragment mm_complies of
                Just err -> throwE [B.ErrorLint stage "PipeCoreCheck/Fragment" err]
                Nothing  -> return mm_complies

        return mm_fragment


---------------------------------------------------------------------------------------------------
-- | Re-check a closed core module, replacing existing type annotations.
coreReCheck
        :: ( Pretty a, Show a
           , Pretty (err (C.AnTEC a n))
           , Ord n, Show n, Pretty n)
        => String                       -- ^ Name of compiler stage.
        -> C.Fragment n err             -- ^ Language fragment to check.
        -> C.Mode n                     -- ^ Checker mode.
        -> B.Sink                       -- ^ Sink for checker trace.
        -> B.Sink                       -- ^ Sink for checked core code.
        -> C.Module (C.AnTEC a n) n     -- ^ Core module to check.
        -> ExceptT [B.Error] IO (C.Module (C.AnTEC a n) n)

coreReCheck !stage !fragment !mode !sinkTrace !sinkChecked !mm
 = {-# SCC "coreReCheck" #-}
   do
        let mm_reannot  = CReannotate.reannotate C.annotTail mm
        coreCheck stage fragment mode sinkTrace sinkChecked mempty mm_reannot


---------------------------------------------------------------------------------------------------
-- | Resolve elaborations in a core module.
coreResolve
        :: (Ord n, Show n, Pretty n)
        => String                       -- ^ Name of compiler stage.
        -> C.Fragment n arr             -- ^ Language fragment to use.
        -> IO [(n, C.ImportValue n (C.Type n))]        
                                        -- ^ Top level env from other modules.
        -> C.Module a n
        -> ExceptT [B.Error] IO (C.Module a n)

coreResolve !stage !fragment !makeNtsTop !mm
 = {-# SCC "coreResolve" #-}
   do   
        ntsTop  <- liftIO $ makeNtsTop

        res     <- liftIO $ CResolve.resolveModule 
                        (C.fragmentProfile fragment) 
                        ntsTop mm
                
        case res of
         Left  err  -> throwE [B.ErrorLint stage "PipeCoreResolve" err]
         Right mm'  -> return mm'


---------------------------------------------------------------------------------------------------
-- | Simplify a core module.
coreSimplify
        :: ( Pretty a, Show a,
             CompoundName n, NFData n, Ord n, Show n, Pretty n)
        => C.Fragment n err
        -> s
        -> C.Simplifier s a n
        -> C.Module a n
        -> ExceptT [B.Error] IO (C.Module () n)

coreSimplify fragment nameZero simpl mm
 = {-# SCC "coreSimplify" #-}
   do   
        let profile     = C.fragmentProfile fragment
        let primKindEnv = C.profilePrimKinds      profile
        let primTypeEnv = C.profilePrimTypes      profile

        let !mm'        = C.result . flip evalState nameZero
                        $ C.applySimplifier profile primKindEnv primTypeEnv simpl mm

        let !mm2        = CReannotate.reannotate (const ()) mm'

        -- NOTE: It is helpful to deepseq here so that we release 
        --       references to the unsimplified version of the code.
        --       Because we've just applied reannotate, we also
        --       release type annotations on the expression tree.
        return $ (mm2 `deepseq` mm2)

