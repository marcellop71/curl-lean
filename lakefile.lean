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

target curl_shim_o pkg : FilePath := do
  let srcFile := pkg.dir / "curl" / "curl_shim.c"
  let oFile   := pkg.buildDir / "c" / "curl_shim.o"
  IO.FS.createDirAll oFile.parent.get!
  let curlInclude ← IO.getEnv "CURL_INCLUDE_DIR"
  let curlIncludeDir := curlInclude.getD "/usr/local/include"
  let flags := #["-fPIC", "-O2", "-I", (← getLeanIncludeDir).toString, "-I", curlIncludeDir]
  compileO oFile srcFile flags
  return .pure oFile

extern_lib libcurl_shim pkg := do
  let shimObj ← curl_shim_o.fetch
  let name := nameToStaticLib "curl_shim"
  buildStaticLib (pkg.staticLibDir / name) #[shimObj]

require LSpec from git
  "https://github.com/argumentcomputer/LSpec.git" @ "main"

require zlogLean from git
  "git@github.com:marcellop71/zlog-lean.git" @ "main"
