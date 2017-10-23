{-# OPTIONS_HADDOCK hide #-}
module DDC.Core.Check.Judge.Kind.TyCon
        ( takeKindOfTyCon
        , takeSortOfKiCon
        , kindOfTwCon
        , kindOfTcCon)
where
import DDC.Type.Exp.Simple


-- | Take the superkind of an atomic kind constructor.
--
--   Yields `Nothing` for the kind function (~>) as it doesn't have a sort
--   without being fully applied.
takeSortOfKiCon :: KiCon -> Maybe (Sort n)
takeSortOfKiCon kc
 = case kc of
        KiConFun        -> Nothing
        KiConData       -> Just sComp
        KiConRegion     -> Just sComp
        KiConEffect     -> Just sComp
        KiConClosure    -> Just sComp
        KiConWitness    -> Just sProp


-- | Take the kind of a `TyCon`, if there is one.
takeKindOfTyCon :: TyCon n -> Maybe (Kind n)
takeKindOfTyCon tt
 = case tt of
        -- Sorts don't have a higher classification.
        TyConSort    _   -> Nothing

        TyConKind    kc  -> takeSortOfKiCon kc
        TyConWitness tc  -> Just $ kindOfTwCon tc
        TyConSpec    tc  -> Just $ kindOfTcCon tc
        TyConBound   _ k -> Just k
        TyConExists  _ k -> Just k


-- | Take the kind of a witness type constructor.
kindOfTwCon :: TwCon -> Kind n
kindOfTwCon tc
 = case tc of
        TwConImpl       -> kWitness  `kFun`  kWitness `kFun` kWitness
        TwConPure       -> kEffect   `kFun`  kWitness
        TwConConst      -> kRegion   `kFun`  kWitness
        TwConDeepConst  -> kData     `kFun`  kWitness
        TwConMutable    -> kRegion   `kFun`  kWitness
        TwConDeepMutable-> kData     `kFun`  kWitness
        TwConDisjoint   -> kEffect   `kFun`  kEffect  `kFun`  kWitness
        TwConDistinct n -> (replicate n kRegion)      `kFuns` kWitness


-- | Take the kind of a computation type constructor.
kindOfTcCon :: TcCon -> Kind n
kindOfTcCon tc
 = case tc of
        TcConUnit        -> kData
        TcConSusp        -> kEffect  `kFun` kData `kFun` kData
        TcConFunExplicit -> kData    `kFun` kData `kFun` kData
        TcConFunImplicit -> kData    `kFun` kData `kFun` kData
        TcConRecord ns   -> map (const kData) ns  `kFuns` kData
        TcConRead        -> kRegion  `kFun` kEffect
        TcConHeadRead    -> kData    `kFun` kEffect
        TcConDeepRead    -> kData    `kFun` kEffect
        TcConWrite       -> kRegion  `kFun` kEffect
        TcConDeepWrite   -> kData    `kFun` kEffect
        TcConAlloc       -> kRegion  `kFun` kEffect
        TcConDeepAlloc   -> kData    `kFun` kEffect