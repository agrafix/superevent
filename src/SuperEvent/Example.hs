{-# LANGUAGE DataKinds #-}
{-# LANGUAGE StrictData #-}
module SuperEvent.Example where

import Data.Maybe
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T

import SuperEvent.Types

type CustomerId = Id Customer
data Customer
    = Customer
    { c_id :: CustomerId
    , c_email :: T.Text
    , c_active :: Bool
    } deriving (Show, Eq)

reduceCustomer :: CustomerAction -> Maybe Customer -> Maybe Customer
reduceCustomer (KeyedAction _ ca) st =
    case st of
      Nothing ->
          case ca of
            CaCreate x -> Just x
            _ -> Nothing
      Just cust ->
          Just $
          case ca of
            CaUpdateEmail x -> cust { c_email = x }
            CaSetActive -> cust { c_active = True }
            _ -> cust

customerProj :: Projection Customer '[CustomerAction]
customerProj =
    Projection
    { p_apply =
         reduceCustomer :&: AlNil
    }

newtype CustomerMap
    = CustomerMap { unCustomerMap :: HM.HashMap CustomerId Customer }
    deriving (Show, Eq)

reduceCustomerMap :: CustomerAction -> Maybe CustomerMap -> Maybe CustomerMap
reduceCustomerMap caf@(KeyedAction tgt _) mcm =
    Just . CustomerMap $
    HM.alter (reduceCustomer caf) tgt cm
    where
      cm = fromMaybe mempty $ unCustomerMap <$> mcm

reduceGlobalAction :: GlobalAction -> Maybe CustomerMap -> Maybe CustomerMap
reduceGlobalAction ga mcm =
    Just . CustomerMap $
    case ga of
      GaDeactivateAll -> fmap (\c -> c { c_active = False }) cm
    where
      cm = fromMaybe mempty $ unCustomerMap <$> mcm

customerMapProj :: Projection CustomerMap '[CustomerAction, GlobalAction]
customerMapProj =
    Projection
    { p_apply =
         reduceCustomerMap :&: reduceGlobalAction :&: AlNil
    }

type CustomerAction = KeyedAction Customer CustomerActionPayload
data CustomerActionPayload
    = CaCreate Customer
    | CaUpdateEmail T.Text
    | CaSetActive
    deriving (Show, Eq)

data GlobalAction
    = GaDeactivateAll
    deriving (Show, Eq)
