{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module SuperEvent.PubSub.InProcess
  ( newInProcessPubSub, InProcess )
where

import SuperEvent.PubSub.Types

import Conduit
import Control.Concurrent.STM

data InProcess t
  = InProcess
  { ipBroadcastChan :: TChan t
  }

instance PubSub IO (InProcess t) t where
  publish = publishImpl
  subscribe = subscribeImpl

newInProcessPubSub :: IO (InProcess t)
newInProcessPubSub =
  InProcess <$> newBroadcastTChanIO

publishImpl :: InProcess t -> t -> IO ()
publishImpl ip t =
  atomically $ writeTChan (ipBroadcastChan ip) t

subscribeImpl :: InProcess t -> ConduitM () t IO ()
subscribeImpl ip =
  do chan <- liftIO $ atomically (dupTChan $ ipBroadcastChan ip)
     let loop =
           do val <- liftIO $ atomically (readTChan chan)
              yield val
              loop
     loop
