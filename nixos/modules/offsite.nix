# The offsite copy (ADR 0007): the Borg repository of the 2 TB disk, copied to Proton Drive by the official CLI. Off by default: tidepool.offsite.proton.enable.
# This is an exception to P1 (docs/exceptions.md, entry 3): no module copies a Borg repository to Proton Drive. What is custom is small: the sync script below, and the way the CLI is run.
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool.offsite.proton;
  stateDir = "/var/lib/proton-offsite";
  # The official CLI, pinned by the SHA-512 that Proton publishes (https://proton.me/download/drive/cli/index.html). It is one executable with its payload inside (patchelf would break it),
  # so it is run in an FHS environment instead of being patched. A new version is a new URL and hash, and lab/proton-offsite/ is the test to run before the change.
  cli = pkgs.stdenvNoCC.mkDerivation {
    pname = "proton-drive-cli"; version = "0.9.0";
    src = pkgs.fetchurl { url = "https://proton.me/download/drive/cli/0.9.0/linux-x64/proton-drive"; sha512 = "3533025ba69ae112b64e3e01fbcc1ad0688136a4043f6cf6a72886967d85fdcd9ec235479c2e113171614be5225bfba93427509a05ca5aa6071d924fa7e91ca8"; };
    dontUnpack = true; dontStrip = true; dontPatchELF = true; dontFixup = true;
    installPhase = "install -D -m755 $src $out/bin/proton-drive";
  };
  # The CLI refuses to run without a Secret Service ("libsecret not available"): a throwaway D-Bus session and a keyring unlocked with the sops secret, around each command. The session
  # of the login is the keyring file in the state directory, so every command, a reboot included, finds it. (`auth logout` removes the local credentials only: the session stays valid at Proton.)
  inner = pkgs.writeShellScript "proton-offsite-cli-inner" ''
    export HOME=${stateDir} XDG_DATA_HOME=${stateDir}/.local/share XDG_CACHE_HOME=${stateDir}/.cache XDG_STATE_HOME=${stateDir}/.local/state
    mkdir -p "$XDG_DATA_HOME/keyrings"
    exec ${pkgs.dbus}/bin/dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- ${pkgs.writeShellScript "proton-offsite-cli-session" ''
      ${pkgs.coreutils}/bin/tr -d '\n' < ${config.sops.secrets.proton-keyring-password.path} | ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --unlock --daemonize --components=secrets > /dev/null
      exec ${cli}/bin/proton-drive "$@"
    ''} "$@"
  '';
  fhs = pkgs.buildFHSEnv { name = "proton-offsite-cli"; targetPkgs = p: [ p.libsecret p.glib ]; runScript = inner; };
  sync = pkgs.writeShellApplication {
    name = "proton-offsite-sync";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq pkgs.borgbackup fhs ];
    text = ''
      repo=${lib.escapeShellArg cfg.repository}; parent=${lib.escapeShellArg cfg.remotePath}; remote="$parent/$(basename "$repo")"
      pd() { proton-offsite-cli "$@"; }
      remote_files() { local dir=$1 rel=$2 type name; while IFS=$'\t' read -r type name; do
          if [ "$type" = folder ]; then remote_files "$dir/$name" "$rel$name/"; else echo "$rel$name"; fi
        done < <(pd filesystem list -j "$dir" | jq -r '.[] | [.type, .name.value] | @tsv'); }
      if [ "''${1:-}" != --copy ]; then
        # the copy runs with the repository locked, so that a backup cannot write into it halfway: Borg's own jobs wait their turn
        exec borg --lock-wait ${toString (12 * 3600)} with-lock "$repo" "$0" --copy
      fi
      pd filesystem info "$parent" > /dev/null 2>&1 || pd filesystem create-folder "$(dirname "$parent")" "$(basename "$parent")"
      # what is new or changed goes up (a new revision; identical content is skipped); what the repository no longer has is moved to the trash (the CLI deletes for good only from the trash,
      # and the trash is the whole account's: nothing here ever empties it)
      pd filesystem upload -f create-new-revision -d merge "$repo" "$parent"
      mapfile -t gone < <(comm -13 <(cd "$repo" && find . -type f | sed 's|^\./||' | sort) <(remote_files "$remote" "" | sort))
      for f in "''${gone[@]}"; do [ -n "$f" ] || continue; echo "trash remote: $f"; pd filesystem trash "$remote/$f" > /dev/null; done
      echo "synced; ''${#gone[@]} stale remote file(s) trashed"
    '';
  };
in
{
  options.tidepool.offsite.proton = {
    enable = lib.mkEnableOption "the copy of the offsite Borg repository to Proton Drive (ADR 0007)";
    repository = lib.mkOption { type = lib.types.str; default = "/mnt/big2tb/borg-offsite"; description = "The Borg repository to copy: the one of the offsite job (backup.nix)."; };
    remotePath = lib.mkOption { type = lib.types.str; default = "/my-files/tidepool"; description = "The folder of Proton Drive that holds the copy (one level under a folder that exists, such as /my-files); the repository's own folder is made inside it."; };
    startAt = lib.mkOption { type = lib.types.str; default = "*-*-* 04:50:00"; description = "When the copy runs (a systemd calendar expression). It waits for Borg's own jobs and for the weekly check."; };
  };
  config = lib.mkIf cfg.enable {
    sops.secrets.proton-keyring-password = { };   # the password of the keyring that holds the CLI's session: a long random line
    environment.systemPackages = [ fhs ];       # `sudo proton-offsite-cli auth login` once, and again when the session lapses
    systemd.services.proton-offsite-sync = {
      description = "Copy the offsite Borg repository to Proton Drive";
      after = [ "network-online.target" ]; wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.repository ];
      environment.BORG_PASSCOMMAND = "cat ${config.sops.secrets.borg-passphrase.path}";
      serviceConfig = {
        Type = "oneshot"; ExecStart = "${sync}/bin/proton-offsite-sync";
        StateDirectory = "proton-offsite"; StateDirectoryMode = "0700";
        TimeoutStartSec = "infinity";   # the first upload is a day or more
        NoNewPrivileges = true; ProtectHome = true;
      };
    };
    systemd.timers.proton-offsite-sync = { wantedBy = [ "timers.target" ]; timerConfig = { OnCalendar = cfg.startAt; Persistent = true; }; };
  };
}
