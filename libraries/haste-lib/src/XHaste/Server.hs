{-# LANGUAGE CPP #-}
-- | XHaste Server monad.
module XHaste.Server (
    Exportable,
    Server, Useless, Export (..), Done (..),
    AppCfg, defaultConfig, cfgURL, cfgPort,
    liftIO, export, mkUseful, runServer, getAppConfig, (<.>)
  ) where
import Control.Applicative
import Control.Monad (ap)
import Haste.Serialize
import Haste.JSON
import qualified Data.Map as M
import XHaste.Protocol
#ifndef __HASTE__
import Control.Concurrent (forkIO)
import Haste.Prim (toJSStr, fromJSStr)
import Network.WebSockets hiding (runServer)
import qualified Network.WebSockets as WS (runServer)
import qualified Data.ByteString.Char8 as BS
#endif

data AppCfg = AppCfg {
    cfgURL  :: String,
    cfgPort :: Int
  }

-- | Create a default configuration from an URL and a port number.
defaultConfig :: String -> Int -> AppCfg
defaultConfig = AppCfg

type Method = [JSON] -> IO JSON
type Exports = M.Map CallID Method
data Useless a = Useful (IO a) | Useless
newtype Done = Done (IO ())

data Export a = Export CallID [JSON]

-- | Apply an exported function to an argument.
--   TODO: look into making this Applicative.
(<.>) :: Serialize a => Export (a -> b) -> a -> Export b
(Export cid args) <.> arg = Export cid (toJSON arg:args)

-- | Make a Useless value useful by extracting it. Only possible server-side,
--   in the IO monad.
mkUseful :: Useless a -> IO a
mkUseful (Useful m) = m
mkUseful _          = error "Useless values are only useful server-side!"

-- | Server monad; allows for exporting functions, limited liftIO and
--   launching the client.
newtype Server a = Server {
    unS :: AppCfg -> CallID -> Exports -> (a, CallID, Exports)
  }

instance Monad Server where
  return x = Server $ \_ cid exports -> (x, cid, exports)
  (Server m) >>= f = Server $ \cfg cid exports ->
    case m cfg cid exports of
      (x, cid', exports') -> unS (f x) cfg cid' exports'

instance Functor Server where
  fmap f m = m >>= return . f

instance Applicative Server where
  (<*>) = ap
  pure  = return

-- | Lift an IO action into the Server monad, the result of which can only be
--   used server-side.
liftIO :: IO a -> Server (Useless a)
#ifdef __HASTE__
liftIO _ = return Useless
#else
liftIO = return . Useful
#endif

-- | An exportable function is of the type
--   (Serialize a, ..., Serialize result) => a -> ... -> IO result
class Exportable a where
  serializify :: a -> [JSON] -> IO JSON

instance Serialize a => Exportable (IO a) where
  serializify m _ = fmap toJSON m

instance (Serialize a, Exportable b) => Exportable (a -> b) where
  serializify f (x:xs) = serializify (f $! fromEither $ fromJSON x) xs
    where
      fromEither (Right x) = x
      fromEither (Left e)  = error $ "Unable to deserialize data: " ++ e

-- | Make a function available to the client as an API call.
export :: Exportable a => a -> Server (Export a)
export s = Server $ \_ cid exports ->
    (Export cid [], cid+1, M.insert cid (serializify s) exports)

-- | Returns the application configuration.
getAppConfig :: Server AppCfg
getAppConfig = Server $ \cfg cid exports -> (cfg, cid, exports)

-- | Run a server computation. runServer never returns before the program
--   terminates.
runServer :: AppCfg -> Server Done -> IO ()
runServer cfg (Server s) = do
#ifdef __HASTE__
    client
#else
    serverEventLoop cfg exports
#endif
  where
    (Done client, _, exports) = s cfg 0 M.empty

#ifndef __HASTE__
-- | Server's communication event loop. Handles dispatching API calls.
serverEventLoop :: AppCfg -> Exports -> IO ()
serverEventLoop cfg exports =
    WS.runServer "0.0.0.0" (cfgPort cfg) $ \pending -> do
      conn <- acceptRequest pending
      recvLoop conn
  where
    encode = BS.pack . fromJSStr . encodeJSON . toJSON
    recvLoop c = do
      msg <- receiveData c
      forkIO $ do
        -- Parse JSON
        case decodeJSON . toJSStr $ BS.unpack msg of
          Just json -> do
            -- Attempt to parse ServerCall from JSON and look up method
            case fromJSON json of
              Right (ServerCall nonce method args)
                | Just m <- M.lookup method exports -> do
                  result <- m args
                  sendTextData c . encode $ ServerReply {
                      srNonce = nonce,
                      srResult = result
                    }
              _ -> do
                error $ "Got bad method call: " ++ show json
          _ -> do
            error $ "Got bad JSON: " ++ BS.unpack msg
      recvLoop c
#endif
