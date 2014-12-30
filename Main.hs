{-# LANGUAGE OverloadedStrings #-}

import           Control.Applicative
import           Control.Concurrent             (threadDelay)
import           Control.Concurrent.MVar
import           Control.Concurrent.STM
import           Control.Exception              (SomeException)
import           Control.Exception.Enclosed
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.ByteString (ByteString)
import           Data.Default                   (def)
import           Data.Function                  (on)
import           Data.Monoid
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Lazy                 as TL
import           Data.UUID
import           Network.Wai.Handler.Warp
import qualified Network.Wai.Handler.WebSockets as WaiWS
import qualified Network.Wai.Middleware.Static  as WaiMS
import qualified Network.WebSockets             as WS
import qualified Network.Wreq                   as W
import           SlaveThread
import qualified System.UUID.V4                 as UUID
import           Web.Scotty

data WsClient = WsClient { wcUid  :: UUID
                         , wcConn :: WS.Connection }

instance Show WsClient where
    show wsc = "WsClient " ++ show (wcUid wsc)

instance Eq WsClient where
    (==) = (==) `on` wcUid

info :: String -> IO ()
info m = putStrLn ("[INFO] " ++ m)

err :: String -> IO ()
err m = putStrLn ("[ERROR] " ++ m)

main :: IO ()
main = do
    info "hello!"
    mq <- atomically $ newTQueue
    void $ fork $ startWebServer mq
    void $ fork $ startBroadcaster
    forever $ threadDelay $ 1000000 * 1

startWebServer :: TQueue Text -> IO ()
startWebServer broadcastMessageQueue = do
    wsState <- newMVar ([]::[WsClient])
    let opts = setSettings def
    scottyOpts opts (app wsState broadcastMessageQueue)
  where
    app wsState mq = do
        middleware $ staticResourcesApp
        middleware $ WaiWS.websocketsOr WS.defaultConnectionOptions (wsApp wsState mq)
        post "/api/broadcast/:word" $ do
            word <- param "word"
            liftIO $ info $ "Asked to broadcast word " ++ T.unpack word
            liftIO $ broadcast wsState (word::Text)
            text ("ok! I will broadcast word " <> TL.pack (show word))
    staticResourcesApp =
        WaiMS.staticPolicy (WaiMS.addBase "resources")
    wsApp wsState mq pending = do
         broadcastQueue wsState mq
         client <- WsClient <$> UUID.uuid <*> WS.acceptRequest pending
         info ("Accepted pending websocket request. New client: "
               ++ show client)
         curr <- readMVar wsState
         info ("Current client list: " ++ show curr)
         modifyMVar_ wsState $ \clients ->
             if clientPresent client clients
             then do
                 info ("Client " ++ show client
                       ++ " is already present. Not adding to list")
                 return clients
             else return (client:clients)
         talk wsState client
    clientPresent client clients = client `elem` clients
    removeClient wsState client = modifyMVar_ wsState $ \clients -> do
        return (filter (/= client) clients)
    talk wsState client = handleAny (catchDisconnect wsState client)
                          $ forever $ do
        msg <- WS.receiveData (wcConn client) :: IO Text
        info ("Received websocket data from client " ++ show client
              ++ ". Data: " ++ show msg)
        when (msg == "ping")
             (WS.sendTextData (wcConn client) ("pong"::Text))
    catchDisconnect wsState client e = do
        info ("Will disconnect (" ++ show e ++ "). Client: "
              ++ show client)
        removeClient wsState client
    setSettings opts = let s = (setPort 3333
                                . setOnException onE
                                . settings) opts
                       in opts { settings = s }
    onE _ e = err ("Some unexpected error: " ++ show e)
    broadcastQueue wsState mq = void $ fork $ forever $ catchReportRestart onBkE $ do
        info "Inside broadcastQueue"
        m <- atomically $ readTQueue mq
        info $ "Queue message received: " ++ show m
        broadcast wsState m
    onBkE e = err ("Error while broadcasting: " ++ show e)
    broadcast wsState m = do
        clients <- readMVar wsState
        forM_ clients $ \client ->
            catchAny (void $ fork $ do
                          info ("Broadcasting to client " ++ show client)
                          WS.sendTextData (wcConn client) m)
                     (\e -> reportErr e >> removeClient wsState client)
      where
        reportErr e = err ("Error while trying to send text data: "
                           ++ show e ++ ". Removing client.")

startBroadcaster :: IO ()
startBroadcaster = do
    let wreq = W.defaults
    forever $ do
        threadDelay (1000000 * 6)
        info "POST /api/broadcast/haskell"
        W.postWith wreq "http://localhost:3333/api/broadcast/haskell" (""::ByteString)

catchReportRestart :: (SomeException -> IO ()) -> IO () -> IO ()
catchReportRestart reporter f = catchAny f reportCrashAndRestart
  where
    reportCrashAndRestart e = reporter e >> catchReportRestart reporter f
