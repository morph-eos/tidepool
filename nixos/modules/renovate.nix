# Renovate on the server (ADR 0018): once a week it opens pull requests on the PUBLIC repository (container pins, Actions' commits, flake.lock), through the NixOS module `services.renovate`.
# The token belongs to a MACHINE USER (a second GitHub account with the write role, not admin), so the protections of the public `main` hold: the bot cannot approve or bypass.
# Off by default: tidepool.renovate.enable.
{ config, lib, pkgs, ... }:
let cfg = config.tidepool.renovate; in
{
  options.tidepool.renovate = {
    enable = lib.mkEnableOption "Renovate on the server";
    repositories = lib.mkOption { type = lib.types.listOf lib.types.str; description = "The repositories to keep up to date, OWNER/NAME (a private value)."; };
    schedule = lib.mkOption { type = lib.types.str; default = "Mon *-*-* 04:30:00"; description = "When it runs (renovate.json says the pull requests are opened before 06:00 on Monday)."; };
  };
  config = lib.mkIf cfg.enable {
    sops.secrets.renovate-token = { };   # the machine user's fine-grained token: contents and pull requests (write) on the public repository only; it EXPIRES, and then the unit fails
    services.renovate = {
      enable = true;
      schedule = cfg.schedule;
      credentials.RENOVATE_TOKEN = config.sops.secrets.renovate-token.path;
      runtimePackages = [ pkgs.nix pkgs.git ];   # `nix flake update` refreshes flake.lock; the stock Renovate has no Nix
      settings = {
        platform = "github";
        repositories = cfg.repositories;
        onboarding = false;
        requireConfig = "required";   # the repository's own renovate.json is the configuration
        autodiscover = false;
        gitAuthor = "tidepool renovate <renovate@users.noreply.github.com>";
      };
    };
  };
}
