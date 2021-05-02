{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
module SuperEvent.PubSub.Types where

import Conduit

class PubSub m ps t | ps -> m, ps -> t where
  publish :: ps -> t -> m ()
  subscribe :: ps -> ConduitM () t m ()
