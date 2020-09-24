module Hasura.GraphQL.Execute.Query
  ( convertQuerySelSet
  -- , queryOpFromPlan
  -- , ReusableQueryPlan
  , GeneratedSqlMap
  , PreparedSql(..)
  , traverseQueryRootField -- for live query planning
  , irToRootFieldPlan
  , parseGraphQLQuery
  ) where

import qualified Data.Aeson                             as J
import qualified Data.Environment                       as Env
import qualified Data.HashMap.Strict                    as Map
import qualified Data.HashMap.Strict.InsOrd             as OMap
import qualified Data.IntMap                            as IntMap
import qualified Data.Sequence.NonEmpty                 as NESeq
import qualified Database.PG.Query                      as Q
import qualified Language.GraphQL.Draft.Syntax          as G
import qualified Network.HTTP.Client                    as HTTP
import qualified Network.HTTP.Types                     as HTTP

import qualified Hasura.GraphQL.Transport.HTTP.Protocol as GH
import qualified Hasura.Logging                         as L
import           Hasura.Server.Version                  (HasVersion)
import qualified Hasura.SQL.DML                         as S
import qualified Hasura.Tracing                         as Tracing

import           Hasura.Db
import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Execute.Action
import           Hasura.GraphQL.Execute.Prepare
import           Hasura.GraphQL.Execute.Remote
import           Hasura.GraphQL.Execute.Resolve
import           Hasura.GraphQL.Parser
import           Hasura.Prelude
import           Hasura.RQL.DML.RemoteJoin
import           Hasura.RQL.DML.Select                  (asSingleRowJsonResp)
import           Hasura.RQL.Types
import           Hasura.Session
import           Hasura.SQL.Value

import qualified Hasura.RQL.DML.Select                  as DS

data PreparedSql
  = PreparedSql
  { _psQuery       :: !Q.Query
  , _psPrepArgs    :: !PrepArgMap
  , _psRemoteJoins :: !(Maybe RemoteJoins)
  }
  deriving Show

-- | Required to log in `query-log`
instance J.ToJSON PreparedSql where
  toJSON (PreparedSql q prepArgs _) =
    J.object [ "query" J..= Q.getQueryText q
             , "prepared_arguments" J..= fmap (pgScalarValueToJson . snd) prepArgs
             ]

-- | The computed SQL with alias which can be logged. Nothing here represents no
-- SQL for cases like introspection responses. Tuple of alias to a (maybe)
-- prepared statement
type GeneratedSqlMap = HashMap G.Name (Maybe PreparedSql)

data RootFieldPlan
  = RFPPostgres !PreparedSql
  | RFPActionQuery !ActionExecuteTx

-- | Intermediate reperesentation of a computed SQL statement and prepared
-- arguments, or a raw bytestring (mostly, for introspection responses)
-- From this intermediate representation, a `LazyTx` can be generated, or the
-- SQL can be logged etc.
data ResolvedQuery
  = RRSql !PreparedSql
  | RRActionQuery !ActionExecuteTx

instance J.ToJSON RootFieldPlan where
  toJSON = \case
    RFPPostgres pgPlan -> J.toJSON pgPlan
    RFPActionQuery _   -> J.String "Action Execution Tx"

data ActionQueryPlan
  = AQPAsyncQuery !DS.AnnSimpleSel -- ^ Cacheable plan
  | AQPQuery !ActionExecuteTx -- ^ Non cacheable transaction

actionQueryToRootFieldPlan
  :: PrepArgMap -> ActionQueryPlan -> RootFieldPlan
actionQueryToRootFieldPlan prepped = \case
  AQPAsyncQuery s -> RFPPostgres $
    PreparedSql (DS.selectQuerySQL DS.JASSingleObject s) prepped Nothing
  AQPQuery tx     -> RFPActionQuery tx

-- See Note [Temporarily disabling query plan caching]
-- data ReusableVariableTypes
-- data ReusableVariableValues

-- data ReusableQueryPlan
--   = ReusableQueryPlan
--   { _rqpVariableTypes :: !ReusableVariableTypes
--   , _rqpFldPlans      :: !FieldPlans
--   }

-- instance J.ToJSON ReusableQueryPlan where
--   toJSON (ReusableQueryPlan varTypes fldPlans) =
--     J.object [ "variables"       J..= () -- varTypes
--              , "field_plans"     J..= fldPlans
--              ]

-- withPlan
--   :: (MonadError QErr m)
--   => SessionVariables -> PGPlan -> HashMap G.Name (WithScalarType PGScalarValue) -> m PreparedSql
-- withPlan usrVars (PGPlan q reqVars prepMap remoteJoins) annVars = do
--   prepMap' <- foldM getVar prepMap (Map.toList reqVars)
--   let args = withUserVars usrVars $ IntMap.elems prepMap'
--   return $ PreparedSql q args remoteJoins
--   where
--     getVar accum (var, prepNo) = do
--       let varName = G.unName var
--       colVal <- onNothing (Map.lookup var annVars) $
--         throw500 $ "missing variable in annVars : " <> varName
--       let prepVal = (toBinaryValue colVal, pstValue colVal)
--       return $ IntMap.insert prepNo prepVal accum

-- turn the current plan into a transaction
mkCurPlanTx
  :: ( HasVersion
     , MonadIO tx
     , MonadTx tx
     , Tracing.MonadTrace tx
     )
  => Env.Environment
  -> HTTP.Manager
  -> [HTTP.Header]
  -> UserInfo
  -> RootFieldPlan
  -> (tx EncJSON, Maybe PreparedSql)
mkCurPlanTx env manager reqHdrs userInfo fldPlan =
  -- generate the SQL and prepared vars or the bytestring
  let (tx, prep) = case fldPlan of
        RFPPostgres (PreparedSql q prepMap remoteJoins) ->
          let args = withUserVars (_uiSession userInfo) prepMap
              ps = PreparedSql q args remoteJoins
          in (RRSql ps, Just ps)
        RFPActionQuery atx -> (RRActionQuery atx, Nothing)
  in (mkLazyRespTx env manager reqHdrs userInfo tx, prep)

-- convert a query from an intermediate representation to... another
irToRootFieldPlan
  :: PrepArgMap
  -> QueryDB S.SQLExp -> PreparedSql
irToRootFieldPlan prepped = \case
  QDBSimple s      -> mkPreparedSql getRemoteJoins (DS.selectQuerySQL DS.JASMultipleRows) s
  QDBPrimaryKey s  -> mkPreparedSql getRemoteJoins (DS.selectQuerySQL DS.JASSingleObject) s
  QDBAggregation s -> mkPreparedSql getRemoteJoinsAggregateSelect DS.selectAggregateQuerySQL s
  QDBConnection s  -> mkPreparedSql getRemoteJoinsAggregateSelect DS.connectionSelectQuerySQL s
  where
    mkPreparedSql get f simpleSel =
      let (simpleSel',remoteJoins) = get simpleSel
      in PreparedSql (f simpleSel') prepped remoteJoins

traverseQueryRootField
  :: forall f a b c d h
   . Applicative f
  => (a -> f b)
  -> RootField (QueryDB a) c h d
  -> f (RootField (QueryDB b) c h d)
traverseQueryRootField f = traverseDB \case
  QDBSimple s       -> QDBSimple      <$> DS.traverseAnnSimpleSelect f s
  QDBPrimaryKey s   -> QDBPrimaryKey  <$> DS.traverseAnnSimpleSelect f s
  QDBAggregation s  -> QDBAggregation <$> DS.traverseAnnAggregateSelect f s
  QDBConnection s   -> QDBConnection  <$> DS.traverseConnectionSelect f s

parseGraphQLQuery
  :: MonadError QErr m
  => GQLContext
  -> [G.VariableDefinition]
  -> Maybe (HashMap G.Name J.Value)
  -> G.SelectionSet G.NoFragments G.Name
  -> m ( InsOrdHashMap G.Name (QueryRootField UnpreparedValue)
       , QueryReusability
       )
parseGraphQLQuery gqlContext varDefs varValsM fields =
  resolveVariables varDefs (fromMaybe Map.empty varValsM) fields
  >>= (gqlQueryParser gqlContext >>> (`onLeft` reportParseErrors))
  where
    reportParseErrors errs = case NESeq.head errs of
      -- TODO: Our error reporting machinery doesn’t currently support reporting
      -- multiple errors at once, so we’re throwing away all but the first one
      -- here. It would be nice to report all of them!
      ParseError{ pePath, peMessage, peCode } ->
        throwError (err400 peCode peMessage){ qePath = pePath }

convertQuerySelSet
  :: forall m tx .
     ( MonadError QErr m
     , HasVersion
     , MonadIO m
     , Tracing.MonadTrace m
     , MonadIO tx
     , MonadTx tx
     , Tracing.MonadTrace tx
     )
  => Env.Environment
  -> L.Logger L.Hasura
  -> GQLContext
  -> UserInfo
  -> HTTP.Manager
  -> HTTP.RequestHeaders
  -> G.SelectionSet G.NoFragments G.Name
  -> [G.VariableDefinition]
  -> Maybe GH.VariableValues
  -> m ( ExecutionPlan (tx EncJSON, Maybe PreparedSql) RemoteCall J.Value
       -- , Maybe ReusableQueryPlan
       , [QueryRootField UnpreparedValue]
       )
convertQuerySelSet env logger gqlContext userInfo manager reqHeaders fields varDefs varValsM = do
  -- Parse the GraphQL query into the RQL AST
  (unpreparedQueries, _reusability) <- parseGraphQLQuery gqlContext varDefs varValsM fields

  -- Transform the RQL AST into a prepared SQL query
  queryPlan <- for unpreparedQueries \unpreparedQuery -> do
    (preparedQuery, PlanningSt _ _ planVals expectedVariables)
      <- flip runStateT initPlanningSt
         $ traverseQueryRootField prepareWithPlan unpreparedQuery
           >>= traverseAction convertActionQuery
    validateSessionVariables expectedVariables $ _uiSession userInfo
    traverseDB (pure . irToRootFieldPlan planVals) preparedQuery
      >>= traverseAction (pure . actionQueryToRootFieldPlan planVals)

  -- Transform the query plans into an execution plan
  let executionPlan = queryPlan <&> \case
        RFRemote (remoteSchemaInfo, remoteField) ->
          buildTypedOperation
            remoteSchemaInfo
            G.OperationTypeQuery
            varDefs
            [G.SelectionField remoteField]
            varValsM
        RFDB db      -> ExecStepDB $ mkCurPlanTx env manager reqHeaders userInfo (RFPPostgres db)
        RFAction rfp -> ExecStepDB $ mkCurPlanTx env manager reqHeaders userInfo rfp
        RFRaw r      -> ExecStepRaw r

  let asts :: [QueryRootField UnpreparedValue]
      asts = OMap.elems unpreparedQueries
  pure (OMap.mapKeys G.unName executionPlan, asts)  -- See Note [Temporarily disabling query plan caching]
  where
    usrVars = _uiSession userInfo

    convertActionQuery
      :: ActionQuery UnpreparedValue -> StateT PlanningSt m ActionQueryPlan
    convertActionQuery = \case
      AQQuery s -> lift $ do
        result <- resolveActionExecution env logger userInfo s $ ActionExecContext manager reqHeaders usrVars
        pure $ AQPQuery $ _aerTransaction result
      AQAsync s -> AQPAsyncQuery <$>
        DS.traverseAnnSimpleSelect prepareWithPlan (resolveAsyncActionQuery userInfo s)

-- See Note [Temporarily disabling query plan caching]
-- use the existing plan and new variables to create a pg query
-- queryOpFromPlan
--   :: ( HasVersion
--      , MonadError QErr m
--      , Tracing.MonadTrace m
--      , MonadIO tx
--      , MonadTx tx
--      , Tracing.MonadTrace tx
--      )
--   => Env.Environment
--   -> HTTP.Manager
--   -> [HTTP.Header]
--   -> UserInfo
--   -> Maybe GH.VariableValues
--   -> ReusableQueryPlan
--   -> m (tx EncJSON, GeneratedSqlMap)
-- queryOpFromPlan env  manager reqHdrs userInfo varValsM (ReusableQueryPlan varTypes fldPlans) = do
--   validatedVars <- _validateVariablesForReuse varTypes varValsM
--   -- generate the SQL and prepared vars or the bytestring
--   resolved <- forM fldPlans $ \(alias, fldPlan) ->
--     (alias,) <$> case fldPlan of
--       RFPRaw resp        -> return $ RRRaw resp
--       RFPPostgres pgPlan -> RRSql <$> withPlan (_uiSession userInfo) pgPlan validatedVars

--   (,) <$> mkLazyRespTx env manager reqHdrs userInfo resolved <*> pure (mkGeneratedSqlMap resolved)

mkLazyRespTx
  :: ( HasVersion
     , MonadIO tx
     , MonadTx tx
     , Tracing.MonadTrace tx
     )
  => Env.Environment
  -> HTTP.Manager
  -> [HTTP.Header]
  -> UserInfo
  -> ResolvedQuery
  -> tx EncJSON
mkLazyRespTx env manager reqHdrs userInfo node = do
  case node of
    RRSql (PreparedSql q args maybeRemoteJoins) -> do
      -- TODO this quietly assumes the intmap keys are contiguous
      let prepArgs = fst <$> IntMap.elems args
      case maybeRemoteJoins of
        Nothing -> Tracing.trace "Postgres" . liftTx $ asSingleRowJsonResp q prepArgs
        Just remoteJoins ->
          executeQueryWithRemoteJoins env manager reqHdrs userInfo q prepArgs remoteJoins
    RRActionQuery actionTx           -> actionTx
