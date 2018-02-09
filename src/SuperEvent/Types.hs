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

import Data.Hashable (Hashable)
import Data.Typeable
import Data.UUID (UUID)

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

class Projection p where
    type State p :: *
