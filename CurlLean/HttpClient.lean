import Lean.Data.Json
import ZlogLean

import CurlLean.Error
import CurlLean.HttpFFI
import CurlLean.Url

namespace Curl.Http

open Lean Curl Curl.Http Zlog

abbrev HttpResult := Except HttpError Response
abbrev HttpHeader := String × String
abbrev HttpHeaders := Array HttpHeader
abbrev HttpQuery := Array (String × String)

structure HttpConfig where
  baseUrl : String := ""
  defaultHeaders : HttpHeaders := #[]
  defaultTimeout : Nat := 30000 -- msec
  followRedirects : Bool := true
  verifySsl : Bool := true
  verbose : Bool := false
  userAgent : String := ""  -- User-Agent header, empty string means don't set it
  apiKey : String := ""     -- API key for Authorization Bearer header, empty string means don't set it
  log : Bool := false       -- Enable logging of requests and responses
deriving Repr

def defaultConfig : HttpConfig := {}

def jsonContentTypeHeader : HttpHeaders := #[("Content-Type", "application/json")]
def formContentTypeHeader : HttpHeaders := #[("Content-Type", "application/x-www-form-urlencoded")]

abbrev HttpM := ReaderT HttpConfig <| ExceptT HttpError IO

instance : MonadReader HttpConfig HttpM := inferInstance
instance : MonadExcept HttpError HttpM := inferInstance

def runHttp (action : HttpM α) : IO (Except HttpError α) :=
  action.run defaultConfig

def runHttpWith (cfg : HttpConfig) (action : HttpM α) : IO (Except HttpError α) :=
  action.run cfg

def getConfig : HttpM HttpConfig := do
  read

def withConfig (f : HttpConfig → HttpConfig) (action : HttpM α) : HttpM α := do
  withReader f action

def withBaseUrl (baseUrl : String) (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with baseUrl }) action

def withHeaders (headers : HttpHeaders) (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with defaultHeaders := cfg.defaultHeaders ++ headers }) action

def withTimeout (timeout : Nat) (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with defaultTimeout := timeout }) action

def withInsecure (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with verifySsl := false }) action

def withSecure (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with verifySsl := true }) action

def withVerbose (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with verbose := true }) action

def withQuiet (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with verbose := false }) action

def withApiKey (apiKey : String) (logging : Bool) (action : HttpM α) : HttpM α :=
  withConfig (fun cfg => { cfg with apiKey := apiKey, log := logging }) action

namespace HttpM

def orElse (action : HttpM α) (fallback : HttpError → HttpM α) : HttpM α := do
  tryCatch action fallback

def orCatch (action : HttpM α) (handler : HttpError → α) : HttpM α := do
  tryCatch action (fun e => pure (handler e))

def onError (action : HttpM α) (handler : HttpError → HttpM Unit) : HttpM α := do
  tryCatch action (fun e => do
    _ ← handler e
    throw e)

def retry (times : Nat) (action : HttpM α) : HttpM α := do
  let rec loop (n : Nat) : HttpM α := do
    tryCatch action (fun e =>
      if n > 0 then
        loop (n - 1)
      else
        throw e)
  loop times

def retryOnNetworkError (times : Nat) (action : HttpM α) : HttpM α := do
  let rec loop (n : Nat) : HttpM α := do
    tryCatch action (fun e =>
      match e with
      | .networkError _ | .timeout =>
        if n > 0 then
          loop (n - 1)
        else
          throw e
      | _ => throw e)
  loop times

end HttpM

namespace Response

def expectSuccess (resp : Response) : HttpM Response :=
  if Response.isSuccess resp then
    pure resp
  else
    throw (HttpError.httpError resp.status resp.body)

def expectJson (resp : Response) : HttpM Json := do
  let successResp ← expectSuccess resp
  match Json.parse successResp.body with
  | Except.ok json => pure json
  | Except.error parseError => throw (HttpError.networkError s!"JSON parse error: {parseError}")

def tryParseJson (resp : Response) : HttpM (Option Json) := do
  match Json.parse resp.body with
  | Except.ok json => pure (some json)
  | Except.error _ => pure none

end Response

structure Request where
  method: HttpMethod
  url : String
  body : String := ""
  headers : HttpHeaders := #[]
  timeout : Option UInt32 := none
deriving Repr

namespace Request

def withBody (req : Request) (body : String) : Request :=
  { req with body }

def withHeaders (req : Request) (headers : HttpHeaders) : Request :=
  { req with headers := req.headers ++ headers }

def withHeader (req : Request) (key value : String) : Request :=
  req.withHeaders #[(key, value)]

def withTimeout (req : Request) (timeout : Nat) : Request :=
  { req with timeout := some (UInt32.ofNat timeout) }

private def buildUrl (baseUrl : String) (url : String) : String :=
  if url.startsWith "http://" || url.startsWith "https://" then
    url
  else if baseUrl.isEmpty then
    url
  else if baseUrl.endsWith "/" && url.startsWith "/" then
    (baseUrl.dropEnd 1).toString ++ url
  else if baseUrl.endsWith "/" || url.startsWith "/" then
    baseUrl ++ url
  else
    baseUrl ++ "/" ++ url

def execute (req : Request) : HttpM Response := do
  let cfg ← read
  let fullUrl := buildUrl cfg.baseUrl req.url
  let mut allHeaders := cfg.defaultHeaders ++ req.headers

  if !cfg.apiKey.isEmpty then
    allHeaders := allHeaders ++ #[("Authorization", s!"Bearer {cfg.apiKey}")]

  let timeout := req.timeout.getD (UInt32.ofNat cfg.defaultTimeout)

  if cfg.log then
    let headersStr := String.intercalate ", " (allHeaders.toList.map (fun (k, v) => s!"{k}: {v}"))
    let bodyInfo := if req.body.isEmpty then "No body" else s!"Body: {req.body.take 200}..."
    liftM $ Zlog.info s!"HTTP {req.method} {fullUrl} | Headers: {headersStr} | {bodyInfo}"

  let result ← liftM <| FFI.curl_easy_perform req.method fullUrl req.body allHeaders cfg.userAgent timeout cfg.verifySsl cfg.verbose
  match result with
  | Except.ok resp =>
    let responseWithJson := Response.mk' resp.status resp.body
    if cfg.log then
      let responseBodyInfo := if resp.body.isEmpty then "No body" else s!"Body: {resp.body.take 200}..."
      liftM $ Zlog.info s!"HTTP Response {resp.status} | {responseBodyInfo}"
    pure responseWithJson
  | Except.error e =>
    if cfg.log then
      liftM $ Zlog.error s!"HTTP Request failed: {e}"
    throw e.toHttpError

def withAuth (req : Request) (token : String) : Request :=
  req.withHeader "Authorization" s!"Bearer {token}"

def withUserAgent (req : Request) (userAgent : String) : Request :=
  req.withHeader "User-Agent" userAgent

end Request

def defaultUserAgent (appName : String) (version : String := "1.0") : String :=
  s!"{appName}/{version} (Lean 4; CurlLean)"

private def packQuery (qs : HttpQuery) : String :=
  if qs.isEmpty then
    ""
  else
    "?" ++ String.intercalate "&" (qs.toList.map (fun (k, v) => s!"{k}={v}"))

class ToReqBody (α : Type) where
  data : α → String
  headers : α → HttpHeaders

instance : ToReqBody String where
  data := id
  headers := fun _ => #[]

instance : ToReqBody Json where
  data := Json.compress
  headers := fun _ => jsonContentTypeHeader

def get [ToUrlString U] (url : U) (query : HttpQuery := #[]) : HttpM Response := do
  let cfg ← read
  let urlStr := ToUrlString.toUrlString url
  let fullUrl := urlStr ++ packQuery query
  if cfg.log then
    liftM $ Zlog.debug s!"GET request to {fullUrl}"
  let request : Request := {
    method := HttpMethod.GET,
    url := fullUrl,
  }
  request.execute

def post [ToUrlString U] [ToReqBody α] (url : U) (data : α) : HttpM Response := do
  let cfg ← read
  let urlStr := ToUrlString.toUrlString url
  if cfg.log then
    let bodyPreview := (ToReqBody.data data).take 200
    liftM $ Zlog.debug s!"POST request to {urlStr} with data: {bodyPreview}..."
  let request : Request := {
    method := HttpMethod.POST,
    url := urlStr,
    body := ToReqBody.data data,
    headers := ToReqBody.headers data
  }
  request.execute

def put [ToUrlString U] [ToReqBody α] (url : U) (data : α) : HttpM Response := do
  let cfg ← read
  let urlStr := ToUrlString.toUrlString url
  if cfg.log then
    let bodyPreview := (ToReqBody.data data).take 200
    liftM $ Zlog.debug s!"PUT request to {urlStr} with data: {bodyPreview}..."
  let request : Request := {
    method := HttpMethod.PUT,
    url := urlStr,
    body := ToReqBody.data data,
    headers := ToReqBody.headers data
  }
  request.execute

def patch [ToUrlString U] [ToReqBody α] (url : U) (data : α) : HttpM Response := do
  let cfg ← read
  let urlStr := ToUrlString.toUrlString url
  if cfg.log then
    let bodyPreview := (ToReqBody.data data).take 200
    liftM $ Zlog.debug s!"PATCH request to {urlStr} with data: {bodyPreview}..."
  let request : Request := {
    method := HttpMethod.PATCH,
    url := urlStr,
    body := ToReqBody.data data,
    headers := ToReqBody.headers data
  }
  request.execute

def delete [ToUrlString U] (url : U) (headers : HttpHeaders := #[]) : HttpM Response := do
  let cfg ← read
  let urlStr := ToUrlString.toUrlString url
  if cfg.log then
    let headersStr := if headers.isEmpty then "no headers" else s!"headers: {repr headers}"
    liftM $ Zlog.debug s!"DELETE request to {urlStr} with {headersStr}"
  let request : Request := {
    method := HttpMethod.DELETE,
    url := urlStr,
    headers := headers
  }
  request.execute

end Curl.Http
