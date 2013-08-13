
module DDC.Source.Tetra.Module
        ( -- * Modules
          Module (..)
        , isMainModule

          -- * Module Names
        , QualName      (..)
        , ModuleName    (..)
        , isMainModuleName

          -- * Top-level things
        , Top           (..))
where
import DDC.Source.Tetra.Exp
import Control.DeepSeq

import DDC.Core.Module          
        ( QualName      (..)
        , ModuleName    (..)
        , isMainModuleName)
        

-- Module ---------------------------------------------------------------------
data Module a n
        = Module
        { -- | Name of this module
          moduleName            :: !ModuleName

          -- Exports ----------------------------
          -- | Names of exported types  (level-1).
        , moduleExportedTypes   :: [n]

          -- | Names of exported values (level-0).
        , moduleExportedValues  :: [n]

          -- Imports ----------------------------
          -- | Imported modules.
        , moduleImportedModules :: [ModuleName]

          -- Local ------------------------------
          -- | Top-level things
        , moduleTops            :: [Top a n] }
        deriving Show


instance (NFData a, NFData n) => NFData (Module a n) where
 rnf !mm
        =     rnf (moduleName mm)
        `seq` rnf (moduleExportedTypes   mm)
        `seq` rnf (moduleExportedValues  mm)
        `seq` rnf (moduleImportedModules mm)
        `seq` rnf (moduleTops            mm)
        

-- | Check if this is the `Main` module.
isMainModule :: Module a n -> Bool
isMainModule mm
        = isMainModuleName
        $ moduleName mm


-- Top Level Thing ------------------------------------------------------------
data Top a n
        -- | Top-level, possibly recursive binding.
        = TopBind a (Bind n) (Exp a n)

        -- | Data type definition.
        | TopData 
        { topAnnot      :: a 
        , topName       :: n                    -- ^ Data type name.
        , topParams     :: [(n, Kind n)]        -- ^ Type parameters.
        , topCtors      :: [(n, Type n)]        -- ^ Data constructors.
        }
        deriving Show


instance (NFData a, NFData n) => NFData (Top a n) where
 rnf !top
  = case top of
        TopBind a b x   
         -> rnf a `seq` rnf b  `seq` rnf x
                 
        TopData a n ps cs 
         -> rnf a `seq` rnf n `seq` rnf ps `seq` rnf cs
