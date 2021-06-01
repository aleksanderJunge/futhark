{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Futhark.AD.Fwd (fwdJVP) where

import Control.Monad
import Control.Monad.RWS.Strict
import Control.Monad.State.Strict
import Data.Bifunctor (second)
import qualified Data.Kind
import Data.List (transpose)
import qualified Data.Map as M
import Futhark.AD.Derivatives
import Futhark.Analysis.PrimExp.Convert
import Futhark.Binder
import Futhark.Construct
import Futhark.IR.SOACS

zeroTan :: Type -> ADM SubExp
zeroTan (Prim t) = return $ constant $ blankPrimValue t
zeroTan t = error $ "zeroTan on non-primitive type: " ++ pretty t

zeroExp :: Type -> Exp
zeroExp (Prim pt) =
  BasicOp $ SubExp $ Constant $ blankPrimValue pt
zeroExp (Array pt shape _) =
  BasicOp $ Replicate shape $ Constant $ blankPrimValue pt
zeroExp t = error $ "zeroExp: " ++ show t

isAcc :: TypeBase s u -> Bool
isAcc Acc {} = True
isAcc _ = False

tanType :: TypeBase s u -> ADM (TypeBase s u)
tanType (Acc acc ispace ts u) = do
  ts_tan <- mapM tanType ts
  return $ Acc acc ispace (ts ++ ts_tan) u
tanType t = return t

slocal' :: ADM a -> ADM a
slocal' = slocal id

slocal :: (RState -> RState) -> ADM a -> ADM a
slocal f m = do
  s <- get
  modify f
  a <- m
  modify $ \s' -> s' {stateTans = stateTans s}
  return a

data RState = RState
  { stateTans :: M.Map VName VName,
    stateNameSource :: VNameSource
  }

newtype ADM a = ADM (BinderT SOACS (State RState) a)
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadState RState,
      MonadFreshNames,
      HasScope SOACS,
      LocalScope SOACS
    )

instance MonadBinder ADM where
  type Lore ADM = SOACS
  mkExpDecM pat e = ADM $ mkExpDecM pat e
  mkBodyM bnds res = ADM $ mkBodyM bnds res
  mkLetNamesM pat e = ADM $ mkLetNamesM pat e

  addStms = ADM . addStms
  collectStms (ADM m) = ADM $ collectStms m

instance MonadFreshNames (State RState) where
  getNameSource = gets stateNameSource
  putNameSource src = modify (\env -> env {stateNameSource = src})

runADM :: MonadFreshNames m => ADM a -> m a
runADM (ADM m) =
  modifyNameSource $ \vn ->
    second stateNameSource $
      runState
        (fst <$> runBinderT m mempty)
        (RState mempty vn)

tanVName :: VName -> ADM VName
tanVName v = newVName (baseString v <> "_tan")

insertTan :: VName -> VName -> ADM ()
insertTan v v' =
  modify $ \env -> env {stateTans = M.insert v v' (stateTans env)}

class TanBinder a where
  type Bundled a :: Data.Kind.Type
  type Bundled a = [a]
  newTan :: a -> ADM a
  bundleNew :: a -> ADM (Bundled a)

instance (Monoid (Bundled a), TanBinder a) => TanBinder [a] where
  type Bundled [a] = Bundled a
  newTan = mapM newTan
  bundleNew = fmap mconcat . mapM bundleNew

instance TanBinder VName where
  newTan v = do
    v' <- tanVName v
    insertTan v v'
    return v'
  bundleNew v = do
    void $ newTan v
    bundleTan v

instance TanBinder (PatElemT (TypeBase s u)) where
  newTan (PatElem p t)
    | isAcc t = do
      insertTan p p
      t' <- tanType t
      return $ PatElem p t'
    | otherwise = do
      p' <- tanVName p
      insertTan p p'
      t' <- tanType t
      return $ PatElem p' t'
  bundleNew pe@(PatElem _ t) = do
    pe' <- newTan pe
    if isAcc t
      then return [pe']
      else return [pe, pe']

instance TanBinder (PatternT (TypeBase s u)) where
  type Bundled (PatternT (TypeBase s u)) = (PatternT (TypeBase s u))
  newTan (Pattern ctx pes) = Pattern ctx <$> newTan pes
  bundleNew (Pattern ctx pes) = Pattern ctx <$> bundleNew pes

instance TanBinder (Param (TypeBase s u)) where
  newTan (Param p t) = do
    PatElem p' t' <- newTan $ PatElem p t
    return $ Param p' t'
  bundleNew param@(Param _ (Prim Unit)) =
    pure [param]
  bundleNew param@(Param _ t) = do
    param' <- newTan param
    if isAcc t
      then return [param']
      else return [param, param']

instance Tangent a => TanBinder (Param (TypeBase s u), a) where
  newTan (p, x) = (,) <$> newTan p <*> tangent x
  bundleNew (p, x) = do
    b <- bundleNew p
    x_tan <- tangent x
    return $ zip b [x, x_tan]

class Tangent a where
  type BundledTan a :: Data.Kind.Type
  type BundledTan a = [a]
  tangent :: a -> ADM a
  bundleTan :: a -> ADM (BundledTan a)

instance Tangent (TypeBase s u) where
  tangent = tanType
  bundleTan t
    | isAcc t = do
      t' <- tangent t
      return [t']
    | otherwise = do
      t' <- tangent t
      return [t, t']

instance (Monoid (BundledTan a), Tangent a) => Tangent [a] where
  type BundledTan [a] = BundledTan a
  tangent = mapM tangent
  bundleTan = (mconcat <$>) . mapM bundleTan

instance Tangent VName where
  tangent v = do
    maybeTan <- gets $ M.lookup v . stateTans
    case maybeTan of
      Just v_tan -> return v_tan
      Nothing -> do
        t <- lookupType v
        v_tan <- newTan v
        letBindNames [v_tan] $ zeroExp t
        return v_tan
  bundleTan v = do
    t <- lookupType v
    if isAcc t
      then return [v]
      else do
        v_tan <- tangent v
        return [v, v_tan]

instance Tangent SubExp where
  tangent (Constant c) = zeroTan $ Prim $ primValueType c
  tangent (Var v) = Var <$> tangent v
  bundleTan c@Constant {} = do
    c_tan <- tangent c
    return [c, c_tan]
  bundleTan (Var v) = fmap Var <$> bundleTan v

patNames :: Pattern -> ADM [VName]
patNames (Pattern [] pes) = pure $ map patElemName pes
patNames _ = error "patNames: non-empty context."

basicFwd :: Pattern -> StmAux () -> BasicOp -> ADM ()
basicFwd pat aux op = do
  pat_tan <- newTan pat
  pat_v_tan <- patNames pat_tan
  case op of
    SubExp se -> do
      se_tan <- tangent se
      addStm $ Let pat_tan aux $ BasicOp $ SubExp se_tan
    Opaque se -> do
      se_tan <- tangent se
      addStm $ Let pat_tan aux $ BasicOp $ Opaque se_tan
    ArrayLit ses t -> do
      ses_tan <- tangent ses
      addStm $ Let pat_tan aux $ BasicOp $ ArrayLit ses_tan t
    UnOp unop x -> do
      let t = unOpType unop
          x_pe = primExpFromSubExp t x
          dx = pdUnOp unop x_pe
      x_tan <- primExpFromSubExp t <$> tangent x
      auxing aux $ letBindNames pat_v_tan <=< toExp $ x_tan ~*~ dx
    BinOp bop x y -> do
      let t = binOpType bop
      x_tan <- primExpFromSubExp t <$> tangent x
      y_tan <- primExpFromSubExp t <$> tangent y
      let (wrt_x, wrt_y) =
            pdBinOp bop (primExpFromSubExp t x) (primExpFromSubExp t y)
      auxing aux $
        letBindNames pat_v_tan <=< toExp $
          x_tan ~*~ wrt_x ~+~ y_tan ~*~ wrt_y
    CmpOp {} ->
      addStm $ Let pat_tan aux $ BasicOp op
    ConvOp cop x -> do
      x_tan <- tangent x
      addStm $ Let pat_tan aux $ BasicOp $ ConvOp cop x_tan
    Assert {} -> return ()
    Index arr slice -> do
      arr_tan <- tangent arr
      addStm $ Let pat_tan aux $ BasicOp $ Index arr_tan slice
    Update arr slice se -> do
      arr_tan <- tangent arr
      se_tan <- tangent se
      addStm $ Let pat_tan aux $ BasicOp $ Update arr_tan slice se_tan
    Concat d arr arrs w -> do
      arr_tan <- tangent arr
      arrs_tans <- tangent arrs
      addStm $ Let pat_tan aux $ BasicOp $ Concat d arr_tan arrs_tans w
    Copy arr -> do
      arr_tan <- tangent arr
      addStm $ Let pat_tan aux $ BasicOp $ Copy arr_tan
    Manifest ds arr -> do
      arr_tan <- tangent arr
      addStm $ Let pat_tan aux $ BasicOp $ Manifest ds arr_tan
    Iota n _ _ it -> do
      addStm $ Let pat_tan aux $ BasicOp $ Replicate (Shape [n]) (intConst it 0)
    Replicate n x -> do
      x_tan <- tangent x
      addStm $ Let pat_tan aux $ BasicOp $ Replicate n x_tan
    Scratch {} -> return ()
    Reshape reshape arr -> do
      arr_tan <- tangent arr
      addStm $ Let pat_tan aux $ BasicOp $ Reshape reshape arr_tan
    Rearrange perm arr -> do
      arr_tan <- tangent arr
      addStm $ Let pat_tan aux $ BasicOp $ Rearrange perm arr_tan
    Rotate rots arr -> do
      arr_tan <- tangent arr
      addStm $ Let pat_tan aux $ BasicOp $ Rotate rots arr_tan
    _ -> error $ "basicFwd: Unsupported op " ++ pretty op

fwdLambda :: Lambda -> ADM Lambda
fwdLambda l@(Lambda params body ret) =
  Lambda <$> bundleNew params <*> inScopeOf l (fwdBody body) <*> bundleTan ret

fwdStreamLambda :: Lambda -> ADM Lambda
fwdStreamLambda l@(Lambda params body ret) =
  Lambda <$> ((take 1 params ++) <$> bundleNew (drop 1 params)) <*> inScopeOf l (fwdBody body) <*> bundleTan ret

interleave :: [a] -> [a] -> [a]
interleave xs ys = concat $ transpose [xs, ys]

zeroFromSubExp :: SubExp -> ADM VName
zeroFromSubExp (Constant c) =
  letExp "zero" $
    BasicOp $ SubExp $ Constant $ blankPrimValue $ primValueType c
zeroFromSubExp (Var v) = do
  t <- lookupType v
  letExp "zero" $ zeroExp t

fwdSOAC :: Pattern -> StmAux () -> SOAC SOACS -> ADM ()
fwdSOAC pat aux (Screma size xs (ScremaForm scs reds f)) = do
  pat' <- bundleNew pat
  xs' <- bundleTan xs
  scs' <- mapM fwdScan scs
  reds' <- mapM fwdRed reds
  f' <- fwdLambda f
  addStm $ Let pat' aux $ Op $ Screma size xs' $ ScremaForm scs' reds' f'
  where
    fwdScan :: Scan SOACS -> ADM (Scan SOACS)
    fwdScan sc = do
      op' <- fwdLambda $ scanLambda sc
      neutral_tans <- mapM zeroFromSubExp $ scanNeutral sc
      return $
        Scan
          { scanNeutral = scanNeutral sc `interleave` map Var neutral_tans,
            scanLambda = op'
          }
    fwdRed :: Reduce SOACS -> ADM (Reduce SOACS)
    fwdRed red = do
      op' <- fwdLambda $ redLambda red
      neutral_tans <- mapM zeroFromSubExp $ redNeutral red
      return $
        Reduce
          { redComm = redComm red,
            redLambda = op',
            redNeutral = redNeutral red `interleave` map Var neutral_tans
          }
fwdSOAC pat aux (Stream size xs form nes lam) = do
  pat' <- bundleNew pat
  lam' <- fwdStreamLambda lam
  xs' <- bundleTan xs
  nes_tan <- mapM (fmap Var . zeroFromSubExp) nes
  let nes' = interleave nes nes_tan
  case form of
    Sequential ->
      addStm $ Let pat' aux $ Op $ Stream size xs' Sequential nes' lam'
    Parallel o comm lam0 -> do
      lam0' <- fwdLambda lam0
      let form' = Parallel o comm lam0'
      addStm $ Let pat' aux $ Op $ Stream size xs' form' nes' lam'
fwdSOAC pat aux (Hist len ops bucket_fun imgs) = do
  pat_tan <- newTan pat
  ops' <- mapM fwdHist ops
  bucket_fun' <- fwdLambda bucket_fun
  addStm $ Let (pat <> pat_tan) aux $ Op $ Hist len ops' bucket_fun' imgs
  where
    fwdHist :: HistOp SOACS -> ADM (HistOp SOACS)
    fwdHist (HistOp width rf dest nes op) = do
      dest' <- bundleTan dest
      nes_tan <- mapM (fmap Var . zeroFromSubExp) nes
      op' <- fwdLambda op
      return $
        HistOp
          { histWidth = width,
            histRaceFactor = rf,
            histDest = dest',
            histNeutral = interleave nes nes_tan,
            histOp = op'
          }
fwdSOAC (Pattern ctx pes) aux (Scatter len lam ivs as) = do
  as_tan <- mapM (\(s, n, a) -> do a_tan <- tangent a; return (s, n, a_tan)) as
  pes_tan <- newTan pes
  ivs' <- bundleTan ivs
  let (as_ws, as_ns, _as_vs) = unzip3 as
      n_indices = sum $ zipWith (*) as_ns $ map length as_ws
  lam' <- fwdScatterLambda n_indices lam
  let s = Let (Pattern ctx (pes ++ pes_tan)) aux $ Op $ Scatter len lam' ivs' $ as ++ as_tan
  addStm s
  where
    fwdScatterLambda :: Int -> Lambda -> ADM Lambda
    fwdScatterLambda n_indices (Lambda params body ret) = do
      params' <- bundleNew params
      ret_tan <- tangent $ drop n_indices ret
      body' <- fwdBodyScatter n_indices body
      let indices = concat $ replicate 2 $ take n_indices ret
          ret' = indices ++ drop n_indices ret ++ ret_tan
      return $ Lambda params' body' ret'
    fwdBodyScatter :: Int -> Body -> ADM Body
    fwdBodyScatter n_indices (Body _ stms res) = do
      (res_tan, stms') <- collectStms $ do
        mapM_ fwdStm stms
        tangent $ drop n_indices res
      let indices = concat $ replicate 2 $ take n_indices res
          res' = indices ++ drop n_indices res ++ res_tan
      return $ mkBody stms' res'

fwdStm :: Stm -> ADM ()
fwdStm (Let pat aux (BasicOp (UpdateAcc acc i x))) = do
  pat' <- bundleNew pat
  x' <- bundleTan x
  acc_tan <- tangent acc
  addStm $ Let pat' aux $ BasicOp $ UpdateAcc acc_tan i x'
fwdStm stm@(Let pat aux (BasicOp e)) = do
  -- XXX: this has to be too naive.
  unless (any isAcc $ patternTypes pat) $
    addStm stm
  basicFwd pat aux e
fwdStm stm@(Let pat _ (Apply f args _ _))
  | Just (_, argts) <- M.lookup f builtInFunctions = do
    addStm stm
    arg_tans <-
      zipWith primExpFromSubExp argts <$> mapM (tangent . fst) args
    pat_tan <- newTan pat
    pat_v_tan <- patNames pat_tan
    let arg_pes = zipWith primExpFromSubExp argts (map fst args)
    case pdBuiltin f arg_pes of
      Nothing ->
        error $ "No partial derivative defined for builtin function: " ++ pretty f
      Just derivs ->
        zipWithM_ (letBindNames . pure) pat_v_tan
          =<< mapM toExp (zipWith (~*~) arg_tans derivs)
fwdStm (Let pat aux (If cond t f (IfDec ret ifsort))) = do
  t' <- slocal' $ fwdBody t
  f' <- slocal' $ fwdBody f
  pat' <- bundleNew pat
  ret' <- bundleTan ret
  addStm $ Let pat' aux $ If cond t' f' $ IfDec ret' ifsort
fwdStm (Let pat aux (DoLoop l_ctx val_pats (WhileLoop v) body)) = do
  val_pats' <- bundleNew val_pats
  pat' <- bundleNew pat
  body' <- fwdBody body
  addStm $ Let pat' aux $ DoLoop l_ctx val_pats' (WhileLoop v) body'
fwdStm (Let pat aux (DoLoop l_ctx val_pats loop@(ForLoop i it bound loop_vars) body)) = do
  pat' <- bundleNew pat
  val_pats' <- bundleNew val_pats
  loop_vars' <- bundleNew loop_vars
  inScopeOf loop $ do
    body' <-
      localScope (scopeOfFParams (map fst $ l_ctx ++ val_pats) <> scopeOf loop) $
        fwdBody body
    addStm $
      Let pat' aux $
        DoLoop l_ctx val_pats' (ForLoop i it bound loop_vars') body'
fwdStm (Let pat aux (WithAcc inputs lam)) = do
  inputs' <- forM inputs $ \(shape, arrs, op) -> do
    arrs_tan <- tangent arrs
    op' <- case op of
      Nothing -> return Nothing
      Just (op_lam, nes) -> do
        nes_tan <- mapM (fmap Var . zeroFromSubExp) nes
        op_lam' <- fwdLambda op_lam
        case op_lam' of
          Lambda (i : _ : ps) body ret -> do
            let op_lam'' = Lambda (i : ps) body ret
            return $ Just (op_lam'', interleave nes nes_tan)
          _ -> error "Malformed lambda in MkAcc."
    pure (shape, arrs <> arrs_tan, op')
  pat' <- bundleNew pat
  lam' <- fwdLambda lam
  addStm $ Let pat' aux $ WithAcc inputs' lam'
fwdStm (Let pat aux (Op soac)) = fwdSOAC pat aux soac
fwdStm stm =
  error $ "unhandled forward mode AD for Stm: " ++ pretty stm ++ "\n" ++ show stm

fwdBody :: Body -> ADM Body
fwdBody (Body _ stms res) = buildBody_ $ do
  mapM_ fwdStm stms
  bundleTan res

fwdBodyOnlyTangents :: Body -> ADM Body
fwdBodyOnlyTangents (Body _ stms res) = buildBody_ $ do
  mapM_ fwdStm stms
  tangent res

fwdJVP :: MonadFreshNames m => Scope SOACS -> Lambda -> m Lambda
fwdJVP scope l@(Lambda params body ret) =
  runADM . localScope scope . inScopeOf l $ do
    params_tan <- newTan params
    body_tan <- fwdBodyOnlyTangents body
    ret_tan <- tangent ret
    return $ Lambda (params ++ params_tan) body_tan (ret ++ ret_tan)
