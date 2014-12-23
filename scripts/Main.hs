{-# LANGUAGE OverloadedStrings #-}

import Prelude as P

import Network.TCP.Proxy.Server
import Data.Binary as Bin

import Data.ByteString as BS
import Data.ByteString.Lazy as BSL
import Data.ByteString.Char8 as BSC
import Data.ByteString.Lazy.Char8 as BSLC
import Data.String
import Data.Text as Txt
import Control.Exception

import System.IO as Sys
import System.Random

import Network.TCP.Proxy.Client
import Network.TCP.Proxy.Socks4 as Socks4
import Network.TCP.Proxy.Server as Proxy
import Data.Map.Strict as Map
import Control.Concurrent.STM.TChan
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM
import Control.Monad
import System.Log.Logger

import Data.Conduit.Binary
import Data.Conduit.List as CL
import Data.Conduit as DC

import Network.BitTorrent.Shepherd as Tracker
import Network.BitTorrent.ClientControl
import Network.BitTorrent.ClientControl.UTorrent
import Network.BitSmuggler.BitTorrentSimulator as Sim
import Network.BitSmuggler.Utils
import Data.Serialize as DS
import Control.Concurrent
import Control.Concurrent.Async
import qualified Filesystem.Path as FS

import Shelly as Sh
import Control.Monad.Trans.Resource

{-

project created to run experiments 
-}

main = do 
  P.putStrLn "running bit-smuggler script"

testHash = Bin.decode $ BSL.replicate 20 0
testDataFile = "/home/dan/repos/bitSmuggler/bit-smuggler/testdata/trafficSample00"

localhost = "127.0.0.1"

initiatorConf = Sim.Config {resourceMap = Map.empty, rpcPort = 2015, peerPort = 3001}

testConnData = ConnectionData {connTorrent = Torrent  testHash "this is the filename"
                              , dataFile = testDataFile
                              , peerAddr = (localhost, peerPort initiatorConf)
                              , proxyAddr = (localhost, 1080)}


receiverConf = Sim.Config {
                      resourceMap = Map.fromList [(Left testDataFile, testConnData)]
                      , rpcPort = 2016, peerPort = 3002}

initiatorPeer = do
  Sim.runClient initiatorConf

receiverPeer = do
  Sim.runClient receiverConf

initCaptureHook incFile outFile a1 a2 = do
  incHook <- captureHook incFile
  outHook <- captureHook outFile
  return $ DataHooks incHook outHook 

captureHook :: Sys.FilePath -> IO (BS.ByteString -> IO BS.ByteString)
captureHook file = do
  rgen <- newStdGen
  let r = (fst $ random rgen) :: Int
  tchan <- newTChanIO 
  debugM logger $ "setting up capture for " P.++ file
  forkIO $ do
    withFile (file P.++ (show r)) WriteMode $ \fileH -> do
      sourceTChan tchan =$ (CL.map (DS.encode . NetworkChunk))  $$ sinkHandle fileH
  debugM logger $ "done setting up capture"
 
  return $ \bs -> atomically $ writeTChan tchan bs >> return bs
 

trafficCapture = do
--  updateGlobalLogger logger  (setLevel DEBUG)
  Proxy.run $ Proxy.Config { proxyPort = 1080
            , initHook =  initCaptureHook "incomingCapture" "outgoingCapture"
            , handshake = Socks4.serverProtocol
       }

printChunk bs = debugM logger (show $ BS.length bs) >> return bs

trafficProxy = do
  Proxy.run $ Proxy.Config { proxyPort = 1080
            , initHook = (\_ _ -> return $ DataHooks printChunk printChunk) 
            , handshake = Socks4.serverProtocol
       }

uTorrentStateFiles :: [String]
uTorrentStateFiles = ["dht.dat", "resume.dat", "rss.dat", "settings.dat", "dht_feed.dat"]

cleanUTorrentState torrentPath other = do
  forM (P.map (torrentPath </> )
    $ (P.map fromString (uTorrentStateFiles P.++ (P.map (P.++ ".old") uTorrentStateFiles))
       P.++ other))
    $ \file -> do
      r <- try' $ shelly $  rm file
--      debugM logger $ "clean result" P.++ (show r)
      return ()
  return ()

webUIPortSeed = 9000
webUIPortPeer = 8000
trackerPort = 6666
utorrentDefCreds = ("admin", "")

milli = 10 ^ 6

testRun = do
  updateGlobalLogger logger (setLevel DEBUG)
  peerSeedTalk "/home/dan/tools/bittorrent/utorrent-server-alpha-v3_3_0/"
                       "/home/dan/tools/bittorrent/utorrent-server-alpha-v3_3_1/"
                       "/home/dan/testdata/sample.txt"
                       "/home/dan/testdata/sample100.torrent"

-- script - 2 utorrent clients talk to get a file 
peerSeedTalk :: Sh.FilePath -> Sh.FilePath -> Sh.FilePath -> Sh.FilePath -> IO ()
peerSeedTalk seedPath peerPath dataFilePath tFilePath = runResourceT $ do
  let oldData = [FS.filename dataFilePath]
  liftIO $ do
    debugM logger $ show oldData
    cleanUTorrentState seedPath oldData
    cleanUTorrentState peerPath oldData
    shelly $ cp dataFilePath seedPath --place file to be seeded

  trackEvents <- liftIO $ newTChanIO 
  tracker <- allocAsync $ async $ runTracker
                        $ Tracker.Config {listenPort = 6666, events = Just trackEvents}

  liftIO $ waitFor (== Booting) trackEvents
  liftIO $ debugM logger "tracker is booting"

--  liftIO $ threadDelay $ 2 * milli

  liftIO $ debugM logger "launching seeder..."
  seeder <- allocAsync $ runUTClient seedPath
  liftIO $ threadDelay $ 1 * milli
  liftIO $ debugM logger "launched seeder"
  seedConn <- liftIO $ makeUTorrentConn localhost webUIPortSeed  utorrentDefCreds
  liftIO $ addTorrentFile seedConn $ pathToString tFilePath

  liftIO $ waitFor (\(AnnounceEv a) -> True) trackEvents
  liftIO $ debugM logger "got announce"
  -- sleep for a while until that is announced; ideally i should put

  proxy <- allocAsync $ async $ trafficProxy
  liftIO $ threadDelay $ 1 * milli
 
  peer <- allocAsync $ runUTClient peerPath
  liftIO $ threadDelay $ 1 * milli
  liftIO $ debugM logger "launched peer. telling it to connect"

  peerConn <- liftIO $ makeUTorrentConn localhost webUIPortPeer utorrentDefCreds

  liftIO $ setSettings peerConn [UPnP False, NATPMP False, RandomizePort False, DHTForNewTorrents False, UTP True, LocalPeerDiscovery False, ProxySetType Socks4, ProxyIP "127.0.0.1", ProxyPort 1080, ProxyP2P True]

  liftIO $ addTorrentFile peerConn $ pathToString tFilePath
 
  liftIO $ P.getLine

  -- close procs
  release $ fst peer 
  release $ fst proxy
  release $ fst seeder
  release $ fst tracker

  return ()

-- this is so stupid I don't even..
pathToString ::Sh.FilePath -> String
pathToString fp = read . P.drop (P.length $ ("FilePath " :: String)) .  show $ fp 

-- careful with utserver failure - utserver fails "silently"
-- returning 0 even when it fails to read params
runUTClient path = async $ shelly $ chdir path
                                  $ Sh.run (path </> ("utserver" :: Sh.FilePath)) []


-- treats an async as a resource that needs to be canceled on close
allocAsync runAsync = allocate runAsync (liftIO . cancel) 

waitFor cond chan = do
  n <- atomically $ readTChan chan
  if (cond n) then return n
  else waitFor cond chan

-- proc
testProc = do
  ncop <-  async $ do
    r <- shelly $ Sh.run (fromString "nc") $ P.map Txt.pack ["-l", "1234"]
    P.putStrLn $ show r
  P.getLine
  cancel ncop
  P.getLine

-- play to showcase the client functionality
runTorrentClientScript = do
  updateGlobalLogger logger (setLevel DEBUG)
  conn <- makeUTorrentConn "127.0.0.1" 9000  ("admin", "")
  debugM logger "made first connection"

{-
  r3 <- setSettings conn [UPnP False, NATPMP False, RandomizePort False, DHTForNewTorrents False, UTP True, LocalPeerDiscovery False, ProxySetType Socks4, ProxyIP "127.0.0.1", ProxyPort 1080, ProxyP2P True]
  debugM logger $ show $  r3
  torrentFile <-return "/home/dan/testdata/sample100.torrent"
 -- addMagnetLink conn archMagnet
  addTorrentFile conn torrentFile
-}
  r <- listTorrents conn
  debugM logger $ "list of torrents  is  " ++  (show r)
  return ()

archMagnet = "magnet:?xt=urn:btih:67f4bcecdca3e046c4dc759c9e5bfb2c48d277b0&dn=archlinux-2014.03.01-dual.iso&tr=udp://tracker.archlinux.org:6969&tr=http://tracker.archlinux.org:6969/announce"
