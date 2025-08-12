import Lean.Data.Json

import CurlLean.Enums
import CurlLean.Error

namespace Curl.Http

open Lean

structure Response where
  status : UInt32
  body   : String
  bodyJSON : Option Json := none

namespace Response

def mk' (status : UInt32) (body : String) : Response :=
  let bodyJSON := match Json.parse body with
    | Except.ok json => some json
    | Except.error _ => none
  { status, body, bodyJSON }

def isSuccess (resp : Response) : Bool :=
  200 ≤ resp.status && resp.status < 300

def isRedirect (resp : Response) : Bool :=
  300 ≤ resp.status && resp.status < 400

def isClientError (resp : Response) : Bool :=
  400 ≤ resp.status && resp.status < 500

def isServerError (resp : Response) : Bool :=
  500 ≤ resp.status && resp.status < 600

def parseJson (resp : Response) : Except String Json := do
  Json.parse resp.body

def expectJsonSuccess (resp : Response) : Except String Json := do
  if 200 ≤ resp.status && resp.status < 300 then
    resp.parseJson
  else
    throw s!"HTTP error {resp.status}: {resp.body}"

end Response

instance : Repr Response where
  reprPrec resp prec :=
    let jsonRepr := match resp.bodyJSON with
      | none => "none"
      | some json => s!"some {json.compress}"
    Repr.addAppParen (s!"Response.mk {resp.status} {repr resp.body} {jsonRepr}") prec

namespace FFI
namespace Raw

/--
Raw FFI entry point:
  headers: newline-delimited "Header: value" entries
  userAgent: User-Agent string (empty string to use curl's default)
  timeoutMs: 0 = no timeout; otherwise libcurl timeout in ms
  verifySsl: true = verify SSL certificates; false = skip verification (insecure)
  verbose: true = enable verbose debug output; false = disable debug output
Returns: (status, body). If libcurl fails, status = 0 and body = error message.
-/
@[extern "lean_curl_easy_perform"]
opaque curl_easy_perform
  (method : @& String)
  (url    : @& String)
  (body   : @& String)
  (headers: @& String)
  (userAgent : @& String)
  (timeoutMs : UInt32)
  (verifySsl : Bool)
  (verbose : Bool)
  : IO (UInt32 × String)

end Raw

/-- Utility: format headers into shim's input string. -/
private def packHeaders (hs : Array (String × String)) : String :=
  String.intercalate "\n" <| hs.toList.map (fun (k, v) => s!"{k}: {v}")

/-- Utility: format query parameters into URL query string. -/
private def packQuery (qs : Array (String × String)) : String :=
  if qs.isEmpty then
    ""
  else
    "?" ++ String.intercalate "&" (qs.toList.map (fun (k, v) => s!"{k}={v}"))

/--
Safe wrapper around Raw.curl_easy_perform that returns proper error handling.
Converts the raw (UInt32 × String) result into Either CurlError Response.
-/
def curl_easy_perform (method : HttpMethod)
             (url : String)
             (body : String := "")
             (headers : Array (String × String) := #[])
             (userAgent : String := "")
             (timeoutMs : UInt32 := 0)
             (verifySsl : Bool := true)
             (verbose : Bool := false)
             : IO (Except CurlError Response) := do
  try
    let h := packHeaders headers
    let (status, responseBody) ← Raw.curl_easy_perform (toString method) url body h userAgent timeoutMs verifySsl verbose

    -- Check for curl errors (status = 0 indicates curl failure)
    match status with
    | 0 =>
      let lowerBody := responseBody.toLower
      if lowerBody.startsWith "timeout" || lowerBody.endsWith "timeout" then
        pure (.error .timeout)
      else if lowerBody.startsWith "url" || lowerBody.endsWith "url" then
        pure (.error (.invalidUrl url))
      else if lowerBody.startsWith "init" || lowerBody.endsWith "init" then
        pure (.error .initFailed)
      else
        pure (.error (.networkError responseBody))
    | _ => pure (.ok (Response.mk' status responseBody))
  catch e =>
    pure (.error (.unknownError e.toString))

end FFI
end Curl.Http
