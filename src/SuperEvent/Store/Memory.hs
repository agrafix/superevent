{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE RankNTypes #-}
module SuperEvent.Store.Memory where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception.Lifted
import Control.Monad.Base
import Control.Monad.Trans.Control
import Data.Hashable
import Data.Typeable
import Data.UUID (UUID)
import GHC.Generics
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T

import SuperEvent.Types

data MemoryKey
    = MemoryKey
    { mk_snapshot :: T.Text
    , mk_uuid :: Maybe UUID
    } deriving (Show, Eq, Generic)

instance Hashable MemoryKey

data AnySnapshot
    = forall x. Typeable x => AnyEvent { unAnyEvent :: x }

class HasMemoryKey st where
    getMemoryKey :: st -> MemoryKey

data MemoryStore
    = MemoryStore
    { ms_queue :: TQueue AnyEvent
    , ms_cache :: TVar (HM.HashMap MemoryKey AnySnapshot)
    , ms_exit :: TVar Bool
    , ms_reducer :: Async ()
    }

withMemoryStore :: MonadBaseControl IO m => (EventStore m st -> m a) -> m a
withMemoryStore go =
    bracket alloc dealloc $ \hdl -> undefined
    where
      reduce es cache exitVar =
          do continue <-
                 atomically $
                 do exit <- readTVar exitVar
                    nextEvent <- tryReadTQueue es
                    if exit
                       then pure False
                       else case nextEvent of
                              Nothing -> retry
                              Just evt ->
                                  -- todo
             when continue (reduce es cache exitVar)

      alloc =
          do eventStream <- liftBase newTQueueIO
             cache <- liftBase (newTVarIO mempty)
             exitVar <- liftBase (newTVarIO False)
             reducer <- liftBase $ async $ reduce eventStream cache exitVar
             pure (MemoryStore eventStream cache exitVar reducer)
