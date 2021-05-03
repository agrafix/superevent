{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module SuperEvent.Store.HasqlSpec (spec) where

import SuperEvent.Store.Hasql
import SuperEvent.Store.TestUtils
import SuperEvent.Store.Types

import Data.Aeson
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
       shouldBeSuccess writeRes
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
       shouldBeSuccess writeRes
       guid2 <- UUID.nextRandom
       writeRes2 <-
           writeToStream store (StreamId "bar") EvAny (V.singleton $ entry guid2)
       shouldBeSuccess writeRes2
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
           entry <$> UUID.nextRandom
       writeRes <- writeToStream store stream EvAny events
       shouldBeSuccess writeRes
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
           entry <$> UUID.nextRandom
       writeRes <- writeToStream store stream EvAny events
       shouldBeSuccess writeRes
       let writtenGuids = V.map ed_guid events
           readHelper pos lim =
               V.map re_guid <$> readAllEvents store pos lim RdForward
       evts <- readHelper (GlobalPosition 0) 10
       evts `shouldBe` V.take 10 writtenGuids

       evts2 <- readHelper (GlobalPosition 11) 100
       evts2 `shouldBe` V.take 90 (V.drop 10 writtenGuids)
