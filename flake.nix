{
  description = "wstudio — a digital audio workstation written in Zig";

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
              # audio backends (linked once the native backends land)
              alsa-lib
              pipewire
            ];
        };
      });

      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "wstudio";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.pkg-config
          ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.alsa-lib ];
        };

        # Cross-compiled with zig's bundled mingw-w64 headers/CRT — no
        # Windows machine or MSVC toolchain needed to build this, only to
        # run it. WASAPI/ole32 come from build.zig's own target-conditional
        # linking, so no extra buildInputs here.
        windows = pkgs.stdenv.mkDerivation {
          pname = "wstudio";
          version = "0.1.0";
          src = self;
          nativeBuildInputs = [ pkgs.zig.hook ];
          zigBuildFlags = [ "-Dtarget=x86_64-windows-gnu" ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
