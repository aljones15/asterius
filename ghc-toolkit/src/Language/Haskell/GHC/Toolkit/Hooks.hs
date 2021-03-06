{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Language.Haskell.GHC.Toolkit.Hooks
  ( hooksFromCompiler
  ) where

import qualified CmmInfo as GHC
import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Data.Data (Data, gmapQl)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified DriverPhases as GHC
import qualified DriverPipeline as GHC
import qualified DynFlags as GHC
import qualified ForeignCall as GHC
import qualified Hooks as GHC
import qualified HscMain as GHC
import qualified HscTypes as GHC
import Language.Haskell.GHC.Toolkit.Compiler
import qualified Module as GHC
import qualified PipelineMonad as GHC
import qualified StgCmm as GHC
import qualified Stream
import Type.Reflection

hasJSFFI :: Data a => a -> Bool
hasJSFFI t =
  case eqTypeRep (typeOf t) (typeRep @GHC.CCallConv) of
    Just HRefl ->
      case t of
        GHC.JavaScriptCallConv -> True
        _ -> False
    _ -> gmapQl (||) False hasJSFFI t

hooksFromCompiler :: Compiler -> IO GHC.Hooks
hooksFromCompiler Compiler {..} = do
  mods_set_ref <- newMVar Set.empty
  parsed_map_ref <- newMVar Map.empty
  typechecked_map_ref <- newMVar Map.empty
  stg_map_ref <- newMVar Map.empty
  cmm_map_ref <- newMVar Map.empty
  cmm_raw_map_ref <- newMVar Map.empty
  cmm_ref <- newEmptyMVar
  cmm_raw_ref <- newEmptyMVar
  jsffi_set_ref <- newMVar Set.empty
  pure
    GHC.emptyHooks
      { GHC.tcRnModuleHook =
          Just $ \mod_summary@GHC.ModSummary {..} save_rn_syntax parsed_module_orig -> do
            parsed_module <- patchParsed mod_summary parsed_module_orig
            typechecked_module <-
              GHC.tcRnModule' mod_summary save_rn_syntax parsed_module >>=
              patchTypechecked mod_summary
            let store :: MVar (Map.Map GHC.Module v) -> v -> IO ()
                store ref v = modifyMVar_ ref $ pure . Map.insert ms_mod v
            liftIO $ do
              store parsed_map_ref parsed_module
              store typechecked_map_ref typechecked_module
              when (hasJSFFI $ GHC.hpm_module parsed_module_orig) $
                modifyMVar_ jsffi_set_ref $ pure . Set.insert ms_mod
            pure typechecked_module
      , GHC.stgCmmHook =
          Just $ \dflags this_mod data_tycons cost_centre_info stg_binds hpc_info -> do
            Stream.liftIO $
              modifyMVar_ stg_map_ref $ pure . Map.insert this_mod stg_binds
            GHC.codeGen
              dflags
              this_mod
              data_tycons
              cost_centre_info
              stg_binds
              hpc_info
      , GHC.cmmToRawCmmHook =
          Just $ \dflags maybe_ms_mod cmms -> do
            rawcmms <- GHC.cmmToRawCmm dflags maybe_ms_mod cmms
            case maybe_ms_mod of
              Just ms_mod -> do
                let store :: MVar (Map.Map GHC.Module v) -> v -> IO ()
                    store ref v = modifyMVar_ ref $ pure . Map.insert ms_mod v
                store cmm_map_ref cmms
                store cmm_raw_map_ref rawcmms
              _ -> do
                putMVar cmm_ref cmms
                putMVar cmm_raw_ref rawcmms
            pure rawcmms
      , GHC.runPhaseHook =
          Just $ \phase input_fn dflags ->
            case phase of
              GHC.HscOut src_flavour _ (GHC.HscRecomp cgguts mod_summary@GHC.ModSummary {..}) -> do
                r <-
                  do skip_gcc <-
                       liftIO $ do
                         s <- readMVar jsffi_set_ref
                         pure $ Set.member ms_mod s
                     if skip_gcc
                       then do
                         output_fn <-
                           GHC.phaseOutputFilename $
                           GHC.hscPostBackendPhase dflags src_flavour $
                           GHC.hscTarget dflags
                         GHC.PipeState {GHC.hsc_env = hsc_env'} <-
                           GHC.getPipeState
                         (outputFilename, _, _) <-
                           liftIO $
                           GHC.hscGenHardCode
                             hsc_env'
                             cgguts
                             mod_summary
                             output_fn
                         GHC.setForeignOs []
                         pure (GHC.RealPhase GHC.StopLn, outputFilename)
                       else GHC.runPhase phase input_fn dflags
                f <-
                  liftIO $
                  modifyMVar mods_set_ref $ \s ->
                    pure (Set.insert ms_mod s, Set.member ms_mod s)
                if f
                  then liftIO $ do
                         let clean :: MVar (Map.Map GHC.Module a) -> IO ()
                             clean ref =
                               modifyMVar_ ref $ pure . Map.delete ms_mod
                         clean parsed_map_ref
                         clean typechecked_map_ref
                         clean stg_map_ref
                         clean cmm_map_ref
                         clean cmm_raw_map_ref
                  else (do let fetch :: MVar (Map.Map GHC.Module v) -> IO v
                               fetch ref =
                                 modifyMVar
                                   ref
                                   (\m ->
                                      let (Just v, m') =
                                            Map.updateLookupWithKey
                                              (\_ _ -> Nothing)
                                              ms_mod
                                              m
                                       in pure (m', v))
                           ir <-
                             liftIO $
                             HaskellIR <$> fetch parsed_map_ref <*>
                             fetch typechecked_map_ref <*>
                             pure cgguts <*>
                             fetch stg_map_ref <*>
                             (fetch cmm_map_ref >>= Stream.collect) <*>
                             (fetch cmm_raw_map_ref >>= Stream.collect)
                           withHaskellIR mod_summary ir)
                pure r
              GHC.RealPhase GHC.Cmm -> do
                r <- GHC.runPhase phase input_fn dflags
                ir <-
                  liftIO $
                  CmmIR <$> (takeMVar cmm_ref >>= Stream.collect) <*>
                  (takeMVar cmm_raw_ref >>= Stream.collect)
                withCmmIR ir
                pure r
              _ -> GHC.runPhase phase input_fn dflags
      }
