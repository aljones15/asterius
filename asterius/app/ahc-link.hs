{-# LANGUAGE RecordWildCards #-}

import Asterius.Main
import Asterius.Types
import Data.Maybe
import Options.Applicative
import System.FilePath

parseTask :: Parser Task
parseTask =
  (\t i m_wasm m_node m_report m_gv wasm_toolkit dbg ir r m_hs m_with_i ghc_flags export_funcs root_syms ->
     Task
       { target = t
       , input = i
       , outputWasm = fromMaybe (i -<.> "wasm") m_wasm
       , outputJS = fromMaybe (i -<.> "js") m_node
       , outputLinkReport = m_report
       , outputGraphViz = m_gv
       , binaryen = wasm_toolkit
       , debug = dbg
       , outputIR = ir || dbg
       , run = r
       , heapSize = maybe 1024 read m_hs
       , asteriusInstanceCallback =
           fromMaybe
             "i => {\ni.wasmInstance.exports.hs_init();\ni.wasmInstance.exports.rts_evalLazyIO(i.staticsSymbolMap.MainCapability, i.staticsSymbolMap.Main_main_closure, 0);\n}"
             m_with_i
       , extraGHCFlags = ghc_flags
       , exportFunctions =
           [AsteriusEntitySymbol {entityName = sym} | sym <- export_funcs]
       , extraRootSymbols =
           [AsteriusEntitySymbol {entityName = sym} | sym <- root_syms]
       }) <$>
  fmap
    (\f ->
       if f
         then Browser
         else Node)
    (switch (long "browser" <> help "Target browsers instead of Node.js")) <*>
  strOption (long "input" <> help "Path of the Main module") <*>
  optional
    (strOption
       (long "output-wasm" <>
        help "Output path of WebAssembly binary, defaults to same path of Main")) <*>
  optional
    (strOption
       (long "output-js" <>
        help
          "Output path of JavaScript, defaults to same path of Main. Must be the same directory as the WebAssembly binary.")) <*>
  optional
    (strOption
       (long "output-link-report" <> help "Output path of linking report")) <*>
  optional
    (strOption
       (long "output-graphviz" <>
        help "Output path of GraphViz file of symbol dependencies")) <*>
  switch (long "binaryen" <> help "Use the binaryen backend") <*>
  switch (long "debug" <> help "Enable debug mode in the runtime") <*>
  switch (long "output-ir" <> help "Output Asterius IR of compiled modules") <*>
  switch (long "run" <> help "Run the compiled module with Node.js") <*>
  optional
    (strOption
       (long "heap-size" <>
        help
          "Heap size in MBs, used for both nursery/object pool. Defaults to 1024.")) <*>
  optional
    (strOption
       (long "asterius-instance-callback" <>
        help
          "Supply a JavaScript callback expression which will be invoked on the initiated asterius instance. Defaults to calling Main.main")) <*>
  many (strOption (long "ghc-option" <> help "Extra GHC flags")) <*>
  many
    (strOption (long "export-function" <> help "Symbol of exported function")) <*>
  many
    (strOption
       (long "extra-root-symbol" <>
        help "Symbol of extra root entity, e.g. Main_f_closure"))

opts :: ParserInfo Task
opts =
  info
    (parseTask <**> helper)
    (fullDesc <>
     progDesc "Producing a standalone WebAssembly binary from Haskell" <>
     header "ahc-link - Linker for the Asterius compiler")

main :: IO ()
main = do
  task@Task {..} <- execParser opts
  ahcLinkMain task
