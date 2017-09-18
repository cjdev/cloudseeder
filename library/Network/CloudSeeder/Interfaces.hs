{-# OPTIONS_GHC -fno-warn-overlapping-patterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Network.CloudSeeder.Interfaces
  ( MonadCLI(..)
  , getArgs'
  , getOptions'
  , whenEnv
  , getEnvArg

  , MonadCloud(..)
  , computeChangeset'
  , getStackInfo'
  , getStackOutputs'
  , runChangeSet'
  , encrypt'
  , upload'
  , generateSecret'
  , generateEncryptUploadSecret
  , CharType(..)
  , CloudError(..)
  , HasCloudError(..)
  , AsCloudError(..)

  , MonadEnvironment(..)
  , StackName(..)

  , MonadFileSystem(..)
  , FileSystemError(..)
  , readFile'
  , HasFileSystemError(..)
  , AsFileSystemError(..)
  ) where

import Prelude hiding (readFile)

import Control.Concurrent (threadDelay)
import Control.DeepSeq (NFData)
import Control.Exception (throw)
import Control.Lens (Traversal', (.~), (^.), (^?), (?~), _Just, only, to)
import Control.Lens.TH (makeClassy, makeClassyPrisms)
import Control.Monad (void, when)
import Control.Monad.Base (MonadBase, liftBase)
import Control.Monad.Catch (MonadCatch, MonadThrow)
import Control.Monad.Error.Lens (throwing)
import Control.Monad.Except (ExceptT, MonadError)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Logger (LoggingT)
import Control.Monad.Reader (MonadReader, ReaderT, ask)
import Control.Monad.State (StateT)
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.AWS (runResourceT, runAWST, send)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Writer (WriterT)
import Crypto.Random
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Function ((&))
import Data.Semigroup ((<>))
import Data.String (IsString)
import Data.UUID (toText)
import Data.UUID.V4 (nextRandom)
import GHC.Generics (Generic)
import GHC.IO.Exception (IOException(..), IOErrorType(..))
import Network.AWS (AsError(..), ErrorMessage(..), HasEnv(..), serviceMessage)
import Options.Applicative (execParser)

import qualified Control.Exception.Lens as IO
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Conversions as T
import qualified Network.AWS.CloudFormation as CF
import qualified Network.AWS.Data.Body as AWS
import qualified Network.AWS.KMS as KMS
import qualified Network.AWS.S3 as S3
import qualified System.Environment as IO

import Network.CloudSeeder.CommandLine
import Network.CloudSeeder.Types

newtype StackName = StackName T.Text
  deriving (Eq, Show, Generic, IsString)
instance NFData StackName

--------------------------------------------------------------------------------
-- | A class of monads that can access command-line arguments.

class Monad m => MonadCLI m where
  -- | Returns positional arguments provided to the program while ignoring flags -- separate from getOptions to avoid cyclical dependencies.
  getArgs :: m Command
  default getArgs :: (MonadTrans t, MonadCLI m', m ~ t m') => m Command
  getArgs = lift getArgs

  -- | Returns flags provided to the program while ignoring positional arguments -- separate from getArgs to avoid cyclical dependencies.
  getOptions :: S.Set ParameterSpec -> m (M.Map T.Text ParameterValue)
  default getOptions :: (MonadTrans t, MonadCLI m', m ~ t m') => S.Set ParameterSpec -> m (M.Map T.Text ParameterValue)
  getOptions = lift . getOptions

getArgs' :: MonadBase IO m => m Command
getArgs' = liftBase $ execParser parseArguments

getOptions' :: MonadBase IO m => S.Set ParameterSpec -> m (M.Map T.Text ParameterValue)
getOptions' = liftBase . execParser . parseOptions

instance MonadCLI m => MonadCLI (ExceptT e m)
instance MonadCLI m => MonadCLI (LoggingT m)
instance MonadCLI m => MonadCLI (ReaderT r m)
instance MonadCLI m => MonadCLI (StateT s m)
instance (Monoid s, MonadCLI m) => MonadCLI (WriterT s m)

-- DSL helpers

getEnvArg :: MonadCLI m => m T.Text
getEnvArg = do
  (ProvisionStack _ env) <- getArgs
  return env

whenEnv :: MonadCLI m => T.Text -> m () -> m ()
whenEnv env x = do
  envToProvision <- getEnvArg
  when (envToProvision == env) x

--------------------------------------------------------------------------------
newtype FileSystemError
  = FileNotFound T.Text
  deriving (Eq, Show)

makeClassy ''FileSystemError
makeClassyPrisms ''FileSystemError

-- | A class of monads that can interact with the filesystem.
class (AsFileSystemError e, MonadError e m) => MonadFileSystem e m | m -> e where
  -- | Reads a file at the given path and returns its contents. If the file does
  -- not exist, is not accessible, or is improperly encoded, this method throws
  -- an exception.
  readFile :: T.Text -> m T.Text

  default readFile :: (MonadTrans t, MonadFileSystem e m', m ~ t m') => T.Text -> m T.Text
  readFile = lift . readFile

readFile' :: (AsFileSystemError e, MonadError e m, MonadBase IO m) => T.Text -> m T.Text
readFile' p = do
    let _IOException_NoSuchThing = IO._IOException . to isNoSuchThingIOError
    x <- liftBase $ IO.catching_ _IOException_NoSuchThing (Just <$> T.readFile (T.unpack p)) (return Nothing)
    maybe (throwing _FileNotFound p) return x
  where
    isNoSuchThingIOError IOError { ioe_type = NoSuchThing } = True
    isNoSuchThingIOError _                                  = False

instance MonadFileSystem e m => MonadFileSystem e (ExceptT e m)
instance MonadFileSystem e m => MonadFileSystem e (LoggingT m)
instance MonadFileSystem e m => MonadFileSystem e (ReaderT r m)
instance MonadFileSystem e m => MonadFileSystem e (StateT s m)
instance (MonadFileSystem e m, Monoid w) => MonadFileSystem e (WriterT w m)

--------------------------------------------------------------------------------
-- | A class of monads that can interact with cloud deployments.
data CharType
  = Alpha
  | Digit
  | AlphaNum
  | Base64
  deriving (Eq, Show)

data CloudError
  = CloudErrorInternal T.Text
  | CloudErrorUser T.Text
  deriving (Eq, Show)

makeClassy ''CloudError
makeClassyPrisms ''CloudError

class (AsCloudError e, MonadError e m) => MonadCloud e m | m -> e where
  computeChangeset :: StackName -> ProvisionType -> T.Text -> M.Map T.Text ParameterValue -> M.Map T.Text T.Text -> m T.Text
  getStackInfo :: StackName -> m (Maybe Stack)
  getStackOutputs :: StackName -> m (Maybe (M.Map T.Text T.Text))
  runChangeSet :: T.Text -> m ()
  encrypt :: T.Text -> T.Text -> m B.ByteString
  upload :: T.Text -> T.Text -> B.ByteString -> m ()
  generateSecret :: Int -> CharType -> m T.Text

  default computeChangeset :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> ProvisionType -> T.Text -> M.Map T.Text ParameterValue -> M.Map T.Text T.Text -> m T.Text
  computeChangeset a b c d e = lift $ computeChangeset a b c d e

  default getStackInfo :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> m (Maybe Stack)
  getStackInfo = lift . getStackInfo

  default getStackOutputs :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> m (Maybe (M.Map T.Text T.Text))
  getStackOutputs = lift . getStackOutputs

  default runChangeSet :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> m ()
  runChangeSet = lift . runChangeSet

  default encrypt :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> T.Text -> m B.ByteString
  encrypt a b = lift $ encrypt a b

  default upload :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> T.Text -> B.ByteString -> m ()
  upload a b c = lift $ upload a b c

  default generateSecret :: (MonadTrans t, MonadCloud e m', m ~ t m') => Int -> CharType -> m T.Text
  generateSecret a b = lift $ generateSecret a b

type MonadCloudIO r e m = (HasEnv r, MonadReader r m, MonadIO m, MonadBaseControl IO m, MonadCatch m, MonadThrow m, AsCloudError e, MonadError e m)

_StackDoesNotExistError :: AsError a => StackName -> Traversal' a ()
_StackDoesNotExistError (StackName stackName) = _ServiceError.serviceMessage._Just.only (ErrorMessage msg)
  where msg = "Stack with id " <> stackName <> " does not exist"

computeChangeset' :: MonadCloudIO r e m => StackName -> ProvisionType -> T.Text -> M.Map T.Text ParameterValue -> M.Map T.Text T.Text -> m T.Text
computeChangeset' (StackName stackName) provisionType templateBody params tags = do
    uuid <- liftBase nextRandom
    let changeSetName = "cs-" <> toText uuid -- change set name must begin with a letter

    env <- ask
    runResourceT . runAWST env $ do
      let request = CF.createChangeSet stackName changeSetName
            & CF.ccsParameters .~ map awsParam (M.toList params)
            & CF.ccsTemplateBody ?~ templateBody
            & CF.ccsCapabilities .~ [CF.CapabilityIAM]
            & CF.ccsTags .~ map awsTag (M.toList tags)
            & CF.ccsChangeSetType ?~ provisionTypeToChangeSetType provisionType
      response <- send request
      maybe (throwing _CloudErrorInternal "createChangeSet did not return a valid response.")
            return (response ^. CF.ccsrsId)
  where
    awsParam (key, Value val) = CF.parameter
      & CF.pParameterKey ?~ key
      & CF.pParameterValue ?~ val
    awsParam (key, UsePreviousValue) = CF.parameter
      & CF.pParameterKey ?~ key
      & CF.pUsePreviousValue ?~ True
    awsTag (key, val) = CF.tag
      & CF.tagKey ?~ key
      & CF.tagValue ?~ val
    provisionTypeToChangeSetType CreateStack = CF.Create
    provisionTypeToChangeSetType (UpdateStack _) = CF.Update

getStackInfo' :: MonadCloudIO r e m => StackName -> m (Maybe Stack)
getStackInfo' (StackName stackName) = do
  env <- ask
  let request = CF.describeStacks & CF.dStackName ?~ stackName
  runResourceT . runAWST env $ do
    response <- IO.trying_ (_StackDoesNotExistError (StackName stackName)) $ send request
    case response ^? _Just.CF.dsrsStacks of
      Nothing -> return Nothing
      Just [s] -> do
        let awsParams = s ^. CF.sParameters
        params <- S.fromList <$> mapM awsParameterKey awsParams
        let stack = Stack params
        return $ Just stack
      Just _ -> throwing _CloudErrorInternal "describeStacks returned more than one stack"
  where
    awsParameterKey x = case x ^. CF.pParameterKey of
      (Just k) -> return k
      Nothing -> throwing _CloudErrorInternal "stack parameter key was missing"

getStackOutputs' :: MonadCloudIO r e m => StackName -> m (Maybe (M.Map T.Text T.Text))
getStackOutputs' (StackName stackName) = do
    env <- ask
    let request = CF.describeStacks & CF.dStackName ?~ stackName
    runResourceT . runAWST env $ do
      response <- IO.trying_ (_StackDoesNotExistError (StackName stackName)) $ send request
      case response ^? _Just.CF.dsrsStacks of
        Nothing -> return Nothing
        Just [stack] -> Just . M.fromList <$> mapM outputToTuple (stack ^. CF.sOutputs)
        Just _ -> throwing _CloudErrorInternal "describeStacks returned more than one stack"
  where
    outputToTuple x = case (x ^. CF.oOutputKey, x ^. CF.oOutputValue) of
      (Just k, Just v) -> return (k, v)
      (Nothing, _) -> throwing _CloudErrorInternal "stack output key was missing"
      (_, Nothing) -> throwing _CloudErrorInternal "stack output value was missing"

runChangeSet' :: MonadCloudIO r e m => T.Text -> m ()
runChangeSet' csId = do
    env <- ask
    waitUntilChangeSetReady env
    runResourceT . runAWST env $
      void $ send (CF.executeChangeSet csId)
  where
    waitUntilChangeSetReady env = do
      liftBase $ threadDelay 1000000
      cs <- runResourceT . runAWST env $
        send (CF.describeChangeSet csId)
      execStatus <- case cs ^. CF.drsExecutionStatus of
        Just x -> return x
        Nothing -> throwing _CloudErrorInternal "change set lacks execution status"
      case cs ^. CF.drsStatus of
        CF.CSSFailed -> throwing _CloudErrorUser "change set creation failed--there were probably no changes"
        _ -> return ()
      case execStatus of
        CF.Available -> return ()
        CF.ExecuteComplete -> throwing _CloudErrorInternal "change set execution already complete"
        CF.ExecuteFailed -> throwing _CloudErrorInternal "change set execution failed"
        CF.ExecuteInProgress -> throwing _CloudErrorInternal "change set execution in progress"
        CF.Obsolete -> throwing _CloudErrorInternal "change set is obsolete"
        CF.Unavailable -> void $ waitUntilChangeSetReady env

generateSecret' :: MonadCloudIO r e m => Int -> CharType -> m T.Text
generateSecret' len charFilter = do
  let isXFilter = case charFilter of
        Alpha -> isAlpha
        Digit -> isDigit
        AlphaNum -> isAlphaNum
        Base64 -> const True
  g :: SystemRandom <- liftBase newGenIO
  -- | because we're filtering out characters, we need to pad the random data to
  -- ensure we end up with a secret of the right size.
  let pad n = n + 1 * 1000
      (bytes, _) = either (throw NeedReseed) id (genBytes (pad len) g)
      ascii = T.convertText $ T.Base64 bytes
      alphanums = T.filter isXFilter ascii
  return $ T.take len alphanums

encrypt' :: MonadCloudIO r e m => T.Text -> T.Text -> m B.ByteString
encrypt' input encryptionKeyId = do
  env <- ask
  runResourceT . runAWST env $ do
    let (T.UTF8 inputBS) = T.convertText input
        request = KMS.encrypt encryptionKeyId inputBS
    response <- send request
    maybe (throwing _CloudErrorInternal "encrypt did not return a valid response.")
      return (response ^. KMS.ersCiphertextBlob)

upload' :: MonadCloudIO r e m => T.Text -> T.Text -> B.ByteString -> m ()
upload' bucket path payload = do
  env <- ask
  runResourceT . runAWST env $ do
    let request = S3.putObject (S3.BucketName bucket) (S3.ObjectKey path) (AWS.toBody payload)
    _ <- send request
    maybe (throwing _CloudErrorInternal "putObject did not return a valid response.")
      return $ return ()

generateEncryptUploadSecret :: MonadCloud e m => Int -> CharType -> T.Text -> T.Text -> T.Text -> m T.Text
generateEncryptUploadSecret len charFilter encryptionKeyId bucket path = do
  secret <- generateSecret len charFilter
  encrypted <- encrypt secret encryptionKeyId
  upload bucket path encrypted
  return secret

instance MonadCloud e m => MonadCloud e (ExceptT e m)
instance MonadCloud e m => MonadCloud e (LoggingT m)
instance MonadCloud e m => MonadCloud e (ReaderT r m)
instance MonadCloud e m => MonadCloud e (StateT s m)
instance (MonadCloud e m, Monoid w) => MonadCloud e (WriterT w m)

--------------------------------------------------------------------------------
-- | A class of monads that can access environment variables
class Monad m => MonadEnvironment m where
  getEnv :: T.Text -> m (Maybe T.Text)

  default getEnv :: (MonadTrans t, MonadEnvironment m', m ~ t m') => T.Text -> m (Maybe T.Text)
  getEnv = lift . getEnv

instance MonadEnvironment IO where
  getEnv = fmap (fmap T.pack) . IO.lookupEnv . T.unpack

instance MonadEnvironment m => MonadEnvironment (ExceptT e m)
instance MonadEnvironment m => MonadEnvironment (LoggingT m)
instance MonadEnvironment m => MonadEnvironment (ReaderT r m)
instance MonadEnvironment m => MonadEnvironment (StateT s m)
instance (MonadEnvironment m, Monoid w) => MonadEnvironment (WriterT w m)
