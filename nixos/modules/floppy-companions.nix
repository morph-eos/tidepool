# Two small companions of Floppy (docs/decisions/0023-floppy.md): the accounts that Nextcloud's list of people implies, and the yearly recap by mail. Both read Floppy through the loopback and its database socket, as root (database.nix maps root to the role `floppy`).
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  fl = cfg.services.floppy;
  pg = config.services.postgresql.package;
  occ = "${config.services.nextcloud.occ}/bin/nextcloud-occ";
  port = "8100";   # floppy.nix: the image's own nginx
in
{
  config = lib.mkIf fl.enable {
    # Nextcloud is the list of people: every enabled user has a Floppy account (and the link to their sign-in) without having to sign in first, new users included.
    systemd.services.floppy-accounts = lib.mkIf (fl.accounts && cfg.sso.enable) {
      description = "Make sure every enabled Nextcloud user has a Floppy account";
      after = [ "podman-floppy.service" "nextcloud-setup.service" ];
      serviceConfig = { Type = "oneshot"; };
      script = ''
        ${pkgs.python3}/bin/python3 ${../floppy/ensure-accounts.py} --occ ${occ} --podman /run/current-system/sw/bin/podman
      '';
    };
    systemd.timers.floppy-accounts = lib.mkIf (fl.accounts && cfg.sso.enable) {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "10min"; };
    };

    # One recap per person: every enabled Nextcloud user who has a Floppy account and an address in Nextcloud gets their own, computed from their own history; nobody else's data is in it.
    # Someone with nothing tracked in the year is skipped (wrapped.py says so and sends nothing); a failure for one person does not stop the others, but the unit ends failed so the alert tells.
    systemd.services.floppy-wrapped = lib.mkIf fl.recap.enable {
      description = "The yearly recap by mail, one per person (Floppy's history)";
      after = [ "postgresql.service" "podman-floppy.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.coreutils pkgs.jq ];
      serviceConfig = {
        Type = "oneshot"; RuntimeDirectory = "floppy-wrapped"; RuntimeDirectoryMode = "0700"; UMask = "0077"; TimeoutStartSec = "60min";
        LoadCredential = "smtp-password:${config.sops.secrets.smtp-password.path}";
        Environment = "TZ=${if config.time.timeZone == null then "UTC" else config.time.timeZone}";
      };
      script = ''
        set -uo pipefail
        tok="$RUNTIME_DIRECTORY/token"
        failed=0
        while IFS=$'\t' read -r user to; do
          case "$to" in *@*.*) ;; *) echo "$user: no address in Nextcloud, no recap"; continue ;; esac
          ( ${pg}/bin/psql -h /run/postgresql -U floppy -d floppy -v u="$user" -tAq <<'SQL'
        select token from users_user where username = :'u';
        SQL
          ) | tr -d '\n' > "$tok"
          if [ "$(wc -c < "$tok")" -lt 10 ]; then echo "$user: no Floppy account, no recap"; continue; fi
          # the programme talks to Floppy on the loopback (the public name may not loop back from the machine itself), under its own name
          ${pkgs.python3}/bin/python3 ${../floppy/wrapped.py} --url http://127.0.0.1:${port} --host-header track.${d} --token-file "$tok" \
            --year "$(date +%Y)" --tz "$TZ" --name "${cfg.brand.name}" \
            --send --to "$to" --from "${cfg.brand.name} <alerts@${d}>" \
            --smtp-host smtp-relay.brevo.com --smtp-port 587 --smtp-user ${if cfg.mail.smtpLogin != null then cfg.mail.smtpLogin else "alerts@${d}"} \
            --smtp-password-file "$CREDENTIALS_DIRECTORY/smtp-password" || { echo "$user: the recap failed" >&2; failed=1; }
          rm -f "$tok"
        done < <(${occ} user:list --output=json --info | jq -r 'to_entries[] | select(.value.enabled) | [.value.user_id, (.value.email // "")] | @tsv')
        exit $failed
      '';
    };
    systemd.timers.floppy-wrapped = lib.mkIf fl.recap.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = fl.recap.calendar; Persistent = true; };
    };
  };
}
