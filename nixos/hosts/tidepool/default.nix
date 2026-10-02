# The real machine. Values come from vars/example.nix here; in use, from the private repository (the flake input that replaces it).
{ ... }:
{
  imports = [ ../../vars/example.nix ];
  networking.hostName = "tidepool";
}
