%
% (c) The GRASP/AQUA Project, Glasgow University, 1997-1998
%
\section{Fast strings}

Compact representations of character strings with
unique identifiers (hash-cons'ish).

\begin{code}
module FastString
       (
	FastString(..),     -- not abstract, for now.

        mkFastString,       -- :: String -> FastString
        mkFastStringNarrow, -- :: String -> FastString
        mkFastSubString,    -- :: Addr -> Int -> Int -> FastString

	mkFastString#,      -- :: Addr# -> FastString
        mkFastSubStringBA#, -- :: ByteArray# -> Int# -> Int# -> FastString

        mkFastStringInt,    -- :: [Int] -> FastString

        uniqueOfFS,	    -- :: FastString -> Int#
	lengthFS,	    -- :: FastString -> Int
	nullFastString,     -- :: FastString -> Bool

	unpackFS,	    -- :: FastString -> String
	unpackIntFS,	    -- :: FastString -> [Int]
	appendFS,	    -- :: FastString -> FastString -> FastString
        headFS,		    -- :: FastString -> Char
        headIntFS,	    -- :: FastString -> Int
        tailFS,		    -- :: FastString -> FastString
	concatFS,	    -- :: [FastString] -> FastString
        consFS,             -- :: Char -> FastString -> FastString
	indexFS,	    -- :: FastString -> Int -> Char
	nilFS,		    -- :: FastString

        hPutFS,		    -- :: Handle -> FastString -> IO ()

	LitString, 
	mkLitString#	    -- :: Addr# -> Addr
       ) where

-- This #define suppresses the "import FastString" that
-- HsVersions otherwise produces
#define COMPILING_FAST_STRING
#include "HsVersions.h"

#if __GLASGOW_HASKELL__ < 503
import PrelPack
import PrelIOBase	( IO(..) )
#else
import CString
import GHC.IOBase	( IO(..) )
#endif

import PrimPacked
import GlaExts
#if __GLASGOW_HASKELL__ < 411
import PrelAddr		( Addr(..) )
#else
import Addr		( Addr(..) )
#endif
#if __GLASGOW_HASKELL__ < 503
import PrelArr		( STArray(..), newSTArray )
import IOExts		( hPutBufBAFull )
#else
import GHC.Arr		( STArray(..), newSTArray )
import IOExts 		( hPutBufBA )
import CString		( unpackNBytesBA# )
#endif

import IOExts		( IORef, newIORef, readIORef, writeIORef )
import IO
import Char             ( chr, ord )

#define hASH_TBL_SIZE 993

#if __GLASGOW_HASKELL__ < 503
hPutBufBA = hPutBufBAFull
#endif
\end{code} 

@FastString@s are packed representations of strings
with a unique id for fast comparisons. The unique id
is assigned when creating the @FastString@, using
a hash table to map from the character string representation
to the unique ID.

\begin{code}
data FastString
  = FastString   -- packed repr. on the heap.
      Int#       -- unique id
		 --  0 => string literal, comparison
		 --  will
      Int#       -- length
      ByteArray# -- stuff

  | UnicodeStr   -- if contains characters outside '\1'..'\xFF'
      Int#       -- unique id
      [Int]      -- character numbers

instance Eq FastString where
	-- shortcut for real FastStrings
  (FastString u1 _ _) == (FastString u2 _ _) = u1 ==# u2
  a == b = case cmpFS a b of { LT -> False; EQ -> True;  GT -> False }

  (FastString u1 _ _) /= (FastString u2 _ _) = u1 /=# u2
  a /= b = case cmpFS a b of { LT -> True;  EQ -> False; GT -> True  }

instance Ord FastString where
    a <= b = case cmpFS a b of { LT -> True;  EQ -> True;  GT -> False }
    a <	 b = case cmpFS a b of { LT -> True;  EQ -> False; GT -> False }
    a >= b = case cmpFS a b of { LT -> False; EQ -> True;  GT -> True  }
    a >	 b = case cmpFS a b of { LT -> False; EQ -> False; GT -> True  }
    max x y | x >= y	=  x
            | otherwise	=  y
    min x y | x <= y	=  x
            | otherwise	=  y
    compare a b = cmpFS a b

lengthFS :: FastString -> Int
lengthFS (FastString _ l# _) = I# l#
lengthFS (UnicodeStr _ s) = length s

nullFastString :: FastString -> Bool
nullFastString (FastString _ l# _) = l# ==# 0#
nullFastString (UnicodeStr _ []) = True
nullFastString (UnicodeStr _ (_:_)) = False

unpackFS :: FastString -> String
unpackFS (FastString _ l# ba#) = unpackNBytesBA# ba# l#
unpackFS (UnicodeStr _ s) = map chr s

unpackIntFS :: FastString -> [Int]
unpackIntFS (UnicodeStr _ s) = s
unpackIntFS fs = map ord (unpackFS fs)

appendFS :: FastString -> FastString -> FastString
appendFS fs1 fs2 = mkFastStringInt (unpackIntFS fs1 ++ unpackIntFS fs2)

concatFS :: [FastString] -> FastString
concatFS ls = mkFastStringInt (concat (map unpackIntFS ls)) -- ToDo: do better

headFS :: FastString -> Char
headFS (FastString _ l# ba#) = 
 if l# ># 0# then C# (indexCharArray# ba# 0#) else error ("headFS: empty FS")
headFS (UnicodeStr _ (c:_)) = chr c
headFS (UnicodeStr _ []) = error ("headFS: empty FS")

headIntFS :: FastString -> Int
headIntFS (UnicodeStr _ (c:_)) = c
headIntFS fs = ord (headFS fs)

indexFS :: FastString -> Int -> Char
indexFS f i@(I# i#) =
 case f of
   FastString _ l# ba#
     | l# ># 0# && l# ># i#  -> C# (indexCharArray# ba# i#)
     | otherwise	     -> error (msg (I# l#))
   UnicodeStr _ s	     -> chr (s!!i)
 where
  msg l =  "indexFS: out of range: " ++ show (l,i)

tailFS :: FastString -> FastString
tailFS (FastString _ l# ba#) = mkFastSubStringBA# ba# 1# (l# -# 1#)
tailFS fs = mkFastStringInt (tail (unpackIntFS fs))

consFS :: Char -> FastString -> FastString
consFS c fs = mkFastStringInt (ord c : unpackIntFS fs)

uniqueOfFS :: FastString -> Int#
uniqueOfFS (FastString u# _ _) = u#
uniqueOfFS (UnicodeStr u# _) = u#

nilFS = mkFastString ""
\end{code}

Internally, the compiler will maintain a fast string symbol
table, providing sharing and fast comparison. Creation of
new @FastString@s then covertly does a lookup, re-using the
@FastString@ if there was a hit.

Caution: mkFastStringUnicode assumes that if the string is in the
table, it sits under the UnicodeStr constructor. Other mkFastString
variants analogously assume the FastString constructor.

\begin{code}
data FastStringTable = 
 FastStringTable
    Int#
    (MutableArray# RealWorld [FastString])

type FastStringTableVar = IORef FastStringTable

string_table :: FastStringTableVar
string_table = 
 unsafePerformIO (
   stToIO (newSTArray (0::Int,hASH_TBL_SIZE) [])
	>>= \ (STArray _ _ arr#) ->
   newIORef (FastStringTable 0# arr#))

lookupTbl :: FastStringTable -> Int# -> IO [FastString]
lookupTbl (FastStringTable _ arr#) i# =
  IO ( \ s# ->
  readArray# arr# i# s#)

updTbl :: FastStringTableVar -> FastStringTable -> Int# -> [FastString] -> IO ()
updTbl fs_table_var (FastStringTable uid# arr#) i# ls =
 IO (\ s# -> case writeArray# arr# i# ls s# of { s2# -> 
	(# s2#, () #) }) >>
 writeIORef fs_table_var (FastStringTable (uid# +# 1#) arr#)

mkFastString# :: Addr# -> FastString
mkFastString# a# =
 case strLength (A# a#) of { (I# len#) -> mkFastStringLen# a# len# }

mkFastStringLen# :: Addr# -> Int# -> FastString
mkFastStringLen# a# len# =
 unsafePerformIO  (
  readIORef string_table	>>= \ ft@(FastStringTable uid# tbl#) ->
  let
   h = hashStr a# len#
  in
--  _trace ("hashed: "++show (I# h)) $
  lookupTbl ft h	>>= \ lookup_result ->
  case lookup_result of
    [] -> 
       -- no match, add it to table by copying out the
       -- the string into a ByteArray
       -- _trace "empty bucket" $
       case copyPrefixStr (A# a#) (I# len#) of
	 (ByteArray _ _ barr#) ->  
	   let f_str = FastString uid# len# barr# in
           updTbl string_table ft h [f_str] >>
           ({- _trace ("new: " ++ show f_str)   $ -} return f_str)
    ls -> 
       -- non-empty `bucket', scan the list looking
       -- entry with same length and compare byte by byte.
       -- _trace ("non-empty bucket"++show ls) $
       case bucket_match ls len# a# of
	 Nothing -> 
           case copyPrefixStr (A# a#) (I# len#) of
	     (ByteArray _ _ barr#) ->  
              let f_str = FastString uid# len# barr# in
              updTbl string_table ft h (f_str:ls) >>
	      ( {- _trace ("new: " ++ show f_str)  $ -} return f_str)
	 Just v  -> {- _trace ("re-use: "++show v) $ -} return v)
  where
   bucket_match [] _ _ = Nothing
   bucket_match (v@(FastString _ l# ba#):ls) len# a# =
      if len# ==# l# && eqStrPrefix a# ba# l# then
	 Just v
      else
	 bucket_match ls len# a#
   bucket_match (UnicodeStr _ _ : ls) len# a# =
      bucket_match ls len# a#

mkFastSubStringBA# :: ByteArray# -> Int# -> Int# -> FastString
mkFastSubStringBA# barr# start# len# =
 unsafePerformIO  (
  readIORef string_table	>>= \ ft@(FastStringTable uid# tbl#) ->
  let
   h = hashSubStrBA barr# start# len#
  in
--  _trace ("hashed(b): "++show (I# h)) $
  lookupTbl ft h		>>= \ lookup_result ->
  case lookup_result of
    [] -> 
       -- no match, add it to table by copying out the
       -- the string into a ByteArray
       -- _trace "empty bucket(b)" $
       case copySubStrBA (ByteArray btm btm barr#) (I# start#) (I# len#) of
         (ByteArray _ _ ba#) ->  
          let f_str = FastString uid# len# ba# in
          updTbl string_table ft h [f_str]     >>
          -- _trace ("new(b): " ++ show f_str)   $
	  return f_str
    ls -> 
       -- non-empty `bucket', scan the list looking
       -- entry with same length and compare byte by byte. 
       -- _trace ("non-empty bucket(b)"++show ls) $
       case bucket_match ls start# len# barr# of
	 Nothing -> 
          case copySubStrBA (ByteArray btm btm barr#) (I# start#) (I# len#) of
            (ByteArray _ _ ba#) ->  
              let f_str = FastString uid# len# ba# in
              updTbl string_table ft h (f_str:ls) >>
	      -- _trace ("new(b): " ++ show f_str)   $
	      return f_str
	 Just v  -> 
              -- _trace ("re-use(b): "++show v) $
	      return v
  )
 where
   btm = error ""

   bucket_match [] _ _ _ = Nothing
   bucket_match (v:ls) start# len# ba# =
    case v of
     FastString _ l# barr# ->
      if len# ==# l# && eqStrPrefixBA barr# ba# start# len# then
	 Just v
      else
	 bucket_match ls start# len# ba#
     UnicodeStr _ _ -> bucket_match ls start# len# ba#

mkFastStringUnicode :: [Int] -> FastString
mkFastStringUnicode s =
 unsafePerformIO  (
  readIORef string_table	>>= \ ft@(FastStringTable uid# tbl#) ->
  let
   h = hashUnicode s
  in
--  _trace ("hashed(b): "++show (I# h)) $
  lookupTbl ft h		>>= \ lookup_result ->
  case lookup_result of
    [] -> 
       -- no match, add it to table by copying out the
       -- the string into a [Int]
          let f_str = UnicodeStr uid# s in
          updTbl string_table ft h [f_str]     >>
          -- _trace ("new(b): " ++ show f_str)   $
	  return f_str
    ls -> 
       -- non-empty `bucket', scan the list looking
       -- entry with same length and compare byte by byte. 
       -- _trace ("non-empty bucket(b)"++show ls) $
       case bucket_match ls of
	 Nothing -> 
              let f_str = UnicodeStr uid# s in
              updTbl string_table ft h (f_str:ls) >>
	      -- _trace ("new(b): " ++ show f_str)   $
	      return f_str
	 Just v  -> 
              -- _trace ("re-use(b): "++show v) $
	      return v
  )
 where
   bucket_match [] = Nothing
   bucket_match (v@(UnicodeStr _ s'):ls) =
       if s' == s then Just v else bucket_match ls
   bucket_match (FastString _ _ _ : ls) = bucket_match ls

mkFastStringNarrow :: String -> FastString
mkFastStringNarrow str =
 case packString str of
  (ByteArray _ (I# len#) frozen#) -> 
    mkFastSubStringBA# frozen# 0# len#
    {- 0-indexed array, len# == index to one beyond end of string,
       i.e., (0,1) => empty string.    -}

mkFastString :: String -> FastString
mkFastString str = if all good str
    then mkFastStringNarrow str
    else mkFastStringUnicode (map ord str)
    where
    good c = c >= '\1' && c <= '\xFF'

mkFastStringInt :: [Int] -> FastString
mkFastStringInt str = if all good str
    then mkFastStringNarrow (map chr str)
    else mkFastStringUnicode str
    where
    good c = c >= 1 && c <= 0xFF

mkFastSubString :: Addr -> Int -> Int -> FastString
mkFastSubString (A# a#) (I# start#) (I# len#) =
 mkFastStringLen# (addrOffset# a# start#) len#
\end{code}

\begin{code}
hashStr  :: Addr# -> Int# -> Int#
 -- use the Addr to produce a hash value between 0 & m (inclusive)
hashStr a# len# =
  case len# of
   0# -> 0#
   1# -> ((ord# c0 *# 631#) +# len#) `remInt#` hASH_TBL_SIZE#
   2# -> ((ord# c0 *# 631#) +# (ord# c1 *# 217#) +# len#) `remInt#` hASH_TBL_SIZE#
   _  -> ((ord# c0 *# 631#) +# (ord# c1 *# 217#) +# (ord# c2 *# 43#) +# len#) `remInt#` hASH_TBL_SIZE#
  where
    c0 = indexCharOffAddr# a# 0#
    c1 = indexCharOffAddr# a# (len# `quotInt#` 2# -# 1#)
    c2 = indexCharOffAddr# a# (len# -# 1#)
{-
    c1 = indexCharOffAddr# a# 1#
    c2 = indexCharOffAddr# a# 2#
-}

hashSubStrBA  :: ByteArray# -> Int# -> Int# -> Int#
 -- use the byte array to produce a hash value between 0 & m (inclusive)
hashSubStrBA ba# start# len# =
  case len# of
   0# -> 0#
   1# -> ((ord# c0 *# 631#) +# len#) `remInt#` hASH_TBL_SIZE#
   2# -> ((ord# c0 *# 631#) +# (ord# c1 *# 217#) +# len#) `remInt#` hASH_TBL_SIZE#
   _  -> ((ord# c0 *# 631#) +# (ord# c1 *# 217#) +# (ord# c2 *# 43#) +# len#) `remInt#` hASH_TBL_SIZE#
  where
    c0 = indexCharArray# ba# 0#
    c1 = indexCharArray# ba# (len# `quotInt#` 2# -# 1#)
    c2 = indexCharArray# ba# (len# -# 1#)

--    c1 = indexCharArray# ba# 1#
--    c2 = indexCharArray# ba# 2#

hashUnicode :: [Int] -> Int#
 -- use the Addr to produce a hash value between 0 & m (inclusive)
hashUnicode [] = 0#
hashUnicode [I# c0] = ((c0 *# 631#) +# 1#) `remInt#` hASH_TBL_SIZE#
hashUnicode [I# c0, I# c1] = ((c0 *# 631#) +# (c1 *# 217#) +# 2#) `remInt#` hASH_TBL_SIZE#
hashUnicode s = ((c0 *# 631#) +# (c1 *# 217#) +# (c2 *# 43#) +# len#) `remInt#` hASH_TBL_SIZE#
  where
    I# len# = length s
    I# c0 = s !! 0
    I# c1 = s !! (I# (len# `quotInt#` 2# -# 1#))
    I# c2 = s !! (I# (len# -# 1#))

\end{code}

\begin{code}
cmpFS :: FastString -> FastString -> Ordering
cmpFS (UnicodeStr u1# s1) (UnicodeStr u2# s2) = if u1# ==# u2# then EQ
    else compare s1 s2
cmpFS (UnicodeStr _ s1) s2 = compare s1 (unpackIntFS s2)
cmpFS s1 (UnicodeStr _ s2) = compare (unpackIntFS s1) s2
cmpFS (FastString u1# _ b1#) (FastString u2# _ b2#) = -- assume non-null chars
  if u1# ==# u2# then
     EQ
  else
   unsafePerformIO (
    _ccall_ strcmp (ByteArray bot bot b1#) (ByteArray bot bot b2#) >>= \ (I# res) ->
    return (
    if      res <#  0# then LT
    else if res ==# 0# then EQ
    else		    GT
    ))
  where
   bot :: Int
   bot = error "tagCmp"
\end{code}

Outputting @FastString@s is quick, just block copying the chunk (using
@fwrite@).

\begin{code}
hPutFS :: Handle -> FastString -> IO ()
hPutFS handle (FastString _ l# ba#)
  | l# ==# 0#  = return ()
  | otherwise  = do mba <- stToIO $ unsafeThawByteArray (ByteArray (bot::Int) bot ba#)
                    hPutBufBA  handle mba (I# l#)
 where
  bot = error "hPutFS.ba"

-- ONLY here for debugging the NCG (so -ddump-stix works for string
-- literals); no idea if this is really necessary.  JRS, 010131
hPutFS handle (UnicodeStr _ is) 
  = hPutStr handle ("(UnicodeStr " ++ show is ++ ")")
\end{code}

Here for convenience only.

\begin{code}
type LitString = Addr
-- ToDo: make it a Ptr when we don't have to support 4.08 any more

mkLitString# :: Addr# -> LitString
mkLitString# a# = A# a#
\end{code}
