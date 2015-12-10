{-# LANGUAGE TypeFamilies #-}
{-# Language FlexibleInstances, FlexibleContexts #-}
module Futhark.Representation.AST.Attributes.Aliases
       ( vnameAliases
       , subExpAliases
       , primOpAliases
       , loopOpAliases
       , aliasesOf
       , Aliased (..)
         -- * Consumption
       , consumedInBinding
       , consumedInExp
       , consumedInPattern
       -- * Extensibility
       , AliasedOp (..)
       , CanBeAliased (..)
       )
       where

import Control.Arrow (first)
import Data.Monoid
import qualified Data.HashSet as HS

import Futhark.Representation.AST.Syntax
import Futhark.Util.Pretty (Pretty)
import Futhark.Representation.AST.Lore (Lore)
import Futhark.Representation.AST.RetType
import Futhark.Representation.AST.Attributes.Types
import Futhark.Representation.AST.Attributes.Patterns
import Futhark.Representation.AST.Attributes.Names (FreeIn)
import Futhark.Transform.Substitute (Substitute)
import Futhark.Transform.Rename (Rename)

class (Lore lore, AliasedOp (Op lore)) => Aliased lore where
  bodyAliases :: Body lore -> [Names]
  consumedInBody :: Body lore -> Names
  patternAliases :: Pattern lore -> [Names]

vnameAliases :: VName -> Names
vnameAliases = HS.singleton

subExpAliases :: SubExp -> Names
subExpAliases Constant{} = mempty
subExpAliases (Var v)    = vnameAliases v

primOpAliases :: PrimOp lore -> [Names]
primOpAliases (SubExp se) = [subExpAliases se]
primOpAliases (ArrayLit es _) = [mconcat $ map subExpAliases es]
primOpAliases BinOp{} = [mempty]
primOpAliases Not{} = [mempty]
primOpAliases Complement{} = [mempty]
primOpAliases Negate{} = [mempty]
primOpAliases Abs{} = [mempty]
primOpAliases Signum{} = [mempty]
primOpAliases (Index _ ident _) =
  [vnameAliases ident]
primOpAliases Iota{} =
  [mempty]
primOpAliases Replicate{} =
  [mempty]
primOpAliases Scratch{} =
  [mempty]
primOpAliases (Reshape _ _ e) =
  [vnameAliases e]
primOpAliases (Rearrange _ _ e) =
  [vnameAliases e]
primOpAliases (Stripe _ _ e) =
  [vnameAliases e]
primOpAliases (Unstripe _ _ e) =
  [vnameAliases e]
primOpAliases (Split _ sizeexps e) =
  replicate (length sizeexps) (vnameAliases e)
primOpAliases Concat{} =
  [mempty]
primOpAliases Copy{} =
  [mempty]
primOpAliases Assert{} =
  [mempty]
primOpAliases (Partition _ n _ arr) =
  replicate n mempty ++ map vnameAliases arr

loopOpAliases :: (Aliased lore) => LoopOp lore -> [Names]
loopOpAliases (DoLoop res merge _ loopbody) =
  map snd $ filter fst $
  zip (map (((`elem` res) . identName) . paramIdent . fst) merge) (bodyAliases loopbody)
loopOpAliases (MapKernel _ _ _ _ _ returns _) =
  map (const mempty) returns
loopOpAliases (ReduceKernel _ _ _ _ _ nes _) =
  map (const mempty) nes
loopOpAliases (ScanKernel _ _ _ _ lam _) =
  replicate (length (lambdaReturnType lam) * 2) mempty

ifAliases :: ([Names], Names) -> ([Names], Names) -> [Names]
ifAliases (als1,cons1) (als2,cons2) =
  map (HS.filter notConsumed) $ zipWith mappend als1 als2
  where notConsumed = not . (`HS.member` cons)
        cons = cons1 <> cons2

funcallAliases :: [(SubExp, Diet)] -> [TypeBase shape Uniqueness] -> [Names]
funcallAliases args t =
  returnAliases t [(subExpAliases se, d) | (se,d) <- args ]

aliasesOf :: (Aliased lore) => Exp lore -> [Names]
aliasesOf (If _ tb fb _) =
  ifAliases
  (bodyAliases tb, consumedInBody tb)
  (bodyAliases fb, consumedInBody fb)
aliasesOf (PrimOp op) = primOpAliases op
aliasesOf (LoopOp op) = loopOpAliases op
aliasesOf (Apply _ args t) =
  funcallAliases args $ retTypeValues t
aliasesOf (Op op) = opAliases op

returnAliases :: [TypeBase shaper Uniqueness] -> [(Names, Diet)] -> [Names]
returnAliases rts args = map returnType' rts
  where returnType' (Array _ _ Nonunique) =
          mconcat $ map (uncurry maskAliases) args
        returnType' (Array _ _ Unique) =
          mempty
        returnType' (Basic _) =
          mempty
        returnType' Mem{} =
          error "returnAliases Mem"

maskAliases :: Names -> Diet -> Names
maskAliases _   Consume = mempty
maskAliases als Observe = als

consumedInBinding :: Aliased lore => Binding lore -> Names
consumedInBinding binding = consumedInPattern (bindingPattern binding) <>
                            consumedInExp (bindingExp binding)

consumedInExp :: (Aliased lore) => Exp lore -> Names
consumedInExp (Apply _ args _) =
  mconcat (map (consumeArg . first subExpAliases) args)
  where consumeArg (als, Consume) = als
        consumeArg (_,   Observe) = mempty
consumedInExp (If _ tb fb _) =
  consumedInBody tb <> consumedInBody fb
consumedInExp (LoopOp (DoLoop _ merge _ _)) =
  mconcat (map (subExpAliases . snd) $
           filter (unique . paramDeclType . fst) merge)
consumedInExp (Op op) = consumedInOp op
consumedInExp _ = mempty

consumedInPattern :: Pattern lore -> Names
consumedInPattern pat =
  mconcat (map (consumedInBindage . patElemBindage) $
           patternContextElements pat ++ patternValueElements pat)
  where consumedInBindage BindVar = mempty
        consumedInBindage (BindInPlace _ src _) = vnameAliases src

class AliasedOp op where
  opAliases :: op -> [Names]
  consumedInOp :: op -> Names

instance AliasedOp () where
  opAliases () = []
  consumedInOp () = mempty

class (AliasedOp (OpWithAliases op),
       Eq (OpWithAliases op),
       Ord (OpWithAliases op),
       Show (OpWithAliases op),
       Pretty (OpWithAliases op),
       FreeIn (OpWithAliases op),
       Substitute (OpWithAliases op),
       Rename (OpWithAliases op)) => CanBeAliased op where
  type OpWithAliases op :: *
  removeOpAliases :: OpWithAliases op -> op
  addOpAliases :: op -> OpWithAliases op

instance CanBeAliased () where
  type OpWithAliases () = ()
  removeOpAliases = id
  addOpAliases = id
