module GI.Callable
    ( genCallable

    , hOutType
    , arrayLengths
    , arrayLengthsMap
    ) where

import Control.Applicative ((<$>))
import Control.Monad (forM, forM_, when)
import Data.List (intercalate)
import Data.Typeable (typeOf)
import qualified Data.Map as Map

import GI.API
import GI.Code
import GI.Conversions
import GI.GObject
import GI.SymbolNaming
import GI.Transfer
import GI.Type
import GI.Util
import GI.Internal.ArgInfo

padTo n s = s ++ replicate (n - length s) ' '

hOutType callable outArgs ignoreReturn = do
  hReturnType <- case returnType callable of
                   TBasicType TVoid -> return $ typeOf ()
                   _                -> if ignoreReturn
                                       then return $ typeOf ()
                                       else haskellType $ returnType callable
  hOutArgTypes <- mapM (haskellType . argType) outArgs
  let maybeHReturnType = if returnMayBeNull callable && not ignoreReturn
                         then "Maybe" `con` [hReturnType]
                         else hReturnType
  return $ case (outArgs, show maybeHReturnType) of
             ([], _)   -> maybeHReturnType
             (_, "()") -> "(,)" `con` hOutArgTypes
             _         -> "(,)" `con` (maybeHReturnType : hOutArgTypes)

mkForeignImport :: String -> Callable -> Bool -> CodeGen ()
mkForeignImport symbol callable throwsGError = foreignImport $ do
    line first
    indent $ do
        mapM_ (\a -> line =<< fArgStr a) (args callable)
        when throwsGError $
               line $ padTo 40 "Ptr (Ptr ()) -> " ++ "-- error"
        line =<< last
    where
    first = "foreign import ccall \"" ++ symbol ++ "\" " ++
                symbol ++ " :: "
    fArgStr arg = do
        ft <- foreignType $ argType arg
        let ft' = case direction arg of
              DirectionInout -> ptr ft
              DirectionOut -> ptr ft
              DirectionIn -> ft
        let start = show ft' ++ " -> "
        return $ padTo 40 start ++ "-- " ++ argName arg
                   ++ " : " ++ show (argType arg)
    last = show <$> io <$> case returnType callable of
                             TBasicType TVoid -> return $ typeOf ()
                             _  -> foreignType (returnType callable)

-- Given a type find the typeclasses the type belongs to, and return
-- the representation of the type in the function signature and the
-- list of typeclass constraints for the type.
argumentType :: [Char] -> Type -> CodeGen ([Char], String, [String])
argumentType [] _               = error "out of letters"
argumentType letters (TGList a) = do
  (ls, name, constraints) <- argumentType letters a
  return (ls, "[" ++ name ++ "]", constraints)
argumentType letters (TGSList a) = do
  (ls, name, constraints) <- argumentType letters a
  return (ls, "[" ++ name ++ "]", constraints)
argumentType letters@(l:ls) t   = do
  api <- findAPI t
  s <- show <$> haskellType t
  case api of
    Just (APIInterface _) -> return (ls, [l],
                                     [interfaceClassName s ++ " " ++ [l],
                                      "ManagedPtr " ++ [l]])
    -- Instead of restricting to the actual class,
    -- we allow for any object descending from it.
    Just (APIObject _) -> do
        isGO <- isGObject t
        if isGO
        then return (ls, [l], [klass s ++ " " ++ [l],
                               "ManagedPtr " ++ [l]])
        else return (letters, s, [])
    _ -> return (letters, s, [])

-- Given an (in) argument to a function, return whether it should be
-- wrapped in a maybe type (useful for nullable types).
wrapMaybe :: Arg -> Bool
wrapMaybe arg =
    if direction arg == DirectionIn && mayBeNull arg
    then case argType arg of
           -- NULL GLists and GSLists are semantically the same as an
           -- empty list, so they don't need a Maybe wrapper on their
           -- type.
           TGList _ -> False
           TGSList _ -> False
           _ -> True
    else False

-- Given the list of arguments returns the list of constraints and the
-- list of types in the signature.
inArgInterfaces :: [Arg] -> CodeGen ([String], [String])
inArgInterfaces inArgs = rec "abcdefghijklmnopqrtstuvwxyz" inArgs
  where
    rec :: [Char] -> [Arg] -> CodeGen ([String], [String])
    rec _ [] = return ([], [])
    rec letters (arg:args) = do
      (ls, t, cons) <- argumentType letters $ argType arg
      --- XXX G(S)List types, and some containers (such as C-arrays)
      --- are always nullable, we do not need to map those to Maybe types.
      let t' = if wrapMaybe arg
               then "Maybe (" ++ t ++ ")"
               else t
      (restCons, restTypes) <- rec ls args
      return (cons ++ restCons, t' : restTypes)

-- Given a callable, return a list of (array, length) pairs, where in
-- each pair "length" is the argument holding the length of the
-- (non-zero-terminated, non-fixed size) C array.
arrayLengthsMap :: Callable -> [(Arg, Arg)] -- List of (array, length)
arrayLengthsMap callable = go (args callable) []
    where
      go :: [Arg] -> [(Arg, Arg)] -> [(Arg, Arg)]
      go [] acc = acc
      go (a:as) acc = case argType a of
                        TCArray False fixedSize length _ ->
                            if fixedSize > -1
                            then go as acc
                            else go as $ (a, (args callable)!!length) : acc
                        _ -> go as acc

-- Return the list of arguments of the callable that contain length
-- arguments, including a possible length for the result of calling
-- the function.
arrayLengths :: Callable -> [Arg]
arrayLengths callable = map snd (arrayLengthsMap callable) ++
               -- Often one of the arguments is just the length of
               -- the result.
               case returnType callable of
                 TCArray False (-1) length _ -> [(args callable)!!length]
                 _ -> []

-- Whether to skip the return value in the generated bindings. The
-- C convention is that functions throwing an error and returning
-- a gboolean set the boolean to TRUE iff there is no error, so
-- the information is always implicit in whether we emit an
-- exception or not, so the return value can be omitted from the
-- generated bindings without loss of information (and omitting it
-- gives rise to a nicer API). See
-- https://bugzilla.gnome.org/show_bug.cgi?id=649657
skipRetVal :: Callable -> Bool -> Bool
skipRetVal callable throwsGError =
    (skipReturn callable) ||
         (throwsGError && returnType callable == TBasicType TBoolean)

freeInArgs' :: (Arg -> String -> String -> CodeGen [String]) ->
               Callable -> Map.Map String String -> CodeGen [String]
freeInArgs' freeFn callable nameMap = concat <$> actions
    where
      actions :: CodeGen [[String]]
      actions = forM (args callable) $ \arg ->
        case Map.lookup (escapeReserved $ argName arg) nameMap of
          Just name -> freeFn arg name $
                       -- Pass in the length argument in case it's needed.
                       case argType arg of
                         TCArray False (-1) length _ ->
                             escapeReserved $ argName $ (args callable)!!length
                         _ -> undefined
          Nothing -> error $ "freeInArgs: do not understand " ++ show arg

-- Return the list of actions freeing the memory associated with the
-- callable variables. This is run if the call to the C function
-- succeeds, if there is an error freeInArgsOnError below is called
-- instead.
freeInArgs = freeInArgs' freeInArg

-- Return the list of actions freeing the memory associated with the
-- callable variables. This is run in case there is an error during
-- the call.
freeInArgsOnError = freeInArgs' freeInArgOnError

-- Returns whether the given type corresponds to a ManagedPtr
-- instance (a thin wrapper over a ForeignPtr).
isManaged   :: Type -> CodeGen Bool
isManaged t = do
  a <- findAPI t
  case a of
    Just (APIObject _)    -> return True
    Just (APIInterface _) -> return True
    Just (APIStruct _)    -> return True
    Just (APIUnion _)     -> return True
    _                     -> return False

-- XXX We should free the memory allocated for the [a] -> Glist (a')
-- etc. conversions.
genCallable :: Name -> String -> Callable -> Bool -> CodeGen ()
genCallable n symbol callable throwsGError = do
    group $ do
      line $ "-- Args : " ++ (show $ args callable)
      line $ "-- Lengths : " ++ (show $ arrayLengths callable)
      line $ "-- hInArgs : " ++ show hInArgs
      line $ "-- returnType : " ++ (show $ returnType callable)
      line $ "-- throws : " ++ (show throwsGError)
      line $ "-- Skip return : " ++ (show $ skipReturn callable)
      when (skipReturn callable && returnType callable /= TBasicType TBoolean) $
           do line "-- XXX return value ignored, but it is not a boolean."
              line "--     This may be a memory leak?"
    mkForeignImport symbol callable throwsGError
    wrapper

    where
    inArgs = filter ((`elem` [DirectionIn, DirectionInout]) . direction) $ args callable
    -- We do not need to expose the length of array arguments to Haskell code.
    hInArgs = filter (not . (`elem` (arrayLengths callable))) inArgs
    outArgs = filter ((`elem` [DirectionOut, DirectionInout]) . direction) $ args callable
    hOutArgs = filter (not . (`elem` (arrayLengths callable))) outArgs
    ignoreReturn = skipRetVal callable throwsGError
    wrapper = group $ do
        let argName' = escapeReserved . argName
        name <- lowerName n
        signature
        line $
            name ++ " " ++
            intercalate " " (map argName' hInArgs) ++
            " = do"
        indent $ do
          readInArrayLengths
          inArgNames <- convertIn
          -- Map from argument names to names passed to the C function
          let nameMap = Map.fromList $ flip zip inArgNames
                                             $ map argName' $ args callable
          if throwsGError
          then do
            line "onException (do"
            indent $ do
              invokeCFunction inArgNames
              result <- convertResult nameMap
              pps <- convertOut nameMap
              touchInArgs
              mapM_ line =<< freeInArgs callable nameMap
              returnResult result pps
            line " ) (do"
            indent $ do
                   actions <- freeInArgsOnError callable nameMap
                   case actions of
                       [] -> line $ "return ()"
                       _ -> mapM_ line actions
            line " )"
          else do
            invokeCFunction inArgNames
            result <- convertResult nameMap
            pps <- convertOut nameMap
            touchInArgs
            mapM_ line =<< freeInArgs callable nameMap
            returnResult result pps

    signature = do
        name <- lowerName n
        line $ name ++ " ::"
        (constraints, types) <- inArgInterfaces hInArgs
        indent $ do
            when (not $ null constraints) $ do
                line $ "(" ++ intercalate ", " constraints ++ ") =>"
            forM_ (zip types hInArgs) $ \(t, a) ->
                 line $ withComment (t ++ " ->") $ argName a
            result >>= line
    result = show <$> io <$> hOutType callable hOutArgs ignoreReturn
    convertIn = forM (args callable) $ \arg -> do
        ft <- foreignType $ argType arg
        let name = escapeReserved $ argName arg
        case direction arg of
          DirectionIn ->
              if wrapMaybe arg
              then do
                let maybeName = "maybe" ++ ucFirst name
                line $ maybeName ++ " <- case " ++ name ++ " of"
                indent $ do
                     line $ "Nothing -> return nullPtr"
                     let jName = "j" ++ ucFirst name
                     line $ "Just " ++ jName ++ " -> do"
                     indent $ do
                             converted <- convert jName $ hToF (argType arg)
                                                               (transfer arg)
                             line $ "return " ++ converted
                return maybeName
             else convert name $ hToF (argType arg) (transfer arg)
          DirectionInout ->
              do name' <- convert name $ hToF (argType arg) (transfer arg)
                 name'' <- genConversion (prime name') $
                             literal $ M $ "malloc :: " ++ show (io $ ptr ft)
                 line $ "poke " ++ name'' ++ " " ++ name'
                 return name''
          DirectionOut -> genConversion name $
                            literal $ M $ "malloc :: " ++ show (io $ ptr ft)
    -- Read the length of in array arguments from the corresponding
    -- Haskell objects.
    readInArrayLengths = forM_ (arrayLengthsMap callable) $ \(array, length) ->
       when (array `elem` hInArgs) $
            do let lvar = escapeReserved $ argName length
                   avar = escapeReserved $ argName array
               if wrapMaybe array
               then do
                 line $ "let " ++ lvar ++ " = case " ++ avar ++ " of"
                 indent $ indent $ do
                      line $ "Nothing -> 0"
                      let jarray = "j" ++ ucFirst avar
                      line $ "Just " ++ jarray ++ " -> " ++
                           computeArrayLength jarray (argType array)
               else line $ "let " ++ lvar ++ " = " ++
                         computeArrayLength avar (argType array)
    invokeCFunction argNames = do
      let returnBind = case returnType callable of
                         TBasicType TVoid -> ""
                         _                -> if ignoreReturn
                                             then "_ <- "
                                             else "result <- "
          maybeCatchGErrors = if throwsGError
                              then "propagateGError $ "
                              else ""
      line $ returnBind ++ maybeCatchGErrors
                   ++ symbol ++ concatMap (" " ++) argNames

    convertResult :: Map.Map String String -> CodeGen String
    convertResult nameMap =
        if ignoreReturn || returnType callable == TBasicType TVoid
        then return undefined
        else case returnType callable of
               -- Non-zero terminated C arrays require knowledge of
               -- the length, so we deal with them directly.
               t@(TCArray False _ _ _) ->
                   convertOutCArray t "result" nameMap (returnTransfer callable)
               t -> do
                 result <- convert "result" $ fToH (returnType callable)
                                                   (returnTransfer callable)
                 when (returnTransfer callable == TransferEverything) $
                      mapM_ line =<< freeElements t "result" undefined
                 when (returnTransfer callable /= TransferNothing) $
                      mapM_ line =<< freeContainer t "result"
                 return result

    convertOut :: Map.Map String String -> CodeGen [String]
    convertOut nameMap = do
      -- Convert out parameters and result
      forM hOutArgs $ \arg -> do
         let name = escapeReserved $ argName arg
             inName = case Map.lookup name nameMap of
                        Just name' -> name'
                        Nothing -> error $ "Parameter " ++
                                      name ++ " not found!"
         case argType arg of
           t@(TCArray False _ _ _) ->
               do aname' <- genConversion inName $ apply $ M "peek"
                  convertOutCArray t aname' nameMap (transfer arg)
           t -> do
             peeked <- genConversion inName $ apply $ M "peek"
             result <- convert peeked $ fToH (argType arg) (transfer arg)
             -- Free the memory associated with the out argument
             when (transfer arg == TransferEverything) $
                  mapM_ line =<< freeElements t peeked undefined
             when (transfer arg /= TransferNothing) $
                  mapM_ line =<< freeContainer t peeked
             return result

    returnResult :: String -> [String] -> CodeGen ()
    returnResult result pps =
      if ignoreReturn || returnType callable == TBasicType TVoid
      then case pps of
             []      -> line "return ()"
             (pp:[]) -> line $ "return " ++ pp
             _       -> line $ "return (" ++ intercalate ", " pps ++ ")"
      else do
        case pps of
          [] -> line $ "return " ++ result
          _  -> line $ "return (" ++ intercalate ", " (result : pps) ++ ")"

    -- Convert a non-zero terminated out array, stored in a variable
    -- named "aname".
    convertOutCArray :: Type -> String -> Map.Map String String ->
                        Transfer -> CodeGen String
    convertOutCArray t@(TCArray False fixed length _) aname nameMap transfer = do
      if fixed > -1
      then do
        unpacked <- convert aname $ unpackCArray (show fixed) t transfer
        -- Free the memory associated with the array
        when (transfer == TransferEverything) $
             mapM_ line =<< freeElements t aname undefined
        when (transfer /= TransferNothing) $
             mapM_ line =<< freeContainer t aname
        return unpacked
      else do
        let lname = escapeReserved $ argName $ (args callable)!!length
            lname' = case Map.lookup lname nameMap of
                       Just n -> n
                       Nothing -> error $ "Couldn't find out array length " ++
                                                   lname
        lname'' <- genConversion lname' $ apply $ M "peek"
        unpacked <- convert aname $ unpackCArray lname'' t transfer
        -- Free the memory associated with the array
        when (transfer == TransferEverything) $
             mapM_ line =<< freeElements t aname lname''
        when (transfer /= TransferNothing) $
             mapM_ line =<< freeContainer t aname
        return unpacked
    -- Remove the warning, this should never be reached.
    convertOutCArray t _ _ _ =
        error $ "convertOutCArray : unexpected " ++ show t
    -- Touch in arguments so we are sure that they exist when the C
    -- function was called.
    touchInArgs = forM_ (args callable) $ \arg -> do
        when (direction arg == DirectionIn) $ do
           let name = escapeReserved $ argName arg
           case argType arg of
             (TGList a) -> do
               managed <- isManaged a
               when managed $ line $ "mapM_ touchManagedPtr " ++ name
             (TGSList a) -> do
               managed <- isManaged a
               when managed $ line $ "mapM_ touchManagedPtr " ++ name
             _ -> do
               managed <- isManaged (argType arg)
               when managed $ line $ if wrapMaybe arg
                    then "whenJust " ++ name ++ " touchManagedPtr"
                    else "touchManagedPtr " ++ name
    withComment a b = padTo 40 a ++ "-- " ++ b
