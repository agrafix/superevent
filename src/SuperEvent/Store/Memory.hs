{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE RankNTypes #-}
module SuperEvent.Store.Memory where

import SuperEvent.Store.Types

import Control.Concurrent.STM
import Data.Monoid
import Data.Time
import qualified Data.HashMap.Strict as HM
import qualified Data.Vector as V

data MemoryStore
    = MemoryStore
    { ms_events :: TVar (HM.HashMap StreamId (TVar (V.Vector RecordedEvent)))
    }

writeToMem ::
    MemoryStore -> StreamId -> ExpectedVersion -> V.Vector EventData -> IO WriteResult
writeToMem ms sid ev eventData =
    do now <- getCurrentTime
       run now
    where
      packEvent timestamp baseNumber idx evt =
          RecordedEvent
          { re_stream = sid
          , re_guid = ed_guid evt
          , re_number = incrementTimes idx baseNumber
          , re_type = ed_type evt
          , re_data = ed_data evt
          , re_metadata = ed_metadata evt
          , re_create = timestamp
          }
      run now =
          atomically $
          do streamVar <- HM.lookup sid <$> readTVar (ms_events ms)
             let go streamHolderVar =
                     do stream <- readTVar streamHolderVar
                        let nextVersion =
                                if V.null stream
                                then EventNumber 0
                                else nextEventNumber (re_number $ V.last stream)
                            recordedEvents =
                                V.imap (packEvent now nextVersion) eventData
                        writeTVar streamHolderVar (stream <> recordedEvents)
                        pure WrSuccess
             case (streamVar, ev) of
               (Nothing, EvEmptyStream) -> pure WrStreamDoesNotExist
               (Nothing, EvExact _) -> pure WrStreamDoesNotExist
               (Nothing, EvStreamExists) -> pure WrStreamDoesNotExist
               (Nothing, EvNoStream) ->
                   do streamHolder <- newTVar V.empty
                      go streamHolder
               (Nothing, EvAny) ->
                   do streamHolder <- newTVar V.empty
                      go streamHolder
               (Just s, EvAny) -> go s
               (Just s, EvStreamExists) -> go s
               (Just s, EvEmptyStream) ->
                   do isEmpty <- V.null <$> readTVar s
                      if isEmpty then go s else pure WrStreamNotEmpty
               (Just s, EvExact en) ->
                   do isEmpty <- V.null <$> readTVar s
                      if isEmpty
                          then pure WrStreamEmpty
                          else do lastElem <- V.last <$> readTVar s
                                  if en == re_number lastElem
                                      then go s
                                      else pure WrWrongExpectedVersion
               (Just _, EvNoStream) -> pure WrStreamExists

instance EventStoreWriter IO MemoryStore where
    writeToStream = writeToMem

readEvtMem :: MemoryStore -> StreamId -> EventNumber -> IO EventReadResult
readEvtMem ms sid en =
    atomically $
    do streamVar <- HM.lookup sid <$> readTVar (ms_events ms)
       case streamVar of
         Nothing -> pure ErrFailed
         Just svar ->
             do stream <- readTVar svar
                case V.find (\x -> re_number x == en) stream of
                  Just evt -> pure (ErrValue evt)
                  Nothing -> pure ErrFailed

instance EventStoreReader IO MemoryStore where
    readEvent = readEvtMem
