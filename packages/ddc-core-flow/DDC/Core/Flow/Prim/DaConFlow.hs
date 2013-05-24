
module DDC.Core.Flow.Prim.DaConFlow
        ( readDaConFlow
        , typeDaConFlow)
where
import DDC.Core.Flow.Prim.TyConFlow
import DDC.Core.Flow.Prim.Base
import DDC.Core.Compounds
import DDC.Core.Exp
import DDC.Base.Pretty
import Data.List
import Data.Char
import Control.DeepSeq


instance NFData DaConFlow


instance Pretty DaConFlow where
 ppr dc
  = case dc of
        DaConFlowTuple n        -> text "T" <> int n <> text "#"


-- | Read a data constructor name.
readDaConFlow :: String -> Maybe DaConFlow
readDaConFlow str
        | Just rest     <- stripPrefix "T" str
        , (ds, "#")     <- span isDigit rest
        , not $ null ds
        , arity         <- read ds
        = Just $ DaConFlowTuple arity

        | otherwise
        = Nothing


-- Type -----------------------------------------------------------------------
-- | Yield the type of a data constructor.
typeDaConFlow :: DaConFlow -> Type Name
typeDaConFlow (DaConFlowTuple n)
        = tForalls (replicate n kData)
        $ \args -> foldr tFunPE (tTupleN args) args
