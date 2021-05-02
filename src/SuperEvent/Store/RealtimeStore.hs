{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
module SuperEvent.Store.RealtimeStore
  ( newRealtimeStore, RealStore )
where

import Conduit
import Control.Monad
import Data.Vector (Vector)
import qualified Data.Vector as V

import SuperEvent.PubSub.Types
import SuperEvent.Store.Types

data RealStore ps st
  = RealStore
  { rsPs :: ps
  , rsStore :: st
  }

newRealtimeStore :: ps -> st -> RealStore ps st
newRealtimeStore = RealStore

instance (MonadIO m, EventStoreWriter m st, PubSub m ps RecordedEvent) => EventStoreWriter m (RealStore ps st) where
  writeToStream = writeToStreamImpl

writeToStreamImpl ::
  (MonadIO m, EventStoreWriter m st, PubSub m ps RecordedEvent)
  => RealStore ps st -> StreamId -> ExpectedVersion -> Vector EventData -> m WriteResult
writeToStreamImpl rs streamId ev eventData =
  do res <- writeToStream (rsStore rs) streamId ev eventData
     case res of
       WrSuccess events -> mapM_ (publish (rsPs rs)) events
       WrWrongExpectedVersion -> pure ()
     pure res

instance (MonadIO m, EventStoreWriter m st, EventStoreReader m st, PubSub m ps RecordedEvent) => EventStoreSubscriber m (RealStore ps st) where
    subscribeTo = subscribeToImpl

subscribeToImpl ::
  forall m st ps. (MonadIO m, EventStoreWriter m st, EventStoreReader m st, PubSub m ps RecordedEvent)
  => RealStore ps st -> SubscriptionConfig -> ConduitM () RecordedEvent m ()
subscribeToImpl rs cfg =
  subscribe (rsPs rs) .| maybeBackfill
  where
    maybeBackfill =
      do cursor <- lift $ readStreamVersion (rsStore rs) (sc_stream cfg)
         desiredStartNumber <-
           case sc_startPosition cfg of
             SspBeginning -> pure firstEventNumber
             SspFrom x -> pure x
             SspCurrent -> pure cursor
         startAt <- readLoop desiredStartNumber cursor
         sendLoop startAt

    readLoop fromNumber toNumber =
      if fromNumber < toNumber
      then do evts <-
                lift $
                readStreamEvents (rsStore rs) (sc_stream cfg) fromNumber 10000 RdForward
              mapM_ yield $ V.filter (\e -> re_number e <= toNumber) evts
              if V.null evts
                then pure fromNumber
                else readLoop (re_number $ V.last evts) toNumber
      else pure fromNumber

    sendLoop startAt =
      do evt <- await
         case evt of
           Just x ->
             do when (re_number x > startAt) $ yield x
                sendLoop startAt
           Nothing -> pure ()
