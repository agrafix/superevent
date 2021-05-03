{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FunctionalDependencies #-}
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

class StreamPositionConsumer es a x | a -> x where
  spcReader :: EventStoreReader m es => es -> a -> x -> Int -> ReadDirection -> m (Vector RecordedEvent)
  spcGetVersion :: EventStoreReader m es => es -> a -> m x

class StreamPosition x where
  spGetStart :: x -> SubscriptionStartPosition x -> x
  spSelector :: RecordedEvent -> x

class StreamFilter a where
  spFilter :: a -> RecordedEvent -> Bool

instance EventStoreReader m es => StreamPositionConsumer es StreamId EventNumber where
  spcReader store stream pos = readStreamEvents store stream pos
  spcGetVersion = readStreamVersion

instance StreamPosition EventNumber where
  spGetStart cursor pos =
    case pos of
      SspBeginning -> firstEventNumber
      SspFrom x -> x
      SspCurrent -> cursor
  spSelector = re_number

instance StreamFilter StreamId where
  spFilter streamId re = re_stream re == streamId

instance StreamPositionConsumer es () GlobalPosition where
  spcReader store _ = readAllEvents store
  spcGetVersion store _ = readGlobalPosition store

instance StreamPosition GlobalPosition where
  spGetStart cursor pos =
    case pos of
      SspBeginning -> GlobalPosition 0
      SspFrom x -> x
      SspCurrent -> cursor
  spSelector = re_globalPosition

instance StreamFilter () where
  spFilter _ _ = True

makeBackfill ::
  ( Monad m
  , Ord x
  , EventStoreReader m es
  , StreamPositionConsumer es a x
  , StreamPosition x
  , StreamFilter a
  )
  => es
  -> a
  -> SubscriptionStartPosition x
  -> ConduitM RecordedEvent RecordedEvent m ()
makeBackfill store a startPos =
  do cursor <- lift $ spcGetVersion store a
     let desiredStartNumber = spGetStart cursor startPos
         reader = spcReader store a
     startAt <- readLoop reader desiredStartNumber cursor
     sendLoop startAt
  where
    readLoop reader fromNumber toNumber =
      if fromNumber < toNumber
      then do evts <- lift $ reader fromNumber 10000 RdForward
              mapM_ yield $ V.filter (\e -> spSelector e <= toNumber) evts
              if V.null evts
                then pure fromNumber
                else readLoop reader (spSelector $ V.last evts) toNumber
      else pure fromNumber

    sendLoop startAt =
      do evt <- await
         case evt of
           Just x ->
             do when (spSelector x > startAt && spFilter a x) $
                  yield x
                sendLoop startAt
           Nothing -> pure ()

subscribeToImpl ::
  forall m st ps. (MonadIO m, EventStoreWriter m st, EventStoreReader m st, PubSub m ps RecordedEvent)
  => RealStore ps st -> Subscription -> ConduitM () RecordedEvent m ()
subscribeToImpl rs cfg =
  subscribe (rsPs rs) .| maybeBackfill
  where
    maybeBackfill =
      case cfg of
        SStream ss ->
          makeBackfill (rsStore rs) (ss_stream ss) (ss_startPosition ss)
        SGlobal gs ->
          makeBackfill (rsStore rs) () (gs_startPosition gs)
