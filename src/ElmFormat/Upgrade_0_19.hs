{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE FlexibleInstances #-}
module ElmFormat.Upgrade_0_19 (transform) where

import AST.V0_16
import AST.Expression
import AST.Pattern
import AST.Variable
import Reporting.Annotation (Located(A))

import qualified Data.Map.Strict as Dict
import qualified Data.Maybe as Maybe
import qualified ElmFormat.Version
import qualified Reporting.Annotation as RA
import qualified Reporting.Region as Region
import qualified ReversedList


transform ::
    Dict.Map LowercaseIdentifier [UppercaseIdentifier]
    -> Dict.Map [UppercaseIdentifier] UppercaseIdentifier
    -> Expr -> Expr
transform exposed importAliases expr =
    let
        basicsReplacements =
            Dict.fromList
              [ ( "flip"
                , Lambda
                    [makeArg "f", makeArg "b", makeArg "a"] []
                    (noRegion $ App
                        (makeVarRef "f")
                        [([], makeVarRef "a"), ([], makeVarRef "b")]
                        (FAJoinFirst JoinAll)
                    )
                    False
                )
              , ( "curry"
                , Lambda
                    [makeArg "f", makeArg "a", makeArg "b"] []
                    (noRegion $ App
                        (makeVarRef "f")
                        [([], noRegion $ AST.Expression.Tuple
                            [ Commented [] (makeVarRef "a") []
                            , Commented [] (makeVarRef "b") []
                            ] False
                        )]
                        (FAJoinFirst JoinAll)
                    )
                    False
                )
              , ( "uncurry"
                , Lambda
                    [makeArg "f", ([], noRegion $ AST.Pattern.Tuple [makeArg' "a", makeArg' "b"]) ] []
                    (noRegion $ App
                        (makeVarRef "f")
                        [ ([], makeVarRef "a")
                        , ([], makeVarRef "b")
                        ]
                        (FAJoinFirst JoinAll)
                    )
                    False
                )
              , ( "rem"
                , Lambda
                    [makeArg "dividend", makeArg "divisor"] []
                    (noRegion $ App
                        (makeVarRef "remainderBy")
                        [ ([], makeVarRef "divisor")
                        , ([], makeVarRef "dividend")
                        ]
                        (FAJoinFirst JoinAll)
                    )
                    False
                )
              ]

        replace var =
            case var of
                VarRef [] (LowercaseIdentifier name) ->
                    Dict.lookup name basicsReplacements

                VarRef [(UppercaseIdentifier "Basics")] (LowercaseIdentifier name) ->
                    Dict.lookup name basicsReplacements

                OpRef (SymbolIdentifier "!") ->
                    Just $
                    Lambda
                      [makeArg "model", makeArg "cmds"] []
                      (noRegion $ Binops
                          (makeVarRef "model")
                          [([], var, [], makeVarRef "cmds")]
                          False
                      )
                      False

                _ -> Nothing

        makeTuple n =
            let
                vars =
                  if n <= 26
                    then fmap (\c -> [c]) (take n ['a'..'z'])
                    else error (pleaseReport'' "UNEXPECTED TUPLE" "more than 26 elements")
            in
                Lambda
                    (fmap makeArg vars)
                    []
                    (noRegion $ AST.Expression.Tuple (fmap (\v -> Commented [] (makeVarRef v) []) vars) False)
                    False
    in
    case RA.drop expr of
        VarExpr var ->
            Maybe.fromMaybe expr $ fmap noRegion $ replace var

        App (A _ (VarExpr var)) args multiline ->
            Maybe.fromMaybe expr $ fmap (\new -> applyLambda (noRegion new) args multiline) $ replace var

        TupleFunction n ->
            noRegion $ makeTuple n

        App (A _ (TupleFunction n)) args multiline ->
            applyLambda (noRegion $ makeTuple n) args multiline

        ExplicitList terms' trailing multiline ->
            let
                ha = (fmap UppercaseIdentifier ["Html", "Attributes"])
                styleExposed = Dict.lookup (LowercaseIdentifier "style") exposed == Just ha
                haAlias = Dict.lookup ha importAliases
            in
            noRegion $ ExplicitList (concat $ fmap (expandHtmlStyle styleExposed haAlias) $ terms') trailing multiline

        _ ->
            expr


expandHtmlStyle :: Bool -> Maybe UppercaseIdentifier -> (Comments, PreCommented (WithEol Expr)) -> [(Comments, PreCommented (WithEol Expr))]
expandHtmlStyle styleExposed importAlias (preComma, (pre, (term, eol))) =
    let
        lambda fRef =
            Lambda
                [([], noRegion $ AST.Pattern.Tuple [makeArg' "a", makeArg' "b"]) ] []
                (noRegion $ App
                    (noRegion $ VarExpr $ fRef)
                    [ ([], makeVarRef "a")
                    , ([], makeVarRef "b")
                    ]
                    (FAJoinFirst JoinAll)
                )
                False

        isHtmlAttributesStyle var =
            case var of
                VarRef [UppercaseIdentifier "Html", UppercaseIdentifier "Attributes"] (LowercaseIdentifier "style") -> True
                VarRef [alias] (LowercaseIdentifier "style") | Just alias == importAlias -> True
                VarRef [] (LowercaseIdentifier "style") -> styleExposed
                _ -> False
    in
    case RA.drop term of
        App (A _ (VarExpr var)) [(preStyle, A _ (ExplicitList styles trailing _))] _ | isHtmlAttributesStyle var ->
            fmap (\(preComma', (pre', (style, eol'))) -> (preComma ++ preComma', (pre ++ preStyle ++ pre' ++ trailing ++ (Maybe.maybeToList $ fmap LineComment eol), (applyLambda (noRegion $ lambda var) [([], style)] (FAJoinFirst JoinAll), eol')))) styles

        _ ->
            [(preComma, (pre, (term, eol)))]

--
-- Generic helpers
--


pleaseReport'' :: String -> String -> String
pleaseReport'' what details =
    "<elm-format-" ++ ElmFormat.Version.asString ++ ": "++ what ++ ": " ++ details ++ " -- please report this at https://github.com/avh4/elm-format/issues >"



nowhere :: Region.Position
nowhere =
    Region.Position 0 0


noRegion :: a -> RA.Located a
noRegion =
    RA.at nowhere nowhere


makeArg :: String -> (Comments, Pattern)
makeArg varName =
    ([], noRegion $ VarPattern $ LowercaseIdentifier varName)


makeArg' :: String -> Commented Pattern
makeArg' varName =
    Commented [] (noRegion $ VarPattern $ LowercaseIdentifier varName) []


makeVarRef :: String -> Expr
makeVarRef varName =
    noRegion $ VarExpr $ VarRef [] $ LowercaseIdentifier varName


class MapExpr a where
    mapExpr :: (Expr' -> Expr') -> a -> a

instance MapExpr (Located Expr') where
    mapExpr f (A region a) = A region (f a)

instance MapExpr IfClause where
    mapExpr f (cond, body) = (mapExpr f cond, mapExpr f body)

instance MapExpr a => MapExpr (PreCommented a) where
    mapExpr f (pre, a) = (pre, mapExpr f a)

instance MapExpr a => MapExpr (WithEol a) where
    mapExpr f (a, eol) = (mapExpr f a, eol)

instance MapExpr a => MapExpr [a] where
    mapExpr f list = fmap (mapExpr f) list

instance MapExpr a => MapExpr (a, Bool) where
    mapExpr f (a, b) = (mapExpr f a, b)

instance MapExpr a => MapExpr (Commented Pattern, a) where
    mapExpr f (x, a) = (x, mapExpr f a)

instance MapExpr a => MapExpr (Comments, Ref, Comments, a) where
    mapExpr f (pre, op, post, a) = (pre, op, post, mapExpr f a)

instance MapExpr a => MapExpr (Commented a) where
    mapExpr f (Commented pre e post) = Commented pre (mapExpr f e) post

instance MapExpr a => MapExpr (Pair key a) where
    mapExpr f (Pair key value multi) = Pair key (mapExpr f value) multi

instance MapExpr Expr' where
  mapExpr f expr =
    case expr of
        Unit _ -> expr
        AST.Expression.Literal _ -> expr
        VarExpr _ -> expr

        App f' args multiline ->
            App (mapExpr f f') (mapExpr f args) multiline
        Unary op e ->
            Unary op (mapExpr f e)
        Binops left restOps multiline ->
            Binops (mapExpr f left) (mapExpr f restOps) multiline
        Parens e ->
            Parens (mapExpr f e)
        ExplicitList terms' post multiline ->
            ExplicitList (mapExpr f terms') post multiline
        Range e1 e2 multiline ->
            Range (mapExpr f e1) (mapExpr f e2) multiline
        AST.Expression.Tuple es multiline ->
            AST.Expression.Tuple (mapExpr f es) multiline
        TupleFunction _ -> expr
        AST.Expression.Record b fs post multiline ->
            AST.Expression.Record b (mapExpr f fs) post multiline
        Access e field' ->
            Access (mapExpr f e) field'
        AccessFunction _ -> expr
        Lambda params pre body multi ->
            Lambda params pre (mapExpr f body) multi
        If c1 elseIfs els ->
            If (mapExpr f c1) (mapExpr f elseIfs) (mapExpr f els)
        Let decls pre body ->
            Let (mapExpr f decls) pre body
        Case cond branches ->
            Case (mapExpr f cond) (mapExpr f branches)
        GLShader _ -> expr

instance MapExpr LetDeclaration where
  mapExpr f d =
      case d of
          LetDefinition name args pre body -> LetDefinition name args pre (mapExpr f body)
          _ -> d


inlineVar :: LowercaseIdentifier -> Bool -> Expr' -> Expr' -> Expr'
inlineVar name insertMultiline value expr =
    Maybe.fromMaybe expr $ inlineVar' name insertMultiline value expr


inlineVar' :: LowercaseIdentifier -> Bool -> Expr' -> Expr' -> Maybe Expr'
inlineVar' name insertMultiline value expr =
    case expr of
        VarExpr (VarRef [] n) | n == name -> Just value

        AST.Expression.Tuple terms' multiline ->
            let
                step (acc, expand) t@(Commented pre (A _ term) post) =
                    case inlineVar' name insertMultiline value term of
                        Nothing -> (ReversedList.push t acc, expand)
                        Just term' -> (ReversedList.push (Commented pre (noRegion term') post) acc, insertMultiline || expand)

                (terms'', multiline'') = foldl step (ReversedList.empty, multiline) terms'
            in
            Just $ AST.Expression.Tuple (ReversedList.toList terms'') multiline''

        -- TODO: handle expanding multiline in contexts other than tuples

        _ -> Just $ mapExpr (inlineVar name insertMultiline value) expr


applyLambda :: Expr -> [PreCommented Expr] -> FunctionApplicationMultiline -> Expr
applyLambda lambda args appMultiline =
    let
        getMapping :: PreCommented Pattern -> PreCommented Expr -> Maybe [(LowercaseIdentifier, Expr')]
        getMapping pat arg =
            case (pat, arg) of
                ( (preVar, A _ (VarPattern name))
                 , (preArg, arg')
                 ) ->
                    Just [(name, Parens $ Commented (preVar ++ preArg) arg' [])]

                ( (preVar, A _ (AST.Pattern.Tuple [Commented preA (A _ (VarPattern nameA)) postA, Commented preB (A _ (VarPattern nameB)) postB]))
                 , (preArg, A _ (AST.Expression.Tuple [Commented preAe eA postAe, Commented preBe eB postBe] _))
                 ) ->
                    Just
                        [ (nameA, Parens $ Commented (preVar ++ preArg) (noRegion $ Parens $ Commented (preA ++ preAe) eA (postAe ++ postA)) [])
                        , (nameB, Parens $ Commented (preB ++ preBe) eB (postBe ++ postB))
                        ]

                _ ->
                    Nothing
    in
    case (RA.drop lambda, args) of
        (Lambda (pat:restVar) preBody body multiline, arg:restArgs) ->
            case getMapping pat arg of
                Nothing ->
                    -- failed to destructure the next argument, so stop
                    noRegion $ App lambda args appMultiline

                Just mappings ->
                    let
                        newBody = foldl (\e (name, value) -> mapExpr (inlineVar name (appMultiline == FASplitFirst) value) e) body mappings
                        newMultiline =
                            case appMultiline of
                                FASplitFirst -> FASplitFirst
                                FAJoinFirst SplitAll -> FASplitFirst
                                FAJoinFirst JoinAll -> FAJoinFirst JoinAll
                    in
                    case restVar of
                        [] ->
                            -- we applied the argument and none are left, so remove the lambda
                            noRegion $ App (noRegion $ Parens $ Commented preBody newBody []) restArgs newMultiline
                        _:_ ->
                            -- we applied this argument; try to apply the next argument
                            applyLambda (noRegion $ Lambda restVar preBody newBody multiline) restArgs newMultiline

        (_, []) -> lambda

        _ -> noRegion $ App lambda args appMultiline
