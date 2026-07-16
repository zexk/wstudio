{ lib, settings }:
let
  luaValue =
    value:
    if builtins.isBool value then
      lib.boolToString value
    else if builtins.isString value then
      ''"${lib.escape [ "\\" "\"" ] value}"''
    else
      toString value;
in
lib.concatStringsSep "\n" (
  lib.mapAttrsToList (name: value: "wstudio.o.${name} = ${luaValue value}") (
    lib.filterAttrs (_: value: value != null) settings
  )
)
