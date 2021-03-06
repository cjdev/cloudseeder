{-# OPTIONS_GHC -fno-warn-overlapping-patterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Network.CloudSeeder.Monads.AWS
  ( MonadCloud(..)
  , computeChangeset'
  , deleteStack'
  , describeChangeSet'
  , describeStack'
  , runChangeSet'
  , encrypt'
  , upload'
  , generateSecret'
  , generateEncryptUploadSecret
  , setStackPolicy'
  , wait'
  , CharType(..)
  , CloudError(..)
  , HasCloudError(..)
  , AsCloudError(..)
  , Waiter(..)
  ) where

import Prelude hiding (readFile)

import Control.Exception (throw)
import Control.Lens (Traversal', (.~), (^.), (^?), (?~), _Just, only)
import Control.Lens.TH (makeClassy, makeClassyPrisms)
import Control.Monad (void)
import Control.Monad.Base (liftBase)
import Control.Monad.Catch (MonadCatch, MonadThrow)
import Control.Monad.Error.Lens (throwing)
import Control.Monad.Except (ExceptT, MonadError)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Logger (MonadLogger, LoggingT, logInfoN)
import Control.Monad.Reader (MonadReader, ReaderT, ask)
import Control.Monad.State (StateT)
import Control.Monad.Trans (MonadTrans, lift)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Writer (WriterT)
import Crypto.Random
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Function ((&))
import Data.Semigroup ((<>))
import Data.UUID (toText)
import Data.UUID.V4 (nextRandom)
import Network.AWS (AsError(..), ErrorMessage(..), HasEnv(..), serviceMessage)

import qualified Control.Exception.Lens as IO
import qualified Control.Monad.Trans.AWS as AWS
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Conversions as T
import qualified Network.AWS.CloudFormation as CF
import qualified Network.AWS.KMS as KMS
import qualified Network.AWS.S3 as S3

import Network.CloudSeeder.Types

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

data Waiter
  = StackCreateComplete
  | StackUpdateComplete
  | StackExists
  | StackDeleteComplete
  deriving (Eq, Show)

class (AsCloudError e, MonadError e m) => MonadCloud e m | m -> e where
  computeChangeset :: StackName -> ProvisionType -> T.Text -> M.Map T.Text ParameterValue -> M.Map T.Text T.Text -> m T.Text
  deleteStack :: StackName -> m ()
  describeChangeSet :: T.Text -> m ChangeSet
  describeStack :: StackName -> m (Maybe Stack)
  runChangeSet :: T.Text -> m ()
  encrypt :: T.Text -> T.Text -> m B.ByteString
  upload :: T.Text -> T.Text -> B.ByteString -> m ()
  generateSecret :: Int -> CharType -> m T.Text
  setStackPolicy :: StackName -> T.Text -> m ()
  wait :: Waiter -> StackName -> m ()

  default computeChangeset :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> ProvisionType -> T.Text -> M.Map T.Text ParameterValue -> M.Map T.Text T.Text -> m T.Text
  computeChangeset a b c d e = lift $ computeChangeset a b c d e

  default deleteStack :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> m ()
  deleteStack = lift . deleteStack

  default describeChangeSet :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> m ChangeSet
  describeChangeSet = lift . describeChangeSet

  default describeStack :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> m (Maybe Stack)
  describeStack = lift . describeStack

  default runChangeSet :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> m ()
  runChangeSet = lift . runChangeSet

  default encrypt :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> T.Text -> m B.ByteString
  encrypt a b = lift $ encrypt a b

  default upload :: (MonadTrans t, MonadCloud e m', m ~ t m') => T.Text -> T.Text -> B.ByteString -> m ()
  upload a b c = lift $ upload a b c

  default generateSecret :: (MonadTrans t, MonadCloud e m', m ~ t m') => Int -> CharType -> m T.Text
  generateSecret a b = lift $ generateSecret a b

  default setStackPolicy :: (MonadTrans t, MonadCloud e m', m ~ t m') => StackName -> T.Text -> m ()
  setStackPolicy a b = lift $ setStackPolicy a b

  default wait :: (MonadTrans t, MonadCloud e m', m ~ t m') => Waiter -> StackName -> m ()
  wait a b = lift $ wait a b

type MonadCloudIO r e m = (HasEnv r, MonadReader r m, MonadIO m, MonadBaseControl IO m, MonadCatch m, MonadThrow m, AsCloudError e, MonadError e m, MonadLogger m, MonadCloud e m)

_StackDoesNotExistError :: AsError a => StackName -> Traversal' a ()
_StackDoesNotExistError (StackName stackName) = _ServiceError.serviceMessage._Just.only (ErrorMessage msg)
  where msg = "Stack with id " <> stackName <> " does not exist"

computeChangeset'
  :: MonadCloudIO r e m
  => StackName
  -> ProvisionType
  -> T.Text
  -> M.Map T.Text ParameterValue
  -> M.Map T.Text T.Text
  -> m T.Text
computeChangeset' (StackName stackName) provisionType templateBody params tags = do
    uuid <- liftBase nextRandom
    let changeSetName = "cs-" <> toText uuid -- change set name must begin with a letter

    env <- ask
    AWS.runResourceT . AWS.runAWST env $ do
      let request = CF.createChangeSet stackName changeSetName
            & CF.ccsParameters .~ map awsParam (M.toList params)
            & CF.ccsTemplateBody ?~ templateBody
            & CF.ccsCapabilities .~ [CF.CapabilityIAM]
            & CF.ccsTags .~ map awsTag (M.toList tags)
            & CF.ccsChangeSetType ?~ provisionTypeToChangeSetType provisionType
      response <- AWS.send request
      maybe (throwing _CloudErrorInternal "createChangeSet did not return a valid response")
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

deleteStack' :: MonadCloudIO r e m => StackName -> m ()
deleteStack' (StackName stackName) = do
  env <- ask
  let request = CF.deleteStack stackName
  AWS.runResourceT . AWS.runAWST env $ void $ AWS.send request

describeChangeSet' :: MonadCloudIO r e m => T.Text -> m ChangeSet
describeChangeSet' csId' = do
  env <- ask
  let request = CF.describeChangeSet csId'
  response <- AWS.runResourceT . AWS.runAWST env $
    IO.trying CF._ChangeSetNotFoundException $ do
      void $ AWS.await CF.changeSetCreateComplete request
      AWS.send request
  case response of
    Left e -> do
      let (AWS.ErrorCode errorCode) = e ^. AWS.serviceCode
      throwing _CloudErrorInternal ("describeChangeSet returned error " <> errorCode <> " for changeset id " <> csId')
    Right r -> do
      execStatus <- maybe
        (throwing _CloudErrorInternal ("describeChangeSet did not return an execution status for changeset id " <> csId'))
        pure
        ((r ^. CF.drsExecutionStatus) :: Maybe CF.ExecutionStatus)
      params <- mapM awsParamToParam (r ^. CF.drsParameters)
      changes' <- mapM awsChangeToChange (r ^. CF.drsChanges)
      pure $ ChangeSet (r ^. CF.drsStatusReason) csId' params execStatus changes'
  where
    awsParamToParam awsParam = do
      key <- maybe
        (throwing _CloudErrorInternal "describeChangeSet parameter missing key")
        pure
        (awsParam ^. CF.pParameterKey)
      let maybeVal = awsParam ^. CF.pParameterValue
          maybeUsePrevVal = awsParam ^. CF.pUsePreviousValue
      case (maybeVal, maybeUsePrevVal) of
        (Just val, Nothing) -> pure $ Parameter (key, Value val)
        (Nothing, Nothing) -> pure $ Parameter (key, Value "")
        (Nothing, Just _) -> pure $ Parameter (key, UsePreviousValue)
        (Just val, Just _) -> throwing
          _CloudErrorInternal
          ("describeChangeSet parameter contains both the value " <> val <> " and UsePreviousVal")
    awsChangeToChange :: (MonadCloudIO r e m) => CF.Change -> m Change
    awsChangeToChange awsChange = do
      awsResourceChange <- maybe
        (throwing _CloudErrorInternal "describeChangeSet change missing resourceChange")
        pure
        (awsChange ^. CF.cResourceChange)
      logicalId' <- maybe
        (throwing _CloudErrorInternal "describeChangeSet resourceChange missing logicalId")
        pure
        (awsResourceChange ^. CF.rcLogicalResourceId)
      let physicalId' = awsResourceChange ^. CF.rcPhysicalResourceId
      resourceType' <- maybe
        (throwing _CloudErrorInternal "describeChangeSet resourceChange missing resourceType")
        pure
        (awsResourceChange ^. CF.rcResourceType)
      action <- maybe
        (throwing _CloudErrorInternal "describeChangeSet resourceChange missing action")
        pure
        (awsResourceChange ^. CF.rcAction)
      case action of
        CF.Add -> pure $ Add $ ChangeAdd logicalId' physicalId' resourceType'
        CF.Remove -> pure $ Remove $ ChangeRemove logicalId' physicalId' resourceType'
        CF.Modify -> do
          let scope' = awsResourceChange ^. CF.rcScope
          let details' = awsResourceChange ^. CF.rcDetails
          replacement' <- maybe
            (throwing _CloudErrorInternal "describeChangeSet resourceChange missing replacement")
            pure
            (awsResourceChange ^. CF.rcReplacement)
          pure $ Modify $ ChangeModify logicalId' physicalId' resourceType' scope' details' replacement'

describeStack' :: MonadCloudIO r e m => StackName -> m (Maybe Stack)
describeStack' (StackName stackName) = do
  env <- ask
  let request = CF.describeStacks & CF.dStackName ?~ stackName
  AWS.runResourceT . AWS.runAWST env $ do
    response <- IO.trying_ (_StackDoesNotExistError (StackName stackName)) $ AWS.send request
    case response ^? _Just.CF.dsrsStacks of
      Nothing -> return Nothing
      Just [s] -> do
        let awsOutputs = s ^. CF.sOutputs
        outputs' <- M.fromList <$> mapM outputToTuple awsOutputs
        let awsParams = s ^. CF.sParameters
        params <- S.fromList <$> mapM awsParameterKey awsParams
        pure $ Just $ Stack
          (s ^. CF.sStackStatusReason)
          (s ^. CF.sChangeSetId)
          (s ^. CF.sStackName)
          outputs'
          params
          (s ^. CF.sStackId)
          (s ^. CF.sStackStatus)
      Just _ -> throwing _CloudErrorInternal "describeStacks returned more than one stack"
  where
    awsParameterKey x = case x ^. CF.pParameterKey of
      (Just k) -> return k
      Nothing -> throwing _CloudErrorInternal "stack parameter key was missing"
    outputToTuple x = case (x ^. CF.oOutputKey, x ^. CF.oOutputValue) of
      (Just k, Just v) -> return (k, v)
      (Nothing, _) -> throwing _CloudErrorInternal "stack output key was missing"
      (_, Nothing) -> throwing _CloudErrorInternal "stack output value was missing"

runChangeSet' :: MonadCloudIO r e m => T.Text -> m ()
runChangeSet' csId' = do
    env <- ask
    r <- AWS.runResourceT . AWS.runAWST env $ do
      void $ AWS.await CF.changeSetCreateComplete (CF.describeChangeSet csId')
      IO.trying CF._InvalidChangeSetStatusException $ AWS.send (CF.executeChangeSet csId')
    case r of
      Left _ -> do
        changeSet <- describeChangeSet csId'
        case changeSet ^. changes of
          [] -> logInfoN "change set contains no changes -- aborting change set execution"
          _ -> throwing _CloudErrorInternal ("executeChangeSet returned invalidChangeSetStatus error for changeset id " <> csId')
      Right _ -> pure ()

setStackPolicy' :: MonadCloudIO r e m => StackName -> T.Text -> m ()
setStackPolicy' stackName policy = do
  let (StackName sName) = stackName
  env <- ask
  AWS.runResourceT . AWS.runAWST env $ do
    let request = CF.setStackPolicy sName
          & CF.sspStackPolicyBody ?~ policy
    response <- IO.trying_ (_StackDoesNotExistError stackName) (AWS.send request)
    case response of
      Just _ -> pure ()
      Nothing -> throwing _CloudErrorInternal "setStackPolicy: stack did not exist"

wait' :: MonadCloudIO r e m => Waiter -> StackName -> m ()
wait' waiter stackName = do
  env <- ask
  let (StackName sName) = stackName
  void $ AWS.runResourceT . AWS.runAWST env $
    AWS.await waiter' (CF.describeStacks & CF.dStackName ?~ sName)
  where
    waiter' = case waiter of
      StackCreateComplete -> CF.stackCreateComplete
      StackUpdateComplete -> CF.stackUpdateComplete
      StackExists -> CF.stackExists
      StackDeleteComplete -> CF.stackDeleteComplete

generateSecret' :: MonadCloudIO r e m => Int -> CharType -> m T.Text
generateSecret' len charFilter = do
  let isXFilter = case charFilter of
        Alpha -> isAlpha
        Digit -> isDigit
        AlphaNum -> isAlphaNum
        Base64 -> const True
  g :: SystemRandom <- liftBase newGenIO
  -- because we're filtering out characters, we need to pad the random data to
  -- ensure we end up with a secret of the right size.
  let pad n = n + 1 * 1000
      (bytes, _) = either (throw NeedReseed) id (genBytes (pad len) g)
      ascii = T.convertText $ T.Base64 bytes
      alphanums = T.filter isXFilter ascii
  return $ T.take len alphanums

encrypt' :: MonadCloudIO r e m => T.Text -> T.Text -> m B.ByteString
encrypt' input encryptionKeyId = do
  env <- ask
  AWS.runResourceT . AWS.runAWST env $ do
    let (T.UTF8 inputBS) = T.convertText input
        request = KMS.encrypt encryptionKeyId inputBS
    response <- AWS.send request
    maybe (throwing _CloudErrorInternal "encrypt did not return a valid response.")
      return (response ^. KMS.ersCiphertextBlob)

upload' :: MonadCloudIO r e m => T.Text -> T.Text -> B.ByteString -> m ()
upload' bucket path payload = do
  env <- ask
  AWS.runResourceT . AWS.runAWST env $ do
    let request = S3.putObject (S3.BucketName bucket) (S3.ObjectKey path) (AWS.toBody payload)
    _ <- AWS.send request
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
