
module DDC.Core.Module.Import
        ( -- * Imported types
          ImportType    (..)
        , kindOfImportType
        , mapKindOfImportType

          -- * Imported capabilities
        , ImportCap (..)
        , typeOfImportCap
        , mapTypeOfImportCap

          -- * Imported values
        , ImportValue   (..)
        , typeOfImportValue
        , mapTypeOfImportValue)
where
import DDC.Core.Module.Name
import Control.DeepSeq


-- ImportType -------------------------------------------------------------------------------------
-- | Define a type being imported into a module.
data ImportType n t
        -- | Type imported abstractly.
        --
        --   Used for phantom types of kind Data, as well as regions, effects,
        --   and any other type that does not have kind Data. When a type is
        --   imported abstractly it has no associated values, so we can just
        --   say that we have the type without worrying about how to represent
        --   its associated values.
        --
        = ImportTypeAbstract
        { importTypeAbstractType :: !t }

        -- | Type of some boxed data.
        --
        --   The objects follow the standard heap object layout, but the code
        --   that constructs and destructs them may have been written in a 
        --   different language.
        --
        --   This is used when importing data types defined in Salt modules.
        --
        | ImportTypeBoxed
        { importTypeBoxed        :: !t }
        deriving Show


instance (NFData n, NFData t) => NFData (ImportType n t) where
 rnf is
  = case is of
        ImportTypeAbstract k            -> rnf k
        ImportTypeBoxed    k            -> rnf k


-- | Take the kind of an `ImportType`.
kindOfImportType :: ImportType n t -> t
kindOfImportType src
 = case src of
        ImportTypeAbstract k            -> k
        ImportTypeBoxed    k            -> k


-- | Apply a function to the kind of an `ImportType`
mapKindOfImportType :: (t -> t) -> ImportType n t -> ImportType n t
mapKindOfImportType f isrc
 = case isrc of
        ImportTypeAbstract k            -> ImportTypeAbstract (f k)
        ImportTypeBoxed    k            -> ImportTypeBoxed    (f k)


-- ImportCapability -------------------------------------------------------------------------------
-- | Define a foreign capability being imported into a module.
data ImportCap n t
        -- | Capability imported abstractly.
        --   For capabilities like (Read r) for some top-level region r
        --   we can just say that we have the capability.
        = ImportCapAbstract
        { importCapAbstractType  :: !t }
        deriving Show


instance (NFData n, NFData t) => NFData (ImportCap n t) where
 rnf ii
  = case ii of
        ImportCapAbstract t     -> rnf t


-- | Take the type of an `ImportCap`.
typeOfImportCap :: ImportCap n t -> t
typeOfImportCap ii
 = case ii of
        ImportCapAbstract t     -> t


-- | Apply a function to the type in an `ImportCapability`.
mapTypeOfImportCap :: (t -> t) -> ImportCap n t -> ImportCap n t
mapTypeOfImportCap f ii
 = case ii of
        ImportCapAbstract t     -> ImportCapAbstract (f t)


-- ImportValue ------------------------------------------------------------------------------------
-- | Define a foreign value being imported into a module.
data ImportValue n t
        -- | Value imported from a module that we compiled ourselves.
        = ImportValueModule
        { 
          -- | Name of the module that we're importing from.
          importValueModuleName         :: !ModuleName 

          -- | Name specific to the module we're importing from 
          --   (the name qualified by the source module name).
        , importValueModuleSpecific     :: !n

          -- | Type of the value that we're importing.
        , importValueModuleType         :: !t

          -- | Local name of the value that we're importing, 
          --   or Nothing if we're not giving it a local name.
        , importValueModuleLocal        :: !(Maybe n)

          -- | Calling convention for this value,
          --   including the number of type parameters, value parameters, and boxings.
        , importValueModuleArity        :: !(Maybe (Int, Int, Int)) }

        -- | Value imported via the C calling convention.
        | ImportValueSea
        { -- | Name of the symbol being imported. 
          --   This can be different from the name that we give it in the core language.
          importValueSeaVar             :: !String 

          -- | Type of the value that we're importing.
        , importValueSeaType            :: !t }
        deriving Show


instance (NFData n, NFData t) => NFData (ImportValue n t) where
 rnf is
  = case is of
        ImportValueModule mn nSpecific t mnLocal mAV 
         -> rnf mn `seq` rnf nSpecific `seq` rnf t `seq` rnf mnLocal `seq` rnf mAV

        ImportValueSea v t
         -> rnf v  `seq` rnf t


-- | Take the type of an imported thing.
typeOfImportValue :: ImportValue n t -> t
typeOfImportValue src
 = case src of
        ImportValueModule _ _ t _ _     -> t
        ImportValueSea    _ t           -> t


-- | Apply a function to the type in an ImportValue.
mapTypeOfImportValue :: (t -> t) -> ImportValue n t -> ImportValue n t
mapTypeOfImportValue f isrc
 = case isrc of
        ImportValueModule mn nSpecific t mnLocal mAr  
         -> ImportValueModule mn nSpecific (f t) mnLocal mAr

        ImportValueSea s t
         -> ImportValueSea s (f t)

