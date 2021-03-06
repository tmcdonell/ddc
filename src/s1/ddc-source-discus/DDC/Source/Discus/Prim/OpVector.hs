{-# LANGUAGE TypeFamilies #-}
-- Types of primitive Source Discus vector operators.
module DDC.Source.Discus.Prim.OpVector
        (typeOpVector)
where
import DDC.Source.Discus.Prim.TyCon
import DDC.Source.Discus.Prim.TyConPrim
import DDC.Source.Discus.Prim.TyConDiscus
import DDC.Source.Discus.Prim.Base
import DDC.Source.Discus.Exp.Generic
import DDC.Source.Discus.Exp.Compounds


-- | Take the type of a primitive vector operator.
typeOpVector :: forall l. (Anon l, GTPrim l ~ PrimType) => l -> OpVector -> GType l
typeOpVector l op
 = case op of
        OpVectorAlloc
         -> makeTForalls l [KRegion, KData] $ \[tR, tA]
         -> TSusp (TAlloc tR) (TVector tR tA)

        OpVectorLength
         -> makeTForalls l [KRegion, KData] $ \[tR, tA]
         -> TVector tR tA ~> TNat

        OpVectorRead
         -> makeTForalls l [KRegion, KData] $ \[tR, tA]
         -> TVector tR tA ~> TNat ~> TSusp (TRead tR) tA

        OpVectorWrite
         -> makeTForalls l [KRegion, KData] $ \[tR, tA]
         -> TVector tR tA ~> TNat ~> tA ~> TSusp (TWrite tR) TVoid

