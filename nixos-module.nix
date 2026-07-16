{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.wstudio;
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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    environment.etc."xdg/wstudio/init.lua" = lib.mkIf (cfg.luaConfig != "") {
      text = cfg.luaConfig;
    };
  };
}
