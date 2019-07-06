{-# LANGUAGE DeriveFunctor, ExistentialQuantification, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving,
             MultiParamTypeClasses, RankNTypes, StandaloneDeriving, TypeOperators, UndecidableInstances #-}

-- | An effect that enables catching exceptions thrown from
-- impure computations such as 'IO'.
--
-- Use of the 'Control.Effect.Error' effect from @Control.Effect.Error@ may lead to
-- simpler code, as well as avoiding the dynamically-typed nature of
-- 'Control.Exception'. This is best used when integrating with third-party
-- libraries that operate in 'IO'. If you are using 'catch' for resource
-- management, consider using 'Control.Effect.Resource' instead.
module Control.Effect.Catch
  ( Catch (..)
  , catch
  , catchSync
  , runCatch
  , withCatch
  , CatchC (..)
  ) where

import           Control.Effect.Carrier
import           Control.Effect.Reader
import           Control.Effect.Sum
import qualified Control.Exception as Exc
import           Control.Exception.Safe (isSyncException)
import           Control.Monad.IO.Class
import           Control.Monad.IO.Unlift

data Catch m k
  = forall output e . Exc.Exception e => CatchIO (m output) (e -> m output) (output -> m k)

deriving instance Functor m => Functor (Catch m)

instance HFunctor Catch where
  hmap f (CatchIO go cleanup k) = CatchIO (f go) (f . cleanup) (f . k)

instance Effect Catch where
  handle state handler (CatchIO go cleanup k)
    = CatchIO (handler (go <$ state)) (\se -> handler (cleanup se <$ state)) (handler . fmap k)

-- | Like 'Control.Effect.Error.catchError', but delegating to
-- 'Control.Exception.catch' under the hood, which allows catching
-- errors that might occur when lifting 'IO' computations.
-- Unhandled errors are rethrown. Use 'Exc.SomeException' if you want
-- to catch all errors.
catch :: (Member Catch sig, Carrier sig m, Exc.Exception e)
      => m a
      -> (e -> m a)
      -> m a
catch go cleanup = send (CatchIO go cleanup pure)

-- | Like 'catch', but the handler only engages on synchronous exceptions.
-- Async exceptions are rethrown.
catchSync :: (Member Catch sig, Carrier sig m, Exc.Exception e, MonadIO m)
          => m a
          -> (e -> m a)
          -> m a
catchSync f g = f `catch` \e ->
  if isSyncException e
      then g e
      -- intentionally rethrowing an async exception synchronously,
      -- since we want to preserve async behavior
      else liftIO (Exc.throw e)

-- | Evaluate a 'Catch' effect.
runCatch :: (forall x . m x -> IO x)
         -> CatchC m a
         -> m a
runCatch handler = runReader (Handler handler) . runCatchC

-- | Evaluate a 'Catch' effect, using 'MonadUnliftIO' to infer a correct
-- unlifting function.
withCatch :: MonadUnliftIO m => CatchC m a -> m a
withCatch c = withRunInIO (\f -> runHandler (Handler f) c)

newtype Handler m = Handler (forall x . m x -> IO x)

runHandler :: Handler m -> CatchC m a -> IO a
runHandler h@(Handler handler) = handler . runReader h . runCatchC

newtype CatchC m a = CatchC { runCatchC :: ReaderC (Handler m) m a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance MonadUnliftIO m => MonadUnliftIO (CatchC m) where
  askUnliftIO = CatchC . ReaderC $ \(Handler h) ->
    withUnliftIO $ \u -> pure (UnliftIO $ \r -> unliftIO u (runCatch h r))

instance (Carrier sig m, MonadIO m) => Carrier (Catch :+: sig) (CatchC m) where
  eff (L (CatchIO act cleanup k)) = do
    handler <- CatchC ask
    liftIO (Exc.catch (runHandler handler act) (runHandler handler . cleanup)) >>= k
  eff (R other) = CatchC (eff (R (handleCoercible other)))
