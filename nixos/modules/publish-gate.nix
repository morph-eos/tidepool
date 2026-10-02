# The publication gate (ADR 0013): a connection that a container engine or Incus has address-translated (a published port) is dropped unless its original port is listed here.
# NixOS's firewall, with forward filtering on, accepts every translated connection ("allow port forward"); this table runs first and makes the list the only way to be public.
{ config, lib, ... }:
let
  cfg = config.tidepool.publishGate;
  ports = lib.concatMapStringsSep ", " toString cfg.allowedPorts;
in
{
  options.tidepool.publishGate.allowedPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    description = "Ports that may be reached from outside through a published (address-translated) connection.";
  };
  config.networking.nftables.tables.publish-gate = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter - 10; policy accept;
        ct status dnat ${lib.optionalString (cfg.allowedPorts != [ ]) "ct original proto-dst != { ${ports} }"} drop
      }
    '';
  };
}
