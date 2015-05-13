{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell   #-}
module Shakespeare.Ophelia.Parser.VDOM.Types where

import           Control.Applicative
import           Control.Monad                 hiding (mapM, sequence)
import           Data.Traversable

import           Control.Concurrent.STM
import           Control.Concurrent.STM.Notify
import           Control.Concurrent.STM.TMVar
import           Prelude                       hiding (mapM, sequence)

import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax

import           Data.String
import           VDOM.Adapter


instance (IsString a) => IsString (STMEnvelope a) where
  fromString = return . fromString

-- | Resulting type from the quasiquoted gertrude
data LiveVDom a =
     LiveVText {liveVTextEvents :: [a], liveVirtualText :: STMEnvelope String } -- ^ Child text with  no tag name, properties, or children
   | LiveVNode {liveVNodeEvents :: [a], liveVNodeTagName :: TagName, liveVNodePropsList :: [Property], liveVNodeChildren :: [LiveVDom a]} -- ^ Basic tree structor for a node with children and properties
   | LiveChild {liveVChildEvents :: [a], liveVChild :: STMEnvelope (LiveVDom a)} -- ^ DOM that can change
   | LiveChildren {liveVChildEvents :: [a], liveVChildren :: STMEnvelope [LiveVDom a]} -- ^ A child that can change


-- | Type that gertrude is parsed into
data PLiveVDom =
     PLiveVText {pLiveVirtualText :: String } -- ^ Child text with  no tag name, properties, or children
   | PLiveVNode {pLiveVNodeTagName :: TagName, pLiveVNodePropsList :: [Property], pLiveVNodeChildren :: [PLiveVDom]} -- ^ Basic tree structor for a node with children and properties
   | PLiveChild {pLiveVChild :: Exp}         -- ^ A parsed TH Exp that will get turned into LiveChild
   | PLiveChildren {pLiveVChildren :: Exp}         -- ^ A parsed TH Exp that will get turned into LiveChildren
   | PLiveInterpText  {pLiveInterpText :: Exp} -- ^ Interpolated text that will get transformed into LiveVText

instance Lift PLiveVDom where
  lift (PLiveVText st) = AppE (ConE 'PLiveVText) <$> (lift st)
  lift (PLiveVNode tn pl ch) = do
    qtn <- lift tn
    qpl <- lift pl
    qch <- lift ch
    return $ AppE (AppE (AppE (ConE 'PLiveVNode) qtn) qpl) qch
  lift (PLiveChild e) = return e
  lift (PLiveChildren e) = return e
  lift (PLiveInterpText t) = return t

-- | Use template haskell to create the live vdom
toLiveVDomTH :: PLiveVDom -> Q Exp
toLiveVDomTH (PLiveVText st) = do
  iStr <- lift st
  return $ AppE (AppE (ConE 'LiveVText) (ListE [])) iStr
toLiveVDomTH (PLiveVNode tn pl ch) = do
  qtn <- lift tn
  qpl <- lift pl
  cExp <- sequence $ toLiveVDomTH <$> ch
  return $ AppE (AppE (AppE (AppE (ConE 'LiveVNode) (ListE [])) qtn) qpl) (ListE cExp)
toLiveVDomTH (PLiveChild e) = return $ AppE (AppE (ConE  'LiveChild) (ListE [])) e
toLiveVDomTH (PLiveChildren e) = return $ AppE (AppE (ConE  'LiveChildren) (ListE [])) e
toLiveVDomTH (PLiveInterpText t) = return $ AppE (AppE (ConE 'LiveVText) (ListE [])) t


-- | Transform LiveDom to VNode so that it can be processed
toProducer :: LiveVDom JSEvent -> STMEnvelope [VNodeAdapter]
toProducer (LiveVText ev t) = (\text -> [VText ev text]) <$> t
toProducer (LiveVNode ev tn pl ch) = do
  ch' <- mapM toProducer ch
  return $ [VNode ev tn pl (join ch')]
toProducer (LiveChild ev ivc) = join $ toProducer <$> (addEvents ev <$> ivc)
toProducer (LiveChildren ev lvc) = do
  xs <- join $ sequence <$> (fmap (toProducer . addEvents ev)) <$> lvc
  return $ join xs

-- | Add an event to a LiveVDom
addEvent :: a -> LiveVDom a -> LiveVDom a
addEvent ev (LiveVText evs ch) = LiveVText (evs ++ [ev]) ch -- ^ Child text with  no tag name, properties, or children
addEvent ev (LiveVNode evs tn pls ch) = LiveVNode (evs ++ [ev]) tn pls ch -- ^ Basic tree structor for a node with children and properties
addEvent ev (LiveChild evs vch) = LiveChild (evs ++ [ev]) vch -- ^ DOM that can change
addEvent ev (LiveChildren evs vchs) = LiveChildren (evs ++ [ev]) vchs -- ^ A child that can change

-- | Add multiple events to LiveVDom
addEvents :: [a] -> LiveVDom a -> LiveVDom a
addEvents ev (LiveVText evs ch) = LiveVText (evs ++ ev) ch -- ^ Child text with  no tag name, properties, or children
addEvents ev (LiveVNode evs tn pls ch) = LiveVNode (evs ++ ev) tn pls ch -- ^ Basic tree structor for a node with children and properties
addEvents ev (LiveChild evs vch) = LiveChild (evs ++ ev) vch -- ^ DOM that can change
addEvents ev (LiveChildren evs vchs) = LiveChildren (evs ++ ev) vchs

-- | Add a list of property to LiveVNode if it is a liveVNode
-- If it isn't it leaves the rest alone
addProps :: LiveVDom a -> [Property] -> LiveVDom a
addProps (LiveVNode evs tn pl ch) pl' = LiveVNode evs tn (pl ++ pl') ch
addProps l _ = l

addDomListener :: TMVar () -> LiveVDom a -> IO ()
addDomListener tm (LiveVText evs ch) = return ()
addDomListener tm (LiveVNode evs tn pls ch) = mapM_ (addDomListener tm) ch
addDomListener tm (LiveChild evs vch) = (atomically $ addListener vch tm) >> 
                                            (addDomListener tm =<< recvIO vch)
addDomListener tm (LiveChildren evs vchs) = (atomically $ addListener vchs tm) >> 
                                                (mapM_ (addDomListener tm) =<< recvIO vchs)

waitForDom :: STMEnvelope (LiveVDom a) -> IO ()
waitForDom envDom = do
  dom <- recvIO envDom
  listener <- newEmptyTMVarIO
  atomically $ addListener envDom $ listener
  addDomListener listener dom
  atomically $ readTMVar listener
