namespace Curl

inductive HttpError where
  | networkError (msg : String)
  | httpError (status : UInt32) (body : String)
  | timeout
  | invalidUrl (url : String)
deriving Repr, BEq

instance : ToString HttpError where
  toString
    | .networkError msg => s!"Network error: {msg}"
    | .httpError status body => s!"HTTP {status}: {body}"
    | .timeout => "Request timeout"
    | .invalidUrl url => s!"Invalid URL: {url}"

inductive CurlError where
  | networkError (msg : String)
  | timeout
  | invalidUrl (url : String)
  | initFailed
  | unknownError (msg : String)
  | otherError (msg : String)
deriving Repr, BEq

instance : ToString CurlError where
  toString
    | .networkError msg => s!"Network error: {msg}"
    | .timeout => "Request timeout"
    | .invalidUrl url => s!"Invalid URL: {url}"
    | .initFailed => "Failed to initialize curl"
    | .unknownError msg => s!"Unknown error: {msg}"
    | .otherError msg => s!"connect other error: {msg}"

def CurlError.toHttpError (e : CurlError) : HttpError :=
  match e with
  | .networkError msg => HttpError.networkError msg
  | .timeout => HttpError.timeout
  | .invalidUrl url => HttpError.invalidUrl url
  | .initFailed => HttpError.networkError "Failed to initialize curl"
  | .unknownError msg => HttpError.networkError msg
  | .otherError msg => HttpError.networkError msg

inductive CurlWSError where
  | connectionFailed (msg : String)
  | sendFailed (msg : String)
  | receiveFailed (msg : String)
  | receiveWouldBlock (msg : String)  -- New: for CURLE_AGAIN cases
  | timeout
  | invalidUrl (url : String)
  | initFailed
  | unknownError (msg : String)
deriving Repr, BEq

instance : ToString CurlWSError where
  toString
    | .connectionFailed msg => s!"Connection failed: {msg}"
    | .sendFailed msg => s!"Send failed: {msg}"
    | .receiveFailed msg => s!"Receive failed: {msg}"
    | .receiveWouldBlock msg => s!"Receive would block: {msg}"
    | .timeout => "WebSocket timeout"
    | .invalidUrl url => s!"Invalid WebSocket URL: {url}"
    | .initFailed => "Failed to initialize WebSocket"
    | .unknownError msg => s!"Unknown WebSocket error: {msg}"

inductive WSError where
  | webSocketError (e : CurlWSError)
  | connectionClosed
  | invalidMessage (msg : String)
  | clientError (msg : String)
deriving Repr

instance : ToString WSError where
  toString
    | .webSocketError e => toString e
    | .connectionClosed => "WebSocket connection closed"
    | .invalidMessage msg => s!"Invalid message: {msg}"
    | .clientError msg => s!"Client error: {msg}"

end Curl
