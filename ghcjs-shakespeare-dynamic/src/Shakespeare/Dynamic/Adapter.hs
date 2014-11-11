module Shakespeare.Dynamic.Adapter where

import           Control.Applicative
import           Control.Monad
import           Data.Foldable
import           Data.Maybe
import           Data.Text           hiding (find, zipWith, map)
import qualified Data.Traversable    as TR
import           Safe

import           Data.Aeson

import           VDOM.Adapter

import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.PureMarshal
import           GHCJS.Types
import           GHCJS.VDOM

import           System.IO.Unsafe    (unsafePerformIO)


-- The orphan instance is to seperate the GHCJS dependency
-- from the JSProp definition
-- This just pushes the data into a JSRef and then casts
-- it back to the correct type so that
-- toJSRef :: JSProp -> IO (JSRef JSProp)
instance ToJSRef JSProp where
  toJSRef (JSPText t) = castToJSRef t
  toJSRef (JSPBool b) = castToJSRef b
  toJSRef (JSPInt i) = castToJSRef i
  toJSRef (JSPInt8 i8) = castToJSRef i8
  toJSRef (JSPInt8 i16) = castToJSRef i16
  toJSRef (JSPInt8 i32) = castToJSRef i32
  toJSRef (JSPWord w) = castToJSRef w
  toJSRef (JSPWord8 w8)  = castToJSRef w8
  toJSRef (JSPWord16 w16)  = castToJSRef w16
  toJSRef (JSPWord32 w32) = castToJSRef w32
  toJSRef (JSPFloat f) = castToJSRef f
  toJSRef (JSPDouble d) = castToJSRef d


-- Push a piece of data into a JSRef and cast it
castToJSRef :: ToJSRef a => a -> IO (JSRef b)
castToJSRef x = castRef <$> toJSRef x



-- Newtype to wrap the [Property] so that
newtype PropList = PropList { unPropList :: [Property]} deriving (Show)


-- The orphan instance is again to seperate the GHCJS dependency
-- from the definition of property
instance ToJSRef (PropList) where
  toJSRef (PropList xs) = do
    x <- newObj
    foldM_ insert x xs 
    return x
    where
      -- VDom uses the property object like a Map from name to value
      -- So we create a map for vdom to access
      insert x (Property name value) = do
        val <- toJSRef value
        setProp name val x
        return x


-- Convert a VNodeAdapter to a VNode in order to diff it with vdom
toVNode :: VNodeAdapter -> VNode
toVNode (VNodeAdapter aTagName innerText aProps aChildren) = js_vnode tagName props $ mChildren aChildren
  where tagName = toJSString aTagName
        props = toProperties . castRef . unsafePerformIO . toJSRef $ PropList aProps
        mChildren [] = mkChildren [text $ toJSString innerText]
        mChildren xs = mkChildren $ (text $ toJSString innerText): (toVNode <$> aChildren)

