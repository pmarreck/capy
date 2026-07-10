{
  description = "capy - Cross-platform Zig GUI library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flake-utils, zig-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };

        inherit (pkgs) lib stdenv;
        zigPkg = pkgs.zigpkgs."0.16.0";
        pname = "capy";
        version = "0.4.1";

        linuxBuildInputs = lib.optionals stdenv.isLinux [
          pkgs.gtk4
          pkgs.glib
          pkgs.cairo
          pkgs.pango
          pkgs.gdk-pixbuf
          pkgs.libGL
          pkgs.libGLU
          pkgs.mesa
          pkgs.alsa-lib
          pkgs.pipewire
        ];

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = ./.;
          nativeBuildInputs = [ zigPkg pkgs.git pkgs.cacert ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-tj5MG+6SJosS2CH/uNNax/RDGwSyYvw6GonM0rWNm1Q=";
          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR="$out"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export GIT_SSL_CAINFO="$SSL_CERT_FILE"
            # Fetch the non-lazy Linux dependency graph. The optional macOS SDK
            # remains lazy so its legacy build script is not evaluated on Linux.
            zig build --fetch
          '';
          dontInstall = true;
          dontFixup = true;
        };

        prepareZigCache = ''
          export HOME="$TMPDIR"
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
          cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
          chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
          unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
        '';

        capyPackage = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ zigPkg pkgs.pkg-config ];
          buildInputs = linuxBuildInputs
            ++ lib.optionals stdenv.isDarwin [ pkgs.apple-sdk pkgs.libiconv ];
          buildPhase = ''
            ${prepareZigCache}
            zig build shared -Doptimize=ReleaseFast -Dcpu=baseline
          '';
          installPhase = ''
            mkdir -p "$out"
            cp -r zig-out/* "$out/"
          '';
        };

        capyTests = pkgs.stdenv.mkDerivation {
          pname = "${pname}-tests";
          inherit version;
          src = ./.;
          nativeBuildInputs = [ zigPkg pkgs.pkg-config ]
            ++ lib.optionals stdenv.isLinux [ pkgs.dbus pkgs.patchelf pkgs.ripgrep pkgs.xvfb-run ];
          buildInputs = linuxBuildInputs
            ++ lib.optionals stdenv.isDarwin [ pkgs.apple-sdk pkgs.libiconv ];
          buildPhase = ''
            ${prepareZigCache}
            ${lib.optionalString stdenv.isLinux ''
              zig build test-compile -Doptimize=ReleaseSafe -Dcpu=baseline --prefix "$TMPDIR/test-out"
              patchelf \
                --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" \
                --set-rpath "${lib.makeLibraryPath linuxBuildInputs}" \
                "$TMPDIR/test-out/bin/test"
              test_output="$TMPDIR/test-output"
              if ! GTK_A11Y=none NO_AT_BRIDGE=1 timeout 600 dbus-run-session \
                --config-file="${pkgs.dbus}/share/dbus-1/session.conf" \
                -- xvfb-run -a "$TMPDIR/test-out/bin/test" >"$test_output" 2>&1; then
                cat "$test_output"
                exit 1
              fi
              if rg -q 'Gtk-(WARNING|CRITICAL)' "$test_output"; then
                cat "$test_output"
                exit 1
              fi
            ''}
            ${lib.optionalString stdenv.isDarwin ''
              timeout 600 zig build test -Doptimize=ReleaseSafe -Dcpu=baseline
            ''}
          '';
          installPhase = ''
            mkdir -p "$out"
            printf 'tests passed\n' > "$out/result"
          '';
        };
      in
      {
        packages.default = capyPackage;

        checks = {
          build = capyPackage;
          test = capyTests;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            zigPkg
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.git
          ]
          ++ linuxBuildInputs
          ++ lib.optionals stdenv.isLinux [
            pkgs.gtk3
            pkgs.android-tools
            pkgs.gdb
            pkgs.valgrind
            pkgs.strace
          ]
          ++ lib.optionals stdenv.isDarwin [
            pkgs.apple-sdk
            pkgs.libiconv
          ];

          shellHook = ''
            unset NIX_CFLAGS_COMPILE
            echo "Capy Development Environment"
            echo "Zig version: $(zig version)"
            echo ""
            echo "Canonical commands: ./build and ./test"
          '' + lib.optionalString stdenv.isLinux ''
            export PKG_CONFIG_PATH="${pkgs.gtk3}/lib/pkgconfig:${pkgs.gtk4}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export LD_LIBRARY_PATH="${lib.makeLibraryPath linuxBuildInputs}:$LD_LIBRARY_PATH"
          '';
        };
      });
}
