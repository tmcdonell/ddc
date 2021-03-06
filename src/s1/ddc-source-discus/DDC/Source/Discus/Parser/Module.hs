
-- | Parser for Source Discus modules.
module DDC.Source.Discus.Parser.Module
        ( -- * Modules
          pModule

          -- * Top-level things
        , pTop)
where
import DDC.Source.Discus.Parser.Exp     as S
import DDC.Source.Discus.Parser.Base    as S
import DDC.Source.Discus.Module         as S
import DDC.Source.Discus.DataDef        as S
import DDC.Source.Discus.Exp            as S
import DDC.Core.Codec.Text.Lexer.Tokens as K
import DDC.Data.Pretty
import Control.Monad
import qualified DDC.Control.Parser     as P
import qualified Data.Text              as Text

import DDC.Core.Codec.Text.Parser
        ( pModuleName
        , pName)


-- Module -----------------------------------------------------------------------------------------
-- | Parse a source tetra module.
pModule :: Parser (Module Source)
pModule
 = do
        _sp      <- pTokSP (KKeyword EModule)
        name     <- pModuleName <?> "a module name"
        tExports <- liftM concat $ P.many pExportSpecs
        tImports <- liftM concat $ P.many pImportSpecs

        tops
         <- P.choice
            [ do pKey EWhere
                 pSym SBraceBra
                 tops <- P.sepEndBy pTop (pSym SSemiColon)
                 pSym SBraceKet
                 return tops

            , do return [] ]

        -- ISSUE #295: Check for duplicate exported names in module parser.
        --  The names are added to a unique map, so later ones with the same
        --  name will replace earlier ones.
        return  $ Module
                { moduleName            = name
                , moduleExportTypes     = []
                , moduleExportValues    = [(n, s) | ExportValue n s  <- tExports]
                , moduleImportModules   = [mn     | ImportModule mn  <- tImports]
                , moduleImportTypes     = [(n, s) | ImportType  n s  <- tImports]
                , moduleImportCaps      = [(n, s) | ImportCap   n s  <- tImports]
                , moduleImportValues    = [(n, s) | ImportValue n s  <- tImports]
                , moduleTops            = tops }


---------------------------------------------------------------------------------------------------
data ExportSpec
        = ExportValue Bound     (ExportValue Bound Type)
        deriving Show

pExportSpecs :: Parser [ExportSpec]
pExportSpecs
 = do   pTok (KKeyword EExport)

        P.choice
         [ do   -- export foreign ...
                pTok (KKeyword EForeign)
                src     <- liftM (renderIndent . ppr) pName

                P.choice
                 [      -- export foreign X value (NAME :: TYPE)+
                   do   pKey EValue
                        pSym SBraceBra
                        sigs <- P.sepEndBy1 (pExportValue src)  (pSym SSemiColon)
                        pSym SBraceKet
                        return sigs
                 ]

         , do   pSym SBraceBra
                names   <- fmap (map fst)
                        $ P.sepEndBy1 pBoundNameSP (pSym SSemiColon)
                pSym SBraceKet
                return  [ExportValue n (ExportValueLocalNoType n) | n <- names]
         ]


-- | Parse a value export spec.
pExportValue :: String -> Parser ExportSpec
pExportValue src
        | elem src ["c", "C"]
        = do    (b@(UName n), _)  <- pBoundNameSP
                pTokSP (KOp ":")
                k       <- pType

                -- ISSUE #327: Allow external symbol to be specified
                --             with foreign C imports and exports.
                let symbol = renderIndent (text $ Text.unpack n)

                return  (ExportValue b (ExportValueSea b (Text.pack symbol) k))

        | otherwise
        = P.unexpected "export mode for foreign value"


---------------------------------------------------------------------------------------------------
-- | An imported foreign type or foreign value.
data ImportSpec
        = ImportModule  ModuleName
        | ImportType    TyConBind (ImportType  TyConBind Type)
        | ImportCap     Bind      (ImportCap   Bind      Type)
        | ImportValue   Bind      (ImportValue Bind      Type)
        deriving Show


-- | Parse some import specs.
pImportSpecs :: Parser [ImportSpec]
pImportSpecs
 = do   pTok (KKeyword EImport)

        P.choice
         [ do   -- import foreign ...
                pTok (KKeyword EForeign)
                src     <- liftM (renderIndent . ppr) pName

                P.choice
                 [      -- import foreign X type (NAME :: TYPE)+
                  do    pKey EType
                        pSym SBraceBra
                        sigs <- P.sepEndBy1 (pImportType src)       (pSym SSemiColon)
                        pSym SBraceKet
                        return sigs

                        -- import foreign X capability (NAME :: TYPE)+
                 , do   pKey ECapability
                        pSym SBraceBra
                        sigs <- P.sepEndBy1 (pImportCapability src) (pSym SSemiColon)
                        pSym SBraceKet
                        return sigs

                        -- import foreign X value (NAME :: TYPE)+
                 , do   pKey EValue
                        pSym SBraceBra
                        sigs <- P.sepEndBy1 (pImportValue src)      (pSym SSemiColon)
                        pSym SBraceKet
                        return sigs
                 ]

         , do   pSym SBraceBra
                names   <-  P.sepEndBy1 pModuleName (pSym SSemiColon)
                        <?> "module names"
                pSym SBraceKet
                return  [ImportModule n | n <- names]
         ]


-- | Parse a type import spec.
pImportType :: String -> Parser ImportSpec
pImportType src
        | "abstract"    <- src
        = do    b       <- pTyConBindName
                pTokSP (KOp ":")
                k       <- pType
                return  (ImportType b (ImportTypeAbstract k))

        | "boxed"       <- src
        = do    b       <- pTyConBindName
                pTokSP (KOp ":")
                k       <- pType
                return  (ImportType b (ImportTypeBoxed k))

        | otherwise
        = P.unexpected "import mode for foreign type"


-- | Parse a capability import.
pImportCapability :: String -> Parser ImportSpec
pImportCapability src
        | "abstract"    <- src
        = do    (b, _)  <- pBindNameSP
                pTokSP (KOp ":")
                t       <- pType
                return  (ImportCap b (ImportCapAbstract t))

        | otherwise
        = P.unexpected "import mode for foreign capability"


-- | Parse a value import spec.
pImportValue :: String -> Parser ImportSpec
pImportValue src
        | elem src ["c", "C"]
        = do    (b@(BName n), _)  <- pBindNameSP
                pTokSP (KOp ":")
                k       <- pType

                -- ISSUE #327: Allow external symbol to be specified
                --             with foreign C imports and exports.
                let symbol = renderIndent (text $ Text.unpack n)

                return  (ImportValue b (ImportValueSea b (Text.pack symbol) k))

        | otherwise
        = P.unexpected "import mode for foreign value"


-- Top Level --------------------------------------------------------------------------------------
pTop    :: Parser (Top Source)
pTop
 = P.choice
 [ do   -- A top-level, possibly recursive binding.
        (sp, l) <- pDeclTermSP
        return  $ TopClause sp l

        -- A data type declaration
 , do   pDeclData

        -- A type binding
 , do   pDeclType
 ]


-- Type -------------------------------------------------------------------------------------------
pDeclType :: Parser (Top Source)
pDeclType
 = do   sp      <- pKey EType
        bType   <- pTyConBindName
        bsParam <- liftM concat $ P.many pTypeParam
        _       <- pSym SEquals
        tBody   <- pType

        return  $  TopType sp bType
                $  foldr (\(b, k) t -> TAbs b k t) tBody bsParam


-- | Parse a type parameter to a data type or type function.
pTypeParam :: Parser [(Bind, Type)]
pTypeParam
 = do   pSym SRoundBra
        bs      <- fmap (fst . unzip) $ P.many1 pBindNameSP
        pTokSP (KOp ":")
        k       <- pType
        pSym SRoundKet
        return  [(b, k) | b <- bs]


-- Data -------------------------------------------------------------------------------------------
-- | Parse a data type declaration.
pDeclData :: Parser (Top Source)
pDeclData
 = do   sp      <- pTokSP (KKeyword EData)
        b       <- pTyConBindName
        ps      <- liftM concat $ P.many pTypeParam

        P.choice
         [ -- Data declaration with constructors that have explicit types.
           do   pKey EWhere
                pSym SBraceBra
                ctors   <- P.sepEndBy1 pDeclDataCtor (pSym SSemiColon)
                pSym SBraceKet
                return  $ TopData sp (DataDef b ps ctors)

           -- Data declaration with no data constructors.
         , do   return  $ TopData sp (DataDef b ps [])
         ]

-- | Parse a data constructor declaration.
pDeclDataCtor :: Parser (DataCtor Source)
pDeclDataCtor
 = do   n       <- pDaConBindName
        pTokSP (KOp ":")
        t       <- pType
        let (tsArg, tResult) = takeTFuns t

        return  $ DataCtor
                { dataCtorName          = n
                , dataCtorFieldTypes    = tsArg
                , dataCtorResultType    = tResult }

