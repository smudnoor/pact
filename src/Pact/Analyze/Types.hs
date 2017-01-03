{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

module Pact.Analyze.Types where

import Control.Monad.Trans.Reader
import Control.Lens hiding ((.=))
import Pact.Typecheck
import Pact.Types
import Data.Either
import Data.Decimal
import Data.Aeson
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>),(<$$>))
import Text.Show.Prettyprint (prettyShow, prettyPrint)

import SmtLib.Syntax.Syntax
import SmtLib.Parsers.CommandsParsers (parseCommand)
import Text.Parsec (parse)
import qualified SmtLib.Syntax.Syntax as Smt
import qualified SmtLib.Syntax.ShowSL as SmtShow

import qualified Data.ByteString.Char8 as BS8
import qualified Data.Yaml as Yaml
import qualified Text.Parsec as Parsec
import qualified SmtLib.Parsers.CommandsParsers as SmtParser

data SymType = SymInteger
  | SymDecimal
  | SymBool
  | SymString
  deriving (Show, Eq, Ord)

newtype SymName = SymName { unSymName :: String } deriving (Show, Eq)

data TrackingStatus = Tracked
  | Untracked {_tWhy :: String}
  | LostTrack {_tWhy :: String}
  deriving (Show, Eq)

data SymVar = SymVar
  { _svName :: SymName
  , _svType :: Maybe SymType
  , _svTracked :: TrackingStatus
  } deriving (Show, Eq)
makeLenses ''SymVar

data ProverCtx = ProverCtx
  { _pcInputArgs :: Map TcId SymVar
  } deriving (Show, Eq)
makeLenses ''ProverCtx

data ProverState = ProverState
  { _psVars :: Map TcId SymVar
  , _psNodeSMT :: [Smt.Command]
  } deriving (Show, Eq)
makeLenses ''ProverState

instance ToJSON ProverState where
  toJSON ProverState{..} = do
    let declrs = init . SmtShow.showSL <$> rights (symVarToDeclareConst <$> Map.elems _psVars)
    toJSON $ declrs ++ (SmtShow.showSL <$> _psNodeSMT)

data SymAst =
  IfBranch
    { _ifbrCond :: Smt.Term
    , _ifbrTrue :: SymAst
    , _ifbrFalse :: SymAst
    , _saProverState :: ProverState } |
  OrErrorBranch
    { _elWhy :: String
    , _saProverState :: ProverState } |
  ErrorLeaf
    { _elWhy :: String
    , _saProverState :: ProverState } |
  ConcreteReturnLeaf
    { _crlResult :: Literal
    , _saProverState :: ProverState } |
  CannotAnalyze
    { _elWhy :: String
    , _saProverState :: ProverState }
  deriving (Show, Eq)

instance ToJSON SymAst where
  toJSON IfBranch{..} =
    object [ "node" .= ("ifBranch" :: String)
           , "state" .= _saProverState
           , "cond" .= (SmtShow.showSL _ifbrCond)
           , "true" .= _ifbrTrue
           , "false" .= _ifbrFalse
           ]
  toJSON OrErrorBranch{..} =
    object [ "node" .= ("OrError" :: String)
           , "state" .= _saProverState
           , "why" .= _elWhy
           ]
  toJSON ErrorLeaf{..} =
    object [ "node" .= ("Error" :: String)
           , "state" .= _saProverState
           , "why" .= _elWhy
           ]
  toJSON ConcreteReturnLeaf{..} =
    object [ "node" .= ("Return" :: String)
           , "state" .= _saProverState
           , "return" .= _crlResult
           ]
  toJSON CannotAnalyze{..} =
    object [ "node" .= ("CannotAnalyze" :: String)
           , "state" .= _saProverState
           , "why" .= _elWhy
           ]

ppSymAst :: SymAst -> IO ()
ppSymAst = BS8.putStrLn . Yaml.encode

type PactAnalysis a = ReaderT ProverState IO a

data LitVal =
    LVDecimal Decimal
  | LVBool Bool
  | LVInteger Integer


isCmpOperator :: String -> Bool
isCmpOperator s = Set.member s $ Set.fromList [">", "<", ">=", "<=", "="]

isLogicalOperator :: String -> Bool
isLogicalOperator s = Set.member s $ Set.fromList ["=", "and", "or", "not"]

isBasicOperator :: String -> Bool
isBasicOperator s = isCmpOperator s || isLogicalOperator s

basicOperatorToQualId :: String -> Either String QualIdentifier
basicOperatorToQualId o
  | o == ">" = Right $ QIdentifier $ ISymbol ">"
  | o == ">=" = Right $ QIdentifier $ ISymbol ">="
  | o == "<" = Right $ QIdentifier $ ISymbol "<"
  | o == "<=" = Right $ QIdentifier $ ISymbol "<="
  | o == "=" = Right $ QIdentifier $ ISymbol "="
  | o == "and" = Right $ QIdentifier $ ISymbol "and"
  | o == "or" = Right $ QIdentifier $ ISymbol "or"
  | o == "not" = Right $ QIdentifier $ ISymbol "not"
  | otherwise = Left $ "Operator " ++ o ++ " is not yet supported!"

isAppView :: AST (TcId, Type) -> (Bool, AST (TcId, Type))
isAppView app@(App _ _ _) = (True, app)
isAppView _ = (False, undefined)

pattern NativeFunc f <- (FNative _ f _ _)

pattern Args_Var var <- [(Var _ var)]
pattern Args_Lit lit <- [(Lit _ _ (LVLit (lit)))]
pattern Args_Var_Var var1 var2 <- [(Var _ var1),(Var _ var2)]
pattern Args_Var_Lit var lit <- [(Var _ var),(Lit _ _ (LVLit (lit)))]
pattern Args_Lit_Var lit var <- [(Lit _ _ (LVLit (lit))),(Var _ var)]
pattern Args_App_App app1 app2 <- [(isAppView -> (True, app1)),(isAppView -> (True, app2))]
pattern Args_App_Lit_Var app' lit var <- [app',(Lit _ _ (LVLit (lit))),(Var _ var)]
pattern Args_App_Lit_Lit app' lit1 lit2 <- [app',(Lit _ _ (LVLit (lit1))),(Lit _ _ (LVLit (lit2)))]

pattern NativeFunc_Lit_Var f lit' var' <- (App _ (NativeFunc f) (Args_Lit_Var lit' var'))
pattern NativeFunc_Var_Lit f var' lit' <- (App _ (NativeFunc f) (Args_Var_Lit var' lit'))
pattern NativeFunc_App_App f app1 app2 <- (App _ (NativeFunc f) (Args_App_App app1 app2))
pattern IF_App_Lit_Lit app' lit1 lit2 <- (App _ (NativeFunc "if") (Args_App_Lit_Lit app' lit1 lit2))

varToTerm :: TcId -> PactAnalysis (Either String Smt.Term)
varToTerm n = do
  sVar <- Map.lookup n <$> view psVars
  return $ case sVar of
    Nothing -> Left $ "Variable " ++ show n ++ "not found!"
    Just SymVar{..} -> case _svTracked of
      Tracked -> Right $ TermQualIdentifier $ QIdentifier $ ISymbol $ unSymName _svName
      err -> Left $ "Variable found but tracking has failed: " ++ show err

literalToTerm :: Literal -> Either String Smt.Term
literalToTerm (LBool v) = Right $ TermQualIdentifier $ QIdentifier $ ISymbol (if v then "true" else "false")
literalToTerm (LString v) = Right $ TermSpecConstant $ SpecConstantString $ show v
literalToTerm (LInteger v) = Right $ TermSpecConstant $ SpecConstantNumeral v
literalToTerm (LDecimal v) = Right $ TermSpecConstant $ SpecConstantDecimal $ show v
literalToTerm (LTime _) = Left $ "Time base proving is currently unsupported"

booleanAstToTerm :: AST (TcId, Type) -> PactAnalysis (Either String Smt.Term)
booleanAstToTerm (NativeFunc_Var_Lit f v@(name', _) l)
  | isBasicOperator f = do
      varAsTerm <- varToTerm name'
      litAsTerm <- return $ literalToTerm l
      op <- return $ basicOperatorToQualId f
      case (op, varAsTerm, litAsTerm) of
        (Right op', Right v', Right l') -> return $ Right $ TermQualIdentifierT op' [v', l']
        err -> return $ Left $ "unable to analyze: " ++ show err
  | otherwise = return $ Left $ "Function " ++ show f ++ " is unsupported"
booleanAstToTerm (NativeFunc_Lit_Var f l v@(name', _))
  | isBasicOperator f = do
      varAsTerm <- varToTerm name'
      litAsTerm <- return $ literalToTerm l
      op <- return $ basicOperatorToQualId f
      case (op, litAsTerm, varAsTerm) of
        (Right op', Right l', Right v') -> return $ Right $ TermQualIdentifierT op' [l',v']
        err -> return $ Left $ "unable to analyze: " ++ show err
  | otherwise = return $ Left $ "Function " ++ show f ++ " is unsupported"
booleanAstToTerm (NativeFunc_App_App f app1 app2)
  | isLogicalOperator f = do
      app1' <- booleanAstToTerm app1
      app2' <- booleanAstToTerm app2
      op <- return $ basicOperatorToQualId f
      case (op, app1', app2') of
        (Right op', Right app1'', Right app2'') -> return $ Right $ TermQualIdentifierT op' [app1'', app2'']
        err -> return $ Left $ "unable to analyze: " ++ show err
booleanAstToTerm err = return $ Left "Unsupported construct found when constructing boolean-expr node"

negateBoolAstTerm :: Smt.Term -> Smt.Term
negateBoolAstTerm t = TermQualIdentifierT (QIdentifier (ISymbol "not")) [t]

boolTermToAssertion :: Smt.Term -> Command
boolTermToAssertion t = Assert t

negateAssertion :: Command -> Command
negateAssertion (Assert t) = Assert $ negateBoolAstTerm t

convertName :: TcId -> SymName
convertName = SymName . show

convertType :: Type -> Maybe SymType
convertType TyInteger = Just SymInteger
convertType TyBool = Just SymBool
convertType TyDecimal = Just SymDecimal
convertType TyString = Just SymString
convertType _ = Nothing

symTypeToSortId :: SymType -> Either String Sort
symTypeToSortId SymInteger = Right $ SortId $ ISymbol "Int"
symTypeToSortId SymBool = Right $ SortId $ ISymbol "Bool"
symTypeToSortId SymDecimal = Right $ SortId $ ISymbol "Real"
symTypeToSortId SymString = Right $ SortId $ ISymbol "String"

constructSymVar :: (TcId, Type) -> SymVar
constructSymVar (name', type') = newVar
  where
    convType = convertType type'
    convName = convertName name'
    trackingStatus = case convType of
      Nothing -> Untracked "Unsupported Type"
      Just _ -> Tracked
    newVar = SymVar { _svName = convName, _svType = convType, _svTracked = trackingStatus}

symVarToDeclareConst :: SymVar -> Either String Command
symVarToDeclareConst SymVar{..} = case _svType of
  Nothing -> Left $ "SymVar Type is unsupported"
  Just t' -> symTypeToSortId t' >>= return . DeclareFun (unSymName _svName) []

analyzeFunction :: Fun (TcId, Type) -> IO (Either String SymAst)
analyzeFunction (FDefun _ name' _ args' bdy') = do
  initialState <- return $ ProverState (Map.fromList $ (\x -> (fst x, constructSymVar x)) <$> args') []
  runReaderT (analyze bdy') initialState

analyze :: [AST (TcId, Type)] -> PactAnalysis (Either String SymAst)
analyze ((IF_App_Lit_Lit app' lit1 lit2):rest) = do
  initialState <- ask
  branchPoint <- booleanAstToTerm app'
  case branchPoint of
    Left err -> return $ Left err
    Right smtTerm -> do
      trueAssert <- return $ boolTermToAssertion smtTerm
      falseAssert <- return $ negateAssertion trueAssert
      return $ Right $ IfBranch
        { _ifbrCond = smtTerm
        , _ifbrTrue = ConcreteReturnLeaf { _crlResult = lit1
                                         , _saProverState = appendSmtCmds [trueAssert] initialState}
        , _ifbrFalse = ConcreteReturnLeaf { _crlResult = lit2
                                         , _saProverState = appendSmtCmds [falseAssert] initialState}
        , _saProverState = initialState
        }

appendSmtCmds :: [Command] -> ProverState -> ProverState
appendSmtCmds cmds ps@ProverState{..} = ps { _psNodeSMT = _psNodeSMT ++ cmds }

-- helper stuff
_parseSmtCmd :: String -> Smt.Command
_parseSmtCmd s = let (Right f) = Parsec.parse SmtParser.parseCommand "" s in f


_inferGtTen :: IO (Either (String, Fun TcId) (Fun (TcId, Type)), TcState)
_inferGtTen = _infer "examples/analyze-tests/analyze-tests.repl" "analyze-tests" "gt-ten"

_getGtTenFun :: IO (Fun (TcId, Type))
_getGtTenFun = do
  (Right f, _) <- _inferGtTen
  return f

_getSampFunc :: String -> IO (Fun (TcId, Type))
_getSampFunc s = do
  (Right f, _) <- _infer "examples/analyze-tests/analyze-tests.repl" "analyze-tests" s
  return f

_analyzeSampFunc :: String -> IO ()
_analyzeSampFunc s = do
  a <- _getSampFunc s
  b <- analyzeFunction a
  case b of
    Left err -> putStrLn $ "Analysis Failed: " ++ show err
    Right v -> ppSymAst v
