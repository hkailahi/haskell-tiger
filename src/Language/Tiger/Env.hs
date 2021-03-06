{-# LANGUAGE OverloadedStrings #-}

module Language.Tiger.Env where
import Language.Tiger.Types
import qualified Language.Tiger.Translate as Translate
import qualified Language.Tiger.Temp as Temp
import qualified Language.Tiger.Symtab as Symtab

data EnvEntry
  = VarEntry
      { -- access :: Translate.Access
        ty :: Ty
      }
  | FunEntry
      { -- level :: Translate.Level
      -- , label :: Temp.Label
        formals :: [Ty]
      , result :: Ty
      }

venv0 :: Symtab.Symtab EnvEntry
venv0 = Symtab.fromList
  [ ("print", FunEntry [StringTy] UnitTy)
  , ("flush", FunEntry [] UnitTy)
  , ("getchar", FunEntry [] StringTy)
  , ("ord", FunEntry [StringTy] IntTy)
  , ("chr", FunEntry [IntTy] StringTy)
  , ("size", FunEntry [StringTy] IntTy)
  , ("substring", FunEntry [StringTy, IntTy, IntTy] IntTy)
  , ("concat", FunEntry [StringTy, StringTy] StringTy)
  , ("not", FunEntry [IntTy] IntTy)
  , ("exit", FunEntry [IntTy] UnitTy)
  ]

tenv0 :: Symtab.Symtab Ty
tenv0 = Symtab.fromList
  [ ("int", IntTy)
  , ("string", StringTy)
  , ("unit", UnitTy)
  , ("nil", NilTy)
  ]
