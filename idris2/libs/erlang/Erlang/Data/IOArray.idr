module Erlang.Data.IOArray

import Data.List
import Erlang
import Erlang.Data.IORef


%default total


data ArrayData : Type -> Type where
  MkArrayData : IORef ErlTerm -> ArrayData a


-- 'unsafe' primitive access, backend dependent
-- get and set assume that the bounds have been checked. Behavious is undefined
-- otherwise.

prim__newArray : HasIO io => Int -> a -> io (ArrayData a)
prim__newArray size value = do
  arr <- pure $ erlUnsafeCall ErlTerm "array" "new" [size, MkTuple2 (MkAtom "default") (MkRaw value)]
  ref <- newIORef arr
  pure (MkArrayData ref)

prim__arrayGet : HasIO io => ArrayData a -> Int -> io a
prim__arrayGet (MkArrayData ref) pos = do
  arr <- readIORef ref
  MkRaw value <- pure $ erlUnsafeCall (Raw a) "array" "get" [pos, arr]
  pure value

prim__arraySet : HasIO io => ArrayData a -> Int -> a -> io ()
prim__arraySet (MkArrayData ref) pos value = do
  arr <- readIORef ref
  newArr <- pure $ erlUnsafeCall ErlTerm "array" "set" [pos, MkRaw value, arr]
  writeIORef ref newArr


export
record IOArray elem where
  constructor MkIOArray
  maxSize : Int
  content : ArrayData (Maybe elem)

export
max : IOArray elem -> Int
max = maxSize

export
newArray : Int -> IO (IOArray elem)
newArray size
    = pure (MkIOArray size !(prim__newArray size Nothing))

export
writeArray : IOArray elem -> Int -> elem -> IO ()
writeArray arr pos el
    = if pos < 0 || pos >= max arr
         then pure ()
         else prim__arraySet (content arr) pos (Just el)

export
readArray : IOArray elem -> Int -> IO (Maybe elem)
readArray arr pos
    = if pos < 0 || pos >= max arr
         then pure Nothing
         else prim__arrayGet (content arr) pos

-- Make a new array of the given size with the elements copied from the
-- other array
export
newArrayCopy : (newsize : Int) -> IOArray elem -> IO (IOArray elem)
newArrayCopy newsize arr
    = do let newsize' = if newsize < max arr then max arr else newsize
         arr' <- newArray newsize'
         copyFrom (content arr) (content arr') (max arr - 1)
         pure arr'
  where
    copyFrom : ArrayData (Maybe elem) ->
               ArrayData (Maybe elem) ->
               Int -> IO ()
    copyFrom old new pos
        = if pos < 0
             then pure ()
             else do el <- prim__arrayGet old pos
                     prim__arraySet new pos el
                     assert_total (copyFrom old new (pos - 1))

export
toList : IOArray elem -> IO (List (Maybe elem))
toList arr = iter 0 (max arr) []
  where
    iter : Int -> Int -> List (Maybe elem) -> IO (List (Maybe elem))
    iter pos end acc
         = if pos >= end
              then pure (reverse acc)
              else do el <- readArray arr pos
                      assert_total (iter (pos + 1) end (el :: acc))

export
fromList : List (Maybe elem) -> IO (IOArray elem)
fromList ns
    = do arr <- newArray (cast (length ns))
         addToArray 0 ns arr
         pure arr
  where
    addToArray : Int -> List (Maybe elem) -> IOArray elem -> IO ()
    addToArray loc [] arr = pure ()
    addToArray loc (Nothing :: ns) arr
        = assert_total (addToArray (loc + 1) ns arr)
    addToArray loc (Just el :: ns) arr
        = do prim__arraySet (content arr) loc (Just el)
             assert_total (addToArray (loc + 1) ns arr)
