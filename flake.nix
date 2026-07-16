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
      version = "1.0.0-beta.1";
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
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              zig
              zls
              pkg-config
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux [
              alsa-lib
              libGL
              pipewire
              libx11
              libxcursor
              libxi
              libxinerama
              libxrandr
            ];
        };
      });

      packages = forAllSystems (pkgs: {
        neutral-terminal = neutralTerminal pkgs;

        gui = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio-gui";
          inherit version;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-J4QVx6y7XZiAkMK/NHdbhuU1wVxuZnjz12My8v49kfs=";
          };
          nativeBuildInputs = [ pkgs.zig.hook ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.alsa-lib
            pkgs.libGL
            pkgs.libx11
            pkgs.libxcursor
            pkgs.libxi
            pkgs.libxinerama
            pkgs.libxrandr
          ];
          postConfigure = ''
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
          buildPhase = ''
            runHook preBuild
            zig build gui-install -Dcpu=baseline --release=safe --prefix "$out"
            runHook postBuild
          '';
          installPhase = "true";
        });

        gui-windows = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "wstudio-gui-windows";
          inherit version;
          src = self;
          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-J4QVx6y7XZiAkMK/NHdbhuU1wVxuZnjz12My8v49kfs=";
          };
          nativeBuildInputs = [ pkgs.zig.hook ];
          postConfigure = ''
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
          buildPhase = ''
            runHook preBuild
            zig build gui-install -Dtarget=x86_64-windows-gnu -Dcpu=baseline --release=safe --prefix "$out"
            runHook postBuild
          '';
          installPhase = "true";
        });

        default = pkgs.stdenv.mkDerivation {
          pname = "wstudio";
          inherit version;
          src = self;
          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.pkg-config
          ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.alsa-lib
            pkgs.libGL
            pkgs.libx11
            pkgs.libxcursor
            pkgs.libxi
            pkgs.libxinerama
            pkgs.libxrandr
          ];
        };

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
            hash = "sha256-J4QVx6y7XZiAkMK/NHdbhuU1wVxuZnjz12My8v49kfs=";
          };
          nativeBuildInputs = [ pkgs.zig.hook ];
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
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
