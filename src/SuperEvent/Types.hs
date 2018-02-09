{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module SuperEvent.Types where

import Control.Monad.RWS.Strict
import Data.Hashable (Hashable)
import Data.Typeable
import Data.UUID (UUID)
import qualified Data.Sequence as Seq

import qualified SuperEvent.Persist.Types as DB

newtype Id p = Id { unId :: UUID }
    deriving (Show, Eq, Hashable)

data KeyedAction p a
    = KeyedAction
    { a_target :: Id p
    , a_action :: a
    }

newtype Event p = Event { unEvent :: p }

data Projection st ps
    = Projection
    { p_apply :: ApplyList st ps
    }

data ApplyList st ps where
    AlNil :: ApplyList st '[]
    (:&:) :: Typeable p => (p -> Maybe st -> Maybe st) -> ApplyList st ps -> ApplyList st (p : ps)

infixr 5 :&:

runApplyList ::
    forall i st ps. (Typeable i) => i -> Maybe st -> ApplyList st ps -> Maybe st
runApplyList i st applyList =
    case applyList of
      AlNil -> st
      (f :: p -> Maybe st -> Maybe st) :&: fs ->
          case cast i of
            Just v -> f v st
            Nothing -> runApplyList i st fs

type family IsMember p ps where
    IsMember p '[] = False
    IsMember p (p : q) = True
    IsMember p (r : q) = IsMember p q

data Pair a b
    = Pair
    { p_fst :: a
    , p_snd :: b
    } deriving (Show, Eq)

data AnyEvent
    = forall x. Typeable x => AnyEvent { unAnyEvent :: x }

newtype SnapT st (ps :: [*]) m a
    = SnapT { runSnapT :: RWST (ApplyList st ps) (Seq.Seq AnyEvent) (Maybe st) m a }
    deriving (Functor, Applicative, Monad, MonadTrans)

currentState :: Monad m => SnapT st ps m (Maybe st)
currentState = SnapT get

emitEvent :: (True ~ IsMember p ps, Typeable p, Monad m) => p -> SnapT st ps m ()
emitEvent x =
    SnapT $
    do tell (Seq.singleton (AnyEvent x))
       app <- ask
       modify' (flip (runApplyList x) app)

data EventStore m st
    = EventStore
    { es_lastSnapshot :: Maybe (Id st) -> m (Maybe st)
    , es_publishEvents :: Seq.Seq AnyEvent -> m ()
    }

withSnapshot ::
    forall m st ps x. Monad m
    => Maybe (Id st)
    -> Projection st ps
    -> EventStore m st
    -> SnapT st ps m x
    -> m (x, Maybe st)
withSnapshot ii prj es go =
    do lastSnapshot <- es_lastSnapshot es ii
       (r, st, evts) <- runRWST (runSnapT go) (p_apply prj) lastSnapshot
       es_publishEvents es evts
       pure (r, st)
