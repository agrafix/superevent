{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module SuperEvent.Store.TestUtils
  ( streamingSpecHelper, shouldBeSuccess )
where

import SuperEvent.Store.Types

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans
import Data.Aeson
import Data.Conduit
import Data.UUID (UUID)
import Test.Hspec
import qualified Data.Text as T
import qualified Data.UUID.V4 as UUID
import qualified Data.Vector as V

shouldBeSuccess :: WriteResult -> IO ()
shouldBeSuccess x =
  case x of
    WrSuccess _ -> pure ()
    WrWrongExpectedVersion -> expectationFailure "expected successfull write"

generateEvents :: IO (V.Vector EventData)
generateEvents =
  do let payload :: T.Text
         payload = "Hello"
         entry guid =
               EventData guid (EventType "foo") (toJSON payload) (toJSON ())
     V.forM (V.fromList [0..999]) $ \(_ :: Int) -> entry <$> UUID.nextRandom

type TestSubscriber = (TVar [RecordedEvent], Async ())

makeEventSubscriber ::
  EventStoreSubscriber IO es
  => es -> StreamId -> SubscriptionStartPosition EventNumber -> IO TestSubscriber
makeEventSubscriber store stream startPos =
  do outVar <- newTVarIO []
     poller <-
       async $
       do let consumer =
                do val <- await
                   case val of
                     Nothing ->
                       do liftIO $ putStrLn "Consumer was terminated"
                          pure ()
                     Just v ->
                       do liftIO $ atomically $ modifyTVar' outVar (v :)
                          consumer
          runConduit $ subscribeTo store (SStream $ StreamSubscription startPos stream) .| consumer
     pure (outVar, poller)

makeGlobalSubscriber ::
  EventStoreSubscriber IO es
  => es -> SubscriptionStartPosition GlobalPosition  -> IO TestSubscriber
makeGlobalSubscriber store startPos =
  do outVar <- newTVarIO []
     poller <-
       async $
       do let consumer =
                do val <- await
                   case val of
                     Nothing ->
                       do liftIO $ putStrLn "Consumer was terminated"
                          pure ()
                     Just v ->
                       do liftIO $ atomically $ modifyTVar' outVar (v :)
                          consumer
          runConduit $ subscribeTo store (SGlobal $ GlobalSubscription startPos) .| consumer
     pure (outVar, poller)

checkAllEventsArrived :: Int -> (TVar [RecordedEvent], Async a) -> IO (V.Vector UUID)
checkAllEventsArrived expectedEvents (outVar, poller) =
  do finalResult <-
           atomically $
           do vals <- readTVar outVar
              when (length vals < expectedEvents) retry
              pure (V.map re_guid $ V.reverse $ V.fromList vals)
     uninterruptibleCancel poller
     pure finalResult

streamingSpecHelper ::
  (EventStoreSubscriber IO es, EventStoreWriter IO es)
  => SpecWith es
streamingSpecHelper =
  describe "streaming" $
  do it "simple case works" simpleWriteSubStream
     it "with existing events works" interleavedStream
     it "with concurrent event writing works" concurrentStream
     it "multiple streams" multiStream
     it "late start" lateStartStream
     describe "global sub" $
       do it "simple case works" simpleWriteGlobalStream
          it "late start" lateStartGlobalStream


simpleWriteSubStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteSubStream store =
    do let stream = StreamId "text"
       (outVar, poller) <- makeEventSubscriber store stream SspBeginning
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny events
       shouldBeSuccess writeRes
       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived 1000 (outVar, poller)
       finalResult `shouldBe` writtenGuids

lateStartStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
lateStartStream store =
    do let stream = StreamId "text"
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny (V.take 50 events)
       shouldBeSuccess writeRes

       (outVar, poller) <- makeEventSubscriber store stream (SspFrom (EventNumber 20))
       writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
       shouldBeSuccess writeRes2

       let expectedGuids = V.map ed_guid $ V.drop 19 events
       finalResult <- checkAllEventsArrived (V.length expectedGuids) (outVar, poller)
       finalResult `shouldBe` expectedGuids

interleavedStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
interleavedStream store =
    do let stream = StreamId "text"
       events <- generateEvents

       writeRes <- writeToStream store stream EvAny (V.take 50 events)
       shouldBeSuccess writeRes

       (outVar, poller) <- makeEventSubscriber store stream SspBeginning
       writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
       shouldBeSuccess writeRes2

       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived 1000 (outVar, poller)
       finalResult `shouldBe` writtenGuids

concurrentStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
concurrentStream store =
    do let stream = StreamId "text"
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny (V.take 50 events)
       shouldBeSuccess writeRes

       _ <- async $
         do writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
            shouldBeSuccess writeRes2
       (outVar, poller) <- makeEventSubscriber store stream SspBeginning

       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived 1000 (outVar, poller)
       finalResult `shouldBe` writtenGuids

multiStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
multiStream store =
    do let stream = StreamId "text"
           stream2 = StreamId "text2"
       events <- generateEvents
       events2 <- generateEvents

       writeRes <- writeToStream store stream EvAny (V.take 50 events)
       shouldBeSuccess writeRes

       writeRes1 <- writeToStream store stream2 EvAny (V.take 50 events2)
       shouldBeSuccess writeRes1

       (outVar, poller) <- makeEventSubscriber store stream SspBeginning

       writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
       shouldBeSuccess writeRes2

       writeRes3 <- writeToStream store stream2 EvAny (V.drop 50 events2)
       shouldBeSuccess writeRes3

       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived 1000 (outVar, poller)
       finalResult `shouldBe` writtenGuids

simpleWriteGlobalStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteGlobalStream store =
    do let stream = StreamId "text"
       (outVar, poller) <- makeGlobalSubscriber store SspBeginning
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny events
       shouldBeSuccess writeRes
       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived 1000 (outVar, poller)
       finalResult `shouldBe` writtenGuids

lateStartGlobalStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
lateStartGlobalStream store =
    do let stream = StreamId "text"
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny (V.take 50 events)
       shouldBeSuccess writeRes

       (outVar, poller) <- makeGlobalSubscriber store (SspFrom (GlobalPosition 20))
       writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
       shouldBeSuccess writeRes2

       let expectedGuids = V.map ed_guid $ V.drop 19 events
       finalResult <- checkAllEventsArrived (V.length expectedGuids) (outVar, poller)
       finalResult `shouldBe` expectedGuids
