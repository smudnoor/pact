{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}


module Pact.Server.Client
  ( PactServerAPI
  , pactServerAPI
  , send
  , poll
  , listen
  , local
  , verify
  , version
  ) where

import Data.Aeson
import Servant.API
import Servant.Client
import qualified Pact.Analyze.Remote.Types as Analyze
import Pact.Types.API
import Pact.Types.Command
import Data.Text (Text)

import Pact.Server.API

send :: SubmitBatch -> ClientM (ApiResponse RequestKeys)
poll :: Poll -> ClientM (ApiResponse PollResponses)
listen :: ListenerRequest -> ClientM (ApiResponse ApiResult)
local :: Command Text -> ClientM (ApiResponse (CommandSuccess Value))
verify :: Analyze.Request -> ClientM Analyze.Response
version :: ClientM Text

(send :<|> poll :<|> listen :<|> local) :<|> verify :<|> version =
  client pactServerAPI