{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecursiveDo #-}

module Plugin.SimulaServer where

import           Linear
import           Plugin.Imports

import qualified Godot.Gdnative.Internal.Api as Api
import qualified Godot.Methods               as G
import           Godot.Nativescript
import           Godot.Extra.Register

import qualified Data.Map.Strict as M

import Plugin.Input
import Plugin.SimulaViewSprite
import Plugin.Types

import Control.Monad
import Control.Concurrent
import System.Environment

import System.Process

import Telemetry

import           Debug.Trace
import           Control.Lens hiding (Context)
import           Control.Concurrent.STM.TVar
import           Control.Exception
import           Control.Monad
import           Control.Monad.STM
import           Data.Maybe
import           Data.List
import           Data.Coerce

import           Foreign hiding (void)
import           Foreign.C.Error
import           Foreign.Ptr
import           Foreign.Marshal.Alloc
import           Foreign.C.Types
import qualified Language.C.Inline as C
import           Debug.C as C
import           Debug.Marshal

import           Text.XkbCommon.Keysym
import           Text.XkbCommon.KeyboardState
import           Text.XkbCommon.InternalTypes
import           Text.XkbCommon.Context
import           Text.XkbCommon.Keymap

import           Graphics.Wayland.Server
import           Graphics.Wayland.Internal.Server
import           Graphics.Wayland.Internal.SpliceServerTypes
import           Graphics.Wayland.WlRoots.Compositor
import           Graphics.Wayland.WlRoots.Output
import           Graphics.Wayland.WlRoots.Surface
import           Graphics.Wayland.WlRoots.Backend
import           Graphics.Wayland.WlRoots.Backend.Headless
import           Graphics.Wayland.Signal
import           Graphics.Wayland.WlRoots.Render
import           Graphics.Wayland.WlRoots.Render.Color
import           Graphics.Wayland.WlRoots.OutputLayout
import           Graphics.Wayland.WlRoots.Input
import           Graphics.Wayland.WlRoots.Seat
import           Graphics.Wayland.WlRoots.Cursor
import           Graphics.Wayland.WlRoots.XCursorManager
import           Graphics.Wayland.WlRoots.XdgShell
import           Graphics.Wayland.WlRoots.Input.Keyboard
import           Graphics.Wayland.WlRoots.Input.Pointer
import           Graphics.Wayland.WlRoots.Cursor
import           Graphics.Wayland.WlRoots.Input.Buttons
import           Graphics.Wayland.WlRoots.Box
import           Graphics.Wayland.WlRoots.Util
import           Graphics.Wayland.WlRoots.DeviceManager

import           System.Clock
import           Control.Monad.Extra

initializeSimulaCtxAndIncludes

instance GodotClass GodotSimulaServer where
  godotClassName = "SimulaServer"

instance ClassExport GodotSimulaServer where
  classInit obj  = initGodotSimulaServer obj

  classExtends = "Spatial"
  classMethods =
    [ GodotMethod NoRPC "_ready" Plugin.SimulaServer.ready
    -- , GodotMethod NoRPC "_input" Plugin.SimulaServer.input -- replaced by _on_wlr_* handlers
    ]

  -- Test:
  classSignals = [ signal "test_signal1" [("arg1", GodotVariantTypeVector3), ("arg2", GodotVariantTypeObject)]
                 , signal "test_signal2" []
                 ]

instance HasBaseClass GodotSimulaServer where
  type BaseClass GodotSimulaServer = GodotSpatial
  super (GodotSimulaServer obj _ _ _ _ _ _ _ _ _) = GodotSpatial obj

ready :: GFunc GodotSimulaServer
ready gss _ = do
  addWlrChildren gss
  -- startSimulaServerOnNewThread gss
  -- startTelemetry (gss ^. gssViews) -- Doesn't seem to require previous function to get to displayRunServer
  toLowLevel VariantNil

addWlrChildren :: GodotSimulaServer -> IO ()
addWlrChildren gss = do
  -- Here we assume gss is already a node in our scene tree.
  waylandDisplay <- unsafeInstance GodotWaylandDisplay "WaylandDisplay"
  G.set_name waylandDisplay =<< toLowLevel "WaylandDisplay"
  G.add_child gss ((safeCast waylandDisplay) :: GodotObject) True
  -- We omit having ViewportBounds children

  -- Children of WaylandDisplay
  wlrDataDeviceManager <- unsafeInstance GodotWlrDataDeviceManager "WlrDataDeviceManager"
  G.set_name wlrDataDeviceManager =<< toLowLevel "WlrDataDeviceManager"
  G.add_child waylandDisplay ((safeCast wlrDataDeviceManager) :: GodotObject) True

  wlrBackend <- unsafeInstance GodotWlrBackend "WlrBackend"
  G.set_name wlrBackend =<< toLowLevel "WlrBackend"
  G.add_child waylandDisplay ((safeCast wlrBackend) :: GodotObject) True

  wlrXdgShell <- unsafeInstance GodotWlrXdgShell "WlrXdgShell"
  G.set_name wlrXdgShell =<< toLowLevel "WlrXdgShell"
  G.add_child waylandDisplay ((safeCast wlrXdgShell) :: GodotObject) True

  wlrSeat <- unsafeInstance GodotWlrSeat "WlrSeat"
  G.set_name wlrSeat =<< toLowLevel "WlrSeat"
  G.add_child waylandDisplay ((safeCast wlrSeat) :: GodotObject) True

  wlrKeyboard <- unsafeInstance GodotWlrKeyboard "WlrKeyboard"
  G.set_name wlrKeyboard =<< toLowLevel "WlrKeyboard"
  G.add_child waylandDisplay ((safeCast wlrKeyboard) :: GodotObject) True

  -- Children of WlrBackend
  wlrOutput <- unsafeInstance GodotWlrOutput "WlrOutput"
  G.set_name wlrOutput =<< toLowLevel "WlrOutput"
  G.add_child wlrBackend ((safeCast wlrOutput) :: GodotObject) True

  wlrCompositor <- unsafeInstance GodotWlrCompositor "WlrCompositor"
  G.set_name wlrCompositor =<< toLowLevel "WlrCompositor"
  G.add_child wlrBackend ((safeCast wlrCompositor) :: GodotObject) True

  -- Update GodotSimulaServer's TVars
  atomically $ writeTVar (_gssWaylandDisplay gss) waylandDisplay
  atomically $ writeTVar (_gssWlrBackend gss) wlrBackend
  atomically $ writeTVar (_gssWlrOutput gss) wlrOutput
  atomically $ writeTVar (_gssWlrCompositor gss) wlrCompositor
  atomically $ writeTVar (_gssWlrXdgShell gss) wlrXdgShell
  atomically $ writeTVar (_gssWlrSeat gss) wlrSeat
  atomically $ writeTVar (_gssWlrDataDeviceManager gss) wlrDataDeviceManager
  atomically $ writeTVar (_gssWlrKeyboard gss) wlrKeyboard

-- TODO: check the origin plane?
moveToUnoccupied :: GodotSimulaServer -> GodotSimulaViewSprite -> IO ()
moveToUnoccupied gss gsvs = do
  viewMap <- atomically $ readTVar (_gssViews gss)
  let otherGsvs = filter (\x -> asObj x /= asObj gsvs) $ M.elems viewMap

  extents <- forM otherGsvs $ \viewSprite -> do
    sprite <- atomically $ readTVar (gsvs ^. gsvsSprite) -- getSprite viewSprite
    aabb   <- G.get_transformed_aabb sprite
    size   <- Api.godot_aabb_get_size aabb >>= fromLowLevel
    pos    <- Api.godot_aabb_get_position aabb >>= fromLowLevel
    return (pos, size + pos)

  let minX = minimum $ 0 : map (view $ _1._x) extents
      maxX = maximum $ 0 :  map (view $ _2._x) extents
  sprite <- atomically $ readTVar (gsvs ^. gsvsSprite)
  aabb   <- G.get_aabb sprite
  size   <- Api.godot_aabb_get_size aabb >>= fromLowLevel
  let sizeX  = size ^. _x
      newPos =
        if abs minX < abs maxX
        then V3 (minX - sizeX/2) 0 0
        else V3 (maxX + sizeX/2) 0 0

  G.translate gsvs =<< toLowLevel newPos


initGodotSimulaServer :: GodotObject -> IO (GodotSimulaServer)
initGodotSimulaServer obj = mdo
  -- let gss = GodotSimulaServer {
  --     _gssObj           = undefined :: GodotObject
  --   , _gssDisplay       = undefined :: DisplayServer
  --   , _gssViews         = undefined :: TVar (M.Map SimulaView GodotSimulaViewSprite)
  --   , _gssBackend       = undefined :: Ptr Backend
  --   , _gssXdgShell      = undefined :: Ptr WlrXdgShell
  --   , _gssSeat          = undefined :: Ptr WlrSeat
  --   , _gssKeyboards     = undefined :: TVar [SimulaKeyboard]
  --   , _gssOutputs       = undefined :: TVar [SimulaOutput]
  --   , _gssRenderer      = undefined :: Ptr Renderer
  --   , _gssNewXdgSurface = undefined :: ListenerToken
  -- }
  -- return gss
  return undefined

getSimulaServerNodeFromPath :: GodotSimulaServer -> String -> IO a
getSimulaServerNodeFromPath gss nodePathStr = do
  nodePath <- (toLowLevel (pack nodePathStr))
  gssNode <- G.get_node ((safeCast gss) :: GodotNode) nodePath
  ret  <- (fromNativeScript (safeCast gssNode)) :: IO a
  return ret