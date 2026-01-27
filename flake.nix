{
  description = "curl-lean - Lean 4 bindings for libcurl with WebSocket support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zlog-lean.url = "github:marcellop71/zlog-lean";
  };

  outputs = { self, nixpkgs, flake-utils, zlog-lean }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Platform-specific Lean 4 binary
        leanVersion = "4.27.0";
        leanPlatform = if pkgs.stdenv.isDarwin then "darwin" else "linux";
        leanArch = if pkgs.stdenv.isDarwin then "darwin" else "linux";
        leanSha256 = if pkgs.stdenv.isDarwin
          then "sha256-5MpUHYaIHDVJfLbmwaITWPA6Syz7Lo1OFOWNwqCoBa4="
          else "sha256-BW4tyFZPwGSoAeafPrGMBEubVGvIsOWiwAJH+KHLjOY=";

        lean4Bin = pkgs.stdenv.mkDerivation {
          pname = "lean4";
          version = leanVersion;
          src = pkgs.fetchurl {
            url = "https://github.com/leanprover/lean4/releases/download/v${leanVersion}/lean-${leanVersion}-${leanPlatform}.tar.zst";
            sha256 = leanSha256;
          };
          nativeBuildInputs = [ pkgs.zstd ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.autoPatchelfHook ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
          unpackPhase = ''
            tar --zstd -xf $src
          '';
          installPhase = ''
            mkdir -p $out
            cp -r lean-${leanVersion}-${leanArch}/* $out/
          '';
        };

        # Library path variable name (different on Darwin vs Linux)
        libPathVar = if pkgs.stdenv.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
        leanBin = lean4Bin;
        lakeBin = lean4Bin;
        zlogDeps = zlog-lean.lib.${system};

        # Native dependencies for building
        nativeDeps = [
          zlogDeps.zlog
          pkgs.curl
          pkgs.gmp
        ];

        # Development shell with all dependencies
        devShell = pkgs.mkShell {
          buildInputs = nativeDeps ++ [
            leanBin
            lakeBin
            pkgs.clang
            pkgs.lld
          ];

          "${libPathVar}" = pkgs.lib.makeLibraryPath nativeDeps;
          LIBRARY_PATH = pkgs.lib.makeLibraryPath nativeDeps;
          C_INCLUDE_PATH = pkgs.lib.makeSearchPath "include" [ zlogDeps.zlog pkgs.curl.dev ];
          CURL_INCLUDE_DIR = "${pkgs.curl.dev}/include";

          shellHook = ''
            echo "curl-lean development environment"
            echo "Lean version: $(lean --version 2>/dev/null || echo 'Lean not found')"
            echo "libcurl available at: ${pkgs.curl}"
          '';
        };

        # Build the Lean package
        curlLeanPackage = pkgs.stdenv.mkDerivation {
          pname = "curl-lean";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ leanBin lakeBin pkgs.clang pkgs.lld pkgs.makeWrapper ];
          buildInputs = nativeDeps ++ [ zlogDeps.zlogLeanPackage ];

          patchPhase = ''
            # Remove require statements from lakefile.lean for Nix build
            # Dependencies are provided via LEAN_PATH instead
            sed -i '/^require LSpec from git/,+1d' lakefile.lean
          '';

          configurePhase = ''
            export HOME=$TMPDIR

            # Set LEAN_PATH to include dependencies
            export LEAN_PATH="${zlogDeps.zlogLeanPackage}/lib/lean:$LEAN_PATH"
          '';

          buildPhase = ''
            # Set up library paths for FFI compilation
            export ${libPathVar}="${pkgs.lib.makeLibraryPath nativeDeps}"
            export LIBRARY_PATH="${pkgs.lib.makeLibraryPath nativeDeps}"
            export C_INCLUDE_PATH="${pkgs.lib.makeSearchPath "include" [ zlogDeps.zlog pkgs.curl.dev ]}"
            export CURL_INCLUDE_DIR="${pkgs.curl.dev}/include"
            export LEAN_PATH="${zlogDeps.zlogLeanPackage}/lib/lean:$LEAN_PATH"

            # Build the package
            ZLOG_LEAN_DIR="$TMPDIR/zlog-lean"
            cp -r "${zlog-lean}" "$ZLOG_LEAN_DIR"
            chmod -R u+w "$ZLOG_LEAN_DIR"
            cat > $TMPDIR/lake-packages.json <<EOF
            {
              "version": "1.1.0",
              "packages": [
                {
                  "type": "path",
                  "scope": "",
                  "name": "zlogLean",
                  "manifestFile": "lake-manifest.json",
                  "inherited": false,
                  "dir": "$ZLOG_LEAN_DIR",
                  "configFile": "lakefile.lean"
                }
              ]
            }
            EOF
            lake build --packages $TMPDIR/lake-packages.json
          '';

          installPhase = ''
            mkdir -p $out/bin $out/lib

            # Copy executables if they exist
            if [ -d .lake/build/bin ]; then
              for bin in .lake/build/bin/*; do
                if [ -f "$bin" ]; then
                  cp "$bin" $out/bin/
                  wrapProgram "$out/bin/$(basename "$bin")" \
                    --prefix ${libPathVar} : "${pkgs.lib.makeLibraryPath nativeDeps}"
                fi
              done
            fi

            # Copy libraries
            if [ -d .lake/build/lib ]; then
              cp -r .lake/build/lib/* $out/lib/
            fi

            # Copy Lake package metadata for downstream consumers
            mkdir -p $out/share/lean
            cp -r .lake/build/ir $out/share/lean/ || true
            cp lakefile.lean $out/share/lean/
            cp lean-toolchain $out/share/lean/
          '';
        };

      in {
        devShells.default = devShell;

        packages.default = curlLeanPackage;

        lib = {
          inherit nativeDeps curlLeanPackage;
          curl = pkgs.curl;
        };
      }
    );
}
