{
  description = "wstudio - a digital audio workstation written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "1.0.0-beta.9";
      # Built with a static archive as well as the usual shared library, so a
      # downloaded wstudio does not ask the user to install it too. Whatever
      # `pkgs` this is applied to decides the platform, which is how the
      # Windows cross-build below gets a mingw copy.
      speexdsp =
        pkgs:
        pkgs.speexdsp.overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-static" ];
        });
      # What a cross-build can get from nixpkgs. Lua is missing on purpose:
      # nixpkgs will not build it for mingw, so build.zig compiles the source
      # drop from build.zig.zon when cross-compiling.
      #
      # libsndfile's codec libraries are here for their DLLs alone: mingw
      # libsndfile links them dynamically, so the release archive has to carry
      # them next to wstudio.exe.
      targetLibs =
        pkgs:
        [
          (speexdsp pkgs)
          pkgs.libsndfile
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [
          pkgs.flac
          pkgs.libogg
          pkgs.libvorbis
          pkgs.libopus
          pkgs.mpg123
          pkgs.lame
        ];
      cLibs = pkgs: targetLibs pkgs ++ [ pkgs.lua5_4 ];
      # One prefix holding both the headers and the libraries, since build.zig
      # points a cross-compile at a single directory.
      targetPrefix =
        pkgs:
        pkgs.symlinkJoin {
          name = "wstudio-target-prefix";
          # Every code-bearing output, because these packages split themselves
          # up differently: mingw libsndfile puts its DLL in `bin`, its import
          # library in `out` and its headers in `dev`.
          paths = pkgs.lib.concatMap (
            p: map (out: p.${out}) (pkgs.lib.subtractLists [ "man" "doc" "info" ] (p.outputs or [ "out" ]))
          ) (targetLibs pkgs);
        };
      neutralTerminal =
        pkgs:
        pkgs.writeShellApplication {
          name = "wstudio-neutral-terminal";
          runtimeInputs = [ pkgs.kitty ];
          text = ''
            export FONTCONFIG_FILE=${
              pkgs.makeFontsConf {
                fontDirectories = [ pkgs.nerd-fonts.jetbrains-mono ];
              }
            }
            exec kitty --config NONE \\
              --override font_family='JetBrainsMono Nerd Font Mono' \\
              --override font_size=14.0 "$@"
          '';
        };
      wstudioPackage =
        pkgs:
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio";
          inherit version;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-U4HA3J4+mxUbSMWyr6W3JjWa1TthohTYCGJnzZR2qFQ=";
          };
          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.pkg-config
            pkgs.installShellFiles
          ];
          buildInputs =
            cLibs pkgs
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.alsa-lib
              pkgs.libGL
              pkgs.libx11
              pkgs.libxcursor
              pkgs.libxi
              pkgs.libxinerama
              pkgs.libxrandr
            ];
          postConfigure = ''ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"'';
          postInstall = ''
            installManPage docs/wstudio.1
          ''
          + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            install -Dm444 assets/linux/wstudio.desktop \
              "$out/share/applications/wstudio.desktop"
            for size in 16 22 24 32 48 64 128 256 512; do
              install -Dm444 "assets/icon/hicolor/''${size}x''${size}/apps/wstudio.png" \
                "$out/share/icons/hicolor/''${size}x''${size}/apps/wstudio.png"
            done
            install -Dm444 assets/icon/wstudio.png "$out/share/pixmaps/wstudio.png"
            install -Dm444 assets/linux/wstudio-mime.xml \
              "$out/share/mime/packages/wstudio.xml"
          '';
          # GLFW loads every platform library at runtime with dlopen (X11,
          # Wayland, and GL alike), and the PipeWire/JACK audio backends
          # dlopen their libraries the same way, so nothing below shows up
          # as DT_NEEDED and autoPatchelf can't help; put them on the
          # binary's rpath.
          postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            patchelf --add-rpath ${
              pkgs.lib.makeLibraryPath [
                pkgs.libGL
                pkgs.libx11
                pkgs.libxcursor
                pkgs.libxi
                pkgs.libxinerama
                pkgs.libxrandr
                pkgs.wayland
                pkgs.libxkbcommon
                pkgs.libdecor
                pkgs.pipewire
                pkgs.libjack2
              ]
            } $out/bin/wstudio
          '';
        });
      macosPackage =
        pkgs:
        let
          sdkPkgs = import nixpkgs {
            inherit (pkgs.stdenv.hostPlatform) system;
            config.allowUnsupportedSystem = true;
          };
          sdk = sdkPkgs.apple-sdk_14.override { enableBootstrap = true; };
        in
        pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
          pname = "wstudio-macos";
          inherit version;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-U4HA3J4+mxUbSMWyr6W3JjWa1TthohTYCGJnzZR2qFQ=";
          };
          nativeBuildInputs = [ pkgs.zig.hook ];
          SDKROOT = sdk.sdkroot;
          postConfigure = ''ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"'';
          zigBuildFlags = [
            "-Dtarget=aarch64-macos"
            "-Dgui=false"
          ];
        });
      # `-u NONE` (src/main.zig) skips loading any init.lua entirely - built-
      # in defaults only, never touching `~/.config/wstudio/init.lua`. For
      # trying out a stock build (or bisecting "is this a config problem or
      # a wstudio problem") without disturbing a real setup.
      defaultConfigLauncher =
        pkgs:
        pkgs.writeShellApplication {
          name = "wstudio-default-config";
          runtimeInputs = [ (wstudioPackage pkgs) ];
          text = ''exec wstudio -u NONE "$@"'';
        };
    in
    {
      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };
      homeManagerModules.default = import ./nix/home-manager-module.nix { inherit self; };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell (
          {
            packages =
              with pkgs;
              [
                zig
                zls
                pkg-config
              ]
              ++ cLibs pkgs
              ++ lib.optionals stdenv.hostPlatform.isLinux [
                alsa-lib
                libGL
                pipewire
                valgrind
                libx11
                libxcursor
                libxi
                libxinerama
                libxrandr
                odin2
                lsp-plugins
              ];
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            # `zig build -Dtarget=x86_64-macos` on an Apple Silicon runner,
            # which the release workflow does, is a cross build by
            # architecture and needs Intel copies of these libraries.
            WSTUDIO_TARGET_PREFIX = targetPrefix pkgs.pkgsx86_64Darwin;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # `zig build -Dtarget=x86_64-windows-gnu` from this shell, which is
            # what CI does, needs the mingw copies rather than the host ones.
            WSTUDIO_TARGET_PREFIX = targetPrefix pkgs.pkgsCross.mingwW64;
            CLAP_PATH = "${pkgs.odin2}/lib/clap";
            WSTUDIO_TEST_CLAP_PATH = "${pkgs.odin2}/lib/clap";
            WSTUDIO_TEST_VST3_PATH = "${pkgs.lsp-plugins}/lib/vst3";
          }
        );
      });

      packages = forAllSystems (pkgs: {
        neutral-terminal = neutralTerminal pkgs;

        default = wstudioPackage pkgs;
        macos = macosPackage pkgs;

        # Cross-compiled with zig's bundled mingw-w64 headers/CRT - no
        # Windows machine or MSVC toolchain needed to build this, only to
        # run it. WASAPI/ole32 come from build.zig's own target-conditional
        # linking, so no extra buildInputs here.
        windows = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio";
          inherit version;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-U4HA3J4+mxUbSMWyr6W3JjWa1TthohTYCGJnzZR2qFQ=";
          };
          nativeBuildInputs = [ pkgs.zig.hook ];
          # Not buildInputs: those set the host's NIX_CFLAGS, and this build
          # targets Windows. build.zig reads the prefix instead.
          WSTUDIO_TARGET_PREFIX = targetPrefix pkgs.pkgsCross.mingwW64;
          postConfigure = ''
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
          zigBuildFlags = [ "-Dtarget=x86_64-windows-gnu" ];
        });
      });

      apps = forAllSystems (pkgs: {
        neutral-terminal = {
          type = "app";
          program = "${neutralTerminal pkgs}/bin/wstudio-neutral-terminal";
          meta.description = "Launch wstudio in a terminal with a known-good font configuration";
        };
        default-config = {
          type = "app";
          program = "${defaultConfigLauncher pkgs}/bin/wstudio-default-config";
          meta.description = "Launch wstudio with its built-in defaults (-u NONE), never touching ~/.config/wstudio/init.lua";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
