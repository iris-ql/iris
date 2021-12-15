{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Iris.App
  ( Config (..),
    VALIDATION_MODE (..),
    defaultConfig,
    debugConfig,
    App (..),
    AppData (..),
    runApp,
    withDebugger,
    mkApp,
    runAppStream,
    MapAPI (..),
    eitherSchema,
  )
where

import qualified Data.Aeson as A
import Data.ByteString.Lazy (ByteString)
import Data.Iris.App.Internal.Resolving
  ( ResolverContext (..),
    ResponseStream,
    ResultT (..),
    RootResolverValue,
    resultOr,
    runRootResolverValue,
  )
import Data.Iris.App.Internal.Stitching (Stitching (..))
import Data.Iris.App.MapAPI (MapAPI (..))
import Data.Mergeable.Utils
  ( empty,
    prop,
    throwErrors,
  )
import Language.Iris
  ( Config (..),
    RenderGQL (..),
    VALIDATION_MODE (..),
    ValidateSchema (..),
    debugConfig,
    defaultConfig,
    internalSchema,
    parseRequestWith,
    render,
  )
import Language.Iris.Types
  ( GQLRequest (..),
    GQLResponse,
    renderResponse,
  )
import Language.Iris.Types.Internal.AST
  ( GQLError,
    GQLErrors,
    LAZY,
    Operation (..),
    OperationType (Mutation, Query, Subscription),
    Schema (..),
    Selection (..),
    SelectionContent (..),
    TypeDefinition,
    VALID,
    Value,
    toAny,
    (<:>),
  )
import qualified Language.Iris.Types.Internal.AST as AST
import Relude hiding (ByteString, empty)

mkApp :: ValidateSchema s => Schema s -> RootResolverValue e m -> App e m
mkApp appSchema appResolvers =
  resultOr
    FailApp
    (App . AppData defaultConfig appResolvers)
    (validateSchema True defaultConfig appSchema)

data App event (m :: Type -> Type)
  = App {app :: AppData event m VALID}
  | FailApp {appErrors :: GQLErrors}

instance RenderGQL (App e m) where
  renderGQL App {app} = renderGQL app
  renderGQL FailApp {appErrors} = renderGQL $ A.encode $ toList appErrors

instance Monad m => Semigroup (App e m) where
  (FailApp err1) <> (FailApp err2) = FailApp (err1 <> err2)
  FailApp {appErrors} <> App {} = FailApp appErrors
  App {} <> FailApp {appErrors} = FailApp appErrors
  (App x) <> (App y) = resultOr FailApp App (stitch x y)

data AppData event (m :: Type -> Type) s = AppData
  { appConfig :: Config,
    appResolvers :: RootResolverValue event m,
    appSchema :: Schema s
  }

instance RenderGQL (AppData e m s) where
  renderGQL = renderGQL . appSchema

instance Monad m => Stitching (AppData e m s) where
  stitch x y =
    AppData (appConfig y)
      <$> prop stitch appResolvers x y
      <*> prop stitch appSchema x y

runAppData ::
  (Monad m, ValidateSchema s) =>
  AppData event m s ->
  GQLRequest ->
  ResponseStream event m (Value VALID)
runAppData AppData {appConfig, appSchema, appResolvers} request = do
  validRequest <- validateReq appSchema appConfig request
  runRootResolverValue appResolvers validRequest

validateReq ::
  ( Monad m,
    ValidateSchema s
  ) =>
  Schema s ->
  Config ->
  GQLRequest ->
  ResponseStream event m ResolverContext
validateReq inputSchema config request = ResultT $
  pure $
    do
      validSchema <- validateSchema True config inputSchema
      schema <- internalSchema <:> validSchema
      operation <- parseRequestWith config validSchema request
      pure
        ( [],
          ResolverContext
            { schema,
              config,
              operation,
              currentType =
                toAny $
                  fromMaybe
                    (AST.query schema)
                    (rootType (operationType operation) schema),
              currentSelection =
                Selection
                  { selectionName = "Root",
                    selectionArguments = empty,
                    selectionPosition = operationPosition operation,
                    selectionAlias = Nothing,
                    selectionContent = SelectionSet (operationSelection operation),
                    selectionDirectives = empty
                  }
            }
        )

rootType :: OperationType -> Schema s -> Maybe (TypeDefinition LAZY s)
rootType Query = Just . AST.query
rootType Mutation = mutation
rootType Subscription = subscription

stateless ::
  Functor m =>
  ResponseStream event m (Value VALID) ->
  m GQLResponse
stateless = fmap (renderResponse . fmap snd) . runResultT

runAppStream :: Monad m => App event m -> GQLRequest -> ResponseStream event m (Value VALID)
runAppStream App {app} = runAppData app
runAppStream FailApp {appErrors} = const $ throwErrors appErrors

runApp :: (MapAPI a b, Monad m) => App e m -> a -> m b
runApp app = mapAPI (stateless . runAppStream app)

withDebugger :: App e m -> App e m
withDebugger App {app = AppData {appConfig = Config {..}, ..}} =
  App {app = AppData {appConfig = Config {debug = True, ..}, ..}, ..}
withDebugger x = x

eitherSchema :: App event m -> Either [GQLError] ByteString
eitherSchema (App AppData {appSchema}) = Right (render appSchema)
eitherSchema (FailApp errors) = Left (toList errors)
