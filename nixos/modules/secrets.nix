# Secrets (ADR 0003): sops-nix with an age key that lives only on the machine (custody: Proton Pass and paper). Nothing secret enters the Nix store.
{ config, ... }:
let cfg = config.tidepool; in
{
  sops.defaultSopsFile = cfg.secretsFile;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets = {
    borg-passphrase = { };
    pgbackrest-cipher = { };
    nextcloud-admin-pass = { owner = "nextcloud"; };
    vaultwarden-env = { owner = "vaultwarden"; };
    webdav-htpasswd = { owner = "nginx"; };
    wg-private-key = { };
    smtp-password = { };
    heartbeat-url = { };
    alertmanager-env = { };   # HEALTHCHECKS_MAIL=<the mail address of the second Healthchecks check>
  };
  # pgBackRest reads extra files from conf.d: the module refuses the cipher passphrase as an option (it would land in the world-readable Nix store)
  sops.templates."pgbackrest-secret.conf" = {
    content = "[global]\nrepo1-cipher-pass=${config.sops.placeholder.pgbackrest-cipher}\n";
    path = "/etc/pgbackrest/conf.d/secret.conf";
    owner = "root"; group = "postgres"; mode = "0640";
  };
}
