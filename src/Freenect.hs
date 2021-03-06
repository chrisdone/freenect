{-# LANGUAGE ViewPatterns, BangPatterns #-}
{-# OPTIONS -fno-warn-name-shadowing #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- | Interface to the Kinect device.
--
-- See the package archive for example programs.
--

module Freenect
       (
       -- * Initializing the context
       -- $contexts
       
       -- * Working with devices
       -- $devices
       
       -- * Events; recieving data
       -- $events

        initialize
       ,newContext
       ,shutdown
       ,countDevices
       ,withContext
       ,processEvents
       ,processEventsTimeout
       ,selectSubdevices
       ,newDevice
       ,openDevice
       ,closeDevice
       ,withDevice
       ,setLogLevel
       ,setVideoCallback
       ,startVideo
       ,stopVideo
       ,setDepthCallback
       ,startDepth
       ,stopDepth
       ,setTiltDegrees
       ,getTiltDegrees
       ,getAcceleration
       ,setLed
       ,setVideoMode
       ,setDepthMode
       ,setFlag
       ,Context
       ,Device
       ,FreenectException(..)
       ,Subdevice(..)
       ,LogLevel(..)
       ,Led(..)
       ,Flag(..)
       ,Resolution(..)
       ,VideoFormat(..)
       ,DepthFormat(..)
       ,setAudioInCallback
       ,startAudio
       ,stopAudio)
       where

import Freenect.FFI

import Control.Exception (bracket,throw,Exception(..))
import Data.Bits
import Data.IORef
import Data.List
import Data.Typeable
import Foreign
import Foreign.C
import Data.Vector.Storable (Vector,unsafeFromForeignPtr)

-- | An acquireable resource. This abstracts the notion of C-level
--   pointers that may or may not refer to something in memory. Avoids
--   segmentation faults and other nasties. Nobody wants segmentation
--   faults in their Haskell code.
data Resource a = Initialized a | Uninitialized a
  deriving Show

-- | A Freenect context.
newtype Context = CPtr (IORef (Resource (Ptr (Ptr ContextStruct))))

-- | A Freenect device.
newtype Device = DPtr (IORef (Resource (Ptr (Ptr DeviceStruct))))

-- | Freenect exception type.
data FreenectException
  = InitFail           -- ^ There was a problem initializing.
  | ShutdownFail       -- ^ There was a problem shutting down.
  | CloseDeviceFail       -- ^ There was a problem closing the device.
  | AlreadyInitializedContext -- ^ Trying to initialize a context that
                              -- was already initialized.
  | AlreadyOpenedDevice -- ^ Trying to open a device that was
                             -- already opened.
  | UseOfUninitializedContext -- ^ Attempt to use an uninitialized
                              --   context.
  | UseOfUninitializedDevice  -- ^ Attempt to use an uninitialized
                              --   device.
  | ProcessEvents CInt       -- ^ Call to process events failed.
  | OpenDeviceFailed Integer -- ^ Opening a device failed.
  | StartVideoProblem        -- ^ Problem starting the video stream.
  | StopVideoProblem         -- ^ Problem stopping the video stream
  | StartDepthProblem        -- ^ Problem starting the depth stream.
  | StopDepthProblem         -- ^ Problem stopping the depth stream
  | UnableToSetTilt          -- ^ Unable to set the tilt.
  | UnableToSetLed           -- ^ Unable to set active led
  | UnableToSetFlag          -- ^ Failed to enable a specific device flag
  | SetVideoMode             -- ^ Unable to set the video mode.
  | VideoModeNotSet          -- ^ TODO, not used: You didn't set the video mode.
  | SetDepthMode             -- ^ Unable to set the depth mode.
  | DepthModeNotSet          -- ^ TODO, not used: You didn't set the depth mode.
  | StartAudioProblem        -- ^ Problem starting the audio stream
  | StopAudioProblem         -- ^ Problem stopping the audio stream
    deriving (Show,Typeable)
instance Exception FreenectException

-- | Initialize a Freenect context. Throws exception if already
--   initialized.
initialize :: Context -> IO ()
initialize (CPtr ptrRef) = do
  ptr <- readIORef ptrRef
  case ptr of
    Initialized{} -> throw AlreadyInitializedContext
    Uninitialized ptr -> do
      succeed InitFail (writeIORef ptrRef (Initialized ptr)) $
        freenect_init ptr 0

-- | Create a new Freenect context. Must be initialized before use.
newContext :: IO Context
newContext = new_freenect_context >>= fmap CPtr . newIORef . Uninitialized

-- | Shutdown a Freenect context.
shutdown :: Context -> IO ()
shutdown cptr@(CPtr ptrRef) = flip withC cptr $ \ptr ->
  succeed ShutdownFail
          (writeIORef ptrRef (Uninitialized ptr))
          (peek ptr >>= freenect_shutdown)
  
-- | Count the number of devices on a Freenect context.
countDevices :: Context -> IO Integer
countDevices =
  withC $ \ptr ->
    fmap fromIntegral (peek ptr >>= freenect_num_devices)

-- | Do something with an initialized context, and free the context at
--   the end of the comutation, or on exception.
withContext :: (Context -> IO a) -> IO a
withContext f = bracket newContext shutdown (\c -> do initialize c; f c)

-- | Process events.
processEvents :: Context -> IO ()
processEvents = withC $ \cptr -> do
  cptr <- peek cptr
  result <- freenect_process_events cptr
  case result of
    -- LIBUSB_ERROR_INTERRUPTED 	
    -- System call interrupted (perhaps due to signal).
    -- I think the GHC runtime sends interrupts sometimes, or
    -- otherwise signals are coming from somewhere but are they appear
    -- to be ignorable.
    -10 -> return ()
    _ | result < 0 -> throw (ProcessEvents result)
      | otherwise  -> return ()


processEventsTimeout :: Context -> Int -> IO ()
processEventsTimeout ctx timeout = flip withC ctx $ \cptr -> do
  cptr   <- peek cptr
  result <- process_events_timeout cptr (fromIntegral timeout)
  case result of
    -- LIBUSB_ERROR_INTERRUPTED 	
    -- System call interrupted (perhaps due to signal).
    -- I think the GHC runtime sends interrupts sometimes, or
    -- otherwise signals are coming from somewhere but are they appear
    -- to be ignorable.
    -10 -> return ()
    _ | result < 0 -> throw (ProcessEvents result)
      | otherwise  -> return ()


-- | Run a computation for which the CInt result is zero (in C this is
--   success), and thrown an exception if the result is non-zero.
succeed :: Exception e => e -> IO () -> IO CInt -> IO ()
succeed e ok m = do
  result <- m
  if result == 0 
     then ok
     else throw e

-- | A sub-device (motor, camera and audio), if supported on the
--   platform.
data Subdevice = Motor | Camera | Audio
  deriving (Show,Eq)

-- | Set which subdevices any subsequent calls to openDevice should
--   open.  This will not affect devices which have already been
--   opened.  The default behavior, should you choose not to call this
--   function at all, is to open all supported subdevices - motor,
--   cameras, and audio, if supported on the platform.
selectSubdevices :: Context -> [Subdevice] -> IO ()
selectSubdevices c (nub -> subdevices) = flip withC c $ \ptr -> do
  ptr <- peek ptr
  freenect_select_subdevices  ptr (foldl1 (.|.) (map toDeviceId subdevices))

  where toDeviceId Motor = 1
        toDeviceId Camera = 2
        toDeviceId Audio = 4

-- | Create a new device.
newDevice :: IO Device
newDevice = new_freenect_device >>= fmap DPtr . newIORef . Uninitialized

-- | Open a Kinect device.
openDevice :: Context -> Device -> Integer -> IO ()
openDevice c (DPtr devptr) index = flip withC c $ \cptr -> do
  dptr <- readIORef devptr
  case dptr of
    Initialized{} -> throw AlreadyOpenedDevice
    Uninitialized dptr -> do
      succeed (OpenDeviceFailed index) (writeIORef devptr (Initialized dptr)) $ do
        cptr <- peek cptr
        freenect_open_device cptr dptr (fromIntegral index)

-- | Close a device.
closeDevice :: Device -> IO ()
closeDevice dptr@(DPtr ptrRef) = do
  flip withD dptr $ \ptr -> do
    succeed CloseDeviceFail
            (writeIORef ptrRef (Uninitialized ptr))
            (peek ptr >>= freenect_close_device)

-- | Do something with an initialized context, and free the context at
--   the end of the comutation, or on exception.
withDevice :: Context -> Integer -> (Device -> IO a) -> IO a
withDevice ctx i f = bracket newDevice closeDevice (\d -> do openDevice ctx d i; f d)

-- | Do something with a device pointer. Unexported.
withD :: (Ptr (Ptr DeviceStruct) -> IO a) -> Device -> IO a
withD cons (DPtr ptr) = do
  ptr <- readIORef ptr
  case ptr of
    Uninitialized{} -> throw UseOfUninitializedDevice
    Initialized ptr -> cons ptr

-- | Do something with a context pointer. Unexported.
withC :: (Ptr (Ptr ContextStruct) -> IO a) -> Context -> IO a
withC cons (CPtr ptr) = do
  ptr <- readIORef ptr
  case ptr of
    Uninitialized{} -> throw UseOfUninitializedContext
    Initialized ptr -> cons ptr

-- | Message logging levels.
data LogLevel
  = LogFatal    -- ^ Crashing/non-recoverable errors
  | LogError    -- ^ Major errors
  | LogWarning  -- ^ Warning messages
  | LogNotice   -- ^ Important messages
  | LogInfo     -- ^ Normal messages
  | LogDebug    -- ^ Useful development messages
  | LogSpew     -- ^ Slightly less useful messages
  | LogFlood    -- ^ EVERYTHING. May slow performance.
  deriving (Show,Eq,Enum)

-- | Set the logging level for the specified context.
setLogLevel :: LogLevel -> Context -> IO ()
setLogLevel level = withC $ \ptr -> do
  ptr <- peek ptr
  freenect_set_log_level ptr (fromIntegral (fromEnum level))

-- | Set callback for video information received event.
setVideoCallback :: Device -> (Vector Word8 -> Word32 -> IO ()) -> IO ()
setVideoCallback d callback = flip withD d $ \dptr -> do
  dptr <- peek dptr
  resolution <- get_freenect_video_resolution dptr
  let !size = resolutionToSize (toEnum (fromIntegral resolution))
  callbackPtr <- wrapVideoCallback $ \_ payloadptr timestamp -> do
    fptr <- newForeignPtr_ payloadptr
    let !vector = unsafeFromForeignPtr fptr 0 (size * 3)
    callback vector timestamp
  freenect_set_video_callback dptr callbackPtr

-- | Set callback for depth information received event.
setDepthCallback :: Device -> (Vector Word16 -> Word32 -> IO ()) -> IO ()
setDepthCallback d callback = flip withD d $ \dptr -> do
  dptr <- peek dptr
  resolution <- get_freenect_depth_resolution dptr
  let !size = resolutionToSize (toEnum (fromIntegral resolution))
  callbackPtr <- wrapDepthCallback $ \_ payloadptr timestamp -> do
    fptr <- newForeignPtr_ payloadptr
    let !vector = unsafeFromForeignPtr fptr 0 size
    callback vector timestamp
  freenect_set_depth_callback dptr callbackPtr

-- | Resolution to size.
resolutionToSize :: Resolution -> Int
resolutionToSize Low    = 320  * 240
resolutionToSize Medium = 640  * 480
resolutionToSize High   = 1280 * 1024

-- | Start the video information stream for a device.
startVideo :: Device -> IO ()
startVideo = withD $ \ptr -> succeed StartVideoProblem (return ()) $ do
  ptr <- peek ptr
  freenect_start_video ptr

-- | Start the video information stream for a device.
stopVideo :: Device -> IO ()
stopVideo = withD $ \ptr -> succeed StopVideoProblem (return ()) $ do
  ptr <- peek ptr
  freenect_stop_video ptr

-- | Start the depth information stream for a device.
startDepth :: Device -> IO ()
startDepth = withD $ \ptr -> succeed StartDepthProblem (return ()) $ do
  ptr <- peek ptr
  freenect_start_depth ptr

-- | Stop the depth information stream for a device.
stopDepth :: Device -> IO ()
stopDepth = withD $ \ptr -> succeed StopDepthProblem (return ()) $ do
  ptr <- peek ptr
  freenect_stop_depth ptr


-- | Set the tilt degrees for a device.
setTiltDegrees :: Double -> Device -> IO ()
setTiltDegrees angle = withD $ \ptr -> succeed UnableToSetTilt (return ()) $ do
  ptr <- peek ptr
  freenect_set_tilt_degs ptr (realToFrac angle)


-- | Get the tilt degrees for a device
getTiltDegrees :: Device -> IO Double
getTiltDegrees= withD $ \ptr -> do
   ptr <- peek ptr
   _ <- freenect_update_tilt_state ptr
   tiltstate <- freenect_get_tilt_state ptr
   fmap realToFrac (freenect_get_tilt_degs tiltstate)


-- | Get the accelaretion for (x, y, z) axes from the internal tilt state 
getAcceleration :: Device -> IO (Double, Double, Double)
getAcceleration = withD $ \ptr -> do
   ptr <- peek ptr
   _ <- freenect_update_tilt_state ptr
   tiltstate <- freenect_get_tilt_state ptr

   allocaArray 3 $ \temp -> do
      let step  = sizeOf (undefined :: CDouble)

      let temp_x = temp                     :: Ptr CDouble
      let temp_y = plusPtr temp step        :: Ptr CDouble
      let temp_z = plusPtr temp (2 * step)  :: Ptr CDouble

      freenect_get_mks_accel tiltstate temp_x temp_y temp_z

      x <- peek temp_x
      y <- peek temp_y 
      z <- peek temp_z 

      return (realToFrac x, realToFrac y, realToFrac z)



data Resolution = Low | Medium | High
  deriving (Enum,Show,Eq,Ord)

data VideoFormat
  = RGB
  | Bayer
  | EightBitIR
  | TenBitIR
  | TenBitPackedIR
  | YUVRGB
  | YUVRaw
  deriving (Enum,Show,Eq)
  
setVideoMode :: Device -> Resolution -> VideoFormat -> IO ()
setVideoMode d res fmt = flip withD d $ \dptr -> do
  dptr <- peek dptr
  frameMode <- find_video_mode_freenect (fromIntegral (fromEnum res))
                                        (fromIntegral (fromEnum fmt))
  succeed SetVideoMode (return ()) $
    set_freenect_video_mode dptr frameMode
  
data DepthFormat
  = ElevenBit
  | TenBit
  | ElevenBitPacked
  | TenBitPacked
  deriving (Enum,Show,Eq)

-- | Sets the current depth mode for the specified device.  The mode
--    cannot be changed while streaming is active.
setDepthMode :: Device -> Resolution -> DepthFormat -> IO ()
setDepthMode d res fmt = flip withD d $ \dptr -> do
  dptr <- peek dptr
  frameMode <- find_depth_mode_freenect (fromIntegral (fromEnum res))
                                        (fromIntegral (fromEnum fmt))
  succeed SetDepthMode (return ()) $
    set_freenect_depth_mode dptr frameMode

data Led 
  = Off
  | Green
  | Red
  | Yellow
  | BlinkGreen
  | BlinkRedYellow
  deriving (Enum,Show,Eq)

-- | Sets the current LED state for the specified device
setLed :: Device -> Led -> IO ()
setLed d led = flip withD d $ \ptr -> do
   ptr <- peek ptr
   succeed UnableToSetLed (return ()) $
      -- BlinkGreen is 4 and 5, BlinkRedYellow is 6 (see libfreenect.h)
      freenect_set_led ptr (if ledcode == 5 then 6 else ledcode)
   where
   ledcode = (fromIntegral (fromEnum led))



data Flag
  = AutoExposure
  | AutoWhiteBalance
  | RawColor
  | MirrorDepth
  | MirrorVideo
  deriving(Show,Eq)

-- | Sets a specific device flag for depth and video cameras. The 
--    bool value defines to enable or disable the given flag. The specific camera
--    has to be started with startVideo/startDepth before Freenect accepts 
--    these flags (seems to be a small bug for me, an issue is written at libfreenect) 
setFlag :: Device -> Flag -> Bool -> IO ()
setFlag d flag enabled = flip withD d $ \ptr -> do
   ptr <- peek ptr
   succeed UnableToSetFlag (return ()) $ 
      freenect_set_flag ptr key value
   where
   key   = toEnumInteger flag
   value = fromIntegral (if enabled then 1 else 0)

   toEnumInteger AutoExposure     = 1 `shift` 14
   toEnumInteger AutoWhiteBalance = 1 `shift` 1
   toEnumInteger RawColor         = 1 `shift` 4
   toEnumInteger MirrorDepth      = 1 `shift` 16
   toEnumInteger MirrorVideo      = 1 `shift` 17
  

-- | Start the audio information stream for a device.
startAudio :: Device -> IO ()
startAudio = withD $ \ptr -> succeed StartAudioProblem (return ()) $ do
  ptr <- peek ptr
  freenect_start_audio ptr

-- | Stop the audio information stream for a device.
stopAudio :: Device -> IO ()
stopAudio = withD $ \ptr -> succeed StopAudioProblem (return ()) $ do
  ptr <- peek ptr
  freenect_stop_audio ptr


-- | Set callback for incoming audio events.
setAudioInCallback 
   :: Device 
   -> (Int -> Vector Word32 -> Vector Word32 -> Vector Word32 -> Vector Word32 -> Vector Word16 -> IO ()) 
   -> IO ()
setAudioInCallback d callback = flip withD d $ \dptr -> do
  dptr <- peek dptr
  callbackPtr <- wrapAudioInCallback $ \_ num lptr lmptr rmptr rptr nptr _  -> do
    let !size = (fromIntegral num)

    l_ptr <- newForeignPtr_ lptr
    lm_ptr <- newForeignPtr_ lmptr
    rm_ptr <- newForeignPtr_ rmptr
    r_ptr <- newForeignPtr_ rptr
    n_ptr <- newForeignPtr_ nptr
    
    let !l_vector  = unsafeFromForeignPtr l_ptr 0 size
    let !lm_vector = unsafeFromForeignPtr lm_ptr 0 size
    let !rm_vector = unsafeFromForeignPtr rm_ptr 0 size
    let !r_vector  = unsafeFromForeignPtr r_ptr 0 size
    let !n_vector  = unsafeFromForeignPtr n_ptr 0 size
    
    callback size l_vector lm_vector rm_vector r_vector n_vector
  freenect_set_audio_in_callback dptr callbackPtr



-- $contexts
-- 
-- First you need to initalize a context. Example:
--
-- @
-- do context <- newContext
--    initalize context
--    ...
--    shutdown context
-- @
--
-- Rather than messing around with this, it's better if you just use
-- withContext, which does this for you:
--
-- @
-- withContext $ \context -> do
--   ...
-- @
-- 
-- All stuff with this library works within a context.

-- $devices
--
-- You need to select which sub devices you want to use from the Kinect
-- (e.g. camera, motor, audio):
--
-- @selectSubdevices context [Camera,Motor]@
-- 
-- Then you open a device context through which you can control the sub devices.
-- 
-- @
-- withDevice context 0 $ \device -> do
--   ...
-- @
--
-- The second argument is which Kinect to use. You can get a count of these using
--
-- @deviceCount <- countDevices context@
--
-- Then you should set the depth mode you want:
--
-- @setDepthMode device Medium ElevenBit@
--
-- This should come before the next part, which is setting the callback:
--
-- @
-- setDepthCallback device $ \payload timestamp -> do
--   printf \"Payload: %s\n\" (take 100 $ show payload)
-- @
-- 
-- Important: Based on the depth mode set earlier, `setDepthCallback'
-- knows how to copy the payload into a vector for the callback. This
-- is why it should come first. Arguably in future APIs a device
-- should not be initializable without a depth mode.
--
-- Once that's done, you start the depth stream:
--
-- @startDepth device@
--
-- Likewise, you can grab video frames. Once you have a context, set the
-- video mode you want using
--
-- @setVideoMode device Medium RGB@
--
-- In this example, we set medium resolution (640x480) with raw RGB24 Bytes.
--
-- Next, set the video callback:
--
-- @
-- setVideoCallback device $ \payload timestamp -> do
--   printf \"Payload: %s\n\" (take 100 $ show payload)
-- @
--
-- Note that unlike depth, which comes in as vector of Word16's, video is a
-- vector of Word8's.
--
-- Lastly, start the video stream:
--
-- @startVideo device@
--
-- $events
--
-- Finally you need a way to receieve data. You call `processEvents'
-- like this, for example:
--
-- @
-- forever $ do
--   processEvents context
-- @
--
-- Calls `processEvents' to trigger the depth and/or video callback. Continue calling
-- it sequentially as much as you want, but not from within the depth or video
-- callbacks.
