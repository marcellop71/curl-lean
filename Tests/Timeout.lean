import CurlLean.HttpFFI

/-!
Regression test: request timeouts must fire when the server stops answering.

Run with `Tests/run-timeout-test.sh`, which starts `Tests/stall_server.py`
(paths `/silent`: never answers, `/midbody`: stalls after part of the body,
`/ok`: normal response). Until 2026-10, `CURLOPT_CONNECT_ONLY` on HTTP
transfers disabled the timeout and both stall cases hung forever.
-/

open Curl.Http

def timeoutMs : UInt32 := 2000

/-- One POST; returns (elapsed ms, result) -/
def post (url : String) : IO (Nat × Except Curl.CurlError Response) := do
  let t0 ← IO.monoMsNow
  let r ← FFI.curl_easy_perform (method := .POST) (url := url) (body := "{}")
    (headers := #[("Content-Type", "application/json")]) (timeoutMs := timeoutMs)
  return ((← IO.monoMsNow) - t0, r)

/-- Check one case; prints the outcome and returns whether it passed -/
def check (base path : String) (onTask : Bool) : IO Bool := do
  let label := s!"{path}{if onTask then " (worker task)" else ""}"
  let (dt, r) ← if onTask then
      IO.ofExcept =<< IO.wait (← IO.asTask (prio := .dedicated) (post (base ++ path)))
    else post (base ++ path)
  let ok := match path, r with
    | "/ok", .ok resp => resp.status == 200
    | "/ok", .error _ => false
    | _, .error .timeout => dt ≥ timeoutMs.toNat - 100 && dt ≤ timeoutMs.toNat + 3000
    | _, _ => false
  let shown := match r with
    | .ok resp => s!"status {resp.status}"
    | .error e => s!"{repr e}"
  IO.println s!"  {if ok then "✓" else "✗"} {label}: {shown} after {dt} ms"
  (← IO.getStdout).flush
  return ok

def main (args : List String) : IO UInt32 := do
  let base := args.headD "http://127.0.0.1:18080"
  IO.println s!"Timeout regression ({timeoutMs} ms) against {base}"
  let mut allOk := true
  for path in ["/ok", "/silent", "/midbody"] do
    for onTask in [false, true] do
      allOk := (← check base path onTask) && allOk
  IO.println (if allOk then "All timeout checks passed." else "Timeout checks FAILED.")
  return if allOk then 0 else 1
