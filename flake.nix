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
      version = "1.0.0-beta.10";
      # fetchDeps converts build.zig.zon's source dependencies into Zig's
      # package cache. One hash keeps native, macOS, and Windows builds synced.
      zigDepsHash = "sha256-0GeMYLsWO89SK6f7rw0HxIqkahbSt/8/SeEkI5WVFus=";
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
      # Only the shifting engine, none of the plugin wrappers: those drag in
      # a JDK (which has no mingw build at all) plus libsamplerate, whose
      # mingw build is broken. Its own FFT and resampler are built in.
      windowsPthreads =
        pkgs:
        pkgs.windows.pthreads.overrideAttrs {
          RCFLAGS = "-I${pkgs.windows.mingw_w64_headers}/include";
        };
      rubberband =
        pkgs:
        pkgs.rubberband.overrideAttrs (old: {
          # mingw needs winpthreads named explicitly; the plain `-pthread`
          # meson passes finds nothing and the shared library fails to link.
          buildInputs = pkgs.lib.optional pkgs.stdenv.hostPlatform.isWindows (windowsPthreads pkgs);
          nativeBuildInputs = with pkgs.buildPackages; [
            meson
            ninja
            pkg-config
          ];
          mesonFlags = (old.mesonFlags or [ ]) ++ [
            "-Dfft=builtin"
            "-Dresampler=builtin"
            "-Dvamp=disabled"
            "-Dladspa=disabled"
            "-Dlv2=disabled"
            "-Djni=disabled"
            "-Dcmdline=disabled"
          ];
          # Reduced C-only build also works on Windows Arm64. Upstream
          # nixpkgs metadata has not listed that target yet.
          meta = (old.meta or { }) // {
            platforms = pkgs.lib.platforms.all;
          };
        });
      # Rubber Band's mingw DLL exports its C++ class API as well as the C
      # one, so the import library nixpkgs ships carries C++ runtime symbols
      # that collide with the libc++ zig links for imgui ("lld-link:
      # duplicate symbol: std::bad_alloc::bad_alloc"). This one holds only
      # the `rubberband_*` C entry points, which is all wstudio calls.
      rubberbandCImportLib =
        pkgs:
        pkgs.runCommand "rubberband-c-implib"
          {
            nativeBuildInputs = [ pkgs.stdenv.cc.bintools.bintools ];
          }
          ''
            mkdir -p $out/lib
            {
              echo "LIBRARY librubberband-3.dll"
              echo "EXPORTS"
              ${pkgs.stdenv.cc.targetPrefix}objdump -p ${rubberband pkgs}/bin/librubberband-3.dll \
                | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^rubberband_[A-Za-z0-9_]*$/) print $i }' \
                | sort -u
            } > rubberband-c.def
            ${pkgs.stdenv.cc.targetPrefix}dlltool \
              ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isAarch64 "-m arm64"} \
              -d rubberband-c.def \
              -D librubberband-3.dll \
              -l $out/lib/librubberband-c.dll.a
          '';
      targetLibs =
        pkgs:
        [
          (speexdsp pkgs)
          (rubberband pkgs)
          pkgs.libsndfile
        ]
        ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isWindows (rubberbandCImportLib pkgs)
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isWindows [
          pkgs.flac
          pkgs.libogg
          pkgs.libvorbis
          pkgs.libopus
          pkgs.libmpg123
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
      # Shared by every wstudio derivation below so `nix flake show`, `nix
      # search` and any downstream consumer see the same description and
      # license rather than an unlabelled package.
      wstudioMeta = pkgs: {
        description = "Keyboard-centric digital audio workstation with a vim-modal terminal UI and a native GUI";
        homepage = "https://github.com/zexk/wstudio";
        license = pkgs.lib.licenses.gpl3Plus;
        mainProgram = "wstudio";
      };
      wstudioPackage =
        pkgs:
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio";
          inherit version;
          meta = wstudioMeta pkgs;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = zigDepsHash;
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
        # A full stdenv, not stdenvNoCC: the C compiler wrapper is what puts
        # buildInputs on NIX_CFLAGS_COMPILE/NIX_LDFLAGS, which is how zig
        # finds libsndfile and friends.
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio-macos";
          inherit version;
          meta = wstudioMeta pkgs;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = zigDepsHash;
          };
          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.pkg-config
          ];
          buildInputs = cLibs pkgs;
          SDKROOT = sdk.sdkroot;
          postConfigure = ''ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"'';
          zigBuildFlags = [
            "-Dtarget=aarch64-macos"
            "-Dgui=false"
          ];
        });
      windowsPackage =
        pkgs: targetPkgs: target:
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio";
          inherit version;
          meta = wstudioMeta pkgs;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = zigDepsHash;
          };
          nativeBuildInputs = [
            pkgs.zig.hook
            targetPkgs.stdenv.cc.bintools.bintools
          ];
          WSTUDIO_TARGET_PREFIX = targetPrefix targetPkgs;
          postConfigure = ''
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
          zigBuildFlags = [ "-Dtarget=${target}" ];
          postInstall = ''
            queue=$(${targetPkgs.stdenv.cc.targetPrefix}objdump -p "$out/bin/wstudio.exe" \
              | sed -n 's/^[[:space:]]*[Dd][Ll][Ll] [Nn]ame: //p')
            copied=""
            while [ -n "$queue" ]; do
              next=""
              for dll in $queue; do
                case " $copied " in *" $dll "*) continue;; esac
                src="$WSTUDIO_TARGET_PREFIX/bin/$dll"
                [ -f "$src" ] || src="$WSTUDIO_TARGET_PREFIX/bin/lib$dll"
                [ -f "$src" ] || continue
                cp "$src" "$out/bin/$dll"
                copied="$copied $dll"
                next="$next $(${targetPkgs.stdenv.cc.targetPrefix}objdump -p "$src" \
                  | sed -n 's/^[[:space:]]*[Dd][Ll][Ll] [Nn]ame: //p')"
              done
              queue="$next"
            done
            test -f "$out/bin/librubberband-3.dll"
            # Arm64 links libsndfile statically; x64 imports its DLL.
            ${pkgs.lib.optionalString (target == "x86_64-windows-gnu") ''
              test -f "$out/bin/libsndfile-1.dll"
            ''}
          '';
        });
      windowsArm64Pkgs =
        pkgs:
        import
          (pkgs.applyPatches {
            name = "nixpkgs-windows-arm64";
            src = nixpkgs;
            patches = [ ./nix/compiler-rt-windows-atomics.patch ];
          })
          {
            system = pkgs.stdenv.hostPlatform.system;
            crossSystem = pkgs.lib.systems.examples.mingw-ucrt-aarch64;
            config.allowUnsupportedSystem = true;
            crossOverlays = [
              (final: prev: {
                libopus = prev.libopus.override { withIntrinsics = false; };
                libmpg123 = prev.libmpg123.overrideAttrs (old: {
                  configureFlags = (old.configureFlags or [ ]) ++ [
                    "--disable-components"
                    "--enable-libmpg123"
                  ];
                  postInstall = (old.postInstall or "") + ''
                    mkdir -p $man/share/man
                  '';
                });
                libsndfile = prev.libsndfile.overrideAttrs {
                  RCFLAGS = "-I${prev.windows.mingw_w64_headers}/include";
                };
              })
            ];
          };
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
      testPluginBundle =
        pkgs:
        pkgs.buildEnv {
          name = "wstudio-test-plugins";
          paths = with pkgs; [
            chow-tape-model
            lsp-plugins
            odin2
            sfizz-ui
            surge-xt
            uhhyou-plugins
          ];
          pathsToLink = [
            "/lib/clap"
            "/lib/vst3"
          ];
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
              ]
              ++ lib.optional (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64) (
                testPluginBundle pkgs
              );
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
          }
          // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86_64) {
            # Third-party plugin release pass is recorded on x86_64 Linux;
            # some validation plugins are unsupported on aarch64.
            CLAP_PATH = "${testPluginBundle pkgs}/lib/clap";
            VST3_PATH = "${testPluginBundle pkgs}/lib/vst3";
          }
        );
        windows-arm64 = pkgs.mkShell {
          packages = [
            pkgs.zig
            (windowsArm64Pkgs pkgs).stdenv.cc.bintools.bintools
          ];
          WSTUDIO_TARGET_PREFIX = targetPrefix (windowsArm64Pkgs pkgs);
        };
      });

      packages = forAllSystems (pkgs: {
        neutral-terminal = neutralTerminal pkgs;

        default = wstudioPackage pkgs;
        macos = macosPackage pkgs;

        # Cross-compiled with zig's bundled mingw-w64 headers/CRT - no
        # Windows machine or MSVC toolchain needed to build this, only to
        # run it. WASAPI/ole32 come from build.zig's own target-conditional
        # linking, so no extra buildInputs here.
        # Not buildInputs: those set host NIX_CFLAGS. build.zig reads target
        # prefix containing libraries for selected Windows architecture.
        windows = windowsPackage pkgs pkgs.pkgsCross.mingwW64 "x86_64-windows-gnu";
        windows-arm64 = windowsPackage pkgs (windowsArm64Pkgs pkgs) "aarch64-windows-gnu";
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
