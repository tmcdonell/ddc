{-# LANGUAGE TypeFamilies #-}
module DDC.Source.Discus.Parser.Type
        ( pBind
        , pType
        , pTypeUnion
        , pTypeApp
        , pTypeArgSP
        , pTyConSP
        , pTyConBound)
where
import DDC.Source.Discus.Parser.Base            as S
import DDC.Source.Discus.Exp.Compounds          as S
import DDC.Source.Discus.Exp.Source             as S
import DDC.Source.Discus.Prim.TyConDiscus       as S
import DDC.Core.Codec.Text.Lexer.Tokens         as K
import qualified DDC.Source.Discus.Lexer        as SL

import qualified DDC.Core.Discus                as C
import qualified DDC.Control.Parser             as P
import qualified Data.Text                      as T


-- | Parse a binder.
pBind :: Parser Bind
pBind
 = P.choice
 -- Named binders.
 [ do    (b, _)  <- pBindNameSP
         return b

 -- Anonymous binders.
 , do    pSym SHat
         return BAnon

 -- Vacant binders.
 , do    pSym SUnderscore
         return BNone
 ]
 <?> "a binder"


-- | Parse a type.
pType :: Parser Type
pType = pTypeUnion


-- | Parse a type union.
pTypeUnion :: Parser Type
pTypeUnion
 = do   t1      <- pTypeFun
        P.choice
         [ -- Type sums.
           -- T2 + T3
           do   sp      <- pTokSP (KOp "+")
                t2      <- pTypeUnion
                return  $  TAnnot sp $ TUnion KEffect t1 t2

         , do   return t1 ]
 <?> "a type"


-- | Parse a quantified type.
pTypeFun :: Parser Type
pTypeFun
 = P.choice
 [ -- Implicit universal quantification (old syntax)
   -- [v1 v1 ... vn : T1]. T2
   do   pSym SSquareBra
        bs      <- P.many1 pBind
        sp      <- pTokSP (KOp ":")
        kBind   <- pTypeUnion
        pSym SSquareKet
        pSym SDot

        tBody   <- pTypeFun
        return  $ foldr (\b t -> TAnnot sp
                              $  TApp (TCon (TyConForall kBind))
                                      (TAbs b kBind t))
                        tBody bs

        -- Implicit function constructor or universal quantification.
 , do   pSym SBraceBra
        P.choice
         [ do   -- Implicit universal quantification.
                -- {@v1 v2 .. vn : T1} -> T2

                pSym SAt
                bs      <- P.many1 pBind
                sp      <- pTokSP (KOp ":")
                kBind   <- pTypeUnion
                pSym SBraceKet
                pSym SArrowDashRight

                tBody   <- pTypeFun
                return  $ foldr (\b t -> TAnnot sp
                                      $  TApp (TCon (TyConForall kBind))
                                              (TAbs b kBind t))
                                tBody bs

         , do   -- Implicit term parameter
                -- {T1} -> T2
                tParam  <- pTypeFun
                pSym SBraceKet
                sp      <- pSym SArrowDashRight
                tResult <- pTypeFun
                return  $  TAnnot sp $ TFunImplicit tParam tResult
         ]


 , P.try $ do
        pSym SRoundBra
        pSym SAt
        bs      <- P.many1 pBind
        sp      <- pTokSP (KOp ":")
        kBind   <- pTypeUnion
        pSym SRoundKet
        pSym SArrowTilde
        tBody   <- pTypeFun
        return  $ foldr (\b t -> TAnnot sp
                              $  TApp (TCon (TyConForall kBind))
                                            (TAbs b kBind t))
                        tBody bs

   -- Function type
 , do   t1      <- pTypeApp
        P.choice
         [ -- T1 => T2
           do   sp      <- pSym SArrowEquals
                t2      <- pTypeFun
                return  $  TAnnot sp $ TImpl t1 t2

           -- T1 -> T2
         , do   sp      <- pSym SArrowDashRight
                t2      <- pTypeFun
                return  $  TAnnot sp $ TFunExplicit  t1 t2

           -- T1 ~> T2
         , do   sp      <- pSym SArrowTilde
                t2      <- pTypeFun
                return  $  TAnnot sp $ TFunImplicit t1 t2

           -- Body type
         , do   return t1
         ]
 ]
 <?> "a type"


-- | Parse a type application.
pTypeApp :: Parser Type
pTypeApp
 = do   ((t, _):ts)  <- P.many1 pTypeArgSP
        return  $  foldl (\t1 (t2, sp) -> TAnnot sp (TApp t1 t2)) t ts
 <?> "an simple type or type application"


-- | Parse a variable, constructor or parenthesised type.
pTypeArgSP :: Parser (Type, SourcePos)
pTypeArgSP
 = P.choice
 [      -- Bound occurrence of a variable.
        --  We don't know the kind of this variable yet, so fill in the
        --  field with the bottom element of computation kinds. This isn't
        --  really part of the language, but makes sense implentation-wise.
   do   (u, sp) <- pBoundNameSP
        return  (TAnnot sp $ TVar u, sp)

 , do   (u, sp) <- pBoundIxSP
        return  (TAnnot sp $ TVar u, sp)

        -- Named type constructors
 , do   (tc, sp) <- pTyConSP
        return  (TAnnot sp $ TCon tc, sp)

        -- Builtin type constructors.
 , do   pTypeBuiltinSP

        -- Primitive record type constructor.
        --  like (x,y,z)#
 , P.try $ do
        sp     <- pSym SRoundBra
        ns     <- fmap (map fst) $ P.sepBy pVarNameSP (pSym SComma)
        pSym SRoundKet
        pSym SHash
        return ( TCon (TyConPrim (PrimTypeTcCon (TcConRecord ns)))
               , sp)

        -- Tuple type.
 , P.try $ do
        sp        <- pSym SRoundBra
        tField1   <- pType
        _         <- pSym SComma
        tsField'  <- P.sepBy1 pType (pSym SComma)
        _         <- pSym SRoundKet
        let ts    =  tField1 : tsField'
        let arity =  length ts
        let nCtor =  T.pack ("Tup" ++ show arity)
        let tc    =  TyConBound (TyConBoundName nCtor)
        return    ( TAnnot sp $  makeTApps (TCon tc) ts
                  , sp)

        -- Full application of a primitive record type constructor.
        --   like (x : Nat, y : Nat, z : Nat)
 , P.try $ do
        sp       <- pSym SRoundBra
        (nsField, tsField)
                <- fmap unzip
                $  P.sepBy
                        (do (n, _)  <- pVarNameSP
                            _       <- pTokSP (KOp ":")
                            t       <- pType
                            return  (n, t))
                        (pSym SComma)
        pSym SRoundKet
        let tRecord = TCon (TyConPrim (PrimTypeTcCon (TcConRecord nsField)))
        return  ( makeTApps tRecord tsField
                , sp)

        -- The syntax for the nullary record type constructor '()#' overlaps
        -- with that of the unit data construtor '()', so try the former first.
 , P.try
    $ do sp     <- pTokSP $ KBuiltin BDaConUnit
         pSym SHash
         return ( TCon (TyConPrim (PrimTypeTcCon (TcConRecord [])))
                , sp)

   -- (TYPE2)
 , do    sp      <- pSym SRoundBra
         t       <- pTypeUnion
         pSym SRoundKet
         return  (t, sp)
 ]
 <?> "an atomic type"


-- | Parse a builtin type.
pTypeBuiltinSP :: Parser (Type, SourcePos)
pTypeBuiltinSP
 = P.choice
 [      -- (=>)
   do   sp      <- pTokSP $ KOpVar "=>"
        return  (TAnnot sp $ TCon (TyConPrim (PrimTypeTwCon TwConImpl)), sp)

        -- (->)
 , do   sp      <- pTokSP $ KOpVar "->"
        return  (TAnnot sp $ TCon TyConFunExplicit, sp)

        -- (~>)
 , do   sp      <- pTokSP $ KOpVar "~>"
        return  (TAnnot sp $ TCon TyConFunImplicit, sp)

        -- Bottoms.
 , do    sp       <- pTokSP (KBuiltin BPure)
         return  (TAnnot sp $ TBot KEffect, sp)
 ]


-- | Parse a type constructor.
pTyConSP :: Parser (TyCon, SourcePos)
pTyConSP  =   P.pTokMaybeSP f <?> "a type constructor"
 where f kk
        = case kk of
                -- Primitive Ambient TyCons.
                KA (KBuiltin (BSoCon c))
                 -> Just $ TyConPrim $ PrimTypeSoCon c

                KA (KBuiltin (BKiCon c))
                 -> Just $ TyConPrim $ PrimTypeKiCon c

                KA (KBuiltin (BTwCon c))
                 -> Just $ TyConPrim $ PrimTypeTwCon c

                KA (KBuiltin (BTcCon c))
                 -> Just $ TyConPrim $ PrimTypeTcCon c

                -- Primitive TyCons.
                KN (KCon (SL.NamePrimType tc))
                 -> Just $ TyConPrim tc

                -- User Bound TyCons.
                KN (KCon (SL.NameCon tx))
                 -> Just (TyConBound (TyConBoundName tx))

                _ -> Nothing


-- | Parse a bound type constructor.
--   Known primitive type constructors do not match.
pTyConBound :: Parser TyCon
pTyConBound
        =   P.pTokMaybe f <?> "a bound type constructor"
 where
        f :: Token SL.Name -> Maybe TyCon
        f (KN (KCon (SL.NameCon tx)))
         |  Nothing <- C.readPrimTyCon      (T.unpack tx)
         ,  Nothing <- S.readPrimTyConDiscus (T.unpack tx)
         = Just (TyConBound (TyConBoundName tx))

        f _ = Nothing

