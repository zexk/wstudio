{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.wstudio;
  settingsText = import ./nix/render-settings.nix {
    inherit lib;
    inherit (cfg) settings;
  };
  configText = if cfg.luaConfig != "" then cfg.luaConfig else settingsText;
in
{
  options.programs.wstudio = {
    enable = lib.mkEnableOption "wstudio, a keyboard-centric DAW";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "wstudio.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The wstudio package to install.";
    };
    luaConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = "wstudio.o.default_tempo = 128";
      description = "System-wide Lua configuration for wstudio.";
    };
    settings = lib.mkOption {
      type = lib.types.submodule (import ./nix/settings.nix { inherit lib; });
      default = { };
      description = "wstudio startup preferences. Cannot be used with luaConfig.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.luaConfig == "" || settingsText == "";
        message = "programs.wstudio.luaConfig and programs.wstudio.settings are mutually exclusive";
      }
    ];
    environment.systemPackages = [ cfg.package ];
    environment.etc."xdg/wstudio/init.lua" = lib.mkIf (configText != "") {
      text = configText;
    };
  };
}
