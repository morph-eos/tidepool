# Every module of the host. Each one is switched by the options in options.nix; the lab and the real host differ in values, not in code.
{ ... }:
{
  imports = [
    ./options.nix
    ./base.nix
    ./storage.nix
    ./secrets.nix
    ./database.nix
    ./backup.nix
    ./services.nix
    ./edge.nix
    ./vpn.nix
    ./vms.nix
    ./publish-gate.nix
    ./observability.nix
    ./verify.nix
  ];
}
