import Lean.Data.Json

import CurlLean.Enums
import CurlLean.Error

namespace Curl.WS

open Lean
open Curl

structure Frame where
  frameType : FrameType
  data : String
deriving Repr

structure Config where
  headers : Array (String × String) := #[]
  timeout : UInt32 := 30000
  verifySsl : Bool := false
  verbose : Bool := false
deriving Repr

def defaultConfig : Config := {}

namespace FFI
namespace Raw

/--
Connect to WebSocket and return connection handle:
  url: WebSocket URL (ws:// or wss://)
  headers: newline-delimited "Header: value" entries
  timeoutMs: 0 = no timeout; otherwise timeout in ms
  verifySsl: true = verify SSL certificates; false = skip verification
  verbose: true = enable verbose debug output; false = disable
Returns: (handle, message). handle: 0 = error, >0 = valid connection handle
-/
@[extern "lean_curl_ws_connect"]
opaque curl_ws_connect
  (url : @& String)
  (headers : @& String)
  (timeoutMs : UInt32)
  (verifySsl : Bool)
  (verbose : Bool)
  : IO (UInt32 × String)

/--
Send message on existing WebSocket connection with specific frame type:
  handle: Connection handle from curl_ws_connect
  message: Message to send
  frameFlags: WebSocket frame flags (text=1, binary=2, ping=4, pong=8, close=16, continuation=0)
Returns: (status, message). Status: 0 = error, 1 = success
-/
@[extern "lean_curl_ws_send_frame_on_connection"]
opaque curl_ws_send_frame_on_connection
  (handle : UInt32)
  (message : @& String)
  (frameFlags : UInt32)
  : IO (UInt32 × String)

/--
Send message on existing WebSocket connection:
  handle: Connection handle from curl_ws_connect
  message: Message to send
  isBinary: true = binary frame, false = text frame
Returns: (status, message). Status: 0 = error, 1 = success
-/
@[extern "lean_curl_ws_send_on_connection"]
opaque curl_ws_send_on_connection
  (handle : UInt32)
  (message : @& String)
  (isBinary : Bool)
  : IO (UInt32 × String)

/--
Receive message on existing WebSocket connection:
  handle: Connection handle from curl_ws_connect
Returns: (frameType, data). frameType: 0 = error, 1 = text, 2 = binary, 3 = close, 4 = ping, 5 = pong, 6 = continuation
-/
@[extern "lean_curl_ws_recv_on_connection"]
opaque curl_ws_recv_on_connection
  (handle : UInt32)
  : IO (UInt32 × String)

/--
Close WebSocket connection:
  handle: Connection handle from curl_ws_connect
Returns: (status, message). Status: 0 = error, 1 = success
-/
@[extern "lean_curl_ws_close_connection"]
opaque curl_ws_close_connection
  (handle : UInt32)
  : IO (UInt32 × String)

/--
Check WebSocket connection validity:
  handle: Connection handle from curl_ws_connect
Returns: (status, message). Status: 0 = invalid, 1 = valid
-/
@[extern "lean_curl_ws_check_connection"]
opaque curl_ws_check_connection
  (handle : UInt32)
  : IO (UInt32 × String)

end Raw

/-- Utility: format headers into shim's input string. -/
private def packHeaders (hs : Array (String × String)) : String :=
  String.intercalate "\n" <| hs.toList.map (fun (k, v) => s!"{k}: {v}")

/-- Convert raw frame type number to FrameType -/
private def parseFrameType (n : UInt32) : Option FrameType :=
  match n with
  | 0 => none  -- error
  | 1 => some .text
  | 2 => some .binary
  | 3 => some .close
  | 4 => some .ping
  | 5 => some .pong
  | 6 => some .continuation
  | _ => none

def connectWS (url : String) (config : Config := defaultConfig) : IO (Except CurlWSError UInt32) := do
  try
    let headers := packHeaders config.headers
    let (handle, response) ← Raw.curl_ws_connect url headers config.timeout config.verifySsl config.verbose

    match handle with
    | 0 => pure (.error (CurlWSError.connectionFailed response))
    | h => pure (.ok h)
  catch e =>
    pure (.error (CurlWSError.unknownError e.toString))

-- Frame type flags for libcurl WebSocket API
private def frameTypeToFlags (frameType : FrameType) : UInt32 :=
  match frameType with
  | .text => 1        -- CURLWS_TEXT
  | .binary => 2      -- CURLWS_BINARY
  | .ping => 4        -- CURLWS_PING
  | .pong => 8        -- CURLWS_PONG
  | .close => 16      -- CURLWS_CLOSE
  | .continuation => 0 -- CURLWS_CONT

def sendFrame (handle : UInt32) (message : String) (frameType : FrameType) : IO (Except CurlWSError Unit) := do
  try
    let flags := frameTypeToFlags frameType
    let (status, response) ← Raw.curl_ws_send_frame_on_connection handle message flags

    match status with
    | 0 => pure (.error (CurlWSError.sendFailed response))
    | _ => pure (.ok ())
  catch e =>
    pure (.error (CurlWSError.unknownError e.toString))

def send (handle : UInt32) (message : String) (isBinary : Bool := false) : IO (Except CurlWSError Unit) := do
  try
    let (status, response) ← Raw.curl_ws_send_on_connection handle message isBinary

    match status with
    | 0 => pure (.error (CurlWSError.sendFailed response))
    | _ => pure (.ok ())
  catch e =>
    pure (.error (CurlWSError.unknownError e.toString))

def receive (handle : UInt32) : IO (Except CurlWSError Frame) := do
  try
    let (frameTypeNum, data) ← Raw.curl_ws_recv_on_connection handle

    match parseFrameType frameTypeNum with
    | none =>
      -- Frame type 0 indicates an error from the C layer
      if frameTypeNum == 0 then
        -- Check if this is a recoverable "would block" error
        if data.startsWith "RETRY:" then
          pure (.error (CurlWSError.receiveWouldBlock data))
        else
          pure (.error (CurlWSError.receiveFailed s!"WebSocket receive error: {data}"))
      else
        pure (.error (CurlWSError.receiveFailed s!"Invalid frame type: {frameTypeNum}"))
    | some frameType => pure (.ok (Frame.mk frameType data))
  catch e =>
    pure (.error (CurlWSError.unknownError e.toString))

def receiveWithRetry (handle : UInt32) (maxRetries : Nat := 10) (retryDelayMs : UInt32 := 1) : IO (Except CurlWSError Frame) := do
  let rec loop (retriesLeft : Nat) : IO (Except CurlWSError Frame) := do
    match ← receive handle with
    | Except.ok frame => pure (.ok frame)
    | Except.error (CurlWSError.receiveWouldBlock msg) =>
      if retriesLeft > 0 then do
        -- Sleep for a short time before retry
        IO.sleep retryDelayMs
        loop (retriesLeft - 1)
      else
        pure (.error (CurlWSError.receiveFailed s!"Receive timed out after {maxRetries} retries: {msg}"))
    | Except.error e => pure (.error e)
  loop maxRetries

def close (handle : UInt32) : IO (Except CurlWSError Unit) := do
  try
    let (status, response) ← Raw.curl_ws_close_connection handle

    match status with
    | 0 => pure (.error (CurlWSError.connectionFailed response))
    | _ => pure (.ok ())
  catch e =>
    pure (.error (CurlWSError.unknownError e.toString))

def checkConnection (handle : UInt32) : IO (Except CurlWSError String) := do
  try
    let (status, response) ← Raw.curl_ws_check_connection handle

    match status with
    | 0 => pure (.error (CurlWSError.connectionFailed response))
    | _ => pure (.ok response)
  catch e =>
    pure (.error (CurlWSError.unknownError e.toString))

-- Convenience functions for the API
def sendText (handle : UInt32) (message : String) : IO (Except CurlWSError Unit) :=
  send handle message false

def sendBinary (handle : UInt32) (message : String) : IO (Except CurlWSError Unit) :=
  send handle message true

def sendPing (handle : UInt32) (message : String := "") : IO (Except CurlWSError Unit) :=
  sendFrame handle message .ping

def sendPong (handle : UInt32) (message : String := "") : IO (Except CurlWSError Unit) :=
  sendFrame handle message .pong

def sendClose (handle : UInt32) (message : String := "") : IO (Except CurlWSError Unit) :=
  sendFrame handle message .close

def sendContinuation (handle : UInt32) (message : String) : IO (Except CurlWSError Unit) :=
  sendFrame handle message .continuation

def sendJson (handle : UInt32) (jsonData : Json) : IO (Except CurlWSError Unit) :=
  sendText handle (jsonData.compress)

def receiveJson (handle : UInt32) : IO (Except CurlWSError Json) := do
  match ← receive handle with
  | Except.error e => pure (Except.error e)
  | Except.ok frame =>
    match frame.frameType with
    | .ping =>
      pure (.error (CurlWSError.receiveFailed "Unexpected PING frame"))
    | .pong =>
      pure (.error (CurlWSError.receiveFailed "Unexpected PONG frame"))
    | .text =>
      match Json.parse frame.data with
      | .ok json => pure (.ok json)
      | .error parseError => pure (.error (CurlWSError.receiveFailed s!"JSON parse error: {parseError}"))
    | .binary => pure (.error (CurlWSError.receiveFailed "Expected text frame for JSON, got binary"))
    | .close => pure (.error (CurlWSError.receiveFailed "Connection closed"))
    | .continuation => pure (.error (CurlWSError.receiveFailed "Unexpected CONTINUATION frame"))

end FFI

end Curl.WS
