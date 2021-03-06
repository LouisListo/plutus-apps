{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}

module Playground.Interpreter where

import Control.Exception (IOException, try)
import Control.Monad.Catch (MonadMask)
import Control.Monad.Error.Class (MonadError, liftEither, throwError)
import Control.Monad.Except.Extras (mapError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Newtype.Generics qualified as Newtype
import Data.Aeson qualified as JSON
import Data.Bifunctor (first)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as BSL
import Data.Text (Text)
import Data.Text qualified as Text
import Language.Haskell.Interpreter (CompilationError (CompilationError, RawError),
                                     InterpreterError (CompilationErrors), InterpreterResult (InterpreterResult),
                                     SourceCode (SourceCode), Warning (Warning), avoidUnsafe)
import Language.Haskell.TH (Ppr, Q, pprint, runQ)
import Language.Haskell.TH.Syntax (liftString)
import Playground.Types (CompilationResult (CompilationResult), Evaluation (program, sourceCode, wallets),
                         EvaluationResult,
                         PlaygroundError (InterpreterError, JsonDecodingError, OtherError, decodingError, expected, input))
import Servant.Client (ClientEnv)
import Text.Regex qualified as Regex
import Webghc.Client (runscript)
import Webghc.Server (CompileRequest (CompileRequest))
import Webghc.Server qualified as Webghc

replaceModuleName :: Text -> Text
replaceModuleName script =
  let scriptString = Text.unpack script
      regex = Regex.mkRegex "module .* where"
   in Text.pack $ Regex.subRegex regex scriptString "module Main where"

ensureMinimumImports :: (MonadError InterpreterError m) => SourceCode -> m ()
ensureMinimumImports script =
  let scriptString = Text.unpack . Newtype.unpack $ script
      regex =
        Regex.mkRegex
          "^import[ \t]+Playground.Contract([ ]*$|[ \t]+\\(.*printSchemas.*\\)|[ \t]+\\(.*printSchemas.*\\))"
      mMatches = Regex.matchRegexAll regex scriptString
   in case mMatches of
        Just _ -> pure ()
        Nothing ->
          let filename = ""
              row = 1
              column = 1
              text =
                [ "You need to import `printSchemas` in order to compile successfully, you can do this with either",
                  "`import Playground.Contract`",
                  "or",
                  "`import Playground.Contract (printSchemas)`"
                ]
              errors = [CompilationError filename row column text]
           in throwError $ CompilationErrors errors

ensureKnownCurrenciesExists :: Text -> Text
ensureKnownCurrenciesExists script =
  let scriptString = Text.unpack script
      regex = Regex.mkRegex "^\\$\\(mkKnownCurrencies \\[.*])"
      mMatches = Regex.matchRegexAll regex scriptString
   in case mMatches of
        Nothing -> script <> "\n$(mkKnownCurrencies [])"
        Just _  -> script

mkCompileScript :: Text -> Text
mkCompileScript script =
  replaceModuleName script
    <> Text.unlines
      [ "",
        "$ensureKnownCurrencies",
        "",
        "main :: IO ()",
        "main = printSchemas (schemas, registeredKnownCurrencies)"
      ]

checkCode :: MonadError InterpreterError m => SourceCode -> m ()
checkCode source = do
  avoidUnsafe source
  ensureMinimumImports source

getCompilationResult :: MonadError InterpreterError m => InterpreterResult String -> m (InterpreterResult CompilationResult)
getCompilationResult (InterpreterResult warnings result) =
  let eSchema = JSON.eitherDecodeStrict . BS8.pack $ result
   in case eSchema of
        Left err ->
          throwError . CompilationErrors . pure . RawError $
            "unable to decode compilation result: " <> Text.pack err
              <> "\n"
              <> Text.pack result
        Right ([schema], currencies) -> do
          let warnings' =
                Warning
                  "It looks like you have not made any functions available, use `$(mkFunctions ['functionA, 'functionB])` to be able to use `functionA` and `functionB`" :
                warnings
          pure . InterpreterResult warnings' $
            CompilationResult [schema] currencies
        Right (schemas, currencies) ->
          pure . InterpreterResult warnings $
            CompilationResult schemas currencies

compile ::
  ( MonadMask m,
    MonadIO m,
    MonadError InterpreterError m
  ) =>
  ClientEnv ->
  SourceCode ->
  m (InterpreterResult CompilationResult)
compile clientEnv source = do
  -- There are a couple of custom rules required for compilation
  checkCode source
  result <- runscript clientEnv $ CompileRequest {
    code = mkCompileScript (Newtype.unpack source),
    implicitPrelude = False
    }
  getCompilationResult result

evaluationToExpr :: (MonadError PlaygroundError m, MonadIO m) => Evaluation -> m Text
evaluationToExpr evaluation = do
  let source = sourceCode evaluation
  mapError InterpreterError $ avoidUnsafe source
  expr <- mkExpr evaluation
  pure $ mkRunScript source (Text.pack expr)

decodeEvaluation :: MonadError PlaygroundError m => InterpreterResult String -> m (InterpreterResult EvaluationResult)
decodeEvaluation (InterpreterResult warnings result) =
  let decodeResult = JSON.eitherDecodeStrict . BS8.pack $ result :: Either String (Either PlaygroundError EvaluationResult)
   in case decodeResult of
        Left err ->
          throwError
            JsonDecodingError
              { expected = "EvaluationResult",
                decodingError = err,
                input = result
              }
        Right eResult ->
          case eResult of
            Left err -> throwError err
            Right result' ->
              pure $ InterpreterResult warnings result'

evaluateSimulation ::
  ( MonadMask m,
    MonadIO m,
    MonadError PlaygroundError m
  ) =>
  ClientEnv ->
  Evaluation ->
  m (InterpreterResult EvaluationResult)
evaluateSimulation clientEnv evaluation = do
  expr <- evaluationToExpr evaluation
  result <- mapError InterpreterError $ runscript clientEnv $ CompileRequest {
    code = expr,
    implicitPrelude = False
    }
  decodeEvaluation result

mkRunScript :: SourceCode -> Text -> Text
mkRunScript (SourceCode script) expr =
  replaceModuleName script <> "\n\nmain :: IO ()" <> "\nmain = printJson $ "
    <> expr

mkExpr :: (MonadError PlaygroundError m, MonadIO m) => Evaluation -> m String
mkExpr evaluation = do
  let programJson = liftString . BSL.unpack . JSON.encode $ program evaluation
      simulatorWalletsJson =
        liftString . BSL.unpack . JSON.encode $ wallets evaluation
  printQ [|stage endpoints $(programJson) $(simulatorWalletsJson)|]

printQ :: (MonadError PlaygroundError m, MonadIO m, Ppr a) => Q a -> m String
printQ q = do
  str <- liftIO . fmap toPlaygroundError . try . runQ . fmap pprint $ q
  liftEither str
  where
    toPlaygroundError :: Either IOException a -> Either PlaygroundError a
    toPlaygroundError = first (OtherError . show)

{-{- HLINT ignore getJsonString -}-}
getJsonString :: (MonadError PlaygroundError m) => JSON.Value -> m String
getJsonString (JSON.String s) = pure $ Text.unpack s
getJsonString v =
  throwError
    JsonDecodingError
      { expected = "String",
        input = BSL.unpack $ JSON.encode v,
        decodingError = "Expected a String."
      }
