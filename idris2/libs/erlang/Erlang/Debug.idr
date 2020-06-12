module Erlang.Debug

import Erlang


%default total


export
erlPrintLn : a -> IO ()
erlPrintLn x = do
  erlUnsafeCall ErlTerm "io" "format" ["~p~n", the (List _) [MkRaw x]]
  pure ()

export
erlInspect : a -> a
erlInspect x = unsafePerformIO $ do
  erlPrintLn x
  pure x