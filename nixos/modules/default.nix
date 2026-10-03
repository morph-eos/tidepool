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
    ./versions.nix
    ./push.nix
    ./nas.nix
    ./deploy.nix
    ./renovate.nix
    ./edge.nix
    ./vpn.nix
    ./vms.nix
    ./publish-gate.nix
    ./observability.nix
    ./verify.nix
  ];
}
