# Deploys (ADR 0018): the SERVER pulls and applies what has been merged, through the NixOS module `system.autoUpgrade` (a timer that runs `nixos-rebuild switch` against the flake).
# Before a change is activated, every backup method runs (system.preSwitchChecks); if one fails the change is NOT activated. Off by default: tidepool.deploy.enable.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool.deploy;
  systemctl = "${config.systemd.package}/bin/systemctl";
  readlink = "${pkgs.coreutils}/bin/readlink";
  sleep = "${pkgs.coreutils}/bin/sleep";
  # the pre-switch script runs with an almost empty PATH: every command is called by its full path (a first version used a bare `readlink`, the check silently found nothing to do, and the
  # change was activated WITHOUT its backups); and it is fail-closed: any unexpected error stops the switch (set -e) instead of skipping the backups
  # a unit that is not a oneshot (the Borg jobs) returns from `start` at once: wait for it to leave the active state, then read its result
  run = unit: ''
    echo "pre-switch backup: ${unit}"
    ${systemctl} start --no-block ${unit}
    ${sleep} 2
    while [ "$(${systemctl} show ${unit} -p ActiveState --value)" = activating ] || [ "$(${systemctl} show ${unit} -p ActiveState --value)" = active ]; do ${sleep} 3; done
    [ "$(${systemctl} show ${unit} -p Result --value)" = success ] || { echo "pre-switch backup FAILED: ${unit}; the new configuration is not activated" >&2; exit 1; }
  '';
in
{
  options.tidepool.deploy = {
    enable = lib.mkEnableOption "the server pulls the flake and applies what changed";
    flake = lib.mkOption { type = lib.types.str; description = "The flake to apply, with the host: the private repository, e.g. git+ssh://git@github.com/OWNER/REPO.git#tidepool (a private value)."; };
    inputs = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; description = "Inputs replaced on every run by the newest commit of their repository, as name = url: the public repository, so that a merge there is a deploy. (`--update-input` does the same but is deprecated.)"; };
    privateRepo = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { options = {
        host = lib.mkOption { type = lib.types.str; default = "github.com"; };
        hostKey = lib.mkOption { type = lib.types.str; default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"; description = "The host's public key, pinned (GitHub's ed25519 key, from https://api.github.com/meta): a different key is refused."; };
      }; });
      default = null;
      description = "Set when the flake is a PRIVATE repository read over ssh: the deploy key (the sops secret `deploy-key`, a read-only key of that one repository) is used for that host, whose key is pinned.";
    };
    interval = lib.mkOption { type = lib.types.str; default = "*:0/10"; description = "How often the server looks (a systemd calendar expression)."; };
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [ {
    environment.systemPackages = [ pkgs.git ];   # the flake is fetched from git repositories; the owner will look at them from a shell
    system.autoUpgrade = {
      enable = true;
      operation = "switch";
      flake = cfg.flake;
      flags = [ "--refresh" "--no-write-lock-file" ] ++ lib.concatLists (lib.mapAttrsToList (name: url: [ "--override-input" name url ]) cfg.inputs);
      dates = cfg.interval;
      randomizedDelaySec = "0";
      allowReboot = false;   # a new kernel waits for the owner's reboot (the disk is unlocked by the TPM)
    };
    # only when the incoming system differs from the running one (the timer runs often; nothing changes most times) and the backup units exist (not at an installation)
    system.preSwitchChecks.backupsFirst = ''
      set -eu
      incoming="''${1-}"; action="''${2-}"
      if [ "$action" = switch ] || [ "$action" = boot ]; then
        running="$(${readlink} -f /run/current-system)"
        if [ "$running" != "$(${readlink} -f "$incoming")" ] && ${systemctl} cat borgbackup-job-everything.service >/dev/null 2>&1; then
          ${run "borgbackup-job-everything.service"}
          ${run "borgbackup-job-offsite.service"}
          ${run "pgbackrest-default-daily.service"}
        fi
      fi
    '';
  } (lib.mkIf (cfg.privateRepo != null) {
    sops.secrets.deploy-key = { mode = "0400"; owner = "root"; };
    programs.ssh.knownHosts.${cfg.privateRepo.host}.publicKey = cfg.privateRepo.hostKey;
    programs.ssh.extraConfig = ''
      Host ${cfg.privateRepo.host}
        IdentityFile ${config.sops.secrets.deploy-key.path}
        IdentitiesOnly yes
        StrictHostKeyChecking yes
    '';
  }) ]);
}
