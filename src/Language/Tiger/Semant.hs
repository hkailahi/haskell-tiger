{-# LANGUAGE RecordWildCards, TupleSections, OverloadedStrings, LambdaCase #-}

-- | Chapter 5: Semantic analysis
-- Type checking and translation to intermediate code
module Language.Tiger.Semant where

import Data.List

import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Except (ExceptT(..))
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.Reader (ReaderT(..))
import Control.Monad.Writer.Class (MonadWriter(..))
import Control.Monad.Writer.Lazy (WriterT(..))
import Control.Monad.Tardis (TardisT(..))
import Data.Functor.Identity
import qualified Data.Sequence as Seq

import Language.Tiger.AST hiding (Ty(..))
import qualified Language.Tiger.AST as AST
import Language.Tiger.Loc (SrcSpan, Span(..))
import Language.Tiger.Types
import Language.Tiger.Gensym
import qualified Language.Tiger.Env as Env
import qualified Language.Tiger.Symtab as Symtab

--------------------------------------------------------------------------------
transProg :: CheckConstraints m a
          -> Exp a -> m ()
--------------------------------------------------------------------------------
transProg e = do
  transExp e
  errs <- ask
  if not (Seq.null errs)
    then throwError errs
    else pure ()

--------------------------------------------------------------------------------
transVar :: CheckConstraints m a
         => VEnv -> TEnv
         -> Var a -> m (Var (Ty, a))
--------------------------------------------------------------------------------
transVar venv tenv = \case
  SimpleVar varName a ->
    Symtab.lookupV varName >>= \case
      Just (VarTy ty) -> pure (Var var (ty, a))
      Just _ -> nonfatal a NoHOF
         Nothing -> nonfatal a UnboundVariable

  FieldVar recVar fieldName a ->
    do Var _ (ty, _)  <- transVar venv tenv recVar
       case ty of
         RecordTy fields _ _ -> case lookup fieldName fields of
           Just fieldTy -> undefined
           Nothing -> nonfatal a NoSuchField
         _ -> fatal a TypeUndefined

  SubscriptVar var1 exp1 a ->
    do Var _ (ty, _)  <- transVar venv tenv recVar
        undefined

--------------------------------------------------------------------------------
transExp :: (HasSrcSpan a, MonadWriter MultipleErrors m)
         => VEnv -> TEnv -> Int
         -> Exp a
         -> m (Exp (Ty, a))
--------------------------------------------------------------------------------
transExp venv tenv loopLevel exp =
  let
    go = transExp venv tenv loopLevel

    goCheck e expectTy = do
      e' <- go e
      let (ty, a) = ann e'
      checkTy a ty expectTy
      return e'

    -- checkFieldTy fe fty = do
    --   fe' <- go fe
    --   ty <- getTy fe'
    --   guard $ ty == fty
    --   return fe'

  in case exp of
    Var v ann ->
      do v' <- transVar venv tenv v
         pure $ Var v' (getTy v', ann)

    Nil ann ->
      NilTy (NilTy, ann)

    Int i ann ->
      Int i (IntTy, ann)

    String s ann ->
      String s (StringTy, ann)

    Call fun args ann ->
      case Symtab.lookup venv fun of
        Just (FunEntry argsTy returnTy)
          | length args == length argsTy ->
            do args' <- for (zip args argsTy) $ \(argE, argTy) ->
                 do argE' <- goCheck argE argTy
                    return argE'
               return $ Call fun args' (returnTy, ann)
          | otherwise ->
            fatal ann (ArityError fun (length argsTy) (length args))

        Nothing -> fatal ann (UndefinedFunction fun)

    Op l o r ann -> do
      l' <- go l
      r' <- go r
      to <- checkOp o (getTy l') (getTy r')
      return $ Op l' o r' (to, ann)

    Record fields recTySymb ann ->
      case Symtab.lookup tenv recTySymb of
        Just ty@(RecordTy fieldTys _) ->
          | length fields == length fieldTys ->
              do fields' <- for (zip fields fieldTys) $
                    \((recFldName, recFldExp, recFldAnn),
                        Field{fieldName, fieldType, fieldAnnot}) ->
                       do recFldName == fieldName
                          e' <- go recFldExp
                          let fldType = fromJust $ Symtab.lookup tenv fieldType
                           --  this should not fail
                          checkTy recFldAnn (getTy e') fldType
                          return (recFldName, e', (getTy e', recFldAnn))
                 return $ Record fields' recTySymb (ty, ann)

          | otherwise ->
             fatal ann $
               TypeMismatch recTySymb
                   (Right ty)
                   (RecordTy (map (\(x,y,_) -> (x,y)) fields) 99999)

        -- recTySymb is not a record
        Just ty -> fatal ann (TypeMismatch recTySymb (Left RecordTyC) ty)

        Nothing -> nonfatal ann (TypeUndefined recTySymb)

    Seq seqs ann
      | null seqs ->
          Seq [] (UnitTy,ann)
      | otherwise ->
        do seqs' <- mapM go seqs
           return $ Seq seqs' (getTy (last seqs), ann)

    Assign v e ann ->
      do v' <- transVar venv tenv v
         e' <- go e
         let vTy = getTy v'
         when (vTy /= NilTy) $ -- FIXME probably need to update venv
           checkTy vTy (getTy e')
         return $ Assign v' e' (UnitTy, ann)

    If c t mf ann ->
      do c' <- goCheck c IntTy
         t' <- go t'
         case mf of
           Nothing ->
             do checkTy (getTy t') UnitTy
                return $ If c' t' Nothing (UnitTy, ann)

           Just f ->
             do f' <- goCheck f (getTy t')
                return $ If c' t' f' (getTy t', ann)

    While c b ann ->
      do c' <- goCheck c IntTy
         b' <- transExp venv tenv (loopLevel+1) b
         checkTy (snd (ann b')) (getTy b') UnitTy
         return $ While c' b' (UnitTy, ann)

    For i lo hi b ann ->
      do lo' <- goCheck lo IntTy
         hi' <- goCheck hi IntTy
         b' <- transExp (Symtab.insert i (VarEntry IntTy) venv) tenv (loopLevel+1)
         checkTy (snd (ann b')) (getTy b') UnitTy
         return $ For i lo' hi' b' (UnitTy, ann)

    Break ann ->
      do when (loopLevel < 1) $
           nonfatal ann BreakOutsideLoop
         pure $ Break (UnitTy, ann)

-- FIXME
    Let binds e ann ->
      do (venv', tenv') <- foldM (uncurry transDec) (venv,tenv) binds
         let binds' = undefined
         e' <- transExp venv' tenv' e
         return $ Let binds' e' (getTy e',ann)

    Array arrTySymb sizeE initE ann ->
      case Symtab.lookup tenv arrTySymb of
        Just ty@(ArrayTy elemTy _) -> do
          sizeE' <- goCheck sizeE IntTy
          initE' <- goCheck initE elemTy
          return $ Array arrTySymb sizeE' initE' (ty, ann)

        Just ty -> fatal ann (TypeMismatch arrTySymb (Left ArrayTyC) ty)
        Nothing -> nonfatal ann (TypeUndefined arrTySymb) -- if nonfatal,
                   -- should probably add this type into env and continue...

--------------------------------------------------------------------------------
transDec :: CheckConstraints m a
         => VEnv -> TEnv
         => Dec a
         -> m (VEnv, TEnv)
--------------------------------------------------------------------------------
transDec venv tenv dec = case dec of
  FunctionDecl fs a ->
    let doFun venv tenv Function{..} =
          do formals <- for funParams $ \Field{..} ->
               do ty <- lookupT tenv fieldType fieldAnnot
                  -- TODO throw error if type not defined...
                  pure (fieldName, VarEntry ty)

             retTy <- maybe (pure UnitTy) (uncurry (lookupT tenv)) funResult

             let formalTys = map snd formals
             let funTy = FunEntry formalTys retTy
             let venv' = Symtab.inserts ((funName, funTy):formals) venv

             _ <- transExp venv' tenv' funBody

             return (venv', tenv)
    in
      foldM (uncurry doFun) (venv, tenv) fs

  VarDecl{name, typ, init, meta} ->
    do init' <- transExp venv tenv init
       let initTy = getTy init'
       declaredTy <- traverse (uncurry (lookupT tenv)) typ
       varTy <- case declaredTy of
         Nothing -> pure initTy
         Just ty -> do checkTy initTy ty; pure ty
       let venv' = Symtab.insert name varTy venv
       return (venv', tenv)

  TypeDecl [(s, ast_t,_)] a ->
    do ty <- transTy tenv ast_t
       let tenv' = Symtab.insert s ty tenv
       return (venv, tenv')

--------------------------------------------------------------------------------
transTy :: (Gensym m, MonadWriter MultipleErrors m)
        => TEnv
        -> AST.Ty a -> m Ty
--------------------------------------------------------------------------------
transTy tenv ty = case ty of
  NameTy symb maybeTy _
     -> undefined
  RecordTy fields uniq
     -> undefined
  ArrayTy symv uniq _
     -> undefined

--------------------------------------------------------------------------------
-- * Errors

data TransError
  = NamedTypeMismatch Symbol (Either TyC Ty) Ty
  | TypeMismatch Ty Ty
  | TypeUndefined Symbol
  | ArityError Symbol Int Int
  | NoHOF
  | UndefinedFunction Symbol
  | UnboundVariable Symbol
  | NoSuchField Symbol Symbol Ty
  | BreakOutsideLoop

instance Show TransError where
  show = \case
    NamedTypeMismatch symb expect actual ->
      "Type mismatch: "
      <> show symb <> " is a "
      <> show actual <> " not a "
      <> either show show expect
    TypeMismatch expect actual ->
      "Type mismatch: expected " <> show expect <> " got " <> show actual
    TypeUndefined ty ->
      "Undefined type: " <> show ty
    ArityError fn expect actual ->
      show fn <> " called with the wrong number of arguments, expected "
      <> show expect <> " got " <> show actual
    NoHOF ->
      "Higher order functions not implemented"
    UndefinedFunction fn ->
      "Undefined function: " <> show fn
    UnboundVariable v ->
      "Unbound variable: " <> show v
    NoSuchField fld r rt ->
      "No field named " <> show fld <> " in record " <> show r <> " of type " <> show rt
    BreakOutsideLoop ->
      "break statement outside loop"

newtype MultipleErrors = MultipleErrors
  { runMultipleErrors :: Seq.Seq (Span TransError) }

-- | log an error and keep going
nonfatal :: (HasSrcSpan a, MonadWriter MultipleErrors m)
         => a -> TransError -> m ()
nonfatal = tell . Seq.singleton . Span . sp

-- | log an error and halt
fatal :: (HasSrcSpan a, MonadWriter MultipleErrors m, MonadError MultipleErrors m)
      => a -> TransError -> m ()
fatal ann err = do
  nonfatal ann err
  errs <- ask
  throwError errs

--------------------------------------------------------------------------------
-- * Monad

-- | Variable environment
type VEnv = Symtab.Symtab Env.EnvEntry

-- | Typing environment
type TEnv = Symtab.Symtab Ty

type CheckConstraints m a =
  ( HasSrcSpan a
  , MonadWriter MultipleErrors m
  , MonadError MultipleErrors m
  , MonadReader (VEnv, TEnv) m
  )

type CheckM = (ExceptT MultipleErrors -- can probably get rid of this...
               (WriterT MultipleErrors
                 (ReaderT (VEnv, TEnv)
                   Identity)))

runCheckM :: CheckM a -> Either MultipleErrors a
runCheckM = fmap fst
          . runIdentity
          . runReaderT (Symtab.venv0, Symtab.tenv0)
          . runWriterT
          . runExceptT

-- * Helpers

lookupV :: (MonadReader (VEnv,TEnv) m) => Symbol -> m (Maybe EnvEntry)
lookupV n = Symtab.lookup n <$> asks fst

lookupT :: (HasSrcSpan a, MonadWriter MultipleErrors m)
        => TEnv -> Symbol -> a -> m (Maybe Ty)
lookupT env t a = maybe (emitError a (TypeUndefined t)) pure $ Symtab.lookup t env

getTy :: Ann f => f (Ty, a) -> Ty
getTy = fst . ann

checkOp :: CheckConstraints m a -- (HasSrcSpan a)
        => Op -> Ty -> Ty -> a
        -> m Ty
checkOp op tl tr a
  | tl /= tr
  = emitError a (TypeMismatch tl tr)
  | isArith
  = checks [tl, tr] IntTy

  | isComp = undefined
  | isEq = undefined
  where
    checks expect = (expect <$) . traverse (\x -> checkTy a x expect)

    isArith = any (op ==) [Plus, Minus, Times, Divide]
    isComp  = any (op ==) [Lt, Le, Gt, Ge]
    isEq    = any (op ==) [Eq, Neq]

checkTy :: HasSrcSpan a => a -> Ty -> Ty -> m ()
checkTy ann expect declared
  | expect == declared = pure ()
  | otherwise = fatal ann (TypeMismatch expect declared)
