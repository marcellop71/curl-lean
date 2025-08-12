namespace Curl

inductive HttpMethod where
  | GET
  | POST
  | PUT
  | DELETE
  | PATCH
deriving Repr, BEq, DecidableEq

instance : ToString HttpMethod where
  toString
    | .GET => "GET"
    | .POST => "POST"
    | .PUT => "PUT"
    | .DELETE => "DELETE"
    | .PATCH => "PATCH"

inductive FrameType where
  | ping
  | pong
  | text
  | binary
  | close
  | continuation
deriving Repr, BEq, DecidableEq

instance : ToString FrameType where
  toString
    | .ping => "PING"
    | .pong => "PONG"
    | .text => "TEXT"
    | .binary => "BINARY"
    | .close => "CLOSE"
    | .continuation => "CONTINUATION"

end Curl
