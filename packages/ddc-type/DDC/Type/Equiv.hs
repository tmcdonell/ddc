
module DDC.Type.Equiv
        ( equivT
	, matchT )
where
import DDC.Type.Exp
import DDC.Type.Compounds
import DDC.Type.Transform.Crush
import DDC.Type.Transform.Trim
import Data.Maybe
import qualified DDC.Type.Sum   as Sum
import qualified Data.Map       as Map
import qualified Data.Set       as Set


-- | Check equivalence of types.
--
--   Checks equivalence up to alpha-renaming, as well as crushing of effects
--   and trimming of closures.
--  
--   * Return `False` if we find any free variables.
--
--   * We assume the types are well-kinded, so that the type annotations on
--     bound variables match the binders. If this is not the case then you get
--     an indeterminate result.
--
equivT  :: Ord n => Type n -> Type n -> Bool
equivT t1 t2
        = equivT' [] [] t1 t2


equivT' :: Ord n
        => [Bind n]
        -> [Bind n]
        -> Type n   -> Type n
        -> Bool

equivT' stack1 stack2 t1 t2
 = let  t1'     = unpackSumT $ crushSomeT t1
        t2'     = unpackSumT $ crushSomeT t2
   in case (t1', t2') of
        (TVar u1,         TVar u2)
         -- Free variables are name-equivalent, bound variables aren't:
	 -- (forall a. a) != (forall b. a)
         | Nothing      <- getBindType stack1 u1
         , Nothing      <- getBindType stack2 u2
         , u1 == u2     -> True

	 -- Both variables are bound in foralls, so check the stack
         -- to see if they would be equivalent if we named them.
         | Just (ix1, t1a)   <- getBindType stack1 u1
         , Just (ix2, t2a)   <- getBindType stack2 u2
         , ix1 == ix2
         -> equivT' stack1 stack2 t1a t2a

         | otherwise
         -> False

        -- Constructor names must be equal.
        (TCon tc1,        TCon tc2)
         -> tc1 == tc2

        -- Push binders on the stack as we enter foralls.
        (TForall b11 t12, TForall b21 t22)
         |  equivT  (typeOfBind b11) (typeOfBind b21)
         -> equivT' (b11 : stack1)
                    (b21 : stack2)
                    t12 t22

        -- Decend into applications.
        (TApp t11 t12,    TApp t21 t22)
         -> equivT' stack1 stack2 t11 t21
         && equivT' stack1 stack2 t12 t22
        
        -- Sums are equivalent if all of their components are.
        (TSum ts1,        TSum ts2)
         -> let ts1'      = Sum.toList ts1
                ts2'      = Sum.toList ts2

                -- If all the components of the sum were in the element
                -- arrays then they come out of Sum.toList sorted
                -- and we can compare corresponding pairs.
                checkFast = and $ zipWith (equivT' stack1 stack2) ts1' ts2'

                -- If any of the components use a higher kinded type variable
                -- like (c : % ~> !) then they won't nessesarally be sorted,
                -- so we need to do this slower O(n^2) check.
                -- Make sure to get the bind stacks the right way around here.
                checkSlow = and [ or (map (equivT' stack1 stack2 t1c) ts2') 
                                | t1c <- ts1' ]
                         && and [ or (map (equivT' stack2 stack1 t2c) ts1') 
                                | t2c <- ts2' ]

            in  (length ts1' == length ts2')
            &&  (checkFast || checkSlow)

        (_, _)  -> False


type VarSet n = Set.Set n
type Subst n = Map.Map n (Type n)


-- | Try to find a simple substitution between two types.
-- Ignoring complicated effect sums.
-- Eg given template "a -> b" and target "Int -> Float", returns substitution:
--	{ a |-> Int, b |-> Float }
--
matchT  :: Ord n
	=> VarSet n	-- ^ only attempt to match these names
	-> Subst n	-- ^ already matched (or @Map.empty@)
	-> Type n	-- ^ template
	-> Type n	-- ^ target
	-> Maybe (Subst n)
matchT vs subst t1 t2
        = matchT' [] [] t1 t2 vs subst


matchT' :: Ord n
        => [Bind n]
        -> [Bind n]
        -> Type n   -> Type n
	-> VarSet n -> Subst n
        -> Maybe (Subst n)

matchT' stack1 stack2 t1 t2 vs subst
 = let  t1'     = unpackSumT $ crushSomeT t1
        t2'     = unpackSumT $ crushSomeT t2
   in case (t1', t2') of
        (TVar u1,         TVar u2)
	 -- If variables are bound in foralls, no need to match.
	 -- Don't check their names - lookup bind depth instead.
	 -- 
	 -- I was calling equivT' here, but changing to matchT':
	 -- perhaps if we had
	 --	RULE [a : **] [b : a]. something [b] ...
	 -- then matching against
	 --	let i = Int in
	 --		something [i]
	 -- so to find a, we need to find i's type.
         | Just (ix1, t1a)   <- getBindType stack1 u1
         , Just (ix2, t2a)   <- getBindType stack2 u2
         , ix1 == ix2
         -> matchT' stack1 stack2 t1a t2a vs subst

        -- Constructor names must be equal.
	--
	-- Will this still work when it's a TyConBound - basically same as TVar?
        (TCon tc1,        TCon tc2)
	 | tc1 == tc2
         -> Just subst

        -- Push binders on the stack as we enter foralls.
        (TForall b11 t12, TForall b21 t22)
         --  equivT  (typeOfBind b11) (typeOfBind b21)
         -> do
		subst' <- matchT' stack1 stack2 (typeOfBind b11) (typeOfBind b21) vs subst
		matchT' (b11 : stack1)
			(b21 : stack2)
			t12 t22
			vs subst'

        -- Decend into applications.
        (TApp t11 t12,    TApp t21 t22)
         -> do
		subst' <- matchT' stack1 stack2 t11 t21 vs subst
		matchT' stack1 stack2 t12 t22 vs subst'
        
	-- TODO sums
        (TSum _,        TSum _)
	 -> Just subst
	{-
        -- Sums are equivalent if all of their components are.
        (TSum ts1,        TSum ts2)
         -> let ts1'      = Sum.toList ts1
                ts2'      = Sum.toList ts2
                equiv     = equivT' stack1 depth1 stack2 depth2

                -- If all the components of the sum were in the element
                -- arrays then they come out of Sum.toList sorted
                -- and we can compare corresponding pairs.
                checkFast = and $ zipWith equiv ts1' ts2'

                -- If any of the components use a higher kinded type variable
                -- like (c : % ~> !) then they won't nessesarally be sorted,
                -- so we need to do this slower O(n^2) check.
                checkSlow = and [ or (map (equiv t1c) ts2') | t1c <- ts1' ]
                         && and [ or (map (equiv t2c) ts1') | t2c <- ts2' ]

            in  (length ts1' == length ts2')
            &&  (checkFast || checkSlow)
	    -}

	-- If template is in variable set, push the target into substitution
	-- But we might need to rename bound variables...
	(TVar (UName n), _)
	-- TODO rewrite binders from t2 to t1 in t2'
	 | Set.member n vs
	 , Nothing <- Map.lookup n subst
	 -> Just $ Map.insert n t2' subst

	 | Set.member n vs
	 , Just t1'' <- Map.lookup n subst
	 , equivT' stack1 stack2 t1'' t2'
	 -> Just subst

        (_, _)  -> Nothing


-- | Unpack single element sums into plain types.
unpackSumT :: Type n -> Type n
unpackSumT (TSum ts)
	| [t]   <- Sum.toList ts = t
unpackSumT tt			 = tt


-- | Crush compound effects and closure terms.
--   We check for a crushable term before calling crushT because that function
--   will recursively crush the components. 
--   As equivT is already recursive, we don't want a doubly-recursive function
--   that tries to re-crush the same non-crushable type over and over.
--
crushSomeT :: (Ord n) => Type n -> Type n
crushSomeT tt
 = case tt of
        (TApp (TCon tc) _)
         -> case tc of
                TyConSpec    TcConDeepRead   -> crushEffect tt
                TyConSpec    TcConDeepWrite  -> crushEffect tt
                TyConSpec    TcConDeepAlloc  -> crushEffect tt

                -- If a closure is miskinded then 'trimClosure' 
                -- can return Nothing, so we just leave the term untrimmed.
                TyConSpec    TcConDeepUse    -> fromMaybe tt (trimClosure tt)

                TyConWitness TwConDeepGlobal -> crushEffect tt
                _                            -> tt

        _ -> tt


-- | Lookup the type of a bound thing from the binder stack.
--   The binder stack contains the binders of all the `TForall`s we've
--   entered under so far.
getBindType :: Eq n => [Bind n] -> Bound n -> Maybe (Int, Type n)
getBindType bs' u'
 = go 0 u' bs'
 where  go n u (BName n1 t : bs)
         | UName n2     <- u
         , n1 == n2     = Just (n, t)

         | otherwise    = go (n + 1) u bs

        go n (UIx i)    (BAnon t   : bs)
         | i < 0        = Nothing
         | i == 0       = Just (n, t)
         | otherwise    = go (n + 1) (UIx (i - 1)) bs

        go n u          (BAnon _   : bs)
         | otherwise    = go (n + 1) u bs

        go n u (BNone _   : bs)
         = go (n + 1) u bs

        go _ _ []       = Nothing

