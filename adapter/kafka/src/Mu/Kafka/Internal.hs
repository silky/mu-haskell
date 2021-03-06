{-# language FlexibleContexts    #-}
{-# language ScopedTypeVariables #-}
{-# language TypeApplications    #-}
{-# language TypeFamilies        #-}
{-# language TypeOperators       #-}
module Mu.Kafka.Internal where

import qualified Data.Avro             as A
import           Data.ByteString
import           Data.ByteString.Lazy  (fromStrict, toStrict)
import           Data.Functor.Identity

import           Mu.Schema

toBS :: forall sch sty t.
        ( ToSchema Identity sch sty t
        , A.ToAvro (Term Identity sch (sch :/: sty)) )
     => Proxy sch -> t -> ByteString
toBS _ = toStrict . A.encode . toSchema @_ @_ @Identity @sch

fromBS :: forall sch sty t.
          ( FromSchema Identity sch sty t
          , A.FromAvro (Term Identity sch (sch :/: sty)) )
       => Proxy sch -> ByteString -> Maybe t
fromBS _ x = fromSchema @_ @_ @Identity @sch @sty <$> resultToMaybe (A.decode (fromStrict x))
  where
    resultToMaybe (A.Error   _) = Nothing
    resultToMaybe (A.Success x) = Just x
