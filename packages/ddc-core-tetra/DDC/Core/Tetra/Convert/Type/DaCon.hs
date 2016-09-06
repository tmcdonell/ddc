
module DDC.Core.Tetra.Convert.Type.DaCon
        ( convertCtorT
        , convertDaCon)
where
import DDC.Core.Tetra.Convert.Type.Kind
import DDC.Core.Tetra.Convert.Type.Data
import DDC.Core.Tetra.Convert.Type.Base
import DDC.Core.Tetra.Convert.Error
import DDC.Core.Exp.Annot.Exp
import DDC.Type.Exp.Simple
import DDC.Control.Check                        (throw)
import qualified DDC.Core.Tetra.Prim            as E
import qualified DDC.Core.Salt.Name             as A


-- Ctor Types -------------------------------------------------------------------------------------
-- | Convert the type of a data constructor.
--
--   The code to build data values is generated by the compiler so that it
--   always has as many parameters as there are function arguments in its
--   type.
--
convertCtorT :: Context -> Type E.Name -> ConvertM a (Type A.Name)
convertCtorT ctx0 tt0
 = convertAbsType ctx0 tt0
 where
        -- Accepting type abstractions --------------------
        convertAbsType ctx tt
         = case tt of
                TForall bParam tBody
                  -> convertConsType ctx bParam tBody
                _ -> convertAbsValue ctx tt

        convertConsType ctx bParam tBody
         -- Erase higher kinded type abstractions.
         | Just _       <- takeKFun $ typeOfBind bParam
         = do   let ctx' = extendKindEnv bParam ctx
                convertAbsType ctx' tBody

         -- Erase effect abstractions.
         | isEffectKind $ typeOfBind bParam
         = do   let ctx' = extendKindEnv bParam ctx
                convertAbsType ctx' tBody

         -- Retain region abstractions.
         | isRegionKind $ typeOfBind bParam
         = do   bParam' <- convertTypeB  bParam
                let ctx' = extendKindEnv bParam ctx
                tBody'  <- convertCtorT ctx' tBody
                return  $ TForall bParam' tBody'

         -- Convert data type abstractions to region abstractions.
         | isDataKind   $ typeOfBind bParam
         , BName (E.NameVar str) _   <- bParam
         , str'         <- str ++ "$r"
         , bParam'      <- BName (A.NameVar str') kRegion
         = do   let ctx' = extendKindEnv bParam ctx
                tBody'  <- convertAbsType ctx' tBody
                return  $ TForall bParam' tBody'

         -- Some other type that we can't convert.
         | otherwise
         = error "ddc-core-tetra.converCtorT: cannot convert type."


        -- Accepting value abstractions -------------------
        convertAbsValue ctx tt
         = case tt of
                TApp{}
                  | Just (tParam, tBody) <- takeTFun tt
                  -> convertConsValue ctx tParam tBody
                _ -> convertDataT ctx tt


        convertConsValue ctx tParam tBody
         = do   tParam' <- convertDataT    ctx tParam
                tBody'  <- convertAbsValue ctx tBody
                return  $  tFun tParam' tBody'


-- DaCon ------------------------------------------------------------------------------------------
-- | Convert a data constructor definition.
convertDaCon 
        :: Context 
        -> DaCon E.Name (Type E.Name)
        -> ConvertM a (DaCon A.Name (Type A.Name))

convertDaCon ctx dc
 = case dc of
        DaConUnit       
         -> return DaConUnit

        DaConPrim n t
         -> do  n'      <- convertDaConNameM dc n
                t'      <- convertCtorT ctx t
                return  $ DaConPrim
                        { daConName             = n'
                        , daConType             = t' }

        DaConBound n
         -> do  n'      <- convertDaConNameM dc n
                return  $ DaConBound
                        { daConName             = n' }


-- | Convert the name of a data constructor.
convertDaConNameM 
        :: DaCon E.Name (Type E.Name)
        -> E.Name 
        -> ConvertM a A.Name

convertDaConNameM dc nn
 = case nn of
        E.NameLitUnboxed (E.NameLitBool val)       
          -> return $ A.NamePrimLit $ A.PrimLitBool val

        E.NameLitUnboxed (E.NameLitNat  val)
          -> return $ A.NamePrimLit $ A.PrimLitNat  val

        E.NameLitUnboxed (E.NameLitInt  val)
          -> return $ A.NamePrimLit $ A.PrimLitInt  val

        E.NameLitUnboxed (E.NameLitWord val bits)
          -> return $ A.NamePrimLit $ A.PrimLitWord val bits

        _ -> throw $ ErrorInvalidDaCon dc

