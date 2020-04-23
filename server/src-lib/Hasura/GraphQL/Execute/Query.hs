module Hasura.GraphQL.Execute.Query
  ( convertQuerySelSet
  , queryOpFromPlan
  , ReusableQueryPlan
  , GeneratedSqlMap
  , PreparedSql(..)
  ) where

import qualified Data.Aeson                             as J
import qualified Data.ByteString                        as B
import qualified Data.ByteString.Lazy                   as LBS
import qualified Data.HashMap.Strict                    as Map
import qualified Data.IntMap                            as IntMap
import qualified Data.TByteString                       as TBS
import qualified Database.PG.Query                      as Q
import qualified Language.GraphQL.Draft.Syntax          as G

import           Control.Lens                           ((^?))
import           Data.Has

import qualified Hasura.GraphQL.Resolve                 as R
import qualified Hasura.GraphQL.Transport.HTTP.Protocol as GH
import qualified Hasura.GraphQL.Validate                as GV
import qualified Hasura.GraphQL.Validate.Field          as V
import qualified Hasura.SQL.DML                         as S

import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Resolve.Action
import           Hasura.GraphQL.Resolve.Types
import           Hasura.GraphQL.Validate.Types
import           Hasura.Prelude
import           Hasura.RQL.DML.Select                  (asSingleRowJsonResp)
import           Hasura.RQL.Types
import           Hasura.Server.Version                  (HasVersion)
import           Hasura.Session
import           Hasura.SQL.Types
import           Hasura.SQL.Value

type PlanVariables = Map.HashMap G.Variable Int

-- | The value is (Q.PrepArg, PGScalarValue) because we want to log the human-readable value of the
-- prepared argument and not the binary encoding in PG format
type PrepArgMap = IntMap.IntMap (Q.PrepArg, PGScalarValue)

horizontalComposition :: PlanVariables -> PrepArgMap -> Map.HashMap G.Variable (Q.PrepArg, PGScalarValue)
horizontalComposition plan prep =
  Map.mapMaybe (\index -> IntMap.lookup index prep) plan

data PGPlan
  = PGPlan
  { _ppQuery     :: !Q.Query
  , _ppVariables :: !PlanVariables
  , _ppPrepared  :: !PrepArgMap
  }

instance J.ToJSON PGPlan where
  toJSON (PGPlan q vars prepared) =
    J.object [ "query"     J..= Q.getQueryText q
             , "variables" J..= vars
             , "prepared"  J..= fmap show prepared
             ]

data RootFieldPlan
  = RFPRaw !B.ByteString
  | RFPPostgres !PGPlan

fldPlanFromJ :: (J.ToJSON a) => a -> RootFieldPlan
fldPlanFromJ = RFPRaw . LBS.toStrict . J.encode

instance J.ToJSON RootFieldPlan where
  toJSON = \case
    RFPRaw encJson     -> J.toJSON $ TBS.fromBS encJson
    RFPPostgres pgPlan -> J.toJSON pgPlan

type FieldPlans = [(G.Alias, RootFieldPlan)]

data ReusableQueryPlan
  = ReusableQueryPlan
  { _rqpVariableTypes :: !ReusableVariableTypes
  , _rqpFldPlans      :: !FieldPlans
  }

instance J.ToJSON ReusableQueryPlan where
  toJSON (ReusableQueryPlan varTypes fldPlans) =
    J.object [ "variables"       J..= varTypes
             , "field_plans"     J..= fldPlans
             ]

withPlan
  :: (MonadError QErr m)
  => SessionVariables -> PGPlan -> Map.HashMap G.Variable (Q.PrepArg, PGScalarValue)
  -> m SafePreparedSql
withPlan usrVars (PGPlan q reqVars prepMap) annVars = do
  prepMap' <- foldM getVar prepMap (Map.toList reqVars)
  let args = withUserVars usrVars $ DataArgs $ IntMap.elems prepMap'
  return $ SafePreparedSql q args
  where
    getVar accum (var, prepNo) = do
      let varName = G.unName $ G.unVariable var
      colVal <- onNothing (Map.lookup var annVars) $
        throw500 $ "missing variable in annVars : " <> varName

      return $ IntMap.insert prepNo colVal accum

-- turn the current plan into a transaction
mkCurPlanTx
  :: (MonadError QErr m)
  => SessionVariables
  -> FieldPlans
  -> m (LazyRespTx, GeneratedSqlMap)
mkCurPlanTx usrVars fldPlans = do
  -- generate the SQL and prepared vars or the bytestring
  resolved <- forM fldPlans $ \(alias, fldPlan) -> do
    fldResp <- case fldPlan of
      RFPRaw resp                      -> return $ SRRRaw resp
      RFPPostgres (PGPlan q _ prepMap) -> do
        let args = withSessionVariables usrVars $ DataArgs $ IntMap.elems prepMap
        return $ SRRSql $ SafePreparedSql q args
    return (alias, fldResp)

  return (mkLazyRespTx resolved, mkGeneratedSqlMap resolved)

-- | A plan of variables getting passed to a prepared statement. Note
-- that the argument indices are 1-indexed in PostgreSQL, and we
-- always pass the current user session variable as a first argument,
-- so that the next argument number should be 2, as is reflected in
-- 'initPlanningSt'.
data PlanningSt
  = PlanningSt
  { _psArgNumber :: !Int
  -- ^ Next index for a newly added variable
  , _psVariables :: !PlanVariables
  -- ^ Mapping from variable names to variable indices
  , _psPrepped   :: !PrepArgMap
  -- ^ Mapping from variable indices to default values including debug info
  }

initPlanningSt :: PlanningSt
initPlanningSt =
  PlanningSt 2 Map.empty IntMap.empty

getVarArgNum :: (MonadState PlanningSt m) => G.Variable -> m Int
getVarArgNum var = do
  PlanningSt curArgNum vars prepped <- get
  case Map.lookup var vars of
    Just argNum -> pure argNum
    Nothing     -> do
      put $ PlanningSt (curArgNum + 1) (Map.insert var curArgNum vars) prepped
      pure curArgNum

addPrepArg
  :: (MonadState PlanningSt m)
  => Int -> (Q.PrepArg, PGScalarValue) -> m ()
addPrepArg argNum arg = do
  PlanningSt curArgNum vars prepped <- get
  put $ PlanningSt curArgNum vars $ IntMap.insert argNum arg prepped

getNextArgNum :: (MonadState PlanningSt m) => m Int
getNextArgNum = do
  PlanningSt curArgNum vars prepped <- get
  put $ PlanningSt (curArgNum + 1) vars prepped
  return curArgNum

prepareWithPlan :: (MonadState PlanningSt m) => UnresolvedVal -> m S.SQLExp
prepareWithPlan = \case
  R.UVPG annPGVal -> do
    let AnnPGVal varM _ colVal = annPGVal
    argNum <- case varM of
      Just var -> getVarArgNum var
      Nothing  -> getNextArgNum
    addPrepArg argNum (toBinaryValue colVal, pstValue colVal)
    return $ toPrepParam argNum (pstType colVal)

  R.UVSessVar ty sessVar -> do
    let sessVarVal =
          S.SEOpApp (S.SQLOp "->>")
          [currentSession, S.SELit $ sessionVariableToText sessVar]
    return $ flip S.SETyAnn (S.mkTypeAnn ty) $ case ty of
      PGTypeScalar colTy -> withConstructorFn colTy sessVarVal
      PGTypeArray _      -> sessVarVal

  R.UVSQL sqlExp -> pure sqlExp
  R.UVSession    -> pure currentSession
  where
    -- We always pass the session variable as the first argument
    currentSession = S.SEPrep 1

convertQuerySelSet
  :: ( MonadError QErr m
     , MonadReader r m
     , Has TypeMap r
     , Has QueryCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has UserInfo r
     , HasVersion
     , MonadIO m
     )
  => QueryReusability
  -> V.SelSet
  -> QueryActionExecuter
  -> m (LazyRespTx, Maybe ReusableQueryPlan, GeneratedSqlMap)
convertQuerySelSet initialReusability fields actionRunner = do
  usrVars <- asks (_uiSession . getter)
  (fldPlans, finalReusability) <- runReusabilityTWith initialReusability $
    forM (toList fields) $ \fld -> do
      fldPlan <- case V._fName fld of
        "__type"     -> fldPlanFromJ <$> R.typeR fld
        "__schema"   -> fldPlanFromJ <$> R.schemaR fld
        "__typename" -> pure $ fldPlanFromJ queryRootNamedType
        _            -> do
          unresolvedAst <- R.queryFldToPGAST fld actionRunner
          (q, PlanningSt _ vars prepped) <- flip runStateT initPlanningSt $
            R.traverseQueryRootFldAST prepareWithPlan unresolvedAst
          pure . RFPPostgres $ PGPlan (R.toPGQuery q) vars prepped
      pure (V._fAlias fld, fldPlan)
  let varTypes = finalReusability ^? _Reusable
      reusablePlan = ReusableQueryPlan <$> varTypes <*> pure fldPlans
  (tx, sql) <- mkCurPlanTx usrVars fldPlans
  pure (tx, reusablePlan, sql)

-- use the existing plan and new variables to create a pg query
queryOpFromPlan
  :: (MonadError QErr m)
  => SessionVariables
  -> Maybe GH.VariableValues
  -> ReusableQueryPlan
  -> m (LazyRespTx, GeneratedSqlMap)
queryOpFromPlan usrVars varValsM (ReusableQueryPlan varTypes fldPlans) = do
  -- generate the SQL and prepared vars or the bytestring
  resolved <- forM fldPlans $ \(alias, fldPlan) ->
    (alias,) <$> case fldPlan of
      RFPRaw resp -> return $ SRRRaw resp
      RFPPostgres pgPlan@(PGPlan _ plan prep) -> do
        validatedVars <- GV.validateVariablesForReuse varTypes (horizontalComposition plan prep) varValsM
        SRRSql <$> withPlan usrVars pgPlan validatedVars

  return (mkLazyRespTx resolved, mkGeneratedSqlMap resolved)


data PreparedSql
  = PreparedSql
  { _psQuery    :: !Q.Query
  , _psPrepArgs :: ![(Q.PrepArg, PGScalarValue)]
    -- ^ The value is (Q.PrepArg, PGScalarValue) because we want to log the human-readable value of the
    -- prepared argument (PGScalarValue) and not the binary encoding in PG format (Q.PrepArg)
  }

newtype DataArgs
  = DataArgs { unDataArgs :: [(Q.PrepArg, PGScalarValue)] }
-- ^ The value is (Q.PrepArg, PGScalarValue) because we want to log the human-readable value of the
-- prepared argument (PGScalarValue) and not the binary encoding in PG format (Q.PrepArg)

newtype UserArgs = UserArgs (Q.PrepArg, PGScalarValue)

data SafePreparedArgs
  = SafePreparedArgs
  { _spaUserArgs:: UserArgs
  , _spaDataArgs:: DataArgs
  }

withUserVars :: UserVars -> DataArgs -> SafePreparedArgs
withUserVars usrVars dataArgs =
  let usrVarsAsPgScalar = PGValJSON $ Q.JSON $ J.toJSON usrVars
      prepArg = Q.toPrepVal (Q.AltJ usrVars)
  in SafePreparedArgs (UserArgs (prepArg, usrVarsAsPgScalar)) dataArgs

data SafePreparedSql
  = SafePreparedSql
  { _spsQuery    :: !Q.Query
  , _spsPrepArgs :: !SafePreparedArgs
  }

-- | Required to log in `query-log`
instance J.ToJSON PreparedSql where
  toJSON (PreparedSql q prepArgs) =
    J.object [ "query" J..= Q.getQueryText q
             , "prepared_arguments" J..= map (txtEncodedPGVal . snd) prepArgs
             ]

-- | Intermediate reperesentation of a computed SQL statement and prepared
-- arguments, or a raw bytestring (mostly, for introspection responses)
-- From this intermediate representation, a `LazyTx` can be generated, or the
-- SQL can be logged etc.
data ResolvedQuery
  = RRRaw !B.ByteString
  | RRSql !PreparedSql

data SafeResolvedQuery
  = SRRRaw !B.ByteString
  | SRRSql !SafePreparedSql

-- | The computed SQL with alias which can be logged. Nothing here represents no
-- SQL for cases like introspection responses. Tuple of alias to a (maybe)
-- prepared statement
type GeneratedSqlMap = [(G.Alias, Maybe PreparedSql)]

mkLazyRespTx :: [(G.Alias, SafeResolvedQuery)] -> LazyRespTx
mkLazyRespTx resolved =
  fmap encJFromAssocList $ forM resolved $ \(alias, node) -> do
    resp <- case node of
      SRRRaw bs
        -> return $ encJFromBS bs
      SRRSql (SafePreparedSql q (SafePreparedArgs (UserArgs userArgs) (DataArgs dataArgs)))
        -> liftTx $ asSingleRowJsonResp q (map fst (userArgs:dataArgs))
    return (G.unName $ G.unAlias alias, resp)

mkGeneratedSqlMap :: [(G.Alias, SafeResolvedQuery)] -> GeneratedSqlMap
mkGeneratedSqlMap resolved =
  flip map resolved $ \(alias, node) ->
    let res = case node of
                SRRRaw _
                  -> Nothing
                SRRSql (SafePreparedSql q (SafePreparedArgs (UserArgs userArgs) (DataArgs dataArgs)))
                  -> Just (PreparedSql q (userArgs:dataArgs))
    in (alias, res)
