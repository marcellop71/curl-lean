import CurlLean.WSClient

/-!
Regression test: WebSocket receive returns whole messages and waits on the socket.

Run with `CurlLeanTests/run-ws-test.sh`, which starts `CurlLeanTests/ws_server.py`.
Until 2026-10 a receive returned one `curl_ws_recv` read (at most 4096 bytes) as a
frame: messages larger than that, or whose bytes had not all arrived, came back split
into broken pieces, and an empty socket meant sleeping 100 ms before retrying.
-/

open Curl.WS

def large : String := String.ofList ((List.range 200000).map fun i => Char.ofNat ('0'.toNat + i % 10))
def split : String := String.ofList (List.replicate 500 'S') ++ "|" ++ String.ofList (List.replicate 500 'T')

/-- Case name, expected message (`none`: nothing should arrive), and the allowed
    elapsed time in ms -/
def cases : List (String × Option String × Nat × Nat) :=
  [ ("small", some "hello", 0, 1000),
    ("large", some large, 0, 2000),
    ("split", some split, 250, 2000),
    ("header-split", some split, 150, 2000),
    ("unicode", some "héllo € 日本 ✓", 150, 2000),
    ("fragmented", some "part1-part2-part3", 100, 2000),
    -- woken by the data, not by a retry tick: well under the old 100 ms sleep granularity
    ("delayed", some "late", 40, 90),
    ("quiet", none, 280, 1000) ]

def check (conn : WSConnection) (name : String) (expected : Option String) (lo hi : Nat) : WSM Bool := do
  conn.sendText s!"case {name}"
  let t0 ← liftM IO.monoMsNow
  let waitMs : UInt32 := if expected.isNone then 300 else 5000
  let got ← conn.receiveTimeout waitMs
  let dt := (← liftM IO.monoMsNow) - t0
  let gotData := got.map (·.data)
  let ok := gotData == expected && lo ≤ dt && dt ≤ hi
  let shown := match gotData with
    | none => "nothing"
    | some d => if d.length > 40 then s!"{d.length} chars" else s!"{repr d}"
  liftM <| IO.println s!"  {if ok then "✓" else "✗"} {name}: {shown} after {dt} ms"
  pure ok

/-- 1000 back-to-back messages: each receive returns exactly one, in order -/
def checkBurst (conn : WSConnection) : WSM Bool := do
  conn.sendText "case burst"
  let mut ok := true
  for i in [:1000] do
    match ← conn.receiveTimeout 5000 with
    | some f => if f.data != s!"m{i}" then ok := false
    | none => ok := false
  liftM <| IO.println s!"  {if ok then "✓" else "✗"} burst: 1000 messages in order"
  pure ok

def main (args : List String) : IO UInt32 := do
  let url := args.headD "ws://127.0.0.1:18081/"
  IO.println s!"WebSocket receive regression against {url}"
  let r ← runWS do
    let conn ← connect url
    let mut allOk := true
    for (name, expected, lo, hi) in cases do
      allOk := (← check conn name expected lo hi) && allOk
    allOk := (← checkBurst conn) && allOk
    conn.close
    pure allOk
  match r with
  | .ok true => IO.println "All receive checks passed."; return 0
  | .ok false => IO.println "Receive checks FAILED."; return 1
  | .error e => IO.println s!"Receive test error: {e}"; return 1
