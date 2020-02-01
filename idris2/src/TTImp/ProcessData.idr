module TTImp.ProcessData

import Core.Context
import Core.Core
import Core.Env
import Core.Hash
import Core.Metadata
import Core.Normalise
import Core.UnifyState
import Core.Value

import TTImp.BindImplicits
import TTImp.Elab.Check
import TTImp.Elab.Utils
import TTImp.Elab
import TTImp.TTImp

import Data.NameMap

%default covering

processDataOpt : {auto c : Ref Ctxt Defs} ->
                 FC -> Name -> DataOpt -> Core ()
processDataOpt fc n NoHints
    = pure ()
processDataOpt fc ndef (SearchBy dets)
    = setDetermining fc ndef dets
processDataOpt fc ndef UniqueSearch
    = setUniqueSearch fc ndef True

checkRetType : {auto c : Ref Ctxt Defs} ->
               Env Term vars -> NF vars ->
               (NF vars -> Core ()) -> Core ()
checkRetType env (NBind fc x (Pi _ _ ty) sc) chk
    = do defs <- get Ctxt
         checkRetType env !(sc defs (toClosure defaultOpts env (Erased fc False))) chk
checkRetType env nf chk = chk nf

checkIsType : {auto c : Ref Ctxt Defs} ->
              FC -> Name -> Env Term vars -> NF vars -> Core ()
checkIsType loc n env nf
    = checkRetType env nf
         (\nf => case nf of
                      NType _ => pure ()
                      _ => throw (BadTypeConType loc n))

checkFamily : {auto c : Ref Ctxt Defs} ->
              FC -> Name -> Name -> Env Term vars -> NF vars -> Core ()
checkFamily loc cn tn env nf
    = checkRetType env nf
         (\nf => case nf of
                      NType _ => throw (BadDataConType loc cn tn)
                      NTCon _ n' _ _ _ =>
                            if tn == n'
                               then pure ()
                               else throw (BadDataConType loc cn tn)
                      _ => throw (BadDataConType loc cn tn))

checkCon : {vars : _} ->
           {auto c : Ref Ctxt Defs} ->
           {auto m : Ref MD Metadata} ->
           {auto u : Ref UST UState} ->
           List ElabOpt -> NestedNames vars ->
           Env Term vars -> Visibility -> Name ->
           ImpTy -> Core Constructor
checkCon {vars} opts nest env vis tn (MkImpTy fc cn_in ty_raw)
    = do cn <- inCurrentNS cn_in
         ty_raw <- bindTypeNames [] vars ty_raw

         defs <- get Ctxt
         -- Check 'cn' is undefined
         Nothing <- lookupCtxtExact cn (gamma defs)
             | Just gdef => throw (AlreadyDefined fc cn)
         ty <-
             wrapError (InCon fc cn) $
                   checkTerm !(resolveName cn) InType opts nest env
                              (IBindHere fc (PI Rig0) ty_raw)
                              (gType fc)

         -- Check 'ty' returns something in the right family
         checkFamily fc cn tn env !(nf defs env ty)
         let fullty = abstractEnvType fc env ty
         logTermNF 5 (show cn) [] fullty

         traverse_ addToSave (keys (getMetas ty))
         addToSave cn
         log 10 $ "Saving from " ++ show cn ++ ": " ++ show (keys (getMetas ty))

         case vis of
              Public => do addHash cn
                           addHash fullty
              _ => pure ()
         pure (MkCon fc cn !(getArity defs [] fullty) fullty)

conName : Constructor -> Name
conName (MkCon _ cn _ _) = cn

-- Get the indices of the constructor type (with non-constructor parts erased)
getIndexPats : {auto c : Ref Ctxt Defs} ->
               ClosedTerm -> Core (List (NF []))
getIndexPats tm
    = do defs <- get Ctxt
         tmnf <- nf defs [] tm
         ret <- getRetType defs tmnf
         getPats defs ret
  where
    getRetType : Defs -> NF [] -> Core (NF [])
    getRetType defs (NBind fc _ (Pi _ _ _) sc)
        = do sc' <- sc defs (toClosure defaultOpts [] (Erased fc False))
             getRetType defs sc'
    getRetType defs t = pure t

    getPats : Defs -> NF [] -> Core (List (NF []))
    getPats defs (NTCon fc _ _ _ args)
        = traverse (evalClosure defs) args
    getPats defs _ = pure [] -- Can't happen if we defined the type successfully!

getDetags : {auto c : Ref Ctxt Defs} ->
            FC -> List ClosedTerm -> Core (Maybe (List Nat))
getDetags fc [] = pure (Just []) -- empty type, trivially detaggable
getDetags fc [t] = pure (Just []) -- one constructor, trivially detaggable
getDetags fc tys
   = do ps <- traverse getIndexPats tys
        case !(getDisjointPos 0 (transpose ps)) of
             [] => pure $ Nothing
             xs => pure $ Just xs
  where
    mutual
      disjointArgs : List (NF []) -> List (NF []) -> Core Bool
      disjointArgs [] _ = pure False
      disjointArgs _ [] = pure False
      disjointArgs (a :: args) (a' :: args')
          = if !(disjoint a a')
               then pure True
               else disjointArgs args args'

      disjoint : NF [] -> NF [] -> Core Bool
      disjoint (NDCon _ _ t _ args) (NDCon _ _ t' _ args')
          = if t /= t'
               then pure True
               else do defs <- get Ctxt
                       argsnf <- traverse (evalClosure defs) args
                       args'nf <- traverse (evalClosure defs) args'
                       disjointArgs argsnf args'nf
      disjoint (NTCon _ n _ _ args) (NDCon _ n' _ _ args')
          = if n /= n'
               then pure True
               else do defs <- get Ctxt
                       argsnf <- traverse (evalClosure defs) args
                       args'nf <- traverse (evalClosure defs) args'
                       disjointArgs argsnf args'nf
      disjoint (NPrimVal _ c) (NPrimVal _ c') = pure (c /= c')
      disjoint _ _ = pure False

    allDisjointWith : NF [] -> List (NF []) -> Core Bool
    allDisjointWith val [] = pure True
    allDisjointWith (NErased _ _) _ = pure False
    allDisjointWith val (nf :: nfs)
        = do ok <- disjoint val nf
             if ok then allDisjointWith val nfs
                   else pure False

    allDisjoint : List (NF []) -> Core Bool
    allDisjoint [] = pure True
    allDisjoint (NErased _ _ :: _) = pure False
    allDisjoint (nf :: nfs)
        = do ok <- allDisjoint nfs
             if ok then allDisjointWith nf nfs
                   else pure False

    -- Which argument positions have completely disjoint contructors
    getDisjointPos : Nat -> List (List (NF [])) -> Core (List Nat)
    getDisjointPos i [] = pure []
    getDisjointPos i (args :: argss)
        = do rest <- getDisjointPos (1 + i) argss
             if !(allDisjoint args)
                then pure (i :: rest)
                else pure rest

export
processData : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto m : Ref MD Metadata} ->
              {auto u : Ref UST UState} ->
              List ElabOpt -> NestedNames vars ->
              Env Term vars -> FC -> Visibility ->
              ImpData -> Core ()
processData {vars} eopts nest env fc vis (MkImpLater dfc n_in ty_raw)
    = do n <- inCurrentNS n_in
         ty_raw <- bindTypeNames [] vars ty_raw

         defs <- get Ctxt
         -- Check 'n' is undefined
         Nothing <- lookupCtxtExact n (gamma defs)
             | Just gdef => throw (AlreadyDefined fc n)

         (ty, _) <-
             wrapError (InCon fc n) $
                    elabTerm !(resolveName n) InType eopts nest env
                              (IBindHere fc (PI Rig0) ty_raw)
                              (Just (gType dfc))
         let fullty = abstractEnvType dfc env ty
         logTermNF 5 ("data " ++ show n) [] fullty

         checkIsType fc n env !(nf defs env ty)
         arity <- getArity defs [] fullty

         -- Add the type constructor as a placeholder
         tidx <- addDef n (newDef fc n Rig1 vars fullty vis
                          (TCon 0 arity [] [] False [] [] Nothing))
         addMutData (Resolved tidx)
         defs <- get Ctxt
         traverse_ (\n => setMutWith fc n (mutData defs)) (mutData defs)

         traverse_ addToSave (keys (getMetas ty))
         addToSave n
         log 10 $ "Saving from " ++ show n ++ ": " ++ show (keys (getMetas ty))

         case vis of
              Private => pure ()
              _ => do addHash n
                      addHash fullty
         pure ()

processData {vars} eopts nest env fc vis (MkImpData dfc n_in ty_raw opts cons_raw)
    = do n <- inCurrentNS n_in
         ty_raw <- bindTypeNames [] vars ty_raw

         log 1 $ "Processing " ++ show n
         defs <- get Ctxt
         (ty, _) <-
             wrapError (InCon fc n) $
                    elabTerm !(resolveName n) InType eopts nest env
                              (IBindHere fc (PI Rig0) ty_raw)
                              (Just (gType dfc))
         let fullty = abstractEnvType dfc env ty

         -- If n exists, check it's the same type as we have here, and is
         -- a data constructor.
         -- When looking up, note the data types which were undefined at the
         -- point of declaration.
         ndefm <- lookupCtxtExact n (gamma defs)
         mw <- case ndefm of
                  Nothing => pure []
                  Just ndef =>
                    case definition ndef of
                         TCon _ _ _ _ _ mw _ _ =>
                            do ok <- convert defs [] fullty (type ndef)
                               if ok then pure mw
                                     else do logTermNF 1 "Previous" [] (type ndef)
                                             logTermNF 1 "Now" [] fullty
                                             throw (AlreadyDefined fc n)
                         _ => throw (AlreadyDefined fc n)

         logTermNF 5 ("data " ++ show n) [] fullty

         checkIsType fc n env !(nf defs env ty)
         arity <- getArity defs [] fullty

         -- Add the type constructor as a placeholder while checking
         -- data constructors
         tidx <- addDef n (newDef fc n Rig1 vars fullty vis
                          (TCon 0 arity [] [] False [] [] Nothing))
         case vis of
              Private => pure ()
              _ => do addHash n
                      addHash fullty

         -- Constructors are private if the data type as a whole is
         -- export
         let cvis = if vis == Export then Private else vis
         cons <- traverse (checkCon eopts nest env cvis (Resolved tidx)) cons_raw

         let ddef = MkData (MkCon dfc n arity fullty) cons
         addData vars vis tidx ddef

         -- Type is defined mutually with every data type undefined at the
         -- point it was declared, and every data type undefined right now
         defs <- get Ctxt
         let mutWith = nub (mw ++ mutData defs)
         log 3 $ show n ++ " defined in a mutual block with " ++ show mw
         setMutWith fc (Resolved tidx) mw

         traverse_ (processDataOpt fc (Resolved tidx)) opts
         dropMutData (Resolved tidx)

         detags <- getDetags fc (map type cons)
         setDetags fc (Resolved tidx) detags

         traverse_ addToSave (keys (getMetas ty))
         addToSave n
         log 10 $ "Saving from " ++ show n ++ ": " ++ show (keys (getMetas ty))

         let connames = map conName cons
         when (not (NoHints `elem` opts)) $
              traverse_ (\x => addHintFor fc (Resolved tidx) x True False) connames

         traverse_ updateErasable (Resolved tidx :: connames)

