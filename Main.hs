-----------------------------------------------------------------------------
-- |
-- Module      :  Main
-- Copyright   :  (c) David Himmelstrup 2005
-- License     :  BSD-like
--
-- Maintainer  :  lemmih@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Entry point to the default cabal-install front-end.
-----------------------------------------------------------------------------

module Main (main) where

import Distribution.Client.Setup
         ( GlobalFlags(..), globalCommand, globalRepos
         , ConfigFlags(..)
         , ConfigExFlags(..), defaultConfigExFlags, configureExCommand
         , InstallFlags(..), defaultInstallFlags
         , installCommand, upgradeCommand
         , FetchFlags(..), fetchCommand
         , checkCommand
         , updateCommand
         , ListFlags(..), listCommand
         , InfoFlags(..), infoCommand
         , UploadFlags(..), uploadCommand
         , ReportFlags(..), reportCommand
         , InitFlags(initVerbosity), initCommand
         , SDistFlags(..), SDistExFlags(..), sdistCommand
         , reportCommand
         , unpackCommand, UnpackFlags(..) )
import Distribution.Simple.Setup
         ( BuildFlags(..), buildCommand
         , HaddockFlags(..), haddockCommand
         , HscolourFlags(..), hscolourCommand
         , CopyFlags(..), copyCommand
         , RegisterFlags(..), registerCommand
         , CleanFlags(..), cleanCommand
         , TestFlags(..), testCommand
         , BenchmarkFlags(..), benchmarkCommand
         , Flag(..), fromFlag, fromFlagOrDefault, flagToMaybe )

import Distribution.Client.SetupWrapper
         ( setupWrapper, SetupScriptOptions(..), defaultSetupScriptOptions )
import Distribution.Client.Config
         ( SavedConfig(..), loadConfig, defaultConfigFile )
import Distribution.Client.Targets
         ( readUserTargets )

import Distribution.Client.List             (list, info)
import Distribution.Client.Install          (install, upgrade)
import Distribution.Client.Configure        (configure)
import Distribution.Client.Update           (update)
import Distribution.Client.Fetch            (fetch)
import Distribution.Client.Check as Check   (check)
--import Distribution.Client.Clean            (clean)
import Distribution.Client.Upload as Upload (upload, check, report)
import Distribution.Client.SrcDist          (sdist)
import Distribution.Client.Unpack           (unpack)
import Distribution.Client.Init             (initCabal)
import qualified Distribution.Client.Win32SelfUpgrade as Win32SelfUpgrade

import Distribution.Simple.Compiler
         ( Compiler, PackageDB(..), PackageDBStack )
import Distribution.Simple.Program
         ( ProgramConfiguration, defaultProgramConfiguration )
import Distribution.Simple.Command
import Distribution.Simple.Configure (configCompilerAux)
import Distribution.Simple.Utils
         ( cabalVersion, die, topHandler, intercalate )
import Distribution.Text
         ( display )
import Distribution.Verbosity as Verbosity
       ( Verbosity, normal, intToVerbosity, lessVerbose )
import qualified Paths_cabal_install_bundle (version)

import System.Environment       (getArgs, getProgName)
import System.Exit              (exitFailure)
import System.FilePath          (splitExtension, takeExtension)
import System.Directory         (doesFileExist)
import Data.List                (intersperse)
import Data.Maybe               (fromMaybe)
import Data.Monoid              (Monoid(..))
import Control.Monad            (unless)

-- | Entry point
--
main :: IO ()
main = getArgs >>= mainWorker

mainWorker :: [String] -> IO ()
mainWorker ("win32selfupgrade":args) = win32SelfUpgradeAction args
mainWorker args = topHandler $
  case commandsRun globalCommand commands args of
    CommandHelp   help                 -> printGlobalHelp help
    CommandList   opts                 -> printOptionsList opts
    CommandErrors errs                 -> printErrors errs
    CommandReadyToGo (globalflags, commandParse)  ->
      case commandParse of
        _ | fromFlag (globalVersion globalflags)        -> printVersion
          | fromFlag (globalNumericVersion globalflags) -> printNumericVersion
        CommandHelp     help           -> printCommandHelp help
        CommandList     opts           -> printOptionsList opts
        CommandErrors   errs           -> printErrors errs
        CommandReadyToGo action        -> action globalflags

  where
    printCommandHelp help = do
      pname <- getProgName
      putStr (help pname)
    printGlobalHelp help = do
      pname <- getProgName
      configFile <- defaultConfigFile
      putStr (help pname)
      putStr $ "\nYou can edit the cabal configuration file to set defaults:\n"
            ++ "  " ++ configFile ++ "\n"
    printOptionsList = putStr . unlines
    printErrors errs = die $ concat (intersperse "\n" errs)
    printNumericVersion = putStrLn $ display Paths_cabal_install_bundle.version
    printVersion        = putStrLn $ "cabal-install version "
                                  ++ display Paths_cabal_install_bundle.version
                                  ++ "\nusing version "
                                  ++ display cabalVersion
                                  ++ " of the Cabal library "

    commands =
      [installCommand         `commandAddAction` installAction
      ,updateCommand          `commandAddAction` updateAction
      ,listCommand            `commandAddAction` listAction
      ,infoCommand            `commandAddAction` infoAction
      ,fetchCommand           `commandAddAction` fetchAction
      ,unpackCommand          `commandAddAction` unpackAction
      ,checkCommand           `commandAddAction` checkAction
      ,sdistCommand           `commandAddAction` sdistAction
      ,uploadCommand          `commandAddAction` uploadAction
      ,reportCommand          `commandAddAction` reportAction
      ,initCommand            `commandAddAction` initAction
      ,configureExCommand     `commandAddAction` configureAction
      ,wrapperAction (buildCommand defaultProgramConfiguration)
                     buildVerbosity    buildDistPref
      ,wrapperAction copyCommand
                     copyVerbosity     copyDistPref
      ,wrapperAction haddockCommand
                     haddockVerbosity  haddockDistPref
      ,wrapperAction cleanCommand
                     cleanVerbosity    cleanDistPref
      ,wrapperAction hscolourCommand
                     hscolourVerbosity hscolourDistPref
      ,wrapperAction registerCommand
                     regVerbosity      regDistPref
      ,wrapperAction testCommand
                     testVerbosity     testDistPref
      ,wrapperAction benchmarkCommand
                     benchmarkVerbosity     benchmarkDistPref
      ,upgradeCommand         `commandAddAction` upgradeAction
      ]

wrapperAction :: Monoid flags
              => CommandUI flags
              -> (flags -> Flag Verbosity)
              -> (flags -> Flag String)
              -> Command (GlobalFlags -> IO ())
wrapperAction command verbosityFlag distPrefFlag =
  commandAddAction command
    { commandDefaultFlags = mempty } $ \flags extraArgs _globalFlags -> do
    let verbosity = fromFlagOrDefault normal (verbosityFlag flags)
        setupScriptOptions = defaultSetupScriptOptions {
          useDistPref = fromFlagOrDefault
                          (useDistPref defaultSetupScriptOptions)
                          (distPrefFlag flags)
        }
    setupWrapper verbosity setupScriptOptions Nothing
                 command (const flags) extraArgs

configureAction :: (ConfigFlags, ConfigExFlags)
                -> [String] -> GlobalFlags -> IO ()
configureAction (configFlags, configExFlags) extraArgs globalFlags = do
  let verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
  config <- loadConfig verbosity (globalConfigFile globalFlags)
                                 (configUserInstall configFlags)
  let configFlags'   = savedConfigureFlags   config `mappend` configFlags
      configExFlags' = savedConfigureExFlags config `mappend` configExFlags
      globalFlags'   = savedGlobalFlags      config `mappend` globalFlags
  (comp, conf) <- configCompilerAux configFlags'
  configure verbosity
            (configPackageDB' configFlags') (globalRepos globalFlags')
            comp conf configFlags' configExFlags' extraArgs

installAction :: (ConfigFlags, ConfigExFlags, InstallFlags, HaddockFlags)
              -> [String] -> GlobalFlags -> IO ()
installAction (configFlags, _, installFlags, _) _ _globalFlags
  | fromFlagOrDefault False (installOnly installFlags)
  = let verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
    in setupWrapper verbosity defaultSetupScriptOptions Nothing
         installCommand (const mempty) []

installAction (configFlags, configExFlags, installFlags, haddockFlags)
              extraArgs globalFlags = do
  let verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
  targets <- readUserTargets verbosity extraArgs
  config <- loadConfig verbosity (globalConfigFile globalFlags)
                                 (configUserInstall configFlags)
  let configFlags'   = savedConfigureFlags   config `mappend` configFlags
      configExFlags' = defaultConfigExFlags         `mappend`
                       savedConfigureExFlags config `mappend` configExFlags
      installFlags'  = defaultInstallFlags          `mappend`
                       savedInstallFlags     config `mappend` installFlags
      globalFlags'   = savedGlobalFlags      config `mappend` globalFlags
  (comp, conf) <- configCompilerAux' configFlags'
  install verbosity
          (configPackageDB' configFlags') (globalRepos globalFlags')
          comp conf globalFlags' configFlags' configExFlags' installFlags' haddockFlags
          targets

listAction :: ListFlags -> [String] -> GlobalFlags -> IO ()
listAction listFlags extraArgs globalFlags = do
  let verbosity = fromFlag (listVerbosity listFlags)
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let configFlags  = savedConfigureFlags config
      globalFlags' = savedGlobalFlags    config `mappend` globalFlags
  (comp, conf) <- configCompilerAux' configFlags
  list verbosity
       (configPackageDB' configFlags)
       (globalRepos globalFlags')
       comp
       conf
       listFlags
       extraArgs

infoAction :: InfoFlags -> [String] -> GlobalFlags -> IO ()
infoAction infoFlags extraArgs globalFlags = do
  let verbosity = fromFlag (infoVerbosity infoFlags)
  targets <- readUserTargets verbosity extraArgs
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let configFlags  = savedConfigureFlags config
      globalFlags' = savedGlobalFlags    config `mappend` globalFlags
  (comp, conf) <- configCompilerAux configFlags
  info verbosity
       (configPackageDB' configFlags)
       (globalRepos globalFlags')
       comp
       conf
       globalFlags'
       infoFlags
       targets

updateAction :: Flag Verbosity -> [String] -> GlobalFlags -> IO ()
updateAction verbosityFlag extraArgs globalFlags = do
  unless (null extraArgs) $ do
    die $ "'update' doesn't take any extra arguments: " ++ unwords extraArgs
  let verbosity = fromFlag verbosityFlag
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let globalFlags' = savedGlobalFlags config `mappend` globalFlags
  update verbosity (globalRepos globalFlags')

upgradeAction :: (ConfigFlags, ConfigExFlags, InstallFlags, HaddockFlags)
              -> [String] -> GlobalFlags -> IO ()
upgradeAction (configFlags, configExFlags, installFlags, haddockFlags)
              extraArgs globalFlags = do
  let verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
  targets <- readUserTargets verbosity extraArgs
  config <- loadConfig verbosity (globalConfigFile globalFlags)
                                 (configUserInstall configFlags)
  let configFlags'   = savedConfigureFlags   config `mappend` configFlags
      configExFlags' = savedConfigureExFlags config `mappend` configExFlags
      installFlags'  = defaultInstallFlags          `mappend`
                       savedInstallFlags     config `mappend` installFlags
      globalFlags'   = savedGlobalFlags      config `mappend` globalFlags
  (comp, conf) <- configCompilerAux' configFlags'
  upgrade verbosity
          (configPackageDB' configFlags') (globalRepos globalFlags')
          comp conf globalFlags' configFlags' configExFlags' installFlags' haddockFlags
          targets

fetchAction :: FetchFlags -> [String] -> GlobalFlags -> IO ()
fetchAction fetchFlags extraArgs globalFlags = do
  let verbosity = fromFlag (fetchVerbosity fetchFlags)
  targets <- readUserTargets verbosity extraArgs
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let configFlags  = savedConfigureFlags config
      globalFlags' = savedGlobalFlags config `mappend` globalFlags
  (comp, conf) <- configCompilerAux' configFlags
  fetch verbosity
        (configPackageDB' configFlags) (globalRepos globalFlags')
        comp conf globalFlags' fetchFlags
        targets

uploadAction :: UploadFlags -> [String] -> GlobalFlags -> IO ()
uploadAction uploadFlags extraArgs globalFlags = do
  let verbosity = fromFlag (uploadVerbosity uploadFlags)
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let uploadFlags' = savedUploadFlags config `mappend` uploadFlags
      globalFlags' = savedGlobalFlags config `mappend` globalFlags
      tarfiles     = extraArgs
  checkTarFiles extraArgs
  if fromFlag (uploadCheck uploadFlags')
    then Upload.check  verbosity tarfiles
    else upload verbosity
                (globalRepos globalFlags')
                (flagToMaybe $ uploadUsername uploadFlags')
                (flagToMaybe $ uploadPassword uploadFlags')
                tarfiles
  where
    checkTarFiles tarfiles
      | null tarfiles
      = die "the 'upload' command expects one or more .tar.gz packages."
      | not (null otherFiles)
      = die $ "the 'upload' command expects only .tar.gz packages: "
           ++ intercalate ", " otherFiles
      | otherwise = sequence_
                      [ do exists <- doesFileExist tarfile
                           unless exists $ die $ "file not found: " ++ tarfile
                      | tarfile <- tarfiles ]

      where otherFiles = filter (not . isTarGzFile) tarfiles
            isTarGzFile file = case splitExtension file of
              (file', ".gz") -> takeExtension file' == ".tar"
              _              -> False

checkAction :: Flag Verbosity -> [String] -> GlobalFlags -> IO ()
checkAction verbosityFlag extraArgs _globalFlags = do
  unless (null extraArgs) $ do
    die $ "'check' doesn't take any extra arguments: " ++ unwords extraArgs
  allOk <- Check.check (fromFlag verbosityFlag)
  unless allOk exitFailure


sdistAction :: (SDistFlags, SDistExFlags) -> [String] -> GlobalFlags -> IO ()
sdistAction (sdistFlags, sdistExFlags) extraArgs _globalFlags = do
  unless (null extraArgs) $ do
    die $ "'sdist' doesn't take any extra arguments: " ++ unwords extraArgs
  sdist sdistFlags sdistExFlags

reportAction :: ReportFlags -> [String] -> GlobalFlags -> IO ()
reportAction reportFlags extraArgs globalFlags = do
  unless (null extraArgs) $ do
    die $ "'report' doesn't take any extra arguments: " ++ unwords extraArgs

  let verbosity = fromFlag (reportVerbosity reportFlags)
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let globalFlags' = savedGlobalFlags config `mappend` globalFlags
      reportFlags' = savedReportFlags config `mappend` reportFlags

  Upload.report verbosity (globalRepos globalFlags')
    (flagToMaybe $ reportUsername reportFlags')
    (flagToMaybe $ reportPassword reportFlags')

unpackAction :: UnpackFlags -> [String] -> GlobalFlags -> IO ()
unpackAction unpackFlags extraArgs globalFlags = do
  let verbosity = fromFlag (unpackVerbosity unpackFlags)
  targets <- readUserTargets verbosity extraArgs
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let globalFlags' = savedGlobalFlags config `mappend` globalFlags
  unpack verbosity
         (globalRepos (savedGlobalFlags config))
         globalFlags'
         unpackFlags
         targets

initAction :: InitFlags -> [String] -> GlobalFlags -> IO ()
initAction initFlags _extraArgs globalFlags = do
  let verbosity = fromFlag (initVerbosity initFlags)
  config <- loadConfig verbosity (globalConfigFile globalFlags) mempty
  let configFlags  = savedConfigureFlags config
  (comp, conf) <- configCompilerAux' configFlags
  initCabal verbosity
            (configPackageDB' configFlags)
            comp
            conf
            initFlags

-- | See 'Distribution.Client.Install.withWin32SelfUpgrade' for details.
--
win32SelfUpgradeAction :: [String] -> IO ()
win32SelfUpgradeAction (pid:path:rest) =
  Win32SelfUpgrade.deleteOldExeFile verbosity (read pid) path
  where
    verbosity = case rest of
      (['-','-','v','e','r','b','o','s','e','=',n]:_) | n `elem` ['0'..'9']
         -> fromMaybe Verbosity.normal (Verbosity.intToVerbosity (read [n]))
      _  ->           Verbosity.normal
win32SelfUpgradeAction _ = return ()

--
-- Utils (transitionary)
--

-- | Currently the user interface specifies the package dbs to use with just a
-- single valued option, a 'PackageDB'. However internally we represent the
-- stack of 'PackageDB's explictly as a list. This function converts encodes
-- the package db stack implicit in a single packagedb.
--
-- TODO: sort this out, make it consistent with the command line UI
implicitPackageDbStack :: Bool -> Maybe PackageDB -> PackageDBStack
implicitPackageDbStack userInstall packageDbFlag
  | userInstall = GlobalPackageDB : UserPackageDB : extra
  | otherwise   = GlobalPackageDB : extra
  where
    extra = case packageDbFlag of
      Just (SpecificPackageDB db) -> [SpecificPackageDB db]
      _                           -> []

configPackageDB' :: ConfigFlags -> PackageDBStack
configPackageDB' cfg =
  implicitPackageDbStack userInstall (flagToMaybe (configPackageDB cfg))
  where
    userInstall = fromFlagOrDefault True (configUserInstall cfg)

configCompilerAux' :: ConfigFlags
                   -> IO (Compiler, ProgramConfiguration)
configCompilerAux' configFlags =
  configCompilerAux configFlags
    --FIXME: make configCompilerAux use a sensible verbosity
    { configVerbosity = fmap lessVerbose (configVerbosity configFlags) }
