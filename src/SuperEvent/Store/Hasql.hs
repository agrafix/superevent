{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module SuperEvent.Store.Hasql
    ( newPgSqlStore, destroyPgSqlStore
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
import Data.String.QQ
import Data.Time.TimeSpan
import Hasql.Statement
import System.Environment
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
import qualified Hasql.Transaction.Sessions as Tx

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
                       Just err -> liftIO $ fail (show err)
                       Nothing -> loop more
           in loop (M.MigrationInitialization : migs)
       pure $ DbStore store

destroyPgSqlStore :: DbStore -> IO ()
destroyPgSqlStore (DbStore (Store pool)) =
  P.release pool

withC :: BSC.ByteString -> (C.Connection -> IO c) -> IO c
withC str =
  let getConn =
        do c <- C.acquire str
           assertRight c
      removeConn = C.release
  in bracket getConn removeConn


assertRight :: (MonadFail f, Show a1) => Either a1 a2 -> f a2
assertRight y =
  case y of
    Right x -> pure x
    Left errMsg -> fail (show errMsg)

-- | Temporary postgres store for tests
withTempStore :: (DbStore -> IO a) -> IO a
withTempStore go =
    do baseConnStr <- BSC.pack . fromMaybe "host=localhost" <$> lookupEnv "PG_STRING"
       bracket (allocDb baseConnStr) (removeDb baseConnStr) $ \dbname ->
         bracket (newPgSqlStore $ baseConnStr <> " dbname=" <> dbname) destroyPgSqlStore go
    where
        removeDb baseConnStr dbname =
            do putStrLn ("TempDB " <> show dbname <> " is pruned")
               withC baseConnStr $ \globalConn ->
                 do runRes2 <-
                      flip S.run globalConn $ S.sql $ "DROP DATABASE IF EXISTS " <> dbname
                    assertRight runRes2
        allocDb baseConnStr =
            do dbnameSuffix <-
                   BSC.pack . take 10 . randomRs ('a', 'z') <$>
                   newStdGen
               let dbname = "eventstore_temp_" <> dbnameSuffix
               withC baseConnStr $ \globalConn ->
                 do runRes <-
                      flip S.run globalConn $
                      do S.sql $ "DROP DATABASE IF EXISTS " <> dbname
                         S.sql $ "CREATE DATABASE " <> dbname
                    assertRight runRes
               withC (baseConnStr <> " dbname=" <> dbname) $ \localConn ->
                 do runRes' <-
                      flip S.run localConn $
                      S.sql "CREATE EXTENSION hstore"
                    assertRight runRes'
               putStrLn ("TempDB " <> show dbname <> " is setup")
               pure dbname

encStreamId :: E.Params StreamId
encStreamId = contramap unStreamId (E.param (E.nonNullable E.text))

encEventType :: E.Params EventType
encEventType = contramap unEventType (E.param (E.nonNullable E.text))

encEventNumber :: E.Params EventNumber
encEventNumber = contramap unEventNumber (E.param (E.nonNullable E.int8))

encGlobalPosition :: E.Params GlobalPosition
encGlobalPosition = contramap unGlobalPosition (E.param (E.nonNullable E.int8))

decEventNumber :: D.Row EventNumber
decEventNumber = EventNumber <$> D.column (D.nonNullable D.int8)

decRecordedEvent :: D.Row RecordedEvent
decRecordedEvent =
    RecordedEvent
    <$> (StreamId <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.uuid)
    <*> decEventNumber
    <*> (EventType <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nonNullable D.jsonb)
    <*> D.column (D.nonNullable D.timestamptz)

qStreamVersion :: Statement StreamId (Maybe EventNumber)
qStreamVersion =
    Statement sql encoder decoder True
    where
      sql =
          "SELECT MAX(version) FROM events WHERE stream = $1"
      encoder =
          encStreamId
      decoder =
          fmap EventNumber <$> D.singleRow (D.column (D.nullable D.int8))

data WriteEvent
    = WriteEvent
    { we_stream :: StreamId
    , we_number :: EventNumber
    , we_data :: EventData
    }

qWriteEvent :: Statement WriteEvent RecordedEvent
qWriteEvent =
    Statement sql encoder decoder True
    where
      sql =
          "INSERT INTO events "
          <> "(id, stream, version, type, data, meta_data)"
          <> " VALUES "
          <> "($1, $2, $3, $4, $5, $6)"
          <> " RETURNING stream, id, version, type, data, meta_data, created"
      encoder =
          contramap (ed_guid . we_data) (E.param (E.nonNullable E.uuid))
          <> contramap we_stream encStreamId
          <> contramap we_number encEventNumber
          <> contramap (ed_type . we_data) encEventType
          <> contramap (ed_data . we_data) (E.param (E.nonNullable E.jsonb))
          <> contramap (ed_metadata . we_data) (E.param (E.nonNullable E.jsonb))
      decoder =
          D.singleRow decRecordedEvent

data SingleEventQuery
    = SingleEventQuery
    { seq_stream :: StreamId
    , seq_number :: EventNumber
    }

qSingleEvent :: Statement SingleEventQuery (Maybe RecordedEvent)
qSingleEvent =
    Statement sql encoder decoder True
    where
      sql =
          "SELECT "
          <> "stream, id, version, type, data, meta_data, created "
          <> "FROM "
          <> "events "
          <> "WHERE stream = $1 AND version = $2 LIMIT 1"
      encoder =
          contramap seq_stream encStreamId
          <> contramap seq_number encEventNumber
      decoder =
          D.rowMaybe decRecordedEvent

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
    contramap esq_stream encStreamId
    <> contramap esq_number encEventNumber
    <> contramap (fromIntegral . esq_limit) (E.param (E.nonNullable E.int8))

qEventStream :: ReadDirection -> Statement EventStreamQuery (V.Vector RecordedEvent)
qEventStream readDir =
    Statement (sqlEventStream readDir) encEventStreamQuery decoder True
    where
      decoder =
          D.rowVector decRecordedEvent

data GlobalEventQuery
    = GlobalEventQuery
    { geq_position :: GlobalPosition
    , geq_limit :: Int
    }

qGlobalEvent ::
    ReadDirection
    -> Statement GlobalEventQuery (V.Vector (GlobalPosition, RecordedEvent))
qGlobalEvent readDir =
    Statement sql encoder decoder True
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
          contramap geq_position encGlobalPosition
          <> contramap (fromIntegral . geq_limit) (E.param (E.nonNullable E.int8))
      decoder =
          D.rowVector $
          (,)
          <$> (GlobalPosition <$> D.column (D.nonNullable D.int8))
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
    do myVersion <- Tx.statement streamId qStreamVersion
       case ev of
         EvAny -> continueIf True myVersion
         EvNoStream -> continueIf (isNothing myVersion) myVersion
         EvStreamExists -> continueIf (isJust myVersion) myVersion
         EvExact expected -> continueIf (myVersion == Just expected) myVersion
    where
        continue vers =
            flip V.imapM events $ \idx event ->
            do let number = incrementTimes idx $ nextEventNumber $ fromMaybe firstEventNumber vers
                   we =
                       WriteEvent
                       { we_stream = streamId
                       , we_number = number
                       , we_data = event
                       }
               Tx.statement we qWriteEvent
        continueIf cond vers =
            if cond
            then do written <- continue vers
                    pure $ WrSuccess written
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
    do res <- S.statement (SingleEventQuery streamId eventNumber) qSingleEvent
       case res of
         Nothing -> pure ErrFailed
         Just v -> pure (ErrValue v)

dbReadStreamEvents ::
    DbStore
    -> StreamId -> EventNumber -> Int -> ReadDirection
    -> IO (V.Vector RecordedEvent)
dbReadStreamEvents store streamId eventNumber size readDir =
    withPool (db_store store) $
    S.statement (EventStreamQuery streamId eventNumber size) (qEventStream readDir)

dbReadAllEvents ::
    DbStore
    -> GlobalPosition -> Int -> ReadDirection
    -> IO (V.Vector (GlobalPosition, RecordedEvent))
dbReadAllEvents store eventNumber size readDir =
    withPool (db_store store) $
    S.statement (GlobalEventQuery eventNumber size) (qGlobalEvent readDir)

instance EventStoreReader IO DbStore where
    readEvent = dbReadEvent
    readStreamEvents = dbReadStreamEvents
    readAllEvents = dbReadAllEvents
    readStreamVersion = dbReadStreamVersion

dbReadStreamVersion :: DbStore -> StreamId -> IO EventNumber
dbReadStreamVersion store streamId =
  withPool (db_store store) $
  fromMaybe firstEventNumber <$> S.statement streamId qStreamVersion

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
             SspCurrent -> liftIO (readStreamVersion store $ sc_stream config)
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
    CONSTRAINT valid_version CHECK (position >= version)
);

CREATE INDEX event_stream ON events (stream);
CREATE INDEX event_stream_version ON events (stream, version);
CREATE INDEX event_position ON events (position);
|]
