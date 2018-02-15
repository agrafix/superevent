{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module SuperEvent.Store.HasqlSpec (spec) where

import SuperEvent.Store.Hasql
import SuperEvent.Store.Types

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans
import Data.Aeson
import Data.Conduit
import Test.Hspec
import qualified Data.Text as T
import qualified Data.UUID.V4 as UUID
import qualified Data.Vector as V

spec :: Spec
spec =
    around withTempStore $
    do it "should work for simple reads" simpleWriteRead
       it "should work for simple reads to two streams" simpleWriteRead2
       it "should work for simple stream reads" simpleWriteReadStream
       it "should work for simple global reads" simpleWriteReadGlobal
       it "should work for simple subscriptions" simpleWriteSubStream

simpleWriteRead ::
    (EventStoreReader IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteRead store =
    do let payload :: T.Text
           payload = "Hello"
           entry guid =
               EventData guid (EventType "foo") (toJSON payload) (toJSON ())
           stream = StreamId "text"
       guid <- UUID.nextRandom
       writeRes <- writeToStream store stream EvAny (V.singleton $ entry guid)
       writeRes `shouldBe` WrSuccess
       evt <- readEvent store stream (nextEventNumber firstEventNumber)
       case evt of
         ErrFailed -> expectationFailure "Read failed"
         ErrValue re -> re_guid re `shouldBe` guid

simpleWriteRead2 ::
    (EventStoreReader IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteRead2 store =
    do let payload :: T.Text
           payload = "Hello"
           entry guid =
               EventData guid (EventType "foo") (toJSON payload) (toJSON ())
           stream = StreamId "text"
       guid <- UUID.nextRandom
       writeRes <- writeToStream store stream EvAny (V.singleton $ entry guid)
       writeRes `shouldBe` WrSuccess
       guid2 <- UUID.nextRandom
       writeRes2 <-
           writeToStream store (StreamId "bar") EvAny (V.singleton $ entry guid2)
       writeRes2 `shouldBe` WrSuccess
       evt <- readEvent store stream (nextEventNumber firstEventNumber)
       case evt of
         ErrFailed -> expectationFailure "Read failed"
         ErrValue re -> re_guid re `shouldBe` guid

simpleWriteReadStream ::
    (EventStoreReader IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteReadStream store =
    do let payload :: T.Text
           payload = "Hello"
           entry guid =
               EventData guid (EventType "foo") (toJSON payload) (toJSON ())
           stream = StreamId "text"
       events <-
           V.forM (V.fromList [0..99]) $ \(_ :: Int) ->
           do guid <- UUID.nextRandom
              pure (entry guid)
       writeRes <- writeToStream store stream EvAny events
       writeRes `shouldBe` WrSuccess
       let writtenGuids = V.map ed_guid events
           readHelper evtNum lim =
               V.map re_guid <$> readStreamEvents store stream evtNum lim RdForward
       evts <- readHelper firstEventNumber 10
       evts `shouldBe` V.take 10 writtenGuids

       evts2 <- readHelper (incrementTimes 11 firstEventNumber) 100
       evts2 `shouldBe` V.take 90 (V.drop 10 writtenGuids)

simpleWriteReadGlobal ::
    (EventStoreReader IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteReadGlobal store =
    do let payload :: T.Text
           payload = "Hello"
           entry guid =
               EventData guid (EventType "foo") (toJSON payload) (toJSON ())
           stream = StreamId "text"
       events <-
           V.forM (V.fromList [0..99]) $ \(_ :: Int) ->
           do guid <- UUID.nextRandom
              pure (entry guid)
       writeRes <- writeToStream store stream EvAny events
       writeRes `shouldBe` WrSuccess
       let writtenGuids = V.map ed_guid events
           readHelper pos lim =
               V.map (re_guid . snd) <$> readAllEvents store pos lim RdForward
       evts <- readHelper (GlobalPosition 0) 10
       evts `shouldBe` V.take 10 writtenGuids

       evts2 <- readHelper (GlobalPosition 11) 100
       evts2 `shouldBe` V.take 90 (V.drop 10 writtenGuids)

simpleWriteSubStream ::
    (EventStoreSubscriber IO es, EventStoreReader IO es, EventStoreWriter IO es)
    => es -> IO ()
simpleWriteSubStream store =
    do let payload :: T.Text
           payload = "Hello"
           entry guid =
               EventData guid (EventType "foo") (toJSON payload) (toJSON ())
           stream = StreamId "text"
       outVar <- newTVarIO []
       poller <-
           async $
           do let consumer =
                      do val <- await
                         case val of
                           Nothing ->
                               do liftIO $ putStrLn "Consumer was terminated"
                                  pure ()
                           Just v ->
                               do liftIO $ atomically $ modifyTVar' outVar ((:) v)
                                  consumer
              subscribeTo store (SubscriptionConfig SspBeginning stream) $$ consumer
       events <-
           V.forM (V.fromList [0..9999]) $ \(_ :: Int) ->
           do guid <- UUID.nextRandom
              pure (entry guid)
       writeRes <- writeToStream store stream EvAny events
       writeRes `shouldBe` WrSuccess
       let writtenGuids = V.map ed_guid events
       finalResult <-
           atomically $
           do vals <- readTVar outVar
              when (length vals < 9999) retry
              pure (V.map re_guid $ V.reverse $ V.fromList vals)
       uninterruptibleCancel poller
       finalResult `shouldBe` writtenGuids
