# curl-lean

A comprehensive HTTP client and WebSocket library for Lean 4 built on top of [libcurl](https://curl.se/libcurl/c/), providing both low-level FFI bindings and high-level monadic interfaces.

> ⚠️ **Warning**: this is work in progress, it is still incomplete and it ~~may~~ will contain errors

## AI Assistance Disclosure

Parts of this repository were created with assistance from AI-powered coding tools, specifically Claude by Anthropic. Not all generated code may have been reviewed. Generated code may have been adapted by the author. Design choices, architectural decisions, and final validation were performed independently by the author.

## Features

### HTTP Client (`CurlLean.Http`)

- Type-safe HTTP methods: GET, POST, PUT, DELETE, PATCH
- Monadic interface with `ReaderT` and `ExceptT` for composable operations
- Configurable client: base URLs, headers, timeouts, SSL verification
- Request builder pattern with fluent API
- Built-in JSON support

### WebSocket Client (`CurlLean.WS`)

- Full WebSocket protocol support with all frame types (text, binary, ping, pong, close, continuation)
- Persistent connection management with handle-based tracking
- Automatic retry logic for transient network issues
- JSON messaging and JSON-RPC protocol support
- Connection health diagnostics

## Project Structure

```
curl-lean/
├── CurlLean/                # Main library
│   ├── HttpClient.lean      # HTTP client implementation
│   ├── HttpFFI.lean         # HTTP FFI bindings
│   ├── WSClient.lean        # WebSocket client implementation
│   ├── WSFFI.lean           # WebSocket FFI bindings
│   ├── Error.lean           # Error type definitions
│   ├── Enums.lean           # HTTP methods and frame types
│   └── Url.lean             # URL parsing and utilities
├── CurlLean.lean            # Root module
├── curl/                    # C FFI implementation
│   ├── curl_shim.c          # Header shim
│   ├── curl_ws_connect.c    # WebSocket connection management
│   └── curl_easy_perform.c  # HTTP request implementation
├── Tests/                   # Test suite
├── lakefile.lean            # Build configuration
└── lean-toolchain           # Lean version (v4.27.0-rc1)
```

## Requirements

- **Lean 4**: v4.27.0-rc1 or compatible
- **libcurl**: 7.86.0+ (with WebSocket support)
- **zlog**: C logging library

### Lean Dependencies

- `zlogLean` - Structured logging
- `LSpec` - Testing framework

## Building

```bash
# Ubuntu/Debian
sudo apt-get install libcurl4-openssl-dev

# macOS
brew install curl

# Verify libcurl version (must be 7.86.0+)
curl --version

# Build the library
lake build
```

## Usage

### HTTP Client

```lean
import CurlLean
open CurlLean.Http

def main : IO Unit := do
  let result ← runHttp do
    let request : Request := {
      method := HttpMethod.GET,
      url := "https://httpbin.org/get"
    }
    request.execute

  match result with
  | Except.ok response => IO.println s!"Status: {response.status}"
  | Except.error err => IO.println s!"Error: {err}"
```

#### With Configuration

```lean
let config : HttpConfig := {
  baseUrl := "https://api.example.com",
  defaultHeaders := #[("User-Agent", "curl-lean/1.0")],
  defaultTimeout := 10000,
  verifySsl := true
}

let result ← runHttpWith config do
  let request : Request := {
    method := HttpMethod.POST,
    url := "/users"
  }
  request.withBody "{\"name\": \"Alice\"}"
         |>.withHeader "Content-Type" "application/json"
         |>.execute
```

### WebSocket Client

```lean
import CurlLean
open CurlLean.WS

def main : IO Unit := do
  let result ← runWS do
    let conn ← connect "wss://ws.postman-echo.com/raw"
    conn.sendText "Hello WebSocket!"
    conn.waitForTextWithRetry 5 200  -- 5 retries, 200ms delay

  match result with
  | Except.ok response => IO.println s!"Echo: {response}"
  | Except.error err => IO.println s!"Error: {err}"
```

#### Frame Handling

```lean
let result ← runWS do
  let conn ← connect "wss://ws.example.com"

  -- Send different frame types
  conn.sendText "Hello"
  conn.sendBinary "Binary data"
  conn.sendPing "heartbeat"

  -- Receive and handle frames
  let frame ← conn.receiveWithRetry 3 100
  match frame.frameType with
  | .text => IO.println s!"Text: {frame.data}"
  | .binary => IO.println s!"Binary: {frame.data}"
  | .ping => conn.sendPong frame.data
  | .pong => IO.println "Pong received"
  | .close => IO.println "Connection closed"
  | .continuation => IO.println "Continuation frame"
```

#### JSON-RPC

```lean
let result ← runWS do
  let conn ← connect "wss://jsonrpc.example.com"

  let request : JsonRpcRequest := {
    method := "ping",
    params := Json.mkObj [("timestamp", Json.str "2024-01-01")],
    id := "1"
  }

  conn.jsonRpcRobust request  -- With automatic retry
```

## API Reference

### HTTP

| Function | Description |
|----------|-------------|
| `get url` | HTTP GET request |
| `post url data` | HTTP POST request |
| `put url data` | HTTP PUT request |
| `patch url data` | HTTP PATCH request |
| `delete url` | HTTP DELETE request |
| `Request.execute` | Execute a custom request |

### WebSocket

| Function | Description |
|----------|-------------|
| `connect url` | Establish WebSocket connection |
| `sendText msg` | Send text frame |
| `sendBinary msg` | Send binary frame |
| `sendPing msg` | Send ping frame |
| `sendPong msg` | Send pong frame |
| `sendClose msg` | Send close frame |
| `sendJson json` | Send JSON data |
| `receive` | Receive a frame |
| `receiveWithRetry n delay` | Receive with retry logic |
| `waitForText` | Wait for text frame |
| `waitForTextWithRetry n delay` | Wait for text with retry |
| `checkConnection` | Validate connection health |
| `close` | Close connection |

### Error Types

```lean
-- HTTP errors
inductive HttpError where
  | networkError (msg : String)
  | httpError (status : UInt32) (body : String)
  | timeout
  | invalidUrl (url : String)

-- WebSocket errors
inductive CurlWSError where
  | connectionFailed (msg : String)
  | sendFailed (msg : String)
  | receiveFailed (msg : String)
  | receiveWouldBlock (msg : String)  -- Recoverable
  | timeout
  | invalidUrl (url : String)
  | initFailed
  | unknownError (msg : String)

inductive WSError where
  | webSocketError (e : CurlWSError)
  | connectionClosed
  | invalidMessage (msg : String)
  | clientError (msg : String)
```

## Configuration

### HTTP Configuration

```lean
structure HttpConfig where
  baseUrl : String := ""
  defaultHeaders : HttpHeaders := #[]
  defaultTimeout : Nat := 30000        -- milliseconds
  followRedirects : Bool := true
  verifySsl : Bool := true
  verbose : Bool := false
  userAgent : String := ""
  apiKey : String := ""
  log : Bool := false
```

### WebSocket Configuration

```lean
structure Config where
  headers : Array (String × String) := #[]
  timeout : UInt32 := 30000            -- milliseconds
  verifySsl : Bool := false
  verbose : Bool := false
```
