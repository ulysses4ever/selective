{-# LANGUAGE DeriveFunctor, RankNTypes, ScopedTypeVariables, TupleSections #-}
module Control.Selective (
    -- * Type class
    Selective (..), (<*?), branch, selectA, apS, selectM,
    Cases (..), casesEnum, cases,

    -- * Conditional combinators
    ifS, whenS, fromMaybeS, orElse, untilRight, whileS, (<||>), (<&&>), anyS,
    allS, matchS, bindS, matchM,

    -- * Static analysis
    Validation (..), dependencies
    ) where

import Build.Task
import Control.Applicative
import Control.Monad.Trans.Except
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State
import Control.Monad.Trans.Writer
import Data.Bifunctor
import Data.Bool
import Data.Functor.Identity
import Data.Proxy
import Data.Semigroup

-- | Selective applicative functors. You can think of 'select' as a selective
-- function application: when given a value of type @Left a@, you __must apply__
-- the given function, but when given a @Right b@, you __may skip__ the function
-- and associated effects, and simply return the @b@.
--
-- Note that it is not a requirement for selective functors to skip unnecessary
-- effects. It may be counterintuitive, but this makes them more useful. Why?
-- Typically, when executing a selective computation, you would want to skip the
-- effects (saving work); but on the other hand, if your goal is to statically
-- analyse a given selective computation and extract the set of all possible
-- effects (without actually executing them), then you do not want to skip any
-- effects, because that defeats the purpose of static analysis.
--
-- The type signature of 'select' is reminiscent of both '<*>' and '>>=', and
-- indeed a selective functor is in some sense a composition of an applicative
-- functor and the 'Either' monad.
--
-- Laws: (F1) Apply a pure function to the result:
--
--            f <$> select x y = select (second f <$> x) ((f .) <$> y)
--
--       (F2) Apply a pure function to the 'Left' case of the first argument:
--
--            select (first f <$> x) y = select x ((. f) <$> y)
--
--       (F3) Apply a pure function to the second argument:
--
--            select x (f <$> y) = select (first (flip f) <$> x) (flip ($) <$> y)
--
--       (P1) Selective application of a pure function:
--
--            select x (pure y) = either y id <$> x
--
--       (P2) Selective application of a function to a pure 'Left' value:
--
--            select (pure (Left x)) y = ($x) <$> y
--
--       (A1) Associativity:
--
--            select x (select y z) = select (select (f <$> x) (g <$> y)) (h <$> z)
--
--            or in operator form:
--
--            x <*? (y <*? z) = (f <$> x) <*? (g <$> y) <*? (h <$> z)
--
--            where f x = Right <$> x
--                  g y = \a -> bimap (,a) ($a) y
--                  h z = uncurry z
--
--
--       Note that there is no law for selective application of a function to a
--       pure 'Right' value, i.e. we do not require that the following holds:
--
--            select (pure (Right x)) y = pure x
--
--       In particular, the following is allowed too:
--
--            select (pure (Right x)) y = const x <$> y
--
--       We therefore allow 'select' to be selective about effects in this case.
--
-- A consequence of the above laws is that 'apS' satisfies 'Applicative' laws.
-- We choose not to require that 'apS' = '<*>', since this forbids some
-- interesting instances, such as 'Validation'.
--
-- If f is also a 'Monad', we require that 'select' = 'selectM'.
--
-- We can rewrite any selective expression in the following canonical form:
--
--          f (a + ... + z)    -- A value to be processed (+ denotes a sum type)
--       -> f (a -> (b + ...)) -- How to process a's
--       -> f (b -> (c + ...)) -- How to process b's
--       ...
--       -> f (y -> z)         -- How to process y's
--       -> f z                -- The resulting z
--
-- See "Control.Selective.Sketch" for proof sketches.
class Applicative f => Selective f where
    select :: f (Either a b) -> f (a -> b) -> f b

data Cases a = Cases [a] (a -> Bool)

casesEnum :: (Bounded a, Enum a) => Cases a
casesEnum = Cases [minBound..maxBound] (const True)

cases :: Eq a => [a] -> Cases a
cases as = Cases as (`elem` as)

-- | An operator alias for 'select', which is sometimes convenient. It tries to
-- follow the notational convention for 'Applicative' operators. The angle
-- bracket pointing to the left means we always use the corresponding value.
-- The value on the right, however, may be skipped, hence the question mark.
(<*?) :: Selective f => f (Either a b) -> f (a -> b) -> f b
(<*?) = select

infixl 4 <*?

-- | The 'branch' function is a natural generalisation of 'select': instead of
-- skipping an unnecessary effect, it chooses which of the two given effectful
-- functions to apply to a given argument; the other effect is unnecessary. It
-- is possible to implement 'branch' in terms of 'select', which is a good
-- puzzle (give it a try!).
branch :: Selective f => f (Either a b) -> f (a -> c) -> f (b -> c) -> f c
branch x l r = fmap (fmap Left) x <*? fmap (fmap Right) l <*? r

-- | We can write a function with the type signature of 'select' using the
-- 'Applicative' type class, but it will always execute the effects associated
-- with the second argument, hence being potentially less efficient.
selectA :: Applicative f => f (Either a b) -> f (a -> b) -> f b
selectA x f = (\e f -> either f id e) <$> x <*> f

-- | 'Selective' is more powerful than 'Applicative': we can recover the
-- application operator '<*>'. In particular, the following 'Applicative' laws
-- hold when expressed using 'apS':
--
-- * Identity     : pure id <*> v = v
-- * Homomorphism : pure f <*> pure x = pure (f x)
-- * Interchange  : u <*> pure y = pure ($y) <*> u
-- * Composition  : (.) <$> u <*> v <*> w = u <*> (v <*> w)
apS :: Selective f => f (a -> b) -> f a -> f b
apS f x = select (Left <$> f) (flip ($) <$> x)

-- | One can easily implement a monadic 'selectM' that satisfies the laws,
-- hence any 'Monad' is 'Selective'.
selectM :: Monad f => f (Either a b) -> f (a -> b) -> f b
selectM mx mf = do
    x <- mx
    case x of
        Left  a -> fmap ($a) mf
        Right b -> pure b

-- Many useful 'Monad' combinators can be implemented with 'Selective'

-- | Branch on a Boolean value, skipping unnecessary effects.
ifS :: Selective f => f Bool -> f a -> f a -> f a
ifS i t e = branch (bool (Right ()) (Left ()) <$> i) (const <$> t) (const <$> e)

-- | Eliminate a specified value @a@ from @f (Either a b)@ by replacing it
-- with a given @f b@.
eliminate :: (Eq a, Selective f) => a -> f b -> f (Either a b) -> f (Either a b)
eliminate x fb fa = select (match x <$> fa) (const . Right <$> fb)
  where
    match _ (Right y) = Right (Right y)
    match x (Left  y) = if x == y then Left () else Right (Left y)

-- | Eliminate all specified values @a@ from @f (Either a b)@ by replacing each
-- of them with a given @f a@.
matchS :: (Eq a, Selective f) => Cases a -> f a -> (a -> f b) -> f (Either a b)
matchS (Cases cs _) x f = foldr (\c -> eliminate c (f c)) (Left <$> x) cs

-- | Eliminate all specified values @a@ from @f (Either a b)@ by replacing each
-- of them with a given @f a@.
matchM :: Monad m => Cases a -> m a -> (a -> m b) -> m (Either a b)
matchM (Cases _ p) mx f = do
    x <- mx
    if p x then Right <$> (f x) else return (Left x)

-- TODO: Add a type-safe version based on @KnownNat@.
-- | A restricted version of monadic bind. Fails with an error if the 'Bounded'
-- and 'Enum' instances for @a@ do not cover all values of @a@.
bindS :: (Bounded a, Enum a, Eq a, Selective f) => f a -> (a -> f b) -> f b
bindS x f = fromRight <$> matchS casesEnum x f
  where
    fromRight (Right b) = b
    fromRight _ = error "Selective.bindS: incorrect Bounded and/or Enum instance"

-- | Conditionally perform an effect.
whenS :: Selective f => f Bool -> f () -> f ()
whenS x act = ifS x act (pure ())

-- | A lifted version of 'fromMaybe'.
fromMaybeS :: Selective f => f a -> f (Maybe a) -> f a
fromMaybeS dx x = select (maybe (Left ()) Right <$> x) (const <$> dx)

-- | Return the first @Right@ value. If both are @Left@'s, accumulate errors.
orElse :: (Selective f, Semigroup e) => f (Either e a) -> f (Either e a) -> f (Either e a)
orElse x = select (Right <$> x) . fmap (\y e -> first (e <>) y)

-- | Keep checking an effectful condition while it holds.
whileS :: Selective f => f Bool -> f ()
whileS act = whenS act (whileS act)

-- | Keep running an effectful computation until it returns a @Right@ value,
-- collecting the @Left@'s using a supplied @Monoid@ instance.
untilRight :: forall a b f. (Monoid a, Selective f) => f (Either a b) -> f (a, b)
untilRight x = select y h
  where
    y :: f (Either a (a, b))
    y = fmap (mempty,) <$> x
    h :: f (a -> (a, b))
    h = (\(as, b) a -> (mappend a as, b)) <$> untilRight x

-- | A lifted version of lazy Boolean OR.
(<||>) :: Selective f => f Bool -> f Bool -> f Bool
(<||>) a b = ifS a (pure True) b

-- | A lifted version of lazy Boolean AND.
(<&&>) :: Selective f => f Bool -> f Bool -> f Bool
(<&&>) a b = ifS a b (pure False)

-- | A lifted version of 'any'. Retains the short-circuiting behaviour.
anyS :: Selective f => (a -> f Bool) -> [a] -> f Bool
anyS p = foldr ((<||>) . p) (pure False)

-- | A lifted version of 'all'. Retains the short-circuiting behaviour.
allS :: Selective f => (a -> f Bool) -> [a] -> f Bool
allS p = foldr ((<&&>) . p) (pure True)

-- Instances

-- As a quick experiment, try: ifS (pure True) (print 1) (print 2)
instance Selective IO where select = selectM

-- And... we need to write a lot more instances
instance Selective [] where select = selectM
instance Selective ((->) a) where select = selectM
instance Monoid a => Selective ((,) a) where select = selectM
instance Selective Identity where select = selectM
instance Selective Maybe where select = selectM
instance Selective Proxy where select = selectM

instance Monad m => Selective (ExceptT s m) where select = selectM
instance Monad m => Selective (ReaderT s m) where select = selectM
instance Monad m => Selective (StateT s m) where select = selectM
instance (Monoid s, Monad m) => Selective (WriterT s m) where select = selectM

-- Selective instance for the standard Applicative Validation
-- This is a good example of a Selective functor which is not a Monad
data Validation e a = Failure e | Success a deriving (Functor, Show)

instance Semigroup e => Applicative (Validation e) where
    pure  = Success
    Failure e1 <*> Failure e2 = Failure (e1 <> e2)
    Failure e1 <*> Success _  = Failure e1
    Success _  <*> Failure e2 = Failure e2
    Success f  <*> Success a  = Success (f a)

instance Semigroup e => Selective (Validation e) where
    select (Success (Right b)) _           = Success b
    select (Success (Left  _)) (Failure e) = Failure e
    select (Success (Left  a)) (Success f) = Success (f a)
    select (Failure e        ) _           = Failure e

-- Static analysis of selective functors
instance Monoid m => Selective (Const m) where
    select = selectA

-- | Extract dependencies from a selective task.
dependencies :: Task Selective k v -> [k]
dependencies task = getConst $ run task (\k -> Const [k])
