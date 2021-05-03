{-# LANGUAGE StrictData #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module SuperEvent.Store.Types where

import Data.Aeson
import Data.Conduit
import Data.Hashable
import Data.Int
import Data.Text (Text)
import Data.Time
import Data.UUID (UUID)
import Data.Vector (Vector)

newtype EventType
    = EventType { unEventType :: Text }
    deriving (Show, Eq, Ord)

newtype EventNumber
    = EventNumber { unEventNumber :: Int64 }
    deriving (Show, Eq, Ord)

firstEventNumber ::EventNumber
firstEventNumber = EventNumber 0

nextEventNumber :: EventNumber -> EventNumber
nextEventNumber (EventNumber x) = EventNumber (x + 1)

incrementTimes :: Int -> EventNumber -> EventNumber
incrementTimes n (EventNumber x) = EventNumber (x + fromIntegral n)

newtype GlobalPosition
    = GlobalPosition { unGlobalPosition :: Int64 }
    deriving (Show, Eq, Ord)

data EventData
    = EventData
    { ed_guid :: UUID
    , ed_type :: EventType
    , ed_data :: Value
    , ed_metadata :: Value
    } deriving (Show, Eq)

data ExpectedVersion
    = EvAny
    | EvNoStream
    | EvStreamExists
    | EvExact EventNumber
    deriving (Show, Eq)

newtype StreamId
    = StreamId { unStreamId :: Text }
    deriving (Show, Eq, Ord, Hashable)

data WriteResult
    = WrSuccess (Vector RecordedEvent)
    | WrWrongExpectedVersion
    deriving (Show, Eq)

class EventStoreWriter m es | es -> m where
    writeToStream ::
        es -> StreamId -> ExpectedVersion -> Vector EventData -> m WriteResult

data RecordedEvent
    = RecordedEvent
    { re_stream :: StreamId
    , re_guid :: UUID
    , re_globalPosition :: GlobalPosition
    , re_number :: EventNumber
    , re_type :: EventType
    , re_data :: Value
    , re_metadata :: Value
    , re_created :: UTCTime
    } deriving (Show, Eq)

data ReadDirection
    = RdForward
    | RdBackward
    deriving (Show, Eq, Ord, Enum, Bounded)

data EventReadResult
    = ErrFailed
    | ErrValue RecordedEvent
    deriving (Show, Eq)

class EventStoreReader m es | es -> m where
    readEvent :: es -> StreamId -> EventNumber -> m EventReadResult
    readLastEvent :: es -> StreamId -> m EventReadResult
    readStreamVersion :: es -> StreamId -> m EventNumber
    readStreamEvents ::
        es -> StreamId -> EventNumber -> Int -> ReadDirection
        -> m (Vector RecordedEvent)

    readGlobalPosition :: es -> m GlobalPosition
    readAllEvents :: es -> GlobalPosition -> Int -> ReadDirection -> m (Vector RecordedEvent)

data SubscriptionStartPosition t
    = SspBeginning
    | SspFrom t
    | SspCurrent
    deriving (Show, Eq)

data StreamSubscription
    = StreamSubscription
    { ss_startPosition :: SubscriptionStartPosition EventNumber
    , ss_stream :: StreamId
    } deriving (Show, Eq)

data GlobalSubscription
    = GlobalSubscription
    { gs_startPosition :: SubscriptionStartPosition GlobalPosition
    } deriving (Show, Eq)

data Subscription
  = SStream StreamSubscription
  | SGlobal GlobalSubscription

class EventStoreSubscriber m es | es -> m where
    subscribeTo :: es -> Subscription -> ConduitM () RecordedEvent m ()
