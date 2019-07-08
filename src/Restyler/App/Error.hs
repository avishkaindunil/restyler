{-# LANGUAGE LambdaCase #-}

module Restyler.App.Error
    ( AppError(..)
    , mapAppError
    , prettyAppError

    -- * Error handling
    , errorPullRequest
    , dieAppErrorHandlers

    -- * Lower-level helpers
    , warnIgnore

    -- * Exported only for direct testing
    , scrubGitHubToken
    )
where

import Restyler.Prelude

import qualified Data.Yaml as Yaml
import GitHub.Data (Error(..))
import GitHub.Request.Display
import Restyler.App.Class
import Restyler.Config
import Restyler.Options
import Restyler.PullRequest
import Restyler.PullRequest.Status
import Restyler.Restyler (Restyler(..))
import System.Exit (die)
import Text.Wrap

data AppError
    = PullRequestFetchError Error
    -- ^ We couldn't fetch the @'PullRequest'@ to restyle
    | PullRequestCloneError IOException
    -- ^ We couldn't clone or checkout the PR's branch
    | ConfigurationError ConfigError
    -- ^ We couldn't load a @.restyled.yaml@
    | RestylerError Restyler IOException
    -- ^ A Restyler we ran exited non-zero
    | GitHubError DisplayGitHubRequest Error
    -- ^ We encountered a GitHub API error during restyling
    | SystemError IOException
    -- ^ Trouble reading a file or etc
    | HttpError IOException
    -- ^ Trouble performing some HTTP request
    | OtherError SomeException
    -- ^ Escape hatch for anything else
    deriving Show

instance Exception AppError

-- | Run a computation, and modify any thrown exceptions to @'AppError'@s
mapAppError :: (MonadUnliftIO m, Exception e) => (e -> AppError) -> m a -> m a
mapAppError f = handle $ throwIO . f

prettyAppError :: AppError -> String
prettyAppError =
    format <$> toErrorTitle <*> toErrorBody <*> toErrorDocumentation
    where format title body docs = title <> ":\n\n" <> body <> docs

-- | /Naively/ scrub ephemeral tokens from error messages
--
-- If there's an error cloning or pushing, it may show the remote's URL which
-- will include the "x-access-token:...@github.com" secret. These are ephemeral
-- and only valid for less than 5 minutes, but we shouldn't show them anyway.
--
-- This function naively strips the 58 characters before "@github.com" which
-- addresses known error messages and should fail-safe by over-scrubbing when it
-- gets something wrong.
--
scrubGitHubToken :: String -> String
scrubGitHubToken msg = maybe msg rebuild $ findIndex "@github.com" msg
  where
    rebuild i = take (i - tokenLen) msg <> "<SCRUBBED>" <> drop i msg
    tokenLen = 58

toErrorTitle :: AppError -> String
toErrorTitle = trouble . \case
    PullRequestFetchError _ -> "fetching your Pull Request from GitHub"
    PullRequestCloneError _ -> "cloning your Pull Request branch"
    ConfigurationError _ -> "with your configuration"
    RestylerError r _ -> "with the " <> rName r <> " restyler"
    GitHubError _ _ -> "communicating with GitHub"
    SystemError _ -> "running a system command"
    HttpError _ -> "performing an HTTP request"
    OtherError _ -> "with something unexpected"
    where trouble = ("We had trouble " <>)

toErrorBody :: AppError -> String
toErrorBody = reflow . \case
    PullRequestFetchError e -> showGitHubError e
    PullRequestCloneError e -> show e
    ConfigurationError (ConfigErrorInvalidYaml e) ->
        Yaml.prettyPrintParseException e
    ConfigurationError (ConfigErrorInvalidRestylers es) ->
        "Invalid Restylers:" <> unlines (map ("  - " <>) es)
    ConfigurationError ConfigErrorNoRestylers -> "No Restylers configured"
    RestylerError _ e -> show e
    GitHubError req e -> "Request: " <> show req <> "\n" <> showGitHubError e
    SystemError e -> show e
    HttpError e -> show e
    OtherError e -> show e

toErrorDocumentation :: AppError -> String
toErrorDocumentation = formatDocs . \case
    ConfigurationError _ ->
        [ "https://github.com/restyled-io/restyled.io/wiki/Common-Errors:-.restyled.yaml"
        ]
    RestylerError r _ -> rDocumentation r
    _ -> []
  where
    formatDocs [] = "\n"
    formatDocs [url] = "\nPlease see " <> url <> "\n"
    formatDocs urls = unlines $ "\nPlease see" : map ("  - " <>) urls

showGitHubError :: Error -> String
showGitHubError = \case
    HTTPError e -> "HTTP exception: " <> show e
    ParseError e -> "Unable to parse response: " <> unpack e
    JsonError e -> "Malformed response: " <> unpack e
    UserError e -> "User error: " <> unpack e

reflow :: String -> String
reflow = indent . wrap
  where
    indent = unlines . map ("  " <>) . lines
    wrap = unpack . wrapText wrapSettings 78 . pack
    wrapSettings =
        WrapSettings {preserveIndentation = True, breakLongWords = False}

-- | Error the original @'PullRequest'@ and re-throw the exception
errorPullRequest
    :: ( HasLogFunc env
       , HasOptions env
       , HasConfig env
       , HasPullRequest env
       , HasGitHub env
       )
    => SomeException
    -> RIO env ()
errorPullRequest = exceptExit $ \ex -> do
    mJobUrl <- oJobUrl <$> view optionsL
    traverse_ errorPullRequestUrl mJobUrl
    throwIO ex

-- | Actually error the @'PullRequest'@, given the job-url to link to
errorPullRequestUrl
    :: (HasLogFunc env, HasConfig env, HasPullRequest env, HasGitHub env)
    => URL
    -> RIO env ()
errorPullRequestUrl url =
    handleAny warnIgnore $ sendPullRequestStatus $ ErrorStatus url

-- | Ignore an exception, warning about it.
warnIgnore :: (Show a, HasLogFunc env) => a -> RIO env ()
warnIgnore ex = logWarn $ "Caught " <> displayShow ex <> ", ignoring."

-- | Error handlers for overall execution
--
-- Usage:
--
-- > {- main routine -} `catches` dieAppErrorHandlers
--
-- Ensures __all__ exceptions (besides @'ExitCode'@s) go through:
--
-- @
-- 'die' . 'prettyAppError'
-- @
--
dieAppErrorHandlers :: [Handler IO ()]
dieAppErrorHandlers =
    [Handler dieAppError, Handler $ exceptExit $ dieAppError . OtherError]

dieAppError :: AppError -> IO a
dieAppError = die . prettyAppError

exceptExit :: Applicative f => (SomeException -> f ()) -> SomeException -> f ()
exceptExit f ex = maybe (f ex) ignore $ fromException ex
  where
    ignore :: Applicative f => ExitCode -> f ()
    ignore _ = pure ()
