module Test.Plutip.Internal.LocalCluster (
  startCluster,
  stopCluster,
  withPlutusInterface,
  ClusterStatus (
    ClusterStarting,
    ClusterStarted,
    ClusterClosing,
    ClusterClosed
  ),
) where

import Cardano.Api (ChainTip (ChainTip), SlotNo (SlotNo))
import Cardano.Api qualified as CAPI
import Cardano.BM.Configuration.Model qualified as CM
import Cardano.BM.Data.Severity qualified as Severity
import Cardano.BM.Data.Tracer (HasPrivacyAnnotation, HasSeverityAnnotation (getSeverityAnnotation))
import Cardano.CLI (LogOutput (LogToFile), withLoggingNamed)
import Cardano.Launcher.Node (nodeSocketFile)
import Cardano.Startup (installSignalHandlers, setDefaultFilePermissions, withUtf8Encoding)
import Cardano.Wallet.Logging (stdoutTextTracer, trMessageText)
import Cardano.Wallet.Shelley.Launch (TempDirLog, withSystemTempDir)
import Cardano.Wallet.Shelley.Launch.Cluster (ClusterLog, localClusterConfigFromEnv, testMinSeverityFromEnv, walletMinSeverityFromEnv, withCluster)
import Control.Concurrent.Async (async)
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader (ReaderT (runReaderT))
import Control.Retry (constantDelay, limitRetries, recoverAll)
import Control.Tracer (Tracer, contramap, traceWith)
import Data.Foldable (for_)
import Data.Kind (Type)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text (Text, pack)
import Data.Text.Class (ToText (toText))
import GHC.IO.Handle (Handle, hDuplicate, hDuplicateTo, hFlush)
import GHC.Stack.Types (HasCallStack)
import Paths_plutip (getDataFileName)
import Plutus.ChainIndex.App qualified as ChainIndex
import Plutus.ChainIndex.Config qualified as ChainIndex
import Plutus.ChainIndex.Logging (defaultConfig)
import Servant.Client (BaseUrl (BaseUrl), Scheme (Http), mkClientEnv, runClientM)
import System.Directory (canonicalizePath, copyFile, createDirectoryIfMissing, doesPathExist, findExecutable, removeDirectoryRecursive)
import System.Environment (setEnv)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, openFile, stdout)
import Test.Plutip.Config (
  PlutipConfig (
    chainIndexPort,
    clusterDataDir,
    clusterWorkingDir,
    relayNodeLogs
  ),
  WorkingDirectory (Fixed, Temporary),
 )
import Test.Plutip.Internal.BotPlutusInterface.Setup qualified as BotSetup
import Test.Plutip.Internal.Types (
  ClusterEnv (
    ClusterEnv,
    chainIndexUrl,
    networkId,
    plutipConf,
    runningNode,
    supportDir,
    tracer
  ),
  RunningNode (RunningNode),
 )
import Test.Plutip.Tools.CardanoApi qualified as Tools
import Text.Printf (printf)
import UnliftIO.Concurrent (forkFinally, myThreadId, throwTo)
import UnliftIO.Exception (bracket, catchIO, finally, throwString)
import UnliftIO.STM (TVar, atomically, newTVarIO, readTVar, retrySTM, writeTVar)

import Cardano.Wallet.Primitive.Types (
  NetworkParameters (NetworkParameters),
  SlotLength (SlotLength),
  SlottingParameters (SlottingParameters),
 )
import Data.Default (Default (def))
import Data.Function ((&))
import Data.Time (nominalDiffTimeToSeconds)
import Ledger (Slot (Slot))
import Ledger.TimeSlot (SlotConfig (scSlotLength))
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Plutus.ChainIndex (Tip (Tip))
import Plutus.ChainIndex.Client qualified as ChainIndexClient
import Plutus.ChainIndex.Config qualified as CIC
import PlutusPrelude ((.~), (^.))

-- | Starting a cluster with a setup action
-- We're heavily depending on cardano-wallet local cluster tooling, however they don't allow the
-- start and stop actions to be two separate processes, which is needed for tasty integration.
-- Instead of rewriting and maintaining these, I introduced a semaphore mechanism to keep the
-- cluster alive until the ClusterClosing action is called.
startCluster ::
  forall (a :: Type).
  PlutipConfig ->
  ReaderT ClusterEnv IO a ->
  IO (TVar (ClusterStatus a), a)
startCluster conf onClusterStart = do
  status <- newTVarIO ClusterStarting
  tid <- myThreadId
  void $
    forkFinally
      ( withPlutusInterface conf $ \clusterEnv -> do
          res <- runReaderT onClusterStart clusterEnv
          atomically $ writeTVar status (ClusterStarted res)
          atomically $ readTVar status >>= \case ClusterClosing -> pure (); _ -> retrySTM
      )
      ( \result -> do
          atomically (writeTVar status ClusterClosed)
          either (throwTo tid) pure result
      )

  setupRes <- atomically $ readTVar status >>= \case ClusterStarted v -> pure v; _ -> retrySTM
  pure (status, setupRes)

--- | Send a shutdown signal to the cluster and wait for it
stopCluster :: TVar (ClusterStatus a) -> IO ()
stopCluster status = do
  atomically $ writeTVar status ClusterClosing
  atomically $ readTVar status >>= \case ClusterClosed -> pure (); _ -> retrySTM

{- Examples:
   `plutus-apps` local cluster: https://github.com/input-output-hk/plutus-apps/blob/75a581c6eb98d36192ce3d3f86ea60a04bc4a52a/plutus-pab/src/Plutus/PAB/LocalCluster/Run.hs
   `cardano-wallet` local cluster: https://github.com/input-output-hk/cardano-wallet/blob/99b13e50f092ffca803fd38b9e435c24dae05c91/lib/shelley/exe/local-cluster.hs
-}
withPlutusInterface :: forall (a :: Type). PlutipConfig -> (ClusterEnv -> IO a) -> IO a
withPlutusInterface conf action = do
  -- current setup requires `cardano-node` and `cardano-cli` as external processes
  checkProcessesAvailable ["cardano-node", "cardano-cli"]

  withLocalClusterSetup conf $ \dir clusterLogs _walletLogs nodeConfigLogHdl -> do
    result <- withLoggingNamed "cluster" clusterLogs $ \(_, (_, trCluster)) -> do
      let tr' = contramap MsgCluster $ trMessageText trCluster
      clusterCfg <- localClusterConfigFromEnv
      withRedirectedStdoutHdl nodeConfigLogHdl $ \restoreStdout ->
        withCluster
          tr'
          dir
          clusterCfg
          mempty
          (\rn -> restoreStdout $ runActionWthSetup rn dir trCluster action)
    handleLogs dir conf
    return result
  where
    runActionWthSetup rn dir trCluster userActon = do
      let tracer' = trMessageText trCluster
      waitForRelayNode tracer' rn
      -- launch chain index in separate thread
      ciPort <- launchChainIndex conf rn dir
      traceWith tracer' (ChaiIndexStartedAt ciPort)
      let cEnv =
            ClusterEnv
              { runningNode = rn
              , chainIndexUrl = BaseUrl Http "localhost" ciPort mempty
              , networkId = CAPI.Mainnet
              , supportDir = dir
              , tracer = trCluster
              , plutipConf = conf
              }

      BotSetup.runSetup cEnv -- run preparations to use `bot-plutus-interface`
      userActon cEnv -- executing user action on cluster

-- Redirect stdout to a provided handle providing mask to temporarily revert back to initial stdout.
withRedirectedStdoutHdl :: Handle -> ((forall b. IO b -> IO b) -> IO a) -> IO a
withRedirectedStdoutHdl hdl action = do
  old_stdout <- hDuplicate stdout
  swapStdout hdl (action $ swapStdout old_stdout)
  where
    swapStdout tmphdl io = do
      hFlush stdout
      old <- hDuplicate stdout
      hDuplicateTo tmphdl stdout
      io `finally` hDuplicateTo old stdout

withDirectory ::
  forall (m :: Type -> Type) (a :: Type).
  MonadUnliftIO m =>
  PlutipConfig ->
  Tracer m TempDirLog ->
  String ->
  (FilePath -> m a) ->
  m a
withDirectory conf tr pathName action =
  case clusterWorkingDir conf of
    Temporary -> withSystemTempDir tr pathName action
    Fixed path shouldKeep -> do
      canonPath <- liftIO $ canonicalizePath path
      liftIO $ doesPathExist canonPath >>= (`when` removeDirectoryRecursive canonPath)
      liftIO $ createDirectoryIfMissing False canonPath
      res <- action canonPath
      unless shouldKeep $ liftIO $ removeDirectoryRecursive canonPath
      return res

-- Do all the program setup required for running the local cluster, create a
-- temporary directory, log output configurations, node_configuration.log handle, and pass these to the given
-- main action.
withLocalClusterSetup ::
  forall (a :: Type).
  PlutipConfig ->
  (FilePath -> [LogOutput] -> [LogOutput] -> Handle -> IO a) ->
  IO a
withLocalClusterSetup conf action = do
  setClusterDataDir

  -- Handle SIGTERM properly
  installSignalHandlers (putStrLn "Terminated")

  -- Ensure key files have correct permissions for cardano-cli
  setDefaultFilePermissions

  -- Set UTF-8, regardless of user locale
  withUtf8Encoding $
    -- This temporary directory will contain logs, and all other data
    -- produced by the local test cluster.
    withDirectory conf stdoutTextTracer "test-cluster" $ \dir -> do
      let logOutputs name minSev =
            -- cluster logs to file only
            [LogToFile (dir </> name) (min minSev Severity.Info)]

      clusterLogs <- logOutputs "cluster.log" <$> testMinSeverityFromEnv
      walletLogs <- logOutputs "wallet.log" <$> walletMinSeverityFromEnv

      bracket
        (openFile (dir </> "node_configuration.log") WriteMode)
        hClose
        (action dir clusterLogs walletLogs)
  where
    setClusterDataDir = do
      defaultClusterDataDir <- getDataFileName "cluster-data"
      setEnv "SHELLEY_TEST_DATA" $
        fromMaybe defaultClusterDataDir (clusterDataDir conf)

checkProcessesAvailable :: [String] -> IO ()
checkProcessesAvailable requiredProcesses = do
  results <- mapM findExecutable requiredProcesses
  unless (isJust `all` results) $
    die $
      "This processes should be available in the environment:\n "
        <> show requiredProcesses
        <> "\n but only these were found:\n "
        <> show (catMaybes results)

waitForRelayNode :: Tracer IO TestsLog -> RunningNode -> IO ()
waitForRelayNode trCluster rn =
  liftIO $ do
    recoverAll policy wait
  where
    policy = constantDelay 500000 <> limitRetries 50
    getTip = trace >> Tools.queryTip rn
    trace = traceWith trCluster WaitingRelayNode
    wait _ = do
      tip <- getTip
      case tip of
        ChainTip (SlotNo _) _ _ -> pure ()
        a -> throwString $ "Timeout waiting for node to start. Last 'tip' response:\n" <> show a
      pure ()

-- | Launch the chain index in a separate thread.
launchChainIndex :: PlutipConfig -> RunningNode -> FilePath -> IO Int
launchChainIndex conf (RunningNode sp _block0 (netParams, _vData) _) dir = do
  let (NetworkParameters _ (SlottingParameters (SlotLength slotLen) _ _ _) _) = netParams

  config <- defaultConfig
  CM.setMinSeverity config Severity.Notice
  let dbPath = dir </> "chain-index.db"
      port = maybe (CIC.cicPort ChainIndex.defaultConfig) fromEnum (chainIndexPort conf)
      chainIndexConfig =
        CIC.defaultConfig
          & CIC.socketPath .~ nodeSocketFile sp
          & CIC.dbPath .~ dbPath
          & CIC.networkId .~ CAPI.Mainnet
          & CIC.port .~ maybe (CIC.cicPort ChainIndex.defaultConfig) fromEnum (chainIndexPort conf)
          & CIC.slotConfig .~ (def {scSlotLength = toMilliseconds slotLen})

  void $ async $ void $ ChainIndex.runMainWithLog (const $ return ()) config chainIndexConfig
  waitForChainIndex port
  return $ chainIndexConfig ^. CIC.port
  where
    toMilliseconds = floor . (1e3 *) . nominalDiffTimeToSeconds

    waitForChainIndex port = do
      let policy = constantDelay 1_000_000 <> limitRetries 60
      recoverAll policy $ \_ -> do
        tip <- queryTipWithChIndex port
        case tip of
          Right (Tip (Slot _) _ _) -> pure ()
          a ->
            throwString $
              "Timeout waiting for chain-index to start indexing. Last response:\n"
                <> either show show a

    queryTipWithChIndex port = do
      manager' <- newManager defaultManagerSettings
      runClientM ChainIndexClient.getTip $ mkClientEnv manager' (BaseUrl Http "localhost" port "")

handleLogs :: HasCallStack => FilePath -> PlutipConfig -> IO ()
handleLogs clusterDir conf =
  copyRelayLog `catchIO` (error . printf "Failed to save relay node log: %s" . show)
  where
    copyRelayLog = for_ (relayNodeLogs conf) $ \toFile ->
      copyFile
        {- We're heavily depending on cardano-wallet local cluster tooling atm.
          Path partially hardcoded in Cardano.Wallet.Shelley.Launch.Cluster by
         `withRelayNode` ("node" subdir) and `genConfig` (file name)
        -}
        (clusterDir </> "pool-1" </> "cardano-node.log")
        toFile

data ClusterStatus (a :: Type)
  = ClusterStarting
  | ClusterStarted a
  | ClusterClosing
  | ClusterClosed

-- Logging

data TestsLog
  = MsgBaseUrl Text Text Text -- wallet url, ekg url, prometheus url
  | MsgSettingUpFaucet
  | MsgCluster ClusterLog
  | WaitingRelayNode
  | ChaiIndexStartedAt Int
  deriving stock (Show)

instance ToText TestsLog where
  toText = \case
    MsgBaseUrl walletUrl ekgUrl prometheusUrl ->
      mconcat
        [ "Wallet url: "
        , walletUrl
        , ", EKG url: "
        , ekgUrl
        , ", Prometheus url:"
        , prometheusUrl
        ]
    MsgSettingUpFaucet -> "Setting up faucet..."
    MsgCluster msg -> toText msg
    WaitingRelayNode -> "Waiting for relay node up and running"
    ChaiIndexStartedAt ciPort -> "Chain-index started at port " <> pack (show ciPort)

instance HasPrivacyAnnotation TestsLog

instance HasSeverityAnnotation TestsLog where
  getSeverityAnnotation = \case
    MsgSettingUpFaucet -> Severity.Notice
    MsgBaseUrl {} -> Severity.Notice
    MsgCluster msg -> getSeverityAnnotation msg
    WaitingRelayNode -> Severity.Notice
    ChaiIndexStartedAt {} -> Severity.Notice
