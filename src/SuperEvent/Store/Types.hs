{-# LANGUAGE StrictData #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module SuperEvent.Store.Types where

import Data.ByteString (ByteString)
import Data.Conduit
import Data.Hashable
import Data.Text (Text)
import Data.Time
import Data.UUID (UUID)
import Data.Vector (Vector)
import Data.Word

newtype EventType
    = EventType { unEventType :: Text }
    deriving (Show, Eq, Ord)

newtype EventNumber
    = EventNumber { unEventNumber :: Word64 }
    deriving (Show, Eq, Ord)

nextEventNumber :: EventNumber -> EventNumber
nextEventNumber (EventNumber x) = EventNumber (x + 1)

incrementTimes :: Int -> EventNumber -> EventNumber
incrementTimes n (EventNumber x) = EventNumber (x + fromIntegral n)

newtype GlobalPosition
    = GlobalPosition { unGlobalPosition :: Word64 }
    deriving (Show, Eq, Ord)

data EventData
    = EventData
    { ed_guid :: UUID
    , ed_type :: EventType
    , ed_data :: ByteString
    , ed_metadata :: ByteString
    } deriving (Show, Eq)

data ExpectedVersion
    = EvAny
    | EvNoStream
    | EvEmptyStream
    | EvStreamExists
    | EvExact EventNumber
    deriving (Show, Eq)

newtype StreamId
    = StreamId { unStreamId :: Text }
    deriving (Show, Eq, Ord, Hashable)

data WriteResult
    = WrSuccess
    | WrWrongExpectedVersion
    | WrStreamDoesNotExist
    | WrStreamExists
    | WrStreamNotEmpty
    | WrStreamEmpty
    deriving (Show, Eq)

class EventStoreWriter m es | es -> m where
    writeToStream :: es -> StreamId -> ExpectedVersion -> Vector EventData -> m WriteResult

data RecordedEvent
    = RecordedEvent
    { re_stream :: StreamId
    , re_guid :: UUID
    , re_number :: EventNumber
    , re_type :: EventType
    , re_data :: ByteString
    , re_metadata :: ByteString
    , re_create :: UTCTime
    } deriving (Show, Eq)

data ReadDirection
    = RdForward
    | RdBackward
    deriving (Show, Eq, Ord, Enum, Bounded)

data StreamEventsSlice
    = StreamEventsSlice
    { ses_stream :: StreamId
    , ses_direction :: ReadDirection
    , ses_fromEventNumber :: EventNumber
    , ses_toEventNumber :: EventNumber
    , ses_nextEventNumber :: EventNumber
    , ses_isEndOfStream :: Bool
    , ses_events :: Vector RecordedEvent
    } deriving (Show, Eq)

data AllEventsSlice
    = AllEventsSlice
    { aes_direction :: ReadDirection
    , aes_fromPosition :: GlobalPosition
    , aes_toPosition :: GlobalPosition
    , aes_nextPosition :: GlobalPosition
    , aes_isEndOfStream :: Bool
    , aes_events :: Vector RecordedEvent
    } deriving (Show, Eq)

data EventReadResult
    = ErrFailed
    | ErrValue RecordedEvent
    deriving (Show, Eq)

class EventStoreReader m es | m -> es where
    readEvent :: es -> StreamId -> EventNumber -> m EventReadResult
    readStreamEvents :: es -> StreamId -> EventNumber -> Int -> ReadDirection -> m StreamEventsSlice
    readAllEvents :: es -> GlobalPosition -> Int -> ReadDirection -> m AllEventsSlice

data SubscriptionStartPosition
    = SspBeginning
    | SspFrom EventNumber
    | SspCurrent
    deriving (Show, Eq)

data SubscriptionConfig
    = SubscriptionConfig
    { sc_startPosition :: SubscriptionStartPosition
    , sc_stream :: StreamId
    } deriving (Show, Eq)

class EventStoreSubscriber m es | m -> es where
    subscribeTo :: es -> SubscriptionConfig -> m (ConduitM () RecordedEvent m ())
