{-# language TemplateHaskell, DataKinds, OverloadedStrings #-}
module Mu.Rpc.Quasi (
  grpc
) where

import Control.Monad.IO.Class
import qualified Data.Text as T
import Language.Haskell.TH
import qualified Network.ProtoBuf.Types as P
import Network.ProtoBuf.Parser

import Mu.Schema.Quasi
import Mu.Rpc

grpc :: String -> (String -> String) -> FilePath -> Q [Dec]
grpc schemaName servicePrefix fp
  = do r <- liftIO $ parseProtoBufFile fp
       case r of
         Left e
           -> fail ("could not parse protocol buffers spec: " ++ show e)
         Right p@P.ProtoBuf { P.package = pkg, P.services = srvs }
           -> do let schemaName' = mkName schemaName
                 schemaDec <- tySynD schemaName' [] (schemaFromProtoBuf p)
                 serviceTy <- mapM (pbServiceDeclToDec servicePrefix pkg schemaName') srvs
                 return (schemaDec : serviceTy)

pbServiceDeclToDec :: (String -> String) -> Maybe [T.Text] -> Name -> P.ServiceDeclaration -> Q Dec
pbServiceDeclToDec servicePrefix pkg schema srv@(P.Service nm _ _)
  = tySynD (mkName $ servicePrefix $ T.unpack nm) []
           (pbServiceDeclToType pkg schema srv)

pbServiceDeclToType :: Maybe [T.Text] -> Name -> P.ServiceDeclaration -> Q Type
pbServiceDeclToType pkg schema (P.Service nm _ methods)
  = [t| 'Service $(textToStrLit nm) $(pkgType pkg)
                 $(typesToList <$> mapM (pbMethodToType schema) methods) |]
  where
    pkgType Nothing  = [t| '[] |]
    pkgType (Just p) = [t| '[ Package $(textToStrLit (T.intercalate "." p)) ] |]

pbMethodToType :: Name -> P.Method -> Q Type
pbMethodToType s (P.Method nm vr v rr r _)
  = [t| 'Method $(textToStrLit nm) '[]
                $(argToType vr v) $(retToType rr r) |]
  where
    argToType P.Single (P.TOther ["google","protobuf","Empty"])
      = [t| '[ ] |]
    argToType P.Single (P.TOther a)
      = [t| '[ 'ArgSingle ('FromSchema $(schemaTy s) $(textToStrLit (last a))) ] |]
    argToType P.Stream (P.TOther a)
      = [t| '[ 'ArgStream ('FromSchema $(schemaTy s) $(textToStrLit (last a))) ] |]
    argToType _ _
      = fail "only message types may be used as arguments"

    retToType P.Single (P.TOther ["google","protobuf","Empty"])
      = [t| 'RetNothing |]
    retToType P.Single (P.TOther a)
      = [t| 'RetSingle ('FromSchema $(schemaTy s) $(textToStrLit (last a))) |]
    retToType P.Stream (P.TOther a)
      = [t| 'RetStream ('FromSchema $(schemaTy s) $(textToStrLit (last a))) |]
    retToType _ _
      = fail "only message types may be used as results"
              
schemaTy :: Name -> Q Type
schemaTy schema = return $ ConT schema

typesToList :: [Type] -> Type
typesToList
  = foldr (\y ys -> AppT (AppT PromotedConsT y) ys) PromotedNilT
textToStrLit :: T.Text -> Q Type
textToStrLit s
  = return $ LitT $ StrTyLit $ T.unpack s