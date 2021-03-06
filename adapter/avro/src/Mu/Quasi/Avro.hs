{-# language DataKinds         #-}
{-# language LambdaCase        #-}
{-# language NamedFieldPuns    #-}
{-# language OverloadedStrings #-}
{-# language TemplateHaskell   #-}
{-# language ViewPatterns      #-}
{-|
Description : Quasi-quoters for Avro IDL format

This module turns schema definitions written in
<https://avro.apache.org/docs/current/idl.html Avro IDL>
into Mu 'Schema's. We provide versions for writing
the IDL inline ('avro') and import it from a file
('avroFile').

/Note/: as of now, only the JSON-based IDL format
is supported, not the Java-like one.
-}
module Mu.Quasi.Avro (
  -- * Service generation from @.avdl@ files
  avdl
  -- * Quasi-quoters for @.avsc@ files
, avro
, avroFile
  -- * Only for internal use
, schemaFromAvroType
) where

import           Control.Monad.IO.Class
import           Data.Aeson                 (decode)
import qualified Data.Avro.Schema           as A
import qualified Data.ByteString            as B
import           Data.ByteString.Lazy.Char8 (pack)
import           Data.Int
import qualified Data.Text                  as T
import           Data.Vector                (fromList, toList)
import           Language.Avro.Parser
import qualified Language.Avro.Types        as A
import           Language.Haskell.TH
import           Language.Haskell.TH.Quote

import           Mu.Rpc
import           Mu.Schema.Definition

-- | Imports an avro definition written in-line as a 'Schema'.
avro :: QuasiQuoter
avro =
  QuasiQuoter
    (const $ fail "cannot use as expression")
    (const $ fail "cannot use as pattern")
    schemaFromAvroString
    (const $ fail "cannot use as declaration")
  where
    schemaFromAvroString :: String -> Q Type
    schemaFromAvroString s =
      case decode (pack s) of
        Nothing           -> fail "could not parse avro spec!"
        Just (A.Union us) -> schemaFromAvro (toList us)
        Just t            -> schemaFromAvro [t]

-- | Imports an avro definition from a file as a 'Schema'.
avroFile :: QuasiQuoter
avroFile = quoteFile avro

-- | Reads a @.proto@ file and generates:
--   * A 'Mu.Schema.Definition.Schema' with all the message
--     types, using the name given as first argument.
--   * A 'Service' declaration for each service in the file,
--     where the name is obtained by applying the function
--     given as second argument to the name in the file.
avdl :: String -> String -> FilePath -> FilePath -> Q [Dec]
avdl schemaName serviceName baseDir initialFile
  = do r <- liftIO $ readWithImports baseDir initialFile
       case r of
         Left e
           -> fail ("could not parse protocol buffers spec: " ++ show e)
         Right p
           -> avdlToDecls schemaName serviceName p

avdlToDecls :: String -> String -> A.Protocol -> Q [Dec]
avdlToDecls schemaName serviceName protocol
  = do let schemaName'  = mkName schemaName
           serviceName' = mkName serviceName
       schemaDec <- tySynD schemaName' [] (schemaFromAvro (A.types protocol))
       serviceDec <- tySynD serviceName' []
         [t| 'Service $(textToStrLit (A.pname protocol)) $(pkgType (A.ns protocol))
                      $(typesToList <$> mapM (avroMethodToType schemaName') (A.messages protocol)) |]
       return [schemaDec, serviceDec]
  where
    pkgType Nothing = [t| '[] |]
    pkgType (Just (A.Namespace p))
                    = [t| '[ Package $(textToStrLit (T.intercalate "." p)) ] |]

schemaFromAvro :: [A.Type] -> Q Type
schemaFromAvro =
  (typesToList <$>) . mapM schemaDecFromAvroType . flattenAvroDecls

schemaDecFromAvroType :: A.Type -> Q Type
schemaDecFromAvroType (A.Record name _ _ _ fields) =
  [t|'DRecord $(textToStrLit $ A.baseName name)
              $(typesToList <$> mapM avroFieldToType fields)|]
  where
    avroFieldToType :: A.Field -> Q Type
    avroFieldToType field =
      [t|'FieldDef $(textToStrLit $ A.fldName field)
                   $(schemaFromAvroType $ A.fldType field)|]
schemaDecFromAvroType (A.Enum name _ _ symbols) =
  [t|'DEnum $(textToStrLit $ A.baseName name)
            $(typesToList <$> mapM avChoiceToType (toList symbols))|]
  where
    avChoiceToType :: T.Text -> Q Type
    avChoiceToType c = [t|'ChoiceDef $(textToStrLit c)|]
schemaDecFromAvroType t = [t|'DSimple $(schemaFromAvroType t)|]

-- | Turns a schema from Avro into a Template Haskell 'Type'.
schemaFromAvroType :: A.Type -> Q Type
schemaFromAvroType =
  \case
    A.Null -> [t|'TPrimitive 'TNull|]
    A.Boolean -> [t|'TPrimitive Bool|]
    A.Int -> [t|'TPrimitive Int32|]
    A.Long -> [t|'TPrimitive Int64|]
    A.Float -> [t|'TPrimitive Float|]
    A.Double -> [t|'TPrimitive Double|]
    A.Bytes -> [t|'TPrimitive B.ByteString|]
    A.String -> [t|'TPrimitive T.Text|]
    A.Array item -> [t|'TList $(schemaFromAvroType item)|]
    A.Map values -> [t|'TMap T.Text $(schemaFromAvroType values)|]
    A.NamedType typeName ->
      [t|'TSchematic $(textToStrLit (A.baseName typeName))|]
    A.Enum {} -> fail "should never happen, please, file an issue"
    A.Record {} -> fail "should never happen, please, file an issue"
    A.Union options ->
      case toList options of
        [A.Null, x] -> toOption x
        [x, A.Null] -> toOption x
        _ ->
          [t|'TUnion $(typesToList <$> mapM schemaFromAvroType (toList options))|]
      where toOption x = [t|'TOption $(schemaFromAvroType x)|]
    A.Fixed {} -> fail "fixed integers are not currently supported"

flattenAvroDecls :: [A.Type] -> [A.Type]
flattenAvroDecls = concatMap (uncurry (:) . flattenDecl)
  where
    flattenDecl :: A.Type -> (A.Type, [A.Type])
    flattenDecl (A.Record name a d o fields) =
      let (flds, tts) = unzip (flattenAvroField <$> fields)
       in (A.Record name a d o flds, concat tts)
    flattenDecl (A.Union _) = error "should never happen, please, file an issue"
    flattenDecl t = (t, [])
    flattenAvroType :: A.Type -> (A.Type, [A.Type])
    flattenAvroType (A.Record name a d o fields) =
      let (flds, tts) = unzip (flattenAvroField <$> fields)
       in (A.NamedType name, A.Record name a d o flds : concat tts)
    flattenAvroType (A.Union (toList -> ts)) =
      let (us, tts) = unzip (map flattenAvroType ts)
       in (A.Union $ fromList us, concat tts)
    flattenAvroType e@A.Enum {A.name} = (A.NamedType name, [e])
    flattenAvroType t = (t, [])
    flattenAvroField :: A.Field -> (A.Field, [A.Type])
    flattenAvroField f =
      let (t, decs) = flattenAvroType (A.fldType f)
       in (f {A.fldType = t}, decs)

avroMethodToType :: Name -> A.Method -> Q Type
avroMethodToType schemaName m
  = [t| 'Method $(textToStrLit (A.mname m)) '[]
                $(typesToList <$> mapM argToType (A.args m))
                $(retToType (A.result m)) |]
  where
    argToType :: A.Argument -> Q Type
    argToType (A.Argument (A.NamedType a) _)
      = [t| 'ArgSingle ('ViaSchema $(conT schemaName) $(textToStrLit (A.baseName a))) |]
    argToType (A.Argument _ _)
      = fail "only named types may be used as arguments"

    retToType :: A.Type -> Q Type
    retToType A.Null
      = [t| 'RetNothing |]
    retToType (A.NamedType a)
      = [t| 'RetSingle ('ViaSchema $(conT schemaName) $(textToStrLit (A.baseName a))) |]
    retToType _
      = fail "only named types may be used as results"

typesToList :: [Type] -> Type
typesToList = foldr (\y ys -> AppT (AppT PromotedConsT y) ys) PromotedNilT

textToStrLit :: T.Text -> Q Type
textToStrLit s = return $ LitT $ StrTyLit $ T.unpack s
