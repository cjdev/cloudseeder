{-# LANGUAGE TemplateHaskell #-}

-- |The `Template` module exports functions dealing with parsing YAML CloudFormation templates.
module Network.CloudSeeder.Template 
  ( Template(..)
  , HasParameterSpecs(..)
  , parameterKey
  ) where 

import Control.Lens (Lens', lens, makeFields)
import Data.Aeson.Types (typeMismatch)
import Data.Yaml (FromJSON(..), Value(..), (.:))

import qualified Data.Text as T

import Network.CloudSeeder.Types

parameterKey :: Lens' ParameterSpec T.Text
parameterKey = lens get set
  where
    get (Required x) = x
    get (Optional x _) = x

    set (Required _) x = Required x
    set (Optional _ y) x = Optional x y

data Template = Template
  { _templateParameterSpecs :: ParameterSpecs
  } deriving (Eq, Show)

makeFields ''Template

instance FromJSON Template where 
  parseJSON (Object v) = Template 
    <$> v .: "Parameters"
  parseJSON invalid = typeMismatch "Template" invalid 