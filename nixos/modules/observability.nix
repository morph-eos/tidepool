# Observability (ADR 0012): Prometheus and Alertmanager with declared rules, email only (Brevo's relay), and a heartbeat to an outside dead-man's switch (Healthchecks.io).
# Lab: the mail goes to a local sink and the heartbeat to a local sink (hosts/lab/fixtures.nix).
{ config, lib, pkgs, ... }:
let
  cfg = config.tidepool;
  d = cfg.domain;
  mailFrom = "alerts@${d}"; mailTo = "admin@${d}";
  smtp = if cfg.lab
    then { smarthost = "127.0.0.1:1025"; require_tls = false; }
    else { smarthost = "smtp-relay.brevo.com:587"; require_tls = true; auth_username = "alerts@${d}"; auth_password_file = "/run/credentials/alertmanager.service/smtp-password"; };
  heartbeat = if cfg.lab then { url = "http://127.0.0.1:8112/ping"; } else { url_file = "/run/credentials/alertmanager.service/heartbeat-url"; };
  blackboxCfg = pkgs.writeText "blackbox.yml" (builtins.toJSON { modules = {
    https = { prober = "http"; timeout = "10s"; http = { valid_status_codes = [ 200 301 302 401 403 404 ]; tls_config.insecure_skip_verify = cfg.lab; }; };   # production verifies the chain: a placeholder certificate must fail
    caa = { prober = "dns"; timeout = "10s"; dns = { query_name = d; query_type = "CAA"; preferred_ip_protocol = "ip4"; validate_answer_rrs.fail_if_not_matches_regexp = [ ".*letsencrypt\\.org.*" ]; }; };
  }; });
  rules = pkgs.writeText "rules.yml" ''
    groups:
    - name: tidepool
      rules:
      - alert: Watchdog
        expr: vector(1)
        labels: { severity: heartbeat }
      - alert: UnitFailed
        expr: node_systemd_unit_state{state="failed"} == 1
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.name }} has failed" }
      - alert: EndpointDown
        expr: probe_success{job="https"} == 0
        for: 5m
        labels: { severity: critical }
        annotations: { summary: "{{ $labels.instance }} does not answer" }
      - alert: CertificateExpiring
        expr: probe_ssl_earliest_cert_expiry{job="https"} - time() < 1209600
        labels: { severity: warning }
        annotations: { summary: "the certificate of {{ $labels.instance }} expires within 14 days" }
      - alert: CaaMissing
        expr: probe_success{job="caa"} == 0
        for: 10m
        labels: { severity: critical }
      - alert: DiskAlmostFull
        expr: node_filesystem_avail_bytes{fstype=~"ext4|zfs"} / node_filesystem_size_bytes{fstype=~"ext4|zfs"} < 0.10
        for: 10m
        labels: { severity: critical }
        annotations: { summary: "{{ $labels.mountpoint }} has less than 10% free" }
      - alert: MemoryPressure
        expr: rate(node_pressure_memory_waiting_seconds_total[5m]) > 0.2
        for: 10m
        labels: { severity: warning }
      - alert: PostgresArchiveFailing
        expr: increase(pg_stat_archiver_failed_count[1h]) > 0
        labels: { severity: critical }
      # a backup timer that has not fired (a never-triggered timer reads 0, hence the "machine up longer than the window" guard)
      - alert: BorgBackupStale
        expr: (time() - node_systemd_timer_last_trigger_seconds{name=~"borgbackup-job-.*\\.timer"} > 14400) and on() (time() - node_boot_time_seconds > 14400)
        labels: { severity: critical }
      - alert: PgBackrestStale
        expr: (time() - node_systemd_timer_last_trigger_seconds{name=~"pgbackrest-.*\\.timer"} > 216000) and on() (time() - node_boot_time_seconds > 216000)
        labels: { severity: critical }
      # a backup unit that has been running for hours: a first backup of a very large library, or a check that hangs while the backups wait for it (they wait up to 12 hours)
      - alert: BackupJobRunningLong
        expr: node_systemd_unit_state{name=~"borgbackup-job-.*\\.service|borgmatic\\.service|pgbackrest-restore-test\\.service", state="active"} == 1
        for: ${if cfg.lab then "2m" else "8h"}
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.name }} has been running for a long time" }
      # the verification jobs of verify.nix must keep running: a check nobody runs is no check
      - alert: BorgChecksStale
        expr: (time() - node_systemd_timer_last_trigger_seconds{name="borgmatic.timer"} > 691200) and on() (time() - node_boot_time_seconds > 691200)   # the timer is weekly: 8 days
        labels: { severity: warning }
      - alert: RestoreTestStale
        expr: (time() - node_systemd_timer_last_trigger_seconds{name="pgbackrest-restore-test.timer"} > 3888000) and on() (time() - node_boot_time_seconds > 3888000)
        labels: { severity: warning }
      - alert: CertificateRenewalStale
        expr: (time() - node_systemd_timer_last_trigger_seconds{name=~"acme-renew-.*\\.timer"} > 259200) and on() (time() - node_boot_time_seconds > 259200)   # 3 days: the renewal timers are daily with a random delay of up to 24 h and an accuracy of 4 h, so two runs can be almost 48 h apart
        labels: { severity: warning }
  '';
  probe = name: module: targets: {
    job_name = name; metrics_path = "/probe"; params.module = [ module ];
    static_configs = [ { inherit targets; } ];
    relabel_configs = [ { source_labels = [ "__address__" ]; target_label = "__param_target"; } { source_labels = [ "__param_target" ]; target_label = "instance"; } { target_label = "__address__"; replacement = "127.0.0.1:9115"; } ];
  };
in
{
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    retentionTime = "30d";
    globalConfig = { scrape_interval = "30s"; evaluation_interval = "30s"; };
    exporters = {
      node = { enable = true; listenAddress = "127.0.0.1"; enabledCollectors = [ "systemd" ]; };
      postgres = { enable = true; listenAddress = "127.0.0.1"; runAsLocalSuperUser = true; };
      blackbox = { enable = true; listenAddress = "127.0.0.1"; configFile = "${blackboxCfg}"; };
      smartctl = lib.mkIf (!cfg.lab) { enable = true; listenAddress = "127.0.0.1"; devices = [ cfg.disks.system cfg.disks.tank cfg.disks.backup16 cfg.disks.big2tb ]; };
    };
    ruleFiles = [ rules ];
    alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ]; } ];
    scrapeConfigs = [
      { job_name = "node"; static_configs = [ { targets = [ "127.0.0.1:9100" ]; } ]; }
      { job_name = "postgres"; static_configs = [ { targets = [ "127.0.0.1:9187" ]; } ]; }
      (probe "https" "https" [ "https://vault.${d}/alive" "https://cloud.${d}/status.php" "https://photos.${d}/api/server/ping" "https://jelly.${d}/health" "https://dav.${d}/" ])
      (probe "caa" "caa" [ "1.1.1.1" ])   # the CAA record, asked of a public resolver, as a CA would see it
    ] ++ lib.optional (!cfg.lab) { job_name = "smartctl"; static_configs = [ { targets = [ "127.0.0.1:9633" ]; } ]; };
    alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      extraFlags = [ "--cluster.listen-address=" ];   # one instance: no gossip port (it listened on every interface)
      environmentFile = config.sops.secrets.alertmanager-env.path;
      checkConfig = false;   # amtool cannot check the unexpanded address
      configuration = {
        route = {
          receiver = "mail";
          group_by = [ "alertname" ]; group_wait = "30s"; group_interval = "30m"; repeat_interval = "12h";   # 30m: a flapping alert is at most one mail per half hour per alert name (Brevo's free plan allows 300 mails a day)
          routes = lib.optional cfg.push.enable { matchers = [ "severity = critical" ]; receiver = "mail-and-push"; } ++ [
            # the Watchdog goes two ways: a webhook ping every 2 minutes (a dead machine or a dead Alertmanager is noticed within minutes) ...
            { matchers = [ "severity = heartbeat" ]; receiver = "heartbeat"; repeat_interval = "1m"; group_interval = "2m"; group_wait = "0s"; continue = true; }
            # ... and a MAIL through the same relay as the real alerts, to the address of a second check (its period is a day): if the mail path breaks, that check goes silent
            # and Healthchecks.io says so by its own mail, which does not depend on our relay. (A webhook ping alone would hide a broken relay.)
            { matchers = [ "severity = heartbeat" ]; receiver = "mailpath"; repeat_interval = if cfg.lab then "1m" else "5h"; group_interval = if cfg.lab then "3m" else "1h"; group_wait = "0s"; }
            # the weekend version watch (versions/rules.yml): all of its alerts in ONE mail, sent once (47 h > the two days they are raised for); no "resolved" mail is sent by the email receiver
            { matchers = [ "severity = weekly" ]; receiver = "mail"; group_by = [ "severity" ]; group_wait = "5m"; group_interval = "12h"; repeat_interval = "47h"; }
            # Alertmanager resends only at a group_interval tick, and only if repeat_interval has already passed: with the two EQUAL the tick comes a few milliseconds too early and a tick is skipped
            # (measured: pings every 4 minutes with both at 2 minutes). So repeat_interval is kept below group_interval: a ping every 2 minutes, a mail every 6 hours in production.
          ];
        };
        receivers = [
          { name = "mail"; email_configs = [ ({ to = mailTo; from = mailFrom; } // smtp) ]; }
          { name = "heartbeat"; webhook_configs = [ heartbeat ]; }
        ] ++ lib.optional cfg.push.enable { name = "mail-and-push"; email_configs = [ ({ to = mailTo; from = mailFrom; } // smtp) ]; webhook_configs = [ { url = "http://127.0.0.1:8111/hook"; } ]; } ++ [
          # $HEALTHCHECKS_MAIL is replaced from the sops file below: the check's address is a secret (whoever knows it can fake a ping), and `to` cannot be read from a file
          { name = "mailpath"; email_configs = [ ({ to = "$HEALTHCHECKS_MAIL"; from = mailFrom; headers.Subject = "tidepool mail path alive"; } // smtp) ]; }
        ];
      };
    };
  };
  # Alertmanager runs as a dynamic user: systemd hands it the two secrets as credentials (they never enter the Nix store and are readable by that unit only)
  systemd.services.alertmanager.serviceConfig.LoadCredential = [
    "smtp-password:${config.sops.secrets.smtp-password.path}"
    "heartbeat-url:${config.sops.secrets.heartbeat-url.path}"
  ];
}
