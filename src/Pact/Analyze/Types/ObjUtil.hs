{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE ExplicitNamespaces    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
module Pact.Analyze.Types.ObjUtil where

import Data.Typeable      (Typeable, Proxy(Proxy))
import Data.Type.Bool     (If, type (||))
import Data.Type.Equality (type (==))
import GHC.TypeLits       (Symbol, CmpSymbol, KnownSymbol)
import Prelude            hiding ((++))

import Pact.Analyze.Types.Types

-- inspiration:
-- https://github.com/dorchard/type-level-sets/blob/master/src/Data/Type/Set.hs

-- section: Append

-- | Type-level list append
type family (:++) (x :: [ k ]) (y :: [ k ]) :: [ k ] where
  '[] :++ ys = ys
  (x ': xs) :++ ys = x ': (xs :++ ys)

infixr 5 :++

-- | Singleton list append
(++) :: SingList s -> SingList t -> SingList (s :++ t)
SingList SNil           ++ x  = x
SingList (SCons k v xs) ++ ys
  = SingList (SCons k v (unSingList (SingList xs ++ ys)))

infixr 5 ++

-- section: Filter

data Flag = FMin | FMax

-- | Type-level filter elements less-than or greater-than-or-equal to the pivot
type family Filter (f :: Flag) (p :: Symbol) (xs :: [ (Symbol, Ty) ])
  :: [ (Symbol, Ty) ] where
  Filter f p '[] = '[]
  Filter 'FMin p ('(k, x) ': xs)
    = If (CmpSymbol k p == 'LT)
         ('(k, x) ': Filter 'FMin p xs)
         (Filter 'FMin p xs)
  Filter 'FMax p ('(k, x) ': xs)
    = If (CmpSymbol k p == 'GT || CmpSymbol k p == 'EQ)
         ('(k, x) ': Filter 'FMax p xs)
         (Filter 'FMax p xs)

class Conder g where
  cond :: Proxy g -> SingList s -> SingList t -> SingList (If g s t)

instance Conder 'True where
  cond _ s _ = s

instance Conder 'False where
  cond _ _ t = t

-- | Filter out the elements less-than or greater-than-or-equal to the pivot
class FilterV (f :: Flag) (p :: Symbol) (xs :: [ (Symbol, Ty) ]) where
  filterV :: Proxy f -> Sing p -> SingList xs -> SingList (Filter f p xs)

instance FilterV f p '[] where
  filterV _ _ (SingList SNil) = SNil'

instance
  ( Conder (CmpSymbol k p == 'LT)
  , FilterV 'FMin p xs
  , SingI x
  , Typeable x
  , KnownSymbol k
  ) => FilterV 'FMin p ('(k, x) ': xs) where
    filterV f p (SingList (SCons k x xs))
      = cond (Proxy @(CmpSymbol k p == 'LT))
             (SCons' k x (filterV f p (SingList xs)))
             (filterV f p (SingList xs))

instance
  ( Conder (CmpSymbol k p == 'GT || CmpSymbol k p == 'EQ)
  , FilterV 'FMax p xs
  , SingI x
  , Typeable x
  , KnownSymbol k
  ) => FilterV 'FMax p ('(k, x) ': xs) where
    filterV f p (SingList (SCons k x xs))
      = cond (Proxy @(CmpSymbol k p == 'GT || CmpSymbol k p == 'EQ))
             (SCons' k x (filterV f p (SingList xs)))
             (filterV f p (SingList xs))

-- section: Nub

-- | Remove duplicates from a sorted list
type family Nub (t :: [ k ]) :: [ k ] where
  Nub '[]           = '[]
  Nub '[e]          = '[e]
  Nub (e ': e ': s) = Nub (e ': s)
  Nub (e ': f ': s) = e ': Nub (f ': s)

-- | Value-level counterpart to the type-level 'Nub'
class Nubable t where
  nub :: SingList t -> SingList (Nub t)

instance Nubable '[] where
  nub (SingList SNil) = SNil'

instance Nubable '[e] where
  nub (SingList (SCons k v SNil)) = SCons' k v SNil'

instance Nubable (e ': s) => Nubable (e ': e ': s) where
  nub (SingList (SCons _ _ (SCons k v s))) = nub (SCons' k v (SingList s))

instance {-# OVERLAPS #-}
  ( Nub (e ': f ': s) ~ (e ': Nub (f ': s))
  , Nubable (f ': s)
  ) => Nubable (e ': f ': s) where
  nub (SingList (SCons k1 v1 (SCons k2 v2 s)))
    = SCons' k1 v1 (nub (SCons' k2 v2 (SingList s)))

-- section: Sort

-- | Type-level quick sort for normalising the representation of sets
type family Sort (xs :: [ (Symbol, Ty) ]) :: [ (Symbol, Ty) ] where
  Sort '[] = '[]
  Sort ('(k, x) ': xs)
    = Sort (Filter 'FMin k xs) :++ '[ '(k, x) ] :++ Sort (Filter 'FMax k xs)

-- | Value-level quick sort that respects the type-level ordering
class Sortable t where
  quicksort :: SingList t -> SingList (Sort t)

instance Sortable '[] where
  quicksort (SingList SNil) = SNil'

instance
  ( Sortable (Filter 'FMin p xs)
  , Sortable (Filter 'FMax p xs)
  , FilterV 'FMin p xs
  , FilterV 'FMax p xs
  , SingI x
  , Typeable x
  , KnownSymbol p
  ) => Sortable ('(p, x) ': xs) where
  quicksort (SingList (SCons k p xs)) =
    quicksort (less k xs') ++ SCons' k p SNil' ++ quicksort (more k xs')
    where less = filterV (Proxy @'FMin)
          more = filterV (Proxy @'FMax)
          xs'  = SingList xs

-- section: Normalization

type Normalize t = Nub (Sort t)

type IsNormalized t = t ~ Nub (Sort t)

normalize
  :: (Sortable t, Nubable (Sort t))
  => SingList t -> SingList (Normalize t)
normalize = nub . quicksort

-- section: Union

type Unionable s t = (Sortable (s :++ t), Nubable (Sort (s :++ t)))

type Union s t = Nub (Sort (s :++ t))

union :: Unionable s t => SingList s -> SingList t -> SingList (Union s t)
union s t = nub (quicksort (s ++ t))