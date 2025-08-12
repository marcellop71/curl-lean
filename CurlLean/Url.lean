namespace Curl

/-! # URL Types and Utilities -/

/-- URL scheme enumeration -/
inductive Scheme where
  | http
  | https
  | ws
  | wss
  deriving Repr, BEq, DecidableEq, Inhabited

namespace Scheme

def toString : Scheme → String
  | .http => "http"
  | .https => "https"
  | .ws => "ws"
  | .wss => "wss"

instance : ToString Scheme where
  toString := Scheme.toString

def fromString? (s : String) : Option Scheme :=
  match s.toLower with
  | "http" => some .http
  | "https" => some .https
  | "ws" => some .ws
  | "wss" => some .wss
  | _ => none

def defaultPort : Scheme → Nat
  | .http => 80
  | .https => 443
  | .ws => 80
  | .wss => 443

def isSecure : Scheme → Bool
  | .http => false
  | .https => true
  | .ws => false
  | .wss => true

end Scheme

/-! ## Query parameter utilities -/

def urlEncode (s : String) : String :=
  -- Basic URL encoding for query parameters
  s.replace " " "%20"
   |>.replace "!" "%21"
   |>.replace "#" "%23"
   |>.replace "$" "%24"
   |>.replace "&" "%26"
   |>.replace "'" "%27"
   |>.replace "(" "%28"
   |>.replace ")" "%29"
   |>.replace "*" "%2A"
   |>.replace "+" "%2B"
   |>.replace "," "%2C"
   |>.replace "/" "%2F"
   |>.replace ":" "%3A"
   |>.replace ";" "%3B"
   |>.replace "=" "%3D"
   |>.replace "?" "%3F"
   |>.replace "@" "%40"
   |>.replace "[" "%5B"
   |>.replace "]" "%5D"

def buildQueryString (params : Array (String × String)) : String :=
  if params.isEmpty then
    ""
  else
    let encodedParams := params.map fun (key, value) =>
      s!"{urlEncode key}={urlEncode value}"
    "?" ++ String.intercalate "&" encodedParams.toList

structure QueryParams where
  params : Array (String × String)
  deriving Repr

namespace QueryParams

def empty : QueryParams := ⟨#[]⟩

def add (qp : QueryParams) (key : String) (value : String) : QueryParams :=
  ⟨qp.params.push (key, value)⟩

def addNat (qp : QueryParams) (key : String) (value : Nat) : QueryParams :=
  qp.add key (toString value)

def addFloat (qp : QueryParams) (key : String) (value : Float) : QueryParams :=
  qp.add key (toString value)

def addBool (qp : QueryParams) (key : String) (value : Bool) : QueryParams :=
  qp.add key (if value then "true" else "false")

def addOption (qp : QueryParams) (key : String) (value : Option String) : QueryParams :=
  match value with
  | some v => qp.add key v
  | none => qp

def addNatOption (qp : QueryParams) (key : String) (value : Option Nat) : QueryParams :=
  match value with
  | some v => qp.addNat key v
  | none => qp

def addFloatOption (qp : QueryParams) (key : String) (value : Option Float) : QueryParams :=
  match value with
  | some v => qp.addFloat key v
  | none => qp

def addBoolOption (qp : QueryParams) (key : String) (value : Option Bool) : QueryParams :=
  match value with
  | some v => qp.addBool key v
  | none => qp

def toString (qp : QueryParams) : String :=
  buildQueryString qp.params

def toOptionString (qp : QueryParams) : Option String :=
  if qp.params.isEmpty then
    none
  else
    some ((buildQueryString qp.params).drop 1).toString  -- Remove the leading '?'

end QueryParams

/-! ## URL Type -/

/-- Represents a complete URL with all components -/
structure Url where
  scheme : Scheme
  host : String
  port : Option Nat := none
  path : String := ""
  query : QueryParams := QueryParams.empty
  fragment : Option String := none
  deriving Repr

namespace Url

/-- Create an HTTP URL -/
def http (host : String) (path : String := "") : Url :=
  { scheme := .http, host, path }

/-- Create an HTTPS URL -/
def https (host : String) (path : String := "") : Url :=
  { scheme := .https, host, path }

/-- Create a WebSocket URL -/
def ws (host : String) (path : String := "") : Url :=
  { scheme := .ws, host, path }

/-- Create a secure WebSocket URL -/
def wss (host : String) (path : String := "") : Url :=
  { scheme := .wss, host, path }

/-- Set the path -/
def withPath (url : Url) (path : String) : Url :=
  { url with path }

/-- Append to the path -/
def appendPath (url : Url) (segment : String) : Url :=
  let newPath :=
    if url.path.isEmpty then
      if segment.startsWith "/" then segment else "/" ++ segment
    else if url.path.endsWith "/" && segment.startsWith "/" then
      url.path ++ segment.drop 1
    else if url.path.endsWith "/" || segment.startsWith "/" then
      url.path ++ segment
    else
      url.path ++ "/" ++ segment
  { url with path := newPath }

/-- Operator for path appending: url / "path" -/
instance : HDiv Url String Url where
  hDiv url segment := url.appendPath segment

/-- Set the port -/
def withPort (url : Url) (port : Nat) : Url :=
  { url with port := some port }

/-- Set query parameters -/
def withQuery (url : Url) (query : QueryParams) : Url :=
  { url with query }

/-- Add a query parameter -/
def addQuery (url : Url) (key : String) (value : String) : Url :=
  { url with query := url.query.add key value }

/-- Add an optional query parameter -/
def addQueryOption (url : Url) (key : String) (value : Option String) : Url :=
  { url with query := url.query.addOption key value }

/-- Add a Nat query parameter -/
def addQueryNat (url : Url) (key : String) (value : Nat) : Url :=
  { url with query := url.query.addNat key value }

/-- Add an optional Nat query parameter -/
def addQueryNatOption (url : Url) (key : String) (value : Option Nat) : Url :=
  { url with query := url.query.addNatOption key value }

/-- Add a Bool query parameter -/
def addQueryBool (url : Url) (key : String) (value : Bool) : Url :=
  { url with query := url.query.addBool key value }

/-- Add an optional Bool query parameter -/
def addQueryBoolOption (url : Url) (key : String) (value : Option Bool) : Url :=
  { url with query := url.query.addBoolOption key value }

/-- Set the fragment -/
def withFragment (url : Url) (fragment : String) : Url :=
  { url with fragment := some fragment }

/-- Convert URL to string representation -/
def toString (url : Url) : String :=
  let schemeStr := s!"{url.scheme}://"
  let hostStr := url.host
  let portStr := match url.port with
    | some p =>
      -- Only include port if it's not the default for the scheme
      if p != url.scheme.defaultPort then s!":{p}" else ""
    | none => ""
  let pathStr := url.path
  let queryStr := url.query.toString
  let fragmentStr := match url.fragment with
    | some f => s!"#{f}"
    | none => ""
  schemeStr ++ hostStr ++ portStr ++ pathStr ++ queryStr ++ fragmentStr

instance : ToString Url where
  toString := Url.toString

/-- Coercion from Url to String for seamless use -/
instance : Coe Url String where
  coe := Url.toString

end Url

/-- Typeclass for types that can be used as URLs -/
class ToUrlString (α : Type) where
  toUrlString : α → String

instance : ToUrlString String where
  toUrlString := id

instance : ToUrlString Url where
  toUrlString := Url.toString

namespace Url

/-- Check if URL has a custom port -/
def hasCustomPort (url : Url) : Bool :=
  match url.port with
  | some p => p != url.scheme.defaultPort
  | none => false

/-- Get the effective port (explicit or default) -/
def effectivePort (url : Url) : Nat :=
  url.port.getD url.scheme.defaultPort

/-- Check if URL is secure (HTTPS or WSS) -/
def isSecure (url : Url) : Bool :=
  url.scheme.isSecure

/-- Parse a URL from a string. Returns none if parsing fails. -/
def parse? (s : String) : Option Url := do
  -- Find scheme separator
  let schemeEnd ← s.toList.findIdx? (· == ':')
  let schemeStr := (s.toList.take schemeEnd)|> String.ofList
  let scheme ← Scheme.fromString? schemeStr

  -- Check for :// after scheme
  let rest := (s.toList.drop (schemeEnd + 1))|> String.ofList
  if !rest.startsWith "//" then
    none
  else
    let afterScheme := (rest.toList.drop 2)|> String.ofList

    -- Split off fragment first
    let (beforeFragment, fragment) :=
      match afterScheme.toList.findIdx? (· == '#') with
      | some idx => ((afterScheme.toList.take idx)|> String.ofList,
                     some ((afterScheme.toList.drop (idx + 1))|> String.ofList))
      | none => (afterScheme, none)

    -- Split off query
    let (beforeQuery, queryStr) :=
      match beforeFragment.toList.findIdx? (· == '?') with
      | some idx => ((beforeFragment.toList.take idx)|> String.ofList,
                     some ((beforeFragment.toList.drop (idx + 1))|> String.ofList))
      | none => (beforeFragment, none)

    -- Split host:port from path
    let (hostPort, path) :=
      match beforeQuery.toList.findIdx? (· == '/') with
      | some idx => ((beforeQuery.toList.take idx)|> String.ofList,
                     (beforeQuery.toList.drop idx)|> String.ofList)
      | none => (beforeQuery, "")

    -- Parse host and optional port
    let (host, port) :=
      -- Check for IPv6 address in brackets
      if hostPort.startsWith "[" then
        match hostPort.toList.findIdx? (· == ']') with
        | some bracketEnd =>
          let ipv6Host := (hostPort.toList.take (bracketEnd + 1))|> String.ofList
          let afterBracket := (hostPort.toList.drop (bracketEnd + 1))|> String.ofList
          if afterBracket.startsWith ":" then
            (ipv6Host, ((afterBracket.toList.drop 1) |> String.ofList).toNat?)
          else
            (ipv6Host, none)
        | none => (hostPort, none)
      else
        match hostPort.toList.reverse.findIdx? (· == ':') with
        | some revColonIdx =>
          let colonIdx := hostPort.length - revColonIdx - 1
          let potentialPort := (hostPort.toList.drop (colonIdx + 1))|> String.ofList
          match potentialPort.toNat? with
          | some p => ((hostPort.toList.take colonIdx)|> String.ofList, some p)
          | none => (hostPort, none)
        | none => (hostPort, none)

    -- Parse query parameters
    let query := match queryStr with
      | some qs => parseQueryString qs
      | none => QueryParams.empty

    pure { scheme, host, port, path, query, fragment }

where
  /-- Parse query string into QueryParams -/
  parseQueryString (qs : String) : QueryParams :=
    let pairs := qs.splitOn "&"
    let params := pairs.filterMap fun pair =>
      match pair.splitOn "=" with
      | [key, value] => some (key, value)
      | [key] => some (key, "")
      | _ => none
    ⟨params.toArray⟩

/-- Parse a URL, returning a default on failure -/
def parse (s : String) (default : Url := Url.https "localhost") : Url :=
  (parse? s).getD default

/-- Check if a string looks like a full URL (has scheme) -/
def isFullUrl (s : String) : Bool :=
  s.startsWith "http://" || s.startsWith "https://" ||
  s.startsWith "ws://" || s.startsWith "wss://"

end Url

/-- Create a Url from a base URL string and append a path -/
def mkUrl (baseUrl : String) (path : String := "") : Url :=
  match Url.parse? baseUrl with
  | some url => url.appendPath path
  | none => Url.https baseUrl path

end Curl
