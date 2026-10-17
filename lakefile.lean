import Lake
open System Lake DSL

-- libcurl must be installed on the system
-- libcurl version 7.86.0 or later is required for WebSocket support

package curlLean where
  extraDepTargets := #[`libcurl_shim]
  moreLinkArgs := #[
    "-Wl,--allow-shlib-undefined",
    "-lcurl",
    "-lzlog"
  ]

@[default_target]
lean_lib CurlLean

/-- Regression test for request timeouts against a stalling server:
    `CurlLeanTests/run-timeout-test.sh` (starts the server, runs this).
    Namespaced module (not `Tests.*`) so it cannot clash with a consumer's own tests. -/
lean_exe «timeout-test» where
  root := `CurlLeanTests.Timeout
  moreLinkArgs := #["-L/usr/lib/x86_64-linux-gnu", "-Wl,-rpath,/usr/lib/x86_64-linux-gnu",
    "-L/usr/local/lib", "-Wl,-rpath,/usr/local/lib"]

/-- WebSocket receive regression (whole messages, waiting on the socket):
    `CurlLeanTests/run-ws-test.sh` (starts the server, runs this). -/
lean_exe «ws-test» where
  root := `CurlLeanTests.WSRecv
  moreLinkArgs := #["-L/usr/lib/x86_64-linux-gnu", "-Wl,-rpath,/usr/lib/x86_64-linux-gnu",
    "-L/usr/local/lib", "-Wl,-rpath,/usr/local/lib"]

/-- Compile `src` into `oFile` with a build trace over `src` and `deps` (local headers,
    `#include`d `.c` files), so editing any of them rebuilds the object and the archives
    that use it. `weakArgs` (include paths) are kept out of the trace. -/
def tracedO (oFile src : FilePath) (deps : Array FilePath := #[])
    (weakArgs traceArgs : Array String := #[]) : SpawnM (Job FilePath) := do
  let inputs ← (#[src] ++ deps).mapM inputTextFile
  let srcJob ← (Job.collectArray inputs).mapM fun _ => pure src
  buildO oFile srcJob weakArgs traceArgs

target curl_shim_o pkg : FilePath := do
  let curlDir := pkg.dir / "curl"
  let curlIncludeDir := (← IO.getEnv "CURL_INCLUDE_DIR").getD "/usr/local/include"
  -- curl_shim.c #includes the other two translation units
  tracedO (pkg.buildDir / "c" / "curl_shim.o") (curlDir / "curl_shim.c")
    #[curlDir / "curl_easy_perform.c", curlDir / "curl_ws_connect.c"]
    (weakArgs := #["-I", (← getLeanIncludeDir).toString, "-I", curlIncludeDir])
    (traceArgs := #["-fPIC", "-O2"])

extern_lib libcurl_shim pkg := do
  let shimObj ← curl_shim_o.fetch
  let name := nameToStaticLib "curl_shim"
  buildStaticLib (pkg.staticLibDir / name) #[shimObj]

require LSpec from git
  "https://github.com/argumentcomputer/LSpec.git" @ "main"

require zlogLean from git
  "git@github.com:marcellop71/zlog-lean.git" @ "v4.35.0"
