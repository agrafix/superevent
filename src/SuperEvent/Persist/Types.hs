{-# LANGUAGE StrictData #-}
module SuperEvent.Persist.Types where

import Data.UUID (UUID)
import Data.Word

newtype SequenceNumber
    = SequenceNumber { unSequenceNumber :: Word64 }
    deriving (Show, Eq)

data Event p
    = Event
    { e_uid :: UUID
    , e_seq :: SequenceNumber
    , e_payload :: p
    } deriving (Show, Eq)

data Snapshot st
    = Snapshot
    { s_lastSeq :: SequenceNumber
    , s_state :: st
    } deriving (Show, Eq)
