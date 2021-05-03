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
  => es -> StreamId -> IO TestSubscriber
makeEventSubscriber store stream =
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
          runConduit $ subscribeTo store (SStream $ StreamSubscription SspBeginning stream) .| consumer
     pure (outVar, poller)

makeGlobalSubscriber ::
  EventStoreSubscriber IO es
  => es -> IO TestSubscriber
makeGlobalSubscriber store =
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
          runConduit $ subscribeTo store (SGlobal $ GlobalSubscription SspBeginning) .| consumer
     pure (outVar, poller)

checkAllEventsArrived :: (TVar [RecordedEvent], Async a) -> IO (V.Vector UUID)
checkAllEventsArrived (outVar, poller) =
  do finalResult <-
           atomically $
           do vals <- readTVar outVar
              when (length vals <= 999) retry
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
     describe "global sub" $
       do it "simple case works" simpleWriteGlobalStream


simpleWriteSubStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteSubStream store =
    do let stream = StreamId "text"
       (outVar, poller) <- makeEventSubscriber store stream
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny events
       shouldBeSuccess writeRes
       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived (outVar, poller)
       finalResult `shouldBe` writtenGuids

interleavedStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
interleavedStream store =
    do let stream = StreamId "text"
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny (V.take 50 events)
       shouldBeSuccess writeRes

       (outVar, poller) <- makeEventSubscriber store stream
       writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
       shouldBeSuccess writeRes2

       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived (outVar, poller)
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
       (outVar, poller) <- makeEventSubscriber store stream

       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived (outVar, poller)
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

       (outVar, poller) <- makeEventSubscriber store stream

       writeRes2 <- writeToStream store stream EvAny (V.drop 50 events)
       shouldBeSuccess writeRes2

       writeRes3 <- writeToStream store stream2 EvAny (V.drop 50 events2)
       shouldBeSuccess writeRes3

       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived (outVar, poller)
       finalResult `shouldBe` writtenGuids

simpleWriteGlobalStream ::
    (EventStoreSubscriber IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteGlobalStream store =
    do let stream = StreamId "text"
       (outVar, poller) <- makeGlobalSubscriber store
       events <- generateEvents
       writeRes <- writeToStream store stream EvAny events
       shouldBeSuccess writeRes
       let writtenGuids = V.map ed_guid events
       finalResult <- checkAllEventsArrived (outVar, poller)
       finalResult `shouldBe` writtenGuids
