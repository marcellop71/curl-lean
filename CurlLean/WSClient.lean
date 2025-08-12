import Lean.Data.Json

import CurlLean.Error
import CurlLean.WSFFI
import CurlLean.Enums
import CurlLean.Url

namespace Curl.WS

open Lean
open Curl Curl.WS

/-- Typeclass for types that can be used as WebSocket URLs -/
class ToWsUrlString (α : Type) where
  toWsUrlString : α → String

instance : ToWsUrlString String where
  toWsUrlString := id

instance : ToWsUrlString Url where
  toWsUrlString := Url.toString

/-- WebSocket client monad -/
abbrev WSM := ReaderT Config (ExceptT WSError IO)

instance : MonadReader Config WSM := inferInstance
instance : MonadExcept WSError WSM := inferInstance

/-- Convert CurlWSError to WSError -/
private def liftWSError (e : CurlWSError) : WSError :=
  match e with
  | .receiveWouldBlock msg => .clientError s!"Socket not ready (retry recommended): {msg}"
  | _ => .webSocketError e

/-- Run WebSocket computation with default config -/
def runWS (action : WSM α) : IO (Except WSError α) :=
  action.run defaultConfig

/-- Run WebSocket computation with custom config -/
def runWSWith (config : Config) (action : WSM α) : IO (Except WSError α) :=
  action.run config

/-- WebSocket connection handle with real connection -/
structure WSConnection where
  handle : UInt32  -- Real connection handle from libcurl
  url : String
  isConnected : Bool := true
deriving Repr

/-- Create a WebSocket connection with persistent handle -/
def connect [ToWsUrlString U] (url : U) : WSM WSConnection := do
  let config ← read
  let urlStr := ToWsUrlString.toWsUrlString url
  let result ← liftM (FFI.connectWS urlStr config)
  match result with
  | Except.ok handle => pure { handle, url := urlStr, isConnected := true }
  | Except.error e => throw (liftWSError e)

namespace WSConnection

/-- Send text message through persistent connection -/
def sendText (conn : WSConnection) (message : String) : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendText conn.handle message)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send binary message through persistent connection -/
def sendBinary (conn : WSConnection) (message : String) : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendBinary conn.handle message)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send JSON message through persistent connection -/
def sendJson (conn : WSConnection) (jsonData : Json) : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendJson conn.handle jsonData)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send ping frame through persistent connection -/
def sendPing (conn : WSConnection) (message : String := "") : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendPing conn.handle message)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send pong frame through persistent connection -/
def sendPong (conn : WSConnection) (message : String := "") : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendPong conn.handle message)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send close frame through persistent connection -/
def sendClose (conn : WSConnection) (message : String := "") : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendClose conn.handle message)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send continuation frame through persistent connection -/
def sendContinuation (conn : WSConnection) (message : String) : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendContinuation conn.handle message)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Send specific frame type through persistent connection -/
def sendFrame (conn : WSConnection) (message : String) (frameType : FrameType) : WSM Unit := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.sendFrame conn.handle message frameType)
  match result with
  | Except.ok () => pure ()
  | Except.error e => throw (liftWSError e)

/-- Receive frame from persistent connection -/
def receive (conn : WSConnection) : WSM Frame := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.receive conn.handle)
  match result with
  | Except.ok frame =>
    if frame.frameType == FrameType.close then
      throw WSError.connectionClosed
    else
      pure frame
  | Except.error e => throw (liftWSError e)

/-- Receive frame from persistent connection with automatic retry for "would block" errors -/
def receiveWithRetry (conn : WSConnection) (maxRetries : Nat := 3) (retryDelayMs : UInt32 := 100) : WSM Frame := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.receiveWithRetry conn.handle maxRetries retryDelayMs)
  match result with
  | Except.ok frame =>
    if frame.frameType == FrameType.close then
      throw WSError.connectionClosed
    else
      pure frame
  | Except.error e => throw (liftWSError e)

/-- Receive JSON from persistent connection -/
def receiveJson (conn : WSConnection) : WSM Json := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let result ← liftM (FFI.receiveJson conn.handle)
  match result with
  | Except.ok json => pure json
  | Except.error e => throw (liftWSError e)

/-- Receive JSON with retry logic for socket errors -/
def receiveJsonWithRetry (conn : WSConnection) (maxRetries : Nat := 3) (retryDelayMs : UInt32 := 100) : WSM Json := do
  if !conn.isConnected then
    throw WSError.connectionClosed

  let rec loop (retriesLeft : Nat) : WSM Json := do
    let result ← liftM (FFI.receiveJson conn.handle)
    match result with
    | Except.ok json => pure json
    | Except.error (CurlWSError.receiveWouldBlock _) =>
      if retriesLeft > 0 then do
        IO.sleep retryDelayMs
        loop (retriesLeft - 1)
      else
        throw (WSError.clientError s!"JSON receive timed out after {maxRetries} retries")
    | Except.error e => throw (liftWSError e)
  loop maxRetries

/-- Wait for specific message type -/
def waitForText (conn : WSConnection) : WSM String := do
  let frame ← conn.receive
  match frame.frameType with
  | .ping => throw (WSError.invalidMessage "Received ping frame, expected text")
  | .pong => throw (WSError.invalidMessage "Received pong frame, expected text")
  | .text => pure frame.data
  | .binary => throw (WSError.invalidMessage "Expected text frame, got binary")
  | .close => throw WSError.connectionClosed
  | .continuation => throw (WSError.invalidMessage "Received continuation frame, expected text")

/-- Wait for text message with retry logic for socket not ready errors -/
def waitForTextWithRetry (conn : WSConnection) (maxRetries : Nat := 3) (retryDelayMs : UInt32 := 100) : WSM String := do
  let frame ← conn.receiveWithRetry maxRetries retryDelayMs
  match frame.frameType with
  | .ping => throw (WSError.invalidMessage "Received ping frame, expected text")
  | .pong => throw (WSError.invalidMessage "Received pong frame, expected text")
  | .text => pure frame.data
  | .binary => throw (WSError.invalidMessage "Expected text frame, got binary")
  | .close => throw WSError.connectionClosed
  | .continuation => throw (WSError.invalidMessage "Received continuation frame, expected text")

/-- Wait for binary message -/
def waitForBinary (conn : WSConnection) : WSM String := do
  let frame ← conn.receive
  match frame.frameType with
  | .ping => throw (WSError.invalidMessage "Received ping frame, expected binary")
  | .pong => throw (WSError.invalidMessage "Received pong frame, expected binary")
  | .binary => pure frame.data
  | .text => throw (WSError.invalidMessage "Expected binary frame, got text")
  | .close => throw WSError.connectionClosed
  | .continuation => throw (WSError.invalidMessage "Received continuation frame, expected binary")

/-- Wait for binary message with retry logic -/
def waitForBinaryWithRetry (conn : WSConnection) (maxRetries : Nat := 3) (retryDelayMs : UInt32 := 100) : WSM String := do
  let frame ← conn.receiveWithRetry maxRetries retryDelayMs
  match frame.frameType with
  | .ping => throw (WSError.invalidMessage "Received ping frame, expected binary")
  | .pong => throw (WSError.invalidMessage "Received pong frame, expected binary")
  | .binary => pure frame.data
  | .text => throw (WSError.invalidMessage "Expected binary frame, got text")
  | .close => throw WSError.connectionClosed
  | .continuation => throw (WSError.invalidMessage "Received continuation frame, expected binary")

/-- Wait for ping message -/
def waitForPing (conn : WSConnection) : WSM String := do
  let frame ← conn.receive
  match frame.frameType with
  | .ping => pure frame.data
  | .pong => throw (WSError.invalidMessage "Received pong frame, expected ping")
  | .text => throw (WSError.invalidMessage "Expected ping frame, got text")
  | .binary => throw (WSError.invalidMessage "Expected ping frame, got binary")
  | .close => throw WSError.connectionClosed
  | .continuation => throw (WSError.invalidMessage "Received continuation frame, expected ping")

/-- Wait for pong message -/
def waitForPong (conn : WSConnection) : WSM String := do
  let frame ← conn.receive
  match frame.frameType with
  | .ping => throw (WSError.invalidMessage "Received ping frame, expected pong")
  | .pong => pure frame.data
  | .text => throw (WSError.invalidMessage "Expected pong frame, got text")
  | .binary => throw (WSError.invalidMessage "Expected pong frame, got binary")
  | .close => throw WSError.connectionClosed
  | .continuation => throw (WSError.invalidMessage "Received continuation frame, expected pong")

/-- Wait for continuation message -/
def waitForContinuation (conn : WSConnection) : WSM String := do
  let frame ← conn.receive
  match frame.frameType with
  | .ping => throw (WSError.invalidMessage "Received ping frame, expected continuation")
  | .pong => throw (WSError.invalidMessage "Received pong frame, expected continuation")
  | .text => throw (WSError.invalidMessage "Expected continuation frame, got text")
  | .binary => throw (WSError.invalidMessage "Expected continuation frame, got binary")
  | .close => throw WSError.connectionClosed
  | .continuation => pure frame.data

/-- Close the WebSocket connection -/
def close (conn : WSConnection) : WSM Unit := do
  if !conn.isConnected then
    pure ()  -- Already closed
  else
    let result ← liftM (FFI.close conn.handle)
    match result with
    | Except.ok () => pure ()
    | Except.error e => throw (liftWSError e)

/-- Check if the WebSocket connection is still valid -/
def checkConnection (conn : WSConnection) : WSM String := do
  if !conn.isConnected then
    throw WSError.connectionClosed
  else
    let result ← liftM (FFI.checkConnection conn.handle)
    match result with
    | Except.ok status => pure status
    | Except.error e => throw (liftWSError e)

end WSConnection

/-- Configuration helpers -/

def withHeaders (headers : Array (String × String)) (action : WSM α) : WSM α :=
  withReader (fun cfg => { cfg with headers := cfg.headers ++ headers }) action

def withTimeout (timeout : UInt32) (action : WSM α) : WSM α :=
  withReader (fun cfg => { cfg with timeout }) action

def withInsecure (action : WSM α) : WSM α :=
  withReader (fun cfg => { cfg with verifySsl := false }) action

def withVerbose (action : WSM α) : WSM α :=
  withReader (fun cfg => { cfg with verbose := true }) action

/-- Echo client example pattern -/
def echoClient [ToWsUrlString U] (url : U) (message : String) : WSM String := do
  let conn ← connect url
  conn.sendText message
  let response ← conn.waitForText
  conn.close
  pure response

/-- Robust echo client with retry logic for socket errors -/
def echoClientRobust [ToWsUrlString U] (url : U) (message : String) : WSM String := do
  let conn ← connect url
  conn.sendText message
  let response ← conn.waitForTextWithRetry 5 200  -- 5 retries, 200ms delay
  conn.close
  pure response

/-- JSON RPC style communication -/
structure JsonRpcRequest where
  method : String
  params : Json
  id : String

structure JsonRpcResponse where
  result : Option Json
  error : Option Json
  id : String

def JsonRpcRequest.toJson (req : JsonRpcRequest) : Json :=
  Json.mkObj [
    ("jsonrpc", "2.0"),
    ("method", req.method),
    ("params", req.params),
    ("id", req.id)
  ]

def JsonRpcResponse.fromJson (json : Json) : Except String JsonRpcResponse := do
  let obj ← json.getObj?
  let idOpt := obj.get? "id"
  let id ← match idOpt with
    | none => throw "Missing id field"
    | some idJson => idJson.getStr?
  let result := obj.get? "result"
  let error := obj.get? "error"
  pure { result, error, id }

/-- Send JSON-RPC request and wait for response using persistent connection -/
def WSConnection.jsonRpc (conn : WSConnection) (req : JsonRpcRequest) : WSM JsonRpcResponse := do
  conn.sendJson req.toJson
  let responseJson ← conn.receiveJson
  match JsonRpcResponse.fromJson responseJson with
  | Except.ok response => pure response
  | Except.error parseError => throw (WSError.invalidMessage s!"Invalid JSON-RPC response: {parseError}")

/-- Robust JSON-RPC with retry logic -/
def WSConnection.jsonRpcRobust (conn : WSConnection) (req : JsonRpcRequest) : WSM JsonRpcResponse := do
  conn.sendJson req.toJson
  let responseJson ← conn.receiveJsonWithRetry
  match JsonRpcResponse.fromJson responseJson with
  | Except.ok response => pure response
  | Except.error parseError => throw (WSError.invalidMessage s!"Invalid JSON-RPC response: {parseError}")

end Curl.WS
