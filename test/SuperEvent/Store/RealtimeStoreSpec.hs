{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module SuperEvent.Store.RealtimeStoreSpec (spec) where

import SuperEvent.PubSub.InProcess
import SuperEvent.Store.Hasql
import SuperEvent.Store.RealtimeStore

import SuperEvent.Store.TestUtils

import Test.Hspec

withSetup :: (RealStore (InProcess t) DbStore -> IO a) -> IO a
withSetup go =
  withTempStore $ \dbStore ->
  do inProcess <- newInProcessPubSub
     go (newRealtimeStore inProcess dbStore)

spec :: Spec
spec =
    around withSetup $
    do streamingSpecHelper
