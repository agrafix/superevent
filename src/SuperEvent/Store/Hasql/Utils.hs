module SuperEvent.Store.Hasql.Utils where

import qualified Hasql.Pool as P
import qualified Hasql.Session as S
import qualified Hasql.Transaction as Tx
import qualified Hasql.Transaction.Sessions as Tx

newtype Store
    = Store
    { unStore :: P.Pool }

dbTx :: Tx.IsolationLevel -> Tx.Mode -> Tx.Transaction a -> S.Session a
dbTx = Tx.transaction

withPool :: Store -> S.Session a -> IO a
withPool pss sess =
    do res <- P.use (unStore pss) sess
       case res of
         Left err -> fail (show err)
         Right ok -> pure ok
