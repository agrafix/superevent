{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module SuperEvent.Store.Hasql
    ( newPgSqlStore
    , withTempStore
    , DbStore
    )
where

import SuperEvent.Store.Hasql.Utils
import SuperEvent.Store.Types

import Control.Exception
import Control.Monad.Trans
import Data.Conduit
import Data.Functor.Contravariant
import Data.Maybe
import Data.Monoid
import Data.String.QQ
import Data.Time.TimeSpan
import Hasql.Query
import System.Random
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Vector as V
import qualified Hasql.Connection as C
import qualified Hasql.Decoders as D
import qualified Hasql.Encoders as E
import qualified Hasql.Migration as M
import qualified Hasql.Pool as P
import qualified Hasql.Session as S
import qualified Hasql.Transaction as Tx

data DbStore
    = DbStore
    { db_store :: Store
    }

newPgSqlStore :: BS.ByteString -> IO DbStore
newPgSqlStore connStr =
    do pool <- P.acquire (20, 60 * 5, connStr)
       let store = Store pool
       let migs = [M.MigrationScript "schemav1" schemaV1]
       withPool store $
           let loop [] = pure ()
               loop (mig : more) =
                  do res <-
                         dbTx Tx.ReadCommitted Tx.Write $ M.runMigration mig
                     case res of
                       M.MigrationError err -> fail err
                       M.MigrationSuccess -> loop more
           in loop (M.MigrationInitialization : migs)
       pure $ DbStore store

-- | Temporary postgres store for tests
withTempStore :: (DbStore -> IO a) -> IO a
withTempStore run =
    bracket allocDb removeDb $ \(_, dbname) ->
    do putStrLn ("TempDB is: " <> show dbname)
       bracket (newPgSqlStore $ "dbname=" <> dbname) (\_ -> pure ()) run
    where
        assertRight y =
            case y of
              Right x -> pure x
              Left errMsg -> fail (show errMsg)
        removeDb (globalConn, dbname) =
            do runRes2 <-
                   flip S.run globalConn $ S.sql $ "DROP DATABASE IF EXISTS " <> dbname
               assertRight runRes2
               C.release globalConn
        allocDb =
            do globalConnE <- C.acquire ""
               globalConn <- assertRight globalConnE
               dbnameSuffix <-
                   BSC.pack . take 10 . randomRs ('a', 'z') <$>
                   newStdGen
               let dbname = "eventstore_temp_" <> dbnameSuffix
               runRes <-
                   flip S.run globalConn $
                   do S.sql $ "DROP DATABASE IF EXISTS " <> dbname
                      S.sql $ "CREATE DATABASE " <> dbname
               assertRight runRes
               localConnE <- C.acquire $ "dbname=" <> dbname
               localConn <- assertRight localConnE
               runRes' <-
                   flip S.run localConn $
                   S.sql $ "CREATE EXTENSION hstore"
               assertRight runRes'
               C.release localConn
               pure (globalConn, dbname)

encStreamId :: E.Value StreamId
encStreamId = contramap unStreamId E.text

encEventType :: E.Value EventType
encEventType = contramap unEventType E.text

encEventNumber :: E.Value EventNumber
encEventNumber = contramap unEventNumber E.int8

encGlobalPosition :: E.Value GlobalPosition
encGlobalPosition = contramap unGlobalPosition E.int8

decEventNumber :: D.Row EventNumber
decEventNumber = EventNumber <$> D.value D.int8

decRecordedEvent :: D.Row RecordedEvent
decRecordedEvent =
    RecordedEvent
    <$> (StreamId <$> D.value D.text)
    <*> D.value D.uuid
    <*> decEventNumber
    <*> (EventType <$> D.value D.text)
    <*> D.value D.jsonb
    <*> D.value D.jsonb
    <*> D.value D.timestamptz

qStreamVersion :: Query StreamId (Maybe EventNumber)
qStreamVersion =
    statement sql encoder decoder True
    where
      sql =
          "SELECT MAX(version) FROM events WHERE stream = $1"
      encoder =
          E.value encStreamId
      decoder =
          fmap EventNumber <$> D.singleRow (D.nullableValue D.int8)

data WriteEvent
    = WriteEvent
    { we_stream :: StreamId
    , we_number :: EventNumber
    , we_data :: EventData
    }

qWriteEvent :: Query WriteEvent ()
qWriteEvent =
    statement sql encoder D.unit True
    where
      sql =
          "INSERT INTO events "
          <> "(id, stream, version, type, data, meta_data)"
          <> " VALUES "
          <> "($1, $2, $3, $4, $5, $6)"
      encoder =
          contramap (ed_guid . we_data) (E.value E.uuid)
          <> contramap we_stream (E.value encStreamId)
          <> contramap we_number (E.value encEventNumber)
          <> contramap (ed_type . we_data) (E.value encEventType)
          <> contramap (ed_data . we_data) (E.value E.jsonb)
          <> contramap (ed_metadata . we_data) (E.value E.jsonb)

data SingleEventQuery
    = SingleEventQuery
    { seq_stream :: StreamId
    , seq_number :: EventNumber
    }

qSingleEvent :: Query SingleEventQuery (Maybe RecordedEvent)
qSingleEvent =
    statement sql encoder decoder True
    where
      sql =
          "SELECT "
          <> "stream, id, version, type, data, meta_data, created "
          <> "FROM "
          <> "events "
          <> "WHERE stream = $1 AND version = $2 LIMIT 1"
      encoder =
          contramap seq_stream (E.value encStreamId)
          <> contramap seq_number (E.value encEventNumber)
      decoder =
          D.maybeRow decRecordedEvent

data EventStreamQuery
    = EventStreamQuery
    { esq_stream :: StreamId
    , esq_number :: EventNumber
    , esq_limit :: Int
    }

sqlEventStream :: ReadDirection -> BS.ByteString
sqlEventStream readDir =
    "SELECT "
    <> "stream, id, version, type, data, meta_data, created "
    <> "FROM "
    <> "events "
    <> "WHERE stream = $1 AND version "
    <> (if readDir == RdForward then ">=" else "<=")
    <> " $2 "
    <> "ORDER BY version "
    <> (if readDir == RdForward then "ASC" else "DESC")
    <> " LIMIT $3"

encEventStreamQuery :: E.Params EventStreamQuery
encEventStreamQuery =
    contramap esq_stream (E.value encStreamId)
    <> contramap esq_number (E.value encEventNumber)
    <> contramap (fromIntegral . esq_limit) (E.value E.int8)

qEventStream :: ReadDirection -> Query EventStreamQuery (V.Vector RecordedEvent)
qEventStream readDir =
    statement (sqlEventStream readDir) encEventStreamQuery decoder True
    where
      decoder =
          D.rowsVector decRecordedEvent

data GlobalEventQuery
    = GlobalEventQuery
    { geq_position :: GlobalPosition
    , geq_limit :: Int
    }

qGlobalEvent ::
    ReadDirection
    -> Query GlobalEventQuery (V.Vector (GlobalPosition, RecordedEvent))
qGlobalEvent readDir =
    statement sql encoder decoder True
    where
      sql =
          "SELECT "
          <> "position, stream, id, version, type, data, meta_data, created "
          <> "FROM "
          <> "events "
          <> "WHERE position "
          <> (if readDir == RdForward then ">=" else "<=")
          <> " $1 "
          <> "ORDER BY position "
          <> (if readDir == RdForward then "ASC" else "DESC")
          <> " LIMIT $2 "
      encoder =
          contramap geq_position (E.value encGlobalPosition)
          <> contramap (fromIntegral . geq_limit) (E.value E.int8)
      decoder =
          D.rowsVector $
          (,)
          <$> (GlobalPosition <$> D.value D.int8)
          <*> decRecordedEvent

dbWriteToStream ::
    DbStore
    -> StreamId
    -> ExpectedVersion
    -> V.Vector EventData
    -> IO WriteResult
dbWriteToStream db streamId ev events =
    withPool (db_store db) $
    dbTx Tx.Serializable Tx.Write $
    do myVersion <- Tx.query streamId qStreamVersion
       case ev of
         EvAny -> continueIf True myVersion
         EvNoStream -> continueIf (isNothing myVersion) myVersion
         EvStreamExists -> continueIf (isJust myVersion) myVersion
         EvExact expected -> continueIf (myVersion == Just expected) myVersion
    where
        continue vers =
            flip V.imapM_ events $ \idx event ->
            do let we =
                       WriteEvent
                       { we_stream = streamId
                       , we_number =
                               incrementTimes idx $
                               nextEventNumber $ fromMaybe firstEventNumber vers
                       , we_data = event
                       }
               Tx.query we qWriteEvent
        continueIf cond vers =
            if cond
            then do continue vers
                    pure WrSuccess
            else pure WrWrongExpectedVersion

instance EventStoreWriter IO DbStore where
    writeToStream = dbWriteToStream

dbReadEvent ::
    DbStore
    -> StreamId
    -> EventNumber
    -> IO EventReadResult
dbReadEvent store streamId eventNumber =
    withPool (db_store store) $
    do res <- S.query (SingleEventQuery streamId eventNumber) qSingleEvent
       case res of
         Nothing -> pure ErrFailed
         Just v -> pure (ErrValue v)

dbReadStreamEvents ::
    DbStore
    -> StreamId -> EventNumber -> Int -> ReadDirection
    -> IO (V.Vector RecordedEvent)
dbReadStreamEvents store streamId eventNumber size readDir =
    withPool (db_store store) $
    S.query (EventStreamQuery streamId eventNumber size) (qEventStream readDir)

dbReadAllEvents ::
    DbStore
    -> GlobalPosition -> Int -> ReadDirection
    -> IO (V.Vector (GlobalPosition, RecordedEvent))
dbReadAllEvents store eventNumber size readDir =
    withPool (db_store store) $
    S.query (GlobalEventQuery eventNumber size) (qGlobalEvent readDir)

instance EventStoreReader IO DbStore where
    readEvent = dbReadEvent
    readStreamEvents = dbReadStreamEvents
    readAllEvents = dbReadAllEvents

-- | Poor mans subscriber implementation as 'hasql' does not support
-- LISTEN/NOTIFY. Could replace with REDIS?
dbSubscribeTo ::
    DbStore
    -> SubscriptionConfig
    -> ConduitM () RecordedEvent IO ()
dbSubscribeTo store config =
    do startNumber <-
           case startPosition of
             SspBeginning -> pure firstEventNumber
             SspFrom x -> pure x
             SspCurrent ->
                 liftIO $ withPool (db_store store) $
                 fromMaybe firstEventNumber <$> S.query streamId qStreamVersion
       innerLoop startNumber
    where
      innerLoop !pos =
          do batch <-
                 liftIO $
                 dbReadStreamEvents store streamId pos 1000 RdForward
             if V.null batch
                then do liftIO $ sleepTS (milliseconds 500)
                        innerLoop pos
                else do V.mapM_ yield batch
                        let lastEl = V.last batch
                        innerLoop (nextEventNumber (re_number lastEl))

      streamId = sc_stream config
      startPosition = sc_startPosition config

instance EventStoreSubscriber IO DbStore where
    subscribeTo = dbSubscribeTo

schemaV1 :: BS.ByteString
schemaV1 = [s|
CREATE TABLE events (
    id UUID NOT NULL,
    stream TEXT NOT NULL,
    version INT8 NOT NULL,
    position SERIAL8 NOT NULL,
    type TEXT NOT NULL,
    data JSONB NOT NULL,
    meta_data JSONB NOT NULL,
    created timestamptz NOT NULL DEFAULT NOW(),
    CONSTRAINT "event_id" PRIMARY KEY (id, stream),
    UNIQUE (stream, version),
    CONSTRAINT valid_version CHECK (version >= position)
);

CREATE INDEX event_stream ON events (stream);
CREATE INDEX event_stream_version ON events (stream, version);
CREATE INDEX event_position ON events (position);
|]
