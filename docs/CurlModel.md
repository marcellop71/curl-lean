# CurlModel - Formal Specification Proposal

A proposal for a formal mathematical model of curl-lean, inspired by the RedisModel approach.

## Background: The RedisModel Approach

The `redis-lean/RedisModel/AbstractMinimal.lean` demonstrates how to create a formal mathematical specification:

1. **Core Abstraction**: Models Redis as a state monad `RedisM DB α`
2. **Abstract Operations**: A typeclass `AbstractOps` defining `set`, `get`, `del`, `existsKey`
3. **Axiom System**: ~12 axioms capturing operational semantics
4. **Proven Theorems**: Idempotence, commutativity, cancellation, algebraic laws

## What Could CurlModel Formalize?

Curl-lean provides HTTP client and WebSocket APIs. The model could formalize:

---

## 1. HTTP Request/Response Model

Formalizes HTTP semantics and the HttpM monad.

```lean
namespace CurlModel.Http

-- HTTP method type
inductive HttpMethod
  | GET | POST | PUT | PATCH | DELETE | HEAD | OPTIONS

-- Core types
structure Request where
  method : HttpMethod
  url : String
  headers : Array (String × String)
  body : String
  timeout : Option Nat

structure Response where
  status : Nat
  headers : Array (String × String)
  body : String

-- HTTP monad (reader over config, except for errors)
abbrev HttpM := ReaderT HttpConfig (ExceptT HttpError IO)

-- Axiom: Successful GET is idempotent (safe method)
axiom get_idempotent : ∀ (url : String) (cfg : HttpConfig),
  let resp1 := runHttpWith cfg (get url)
  let resp2 := runHttpWith cfg (get url)
  resp1.isOk ∧ resp2.isOk → resp1 = resp2  -- Idealized; assumes no server-side changes

-- Axiom: Status codes in valid range
axiom status_code_range : ∀ (resp : Response),
  100 ≤ resp.status ∧ resp.status < 600

-- Axiom: Success means 2xx status
axiom success_means_2xx : ∀ (resp : Response),
  Response.isSuccess resp ↔ 200 ≤ resp.status ∧ resp.status < 300

-- Axiom: Redirects are followed (when enabled)
axiom redirects_followed : ∀ (cfg : HttpConfig) (url : String),
  cfg.followRedirects →
  let resp := runHttpWith cfg (get url)
  resp.isOk → resp.get!.status ≠ 301 ∧ resp.get!.status ≠ 302

-- Axiom: Timeout causes error
axiom timeout_causes_error : ∀ (cfg : HttpConfig) (req : Request),
  requestDuration req > cfg.defaultTimeout →
  runHttpWith cfg req.execute = .error HttpError.timeout
```

---

## 2. HTTP Method Semantics Model

Formalizes the semantic differences between HTTP methods.

```lean
namespace CurlModel.Methods

-- Safe methods (no side effects on server)
def isSafe : HttpMethod → Bool
  | .GET | .HEAD | .OPTIONS => true
  | _ => false

-- Idempotent methods (repeated calls have same effect)
def isIdempotent : HttpMethod → Bool
  | .GET | .HEAD | .OPTIONS | .PUT | .DELETE => true
  | .POST | .PATCH => false

-- Axiom: Safe methods don't modify server state
axiom safe_no_side_effects : ∀ (m : HttpMethod) (url : String),
  isSafe m →
  let serverStateBefore := getServerState url
  let _ := execute { method := m, url }
  let serverStateAfter := getServerState url
  serverStateBefore = serverStateAfter

-- Axiom: Idempotent methods can be safely retried
axiom idempotent_safe_retry : ∀ (m : HttpMethod) (url : String) (body : String),
  isIdempotent m →
  let effect1 := execute { method := m, url, body }
  let effect2 := execute { method := m, url, body }
  serverEffect effect1 = serverEffect effect2

-- Axiom: POST creates new resource
axiom post_creates : ∀ (url : String) (body : String),
  let resp := execute { method := .POST, url, body }
  resp.isOk → resp.status ∈ [200, 201, 202]

-- Axiom: PUT replaces resource
axiom put_replaces : ∀ (url : String) (body : String),
  let resp := execute { method := .PUT, url, body }
  resp.isOk → getResource url = body

-- Axiom: DELETE removes resource
axiom delete_removes : ∀ (url : String),
  let resp := execute { method := .DELETE, url }
  resp.isOk → ¬exists (getResource url)
```

---

## 3. URL Building Model

Formalizes URL construction and validation.

```lean
namespace CurlModel.Url

-- URL components
structure Url where
  scheme : String  -- "http" or "https"
  host : String
  port : Option Nat
  path : String
  query : Array (String × String)

-- Build URL string
def build (url : Url) : String := ...

-- Axiom: Build produces valid URL
axiom build_valid : ∀ (url : Url),
  isValidUrl (build url)

-- Axiom: Query parameters are properly encoded
axiom query_encoded : ∀ (url : Url) (k v : String),
  (k, v) ∈ url.query →
  build url |>.containsSubstr (urlEncode k ++ "=" ++ urlEncode v)

-- Axiom: Base URL + path concatenation
axiom base_path_concat : ∀ (base path : String),
  buildUrl base path =
    if path.startsWith "http" then path
    else if base.endsWith "/" ∧ path.startsWith "/" then base.dropRight 1 ++ path
    else if base.endsWith "/" ∨ path.startsWith "/" then base ++ path
    else base ++ "/" ++ path

-- Axiom: Scheme preserved in build
axiom scheme_preserved : ∀ (url : Url),
  (build url).startsWith url.scheme
```

---

## 4. Configuration Monad Model

Formalizes the HttpConfig reader monad pattern.

```lean
namespace CurlModel.Config

structure HttpConfig where
  baseUrl : String
  defaultHeaders : Array (String × String)
  defaultTimeout : Nat
  followRedirects : Bool
  verifySsl : Bool
  verbose : Bool
  apiKey : String

-- Axiom: withConfig modifies reader context
axiom with_config_modifies : ∀ (f : HttpConfig → HttpConfig) (action : HttpM α) (cfg : HttpConfig),
  runHttpWith cfg (withConfig f action) = runHttpWith (f cfg) action

-- Axiom: withBaseUrl specializes withConfig
axiom with_base_url_spec : ∀ (url : String) (action : HttpM α) (cfg : HttpConfig),
  runHttpWith cfg (withBaseUrl url action) =
  runHttpWith { cfg with baseUrl := url } action

-- Axiom: withHeaders appends to existing headers
axiom with_headers_appends : ∀ (hdrs : HttpHeaders) (action : HttpM α) (cfg : HttpConfig),
  runHttpWith cfg (withHeaders hdrs action) =
  runHttpWith { cfg with defaultHeaders := cfg.defaultHeaders ++ hdrs } action

-- Axiom: API key adds Authorization header
axiom api_key_adds_auth : ∀ (key : String) (action : HttpM α) (cfg : HttpConfig),
  key ≠ "" →
  runHttpWith { cfg with apiKey := key } action
  -- Request will include "Authorization: Bearer {key}" header
```

---

## 5. Error Handling Model

Formalizes HTTP error semantics.

```lean
namespace CurlModel.Error

inductive HttpError
  | networkError (msg : String)
  | timeout
  | httpError (status : Nat) (body : String)
  | parseError (msg : String)

-- Axiom: Network errors are retryable
axiom network_error_retryable : ∀ (e : HttpError),
  match e with
  | .networkError _ | .timeout => isRetryable e = true
  | _ => isRetryable e = false

-- Axiom: HTTP 4xx errors are client errors (not retryable without changes)
axiom client_error_not_retryable : ∀ (status : Nat) (body : String),
  400 ≤ status ∧ status < 500 →
  isRetryable (.httpError status body) = false

-- Axiom: HTTP 5xx errors may be retryable
axiom server_error_may_retry : ∀ (status : Nat) (body : String),
  500 ≤ status ∧ status < 600 →
  isRetryable (.httpError status body) = true

-- Axiom: Retry reduces eventually to success or permanent failure
axiom retry_terminates : ∀ (n : Nat) (action : HttpM α),
  let result := retry n action
  result.isOk ∨ (∃ e, result = .error e ∧ ¬isRetryable e)

-- Axiom: retryOnNetworkError only retries network errors
axiom retry_on_network_selective : ∀ (n : Nat) (action : HttpM α) (e : HttpError),
  match e with
  | .networkError _ | .timeout => retryOnNetworkError n action may retry
  | _ => retryOnNetworkError n action does not retry
```

---

## 6. WebSocket Model

Formalizes WebSocket connection semantics.

```lean
namespace CurlModel.WebSocket

-- WebSocket state
inductive WSState
  | connecting
  | open
  | closing
  | closed

-- Operations
def connect (url : String) : IO (Option WSConnection) := ...
def send (conn : WSConnection) (msg : String) : IO Bool := ...
def receive (conn : WSConnection) : IO (Option String) := ...
def close (conn : WSConnection) : IO Unit := ...

-- Axiom: Connection state machine
axiom ws_state_transitions : ∀ (conn : WSConnection),
  conn.state = .connecting → (conn'.state = .open ∨ conn'.state = .closed)
  conn.state = .open → (conn'.state = .open ∨ conn'.state = .closing)
  conn.state = .closing → conn'.state = .closed
  conn.state = .closed → conn'.state = .closed

-- Axiom: Send requires open connection
axiom send_requires_open : ∀ (conn : WSConnection) (msg : String),
  conn.state ≠ .open → send conn msg = false

-- Axiom: Close transitions to closed
axiom close_transitions : ∀ (conn : WSConnection),
  (≡ close conn on state).state = .closed

-- Axiom: Messages received in order
axiom messages_ordered : ∀ (conn : WSConnection),
  let msgs := receiveAll conn
  msgs.isSortedBy (·.timestamp)
```

---

## Comparison with RedisModel

| Aspect | RedisModel | CurlModel |
|--------|------------|-----------|
| Core abstraction | Key-value store | HTTP client |
| State type | DB (opaque) | HttpConfig (reader) |
| Operations | GET, SET, DEL | get, post, put, delete |
| Key invariants | set-get consistency | method semantics, status codes |
| Composition | monadic DB ops | HttpM reader/except |

---

## Recommended Implementation Order

1. **URL Building** - Foundational, pure functions
2. **HTTP Method Semantics** - Core HTTP concepts
3. **Error Handling** - Cross-cutting concern
4. **Configuration Monad** - Reader monad properties
5. **Request/Response** - Full HTTP semantics
6. **WebSocket** - Stateful connection model

## Why Model HTTP Formally?

1. **Method Safety**: Ensure safe/idempotent methods are used correctly
2. **Error Handling**: Prove retry logic is sound
3. **URL Construction**: Verify URL building produces valid URLs
4. **Configuration**: Ensure config changes propagate correctly
5. **Testing**: Axioms suggest property-based test cases
