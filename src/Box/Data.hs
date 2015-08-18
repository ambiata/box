{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Box.Data (
    Box (..)
  , BoxStore (..)
  , Query (..)
  , Exact (..)
  , Infix (..)
  , InstanceId (..)
  , Host (..)
  , Name (..)
  , Client (..)
  , Flavour (..)
  , BoxError (..)
  , queryHasMatch
  , queryFromText
  , queryParser
  , queryRender
  , boxesFromText
  , boxFromText
  , boxesToText
  , boxToText
  , boxParser
  , boxErrorRender
  , selectRandomBox
  ) where

import           Data.Attoparsec.Text as AP
import           Data.Text as T

import           Mismi.S3.Data

import           P

import           System.IO
import           System.Random.Shuffle

------------------------------------------------------------------------
-- Types

data Box =
  Box {
      boxInstance :: InstanceId
    , boxHost :: Host
    , boxPublicHost :: Host
    , boxName :: Name
    , boxClient :: Client
    , boxFlavour :: Flavour
    } deriving (Eq, Show)

data BoxStore =
    BoxStoreLocal FilePath
  | BoxStoreS3 Address
  deriving (Eq, Show)

data Query = Query {
    queryClient  :: Exact Client
  , queryFlavour :: Exact Flavour
  , queryName    :: Infix Name
  } deriving (Eq, Show)

data Exact a =
    Exact a
  | ExactAll
  deriving (Eq, Show)

data Infix a =
    Infix a
  | InfixAll
  deriving (Eq, Show)

newtype InstanceId =
  InstanceId {
    unInstanceId :: Text
  } deriving (Eq, Show)

newtype Host =
  Host {
    unHost :: Text
  } deriving (Eq, Show)

newtype Name =
  Name {
    unName :: Text
  } deriving (Eq, Show)

newtype Client =
  Client {
    unClient :: Text
  } deriving (Eq, Show)

newtype Flavour =
  Flavour {
    unFlavour :: Text
  } deriving (Eq, Show)

data BoxError =
    BoxNotFound BoxStore
  | BoxParseError Text
  deriving (Eq, Show)


------------------------------------------------------------------------
-- Query

isExactMatch :: Exact a -> Bool
isExactMatch (ExactAll) = False
isExactMatch (Exact _)  = True

isInfixMatch :: Infix a -> Bool
isInfixMatch (InfixAll) = False
isInfixMatch (Infix _)  = True

queryHasMatch :: Query -> Bool
queryHasMatch (Query c f n) =
  isExactMatch c || isExactMatch f || isInfixMatch n

queryFromText :: Text -> Either Text Query
queryFromText =
  first T.pack . parseOnly queryParser

queryParser :: Parser Query
queryParser =
  part `AP.sepBy1` delim <* AP.endOfInput >>= \case
    []         -> pure $ Query (mClient Nothing) (mFlavour Nothing) (mName Nothing)
    (c:[])     -> pure $ Query (mClient c)       (mFlavour Nothing) (mName Nothing)
    (c:f:[])   -> pure $ Query (mClient c)       (mFlavour f)       (mName Nothing)
    (c:f:n:[]) -> pure $ Query (mClient c)       (mFlavour f)       (mName n)
    _          -> fail "filter can only contain three parts (client, flavour, name)"
  where
    mClient  = maybe ExactAll (Exact . Client)
    mFlavour = maybe ExactAll (Exact . Flavour)
    mName    = maybe InfixAll (Infix . Name)

    part  = takeMaybe <$> AP.takeWhile (/= ':')
    delim = AP.char ':'

    takeMaybe t | T.null t  = Nothing
                | otherwise = Just t

queryRender :: Query -> Text
queryRender (Query c f n) =
       exactRender unClient  c
    <> sepcf
    <> exactRender unFlavour f
    <> sepfn
    <> infixRender unName    n
  where
    -- we need a separator between client/flavour if
    -- flavour or name are not a wildcard match
    sepcf | isExactMatch f = ":"
          | isInfixMatch n = ":"
          | otherwise      = ""

    -- we need a separator between flavour/name if
    -- name is not a wildcard match
    sepfn | isInfixMatch n = ":"
          | otherwise      = ""

exactRender :: (a -> Text) -> Exact a -> Text
exactRender _ (ExactAll) = ""
exactRender f (Exact x)  = f x

infixRender :: (a -> Text) -> Infix a -> Text
infixRender _ (InfixAll) = ""
infixRender f (Infix x)  = f x

------------------------------------------------------------------------
-- Box

boxesFromText :: Text -> Either Text [Box]
boxesFromText =
  traverse boxFromText . T.lines

boxFromText :: Text -> Either Text Box
boxFromText =
  first T.pack . parseOnly boxParser

boxesToText :: [Box] -> Text
boxesToText [] =
  ""
boxesToText bs =
  (<> "\n") . T.intercalate "\n" . fmap boxToText $ bs

boxToText :: Box -> Text
boxToText (Box (InstanceId i) (Host h) (Host p) (Name n) (Client c) (Flavour f)) =
  T.intercalate " " [i, h, p, n, c, f]

boxParser :: Parser Box
boxParser = do
  let t = AP.takeWhile (/= ' ')
      ts = t <* string " "
  i <- InstanceId <$> ts
  h <- Host <$> ts
  p <- Host <$> ts
  n <- Name <$> ts
  c <- Client <$> ts
  f <- Flavour <$> t
  endOfInput
  pure $ Box i h p n c f

boxStoreRender :: BoxStore -> Text
boxStoreRender (BoxStoreLocal f) =
  T.pack f
boxStoreRender (BoxStoreS3 a) =
  addressToText a

boxErrorRender :: BoxError -> Text
boxErrorRender (BoxNotFound bs) =
  "Could not find the box file located at: " <> boxStoreRender bs
boxErrorRender (BoxParseError e) =
  "Error parsing box file with the following error: " <> e

-- | Select a box at random so that the first box isn't the list isn't always picked again and again
selectRandomBox :: [Box] -> IO (Maybe Box)
selectRandomBox =
  fmap listToMaybe . shuffleM
