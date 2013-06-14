-- Routines dealing with memory management in marshalling functions.

module GI.Transfer
    ( freeInArg
    , freeElements
    , freeContainer

    , freeInArgOnError
    ) where

import Control.Applicative ((<$>), (<*>))
import Data.Maybe (fromMaybe)

import GI.API
import GI.Code
import GI.GObject
import GI.Type
import GI.Util
import GI.Internal.ArgInfo

-- Basic primitives for freeing the given types. For containers this
-- is only for freeing the container itself, freeing the elements is
-- done separately.
basicFreeFn :: Type -> Maybe String
basicFreeFn (TBasicType TUTF8) = Just "F.free"
basicFreeFn (TBasicType TFileName) = Just "F.free"
basicFreeFn (TBasicType _) = Nothing
basicFreeFn (TInterface _ _) = Nothing
basicFreeFn (TCArray _ _ _ _) = Just "F.free"
basicFreeFn (TGArray _) = Just "unrefGArray"
basicFreeFn (TPtrArray _) = Just "unrefPtrArray"
basicFreeFn (TByteArray) = Just "unrefByteArray"
basicFreeFn (TGList _) = Just "g_list_free"
basicFreeFn (TGSList _) = Just "g_slist_free"
basicFreeFn (TGHash _ _) = Nothing
basicFreeFn (TError) = Nothing

-- Basic free primitives in the case that an error occured.
basicFreeFnOnError :: Type -> Transfer -> CodeGen (Maybe String)
basicFreeFnOnError (TBasicType TUTF8) _ = return $ Just "F.free"
basicFreeFnOnError (TBasicType TFileName) _ = return $ Just "F.free"
basicFreeFnOnError (TBasicType _) _ = return Nothing
basicFreeFnOnError t@(TInterface _ _) transfer = do
  api <- findAPI t
  case api of
    Just (APIObject _) -> if transfer == TransferEverything
                          then do
                            isGO <- isGObject t
                            if isGO
                            then return $ Just "unrefObject"
                            else do
                              line $ "-- XXX Transfer a non-GObject object"
                              return Nothing
                          else return Nothing
    Just (APIInterface _) -> if transfer == TransferEverything
                             then do
                               isGO <- isGObject t
                               if isGO
                               then return $ Just "unrefObject"
                               else do
                                 line $ "-- XXX Transfer a non-GObject object"
                                 return Nothing
                             else return Nothing
    Just (APIUnion u) -> if transfer == TransferEverything
                         then if unionIsBoxed u
                              then return $ Just "freeBoxed"
                              else do
                                line $ "-- XXX Transfer a non-boxed union"
                                return Nothing
                         else return Nothing
    Just (APIStruct s) -> if transfer == TransferEverything
                          then if structIsBoxed s
                               then return $ Just "freeBoxed"
                               else do
                                 line $ "-- XXX Transfer a non-boxed struct"
                                 return Nothing
                          else return Nothing
    _ -> return Nothing
basicFreeFnOnError (TCArray _ _ _ _) _ = return $ Just "F.free"
basicFreeFnOnError (TGArray _) _ = return $ Just "unrefGArray"
basicFreeFnOnError (TPtrArray _) _ = return $ Just "unrefPtrArray"
basicFreeFnOnError (TByteArray) _ = return $ Just "unrefByteArray"
basicFreeFnOnError (TGList _) _ = return $ Just "g_list_free"
basicFreeFnOnError (TGSList _) _ = return $ Just "g_slist_free"
basicFreeFnOnError (TGHash _ _) _ = return Nothing
basicFreeFnOnError (TError) _ = return Nothing

-- If the given type maps to a list in Haskell, return the type of the
-- elements.
elementType :: Type -> Maybe Type
elementType (TCArray _ _ _ (TBasicType TUInt8)) = Nothing -- ByteString
elementType (TCArray _ _ _ t) = Just t
elementType (TGArray t) = Just t
elementType (TPtrArray t) = Just t
elementType (TGList t) = Just t
elementType (TGSList t) = Just t
elementType _ = Nothing

-- Return the name of the function mapping over elements in a
-- container type.
elementMap :: Type -> String -> Maybe String
elementMap (TCArray _ _ _ (TBasicType TUInt8)) _ = Nothing -- ByteString
elementMap (TCArray True _ _ _) _ = Just "mapZeroTerminatedCArray"
elementMap (TCArray False fixed _ _) _
    | fixed > (-1) = Just $ parenthesize $ "mapCArrayWithLength " ++ show fixed
elementMap (TCArray False (-1) _ _) len
    = Just $ parenthesize $ "mapCArrayWithLength " ++ len
elementMap (TGArray _) _ = Just "mapGArray"
elementMap (TPtrArray _) _ = Just "mapPtrArray"
elementMap (TGList _) _ = Just "mapGList"
elementMap (TGSList _) _ = Just "mapGSList"
elementMap _ _ = Nothing

-- Free just the container, but not the elements.
freeContainer :: Type -> String -> CodeGen [String]
freeContainer t label =
    case basicFreeFn t of
      Nothing -> return []
      Just fn -> return [fn ++ " " ++ label]

-- Free the elements in a container type.
freeElements :: Type -> String -> String -> CodeGen [String]
freeElements t label len = return $ fromMaybe [] $ do
   inner <- elementType t
   innerFree <- basicFreeFn inner
   mapFn <- elementMap t len
   return [mapFn ++ " " ++ innerFree ++ " " ++ label]

-- Free the elements of a container type in the case an error ocurred,
-- in particular args that should have been transferred did not get
-- transfered.
freeElementsOnError :: Arg -> String -> String -> CodeGen [String]
freeElementsOnError arg label len =
    case elementType (argType arg) of
      Nothing -> return []
      Just inner -> do
        innerFree <- basicFreeFnOnError inner (transfer arg)
        case innerFree of
          Nothing -> return []
          Just freeFn ->
              case elementMap inner len of
                Nothing -> return []
                Just mapFn -> return [mapFn ++ " " ++ freeFn ++ " " ++ label]

freeIn arg label len = do
    let t = argType arg
    case transfer arg of
      TransferNothing -> (++) <$> freeElements t label len <*> freeContainer t label
      TransferContainer -> freeElements t label len
      TransferEverything -> return []

freeInOnError arg label len =
    (++) <$> freeElementsOnError arg label len
             <*> freeContainer (argType arg) label

freeOut label = return ["F.free " ++ label]

-- Given an input argument to a C callable, and its label in the code,
-- return the list of actions relevant to freeing the memory allocated
-- for the argument (if appropriate, depending on the ownership
-- transfer semantics of the callable).
freeInArg :: Arg -> String -> String -> CodeGen [String]
freeInArg arg label len = case direction arg of
                            DirectionIn -> freeIn arg label len
                            DirectionOut -> freeOut label
                            DirectionInout -> freeOut label

-- Same thing as freeInArg, but called in case the call to C didn't
-- succeed. We thus free everything we allocated in preparation for
-- the call, including args that would have been transferred to C.
freeInArgOnError :: Arg -> String -> String -> CodeGen [String]
freeInArgOnError arg label len = case direction arg of
                            DirectionIn -> freeInOnError arg label len
                            DirectionOut -> freeOut label
                            DirectionInout -> freeOut label
