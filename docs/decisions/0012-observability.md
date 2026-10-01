# 0012. Observability: finding out that something broke without noticing by chance

- **Status:** proposed (2026-10-01): accepted: email only, Brevo as the relay, and Healthchecks.io (hosted free plan) as the outside heartbeat; the owner confirmed each on 2026-10-01
- **Date:** 2026-10-01
- **Phase:** 5, Observability

## Context

v0 has no monitoring beyond a `smartcheck` container that writes a log nobody reads. Every earlier phase left a failure that is **silent** by design:

| Silent failure | Where it was found |
|---|---|
| A certificate order fails at boot and every name stays on a **placeholder certificate**, the other orders showing only `Dependency failed` | [ADR 0009](0009-remote-access-vpn.md), lab |
| A backup job (Borg, pgBackRest) does not run or fails; the Borg module has no notification | [ADR 0004](0004-backup.md), [0007](0007-offsite-copy.md) |
| PostgreSQL stops archiving its WAL: the point-in-time recovery silently stops being possible | [ADR 0004](0004-backup.md) |
| A disk degrades (SMART) while the 16 TB disk holds the **only copy of the media** | [ADR 0005](0005-storage-layout-and-filesystem.md) |
| Memory is short (ZFS cache, Immich's machine learning) | [ADR 0005](0005-storage-layout-and-filesystem.md) |
| The CAA record is removed or changed, or the DNS delegation breaks | [ADR 0008](0008-edge.md) |
| A service answers 502 behind nginx while its unit is "active" | lab, this phase |
| **The server itself is down**, and nothing inside it can say so | by definition |

## Requirements

- **Must:** each case above produces a notification **without anyone looking**; the notification reaches the owner **outside the server** (a mail to a dead server is no mail); **a dead server is noticed** (a heartbeat watched from outside); declared as code, **no script**; no secrets in the Nix store ([ADR 0003](0003-secrets.md)).
- **Should:** the NixOS modules maintained; the cost in memory small on this machine that already runs ZFS, PostgreSQL, Immich and Jellyfin; alert rules in files that review well; a push to the phone for the critical cases.
- **Won't:** a dashboard as the way to find problems (nobody watches it); logs aggregation (Loki) in this phase; tracing; a paid SaaS.

## Candidates

| Candidate | What it is | NixOS modules |
|---|---|---|
| **A. Prometheus + Alertmanager** with exporters (node, postgres, blackbox, smartctl), **ntfy** for the push, Grafana optional | metrics, rules in YAML, routing and repetition of alerts | `services.prometheus` (and `.alertmanager`, `.exporters.*`), `services.ntfy-sh`, `services.grafana` |
| **B. Gatus** | a single binary that probes endpoints and certificates by conditions and sends the alerts itself | `services.gatus` |
| Not tested: Netdata, Monit, Uptime Kuma, Healthchecks self-hosted (it would need its own outside watcher), Gotify | | |

## Results

`lab/observability-bakeoff.sh` in the NixOS lab VM (`exp/observability`, tag `exp-observability`). Real failures are made on purpose; the time is counted until the notification arrives in a **mail sink** (a small SMTP server logging to a file) and in **ntfy**. **The lab timings are short on purpose** (rule `for:` of 1-2 minutes, the evaluation every 15 s); the production values are in the decision.

**A: Prometheus, Alertmanager, ntfy**

| Check | Result |
|---|---|
| A1. A heartbeat (an always-firing rule, repeated to an outside address) | **a webhook is called repeatedly**; Alertmanager's grouping makes the repeat interval **2 minutes in the lab**, not the 1 minute configured: the outside service must tolerate that |
| A2. A systemd unit fails | **mail after 87 s** (`UnitFailed`, with the unit's name) |
| A3. A service stops (Vaultwarden) | **mail after 76 s**; the **push** (ntfy) arrived at the **same moment**, titled `https://vault.lab.test/alive does not answer` |
| A4. Certificates near expiry | the probes read the expiry of every name (`probe_ssl_earliest_cert_expiry`); with the lab threshold raised, **`CertificateExpiring` fired for the four names** |
| A5. The CAA record | a blackbox DNS probe asks a public resolver (1.1.1.1) and checks for `letsencrypt.org`: **`probe_success = 1`** for the owner's domain; the rule fires when it is gone |
| A6. A filesystem at 6% free | **mail after 91 s** (`DiskAlmostFull`) |
| A7. Memory pressure | the PSI metric exists; the rule uses its rate (lab: about 0.00004 s/s, no alert) |
| A8. PostgreSQL archiving | `pg_stat_archiver_failed_count` exists; the rule `increase(...[10m]) > 0` **was not made to fail** here |
| A9. Timers (the pattern for "a backup did not run") | **10 timers** seen with their last trigger time |
| A10. SMART | the smartctl exporter runs, but a virtual disk has **no SMART data: 0 series**; the rule is **not tested** on a real disk |
| A11. Memory (MiB) | Prometheus 36, Alertmanager 14, alertmanager-ntfy 4, ntfy 12, node 9, postgres 7, blackbox 15, smartctl 10: **about 107 MiB without Grafana**; **Grafana 217 MiB** |
| A12. Grafana | starts with the Prometheus data source provisioned from code |
| Our own configuration | one module, **no script**; the rules are YAML files; the lab-only scaffolding (SMTP sink, heartbeat sink, fixed Grafana passwords) is **not** part of it |

**B: Gatus**

| Check | Result |
|---|---|
| Three endpoints with `[STATUS] == 200` and `[CERTIFICATE_EXPIRATION] > 240h`, alerts to ntfy | all green on a healthy system |
| Vaultwarden stopped | **push after 27 s** (two failures in a row at 15 s), listing which condition failed (`502`) and which passed |
| Memory | **6 MiB** |
| What it does **not** see | systemd units, disks, memory, PostgreSQL, timers, the CAA record, SMART: **it answers only "does it respond"** |

**What running it showed (rule-design lessons, in the code as comments):**
- **A timer that has never triggered reads `0`** in `node_systemd_timer_last_trigger_seconds`, so `time() - metric` is huge and the rule `TimerStale` fired for every new timer. The rule needs "and the machine has been up longer than the window" (`and on() time() - node_boot_time_seconds > window`).
- **A certificate that expires soon is not what fails first**: the failure seen in phase 3 was an order that **never succeeded**, leaving a placeholder certificate. The probe of the **served** certificate (`probe_ssl_earliest_cert_expiry`, plus the blackbox TLS check, which rejects an untrusted certificate when the module verifies it) catches it, because it measures what a visitor receives and not what ACME believes.
- **Internal monitoring cannot report that the server is dead.** The heartbeat exists for that: an always-firing alert sent every few minutes to an **outside** service that alerts when the pings **stop**.
- **Alerts that repeat forever train you to ignore them**: the `repeat_interval` of ordinary alerts is hours; only the heartbeat repeats fast.
- The `smartd` daemon of [ADR 0011](0011-services.md) and the smartctl exporter overlap: the exporter gives the owner the numbers over time; `smartd` mails by itself. One of them is enough for the alert (below).

**Not tested:** the heartbeat against a real outside service; real email delivery (needs an SMTP relay and credentials, as sops secrets); the smartctl and PostgreSQL rules on real data; an ntfy reachable from the phone (it needs a public name or the VPN, and the **iOS push needs the upstream relay**); Grafana dashboards beyond the provisioned data source; the cost over weeks (the Prometheus retention and disk use).

## Criteria, in this order

1. **Coverage (measured):** how many of the silent failures above produce a notification.
2. **Reaches the owner when the server is dead:** an outside heartbeat or nothing.
3. **P1:** modules, rules in files, no script, no secrets in the store.
4. **Memory and moving parts.**

## Decision

**Accepted. A, Prometheus and Alertmanager with declared rules, as the only monitoring that raises alerts;** B is **not** adopted, because it covers one of the eight cases and A already does that case (the blackbox probe with its TLS check) with the same speed in the lab (76 s against 27 s: a difference of the `for:` values, not of the tools). Its 6 MiB are the argument for it, not its coverage.

- **Exporters:** node (with the `systemd` collector), postgres, blackbox (HTTPS with certificate expiry; DNS for the CAA record), and **smartctl** for the numbers; `smartd` keeps mailing by itself, so a SMART warning has two independent paths.
- **Rules (declared as YAML, in the repository):** `UnitFailed`, `EndpointDown`, `CertificateExpiring` (production: **14 days**), `CaaMissing`, `DiskAlmostFull`, `MemoryPressure`, `PostgresArchiveFailing`, `TimerStale` (the pattern for every backup timer, with the "never triggered" guard) and the heartbeat `Watchdog`.
- **Notification: email only** (the owner's choice, 2026-10-01): every alert goes by mail, `repeat_interval` in hours. **ntfy and alertmanager-ntfy are left out** of the production module (about 16 MiB and two services fewer); they stay in the experiment branch and can be added later in a few lines. The mail goes through **Brevo's SMTP relay**, which **already works for the owner in v0**; the SMTP key is a sops secret, and the SPF and DKIM records Brevo asks for sit in the owner's DNS.
- **The heartbeat goes to an outside dead-man's-switch** (a free tier of a service such as Healthchecks.io, or the owner's own address on another host): this is the **only case where the monitoring depends on a third party**, and it receives **nothing but the fact that a ping arrived**.
- **Grafana: not by default** (217 MiB, and nobody opens a dashboard to find a failure); it is one `enable` and the data source is provisioned when the owner wants to look at trends.
- **No Loki** in this phase.

## Heartbeat services compared (from the vendors' pages read on 2026-10-01 with WebFetch: healthchecks.io/pricing, /about and the docs; deadmanssnitch.com/plans; uptimerobot.com/pricing and /terms; betterstack.com/pricing and its heartbeat docs; **not tested**)

| Service | Free plan | Alert path | Notes |
|---|---|---|---|
| **Healthchecks.io** | 20 checks, 100 log entries per check; email alerts (SMS, WhatsApp and phone calls are paid) | its own mail | built for exactly this (period, grace time, cron schedules); **open source (BSD) and self-hostable**; runs on Hetzner bare metal, one-person company in Latvia; stores only the pings and notification records; the paid "Supporter" plan ($5) adds nothing but support |
| UptimeRobot | 50 monitors, 5-minute interval, **heartbeat monitors included**; email, SMS and voice need credits; usable for any purpose, commercial included | its own mail | a general uptime tool, heartbeat is a side feature; paid from $108 a year |
| Better Stack | 10 monitors, email and Slack alerts; **heartbeats on the free plan not confirmed** by the pages read | its own mail | the heavier incident-management product |
| Dead Man's Snitch | **one** snitch | its own mail | enough for a single heartbeat; $5 a month for three |

**Reading:** all four do the one thing needed (a missing ping raises an alert by their own mail, independent of Brevo). **Healthchecks.io fits best:** the purpose-built tool, a 20-check free plan of which we use one, a documented grace time, and **an escape hatch with no lock-in** (the same software can be self-hosted on a VPS if the free plan ever goes away). UptimeRobot is the runner-up; Dead Man's Snitch's single free check is just enough but with no room to grow. **Not measured:** the minimum ping period on the free plan, the real alert delay, and the mail's deliverability (it could land in spam: the owner adds the sender to contacts).

## Decision: heartbeat on Healthchecks.io, hosted free plan (confirmed by the owner)

One check with a short period and a grace time of a few minutes; Alertmanager's `Watchdog` calls its ping address (a secret, read from a sops file, not in the Nix store). It receives the fact that a ping arrived.

## Consequences

- The **Borg and pgBackRest jobs** must each expose a systemd timer that `TimerStale` watches, and **a failed backup unit is a `UnitFailed`**: that closes the "notification when a backup job fails" item without touching the Borg module. `borg check` and the verification restore remain phase 7.
- The **certificate-order failure** of phase 3 is caught by the probe of the served certificate and by `UnitFailed` on the order's unit.
- The CAA rule needs an update when the record gets its `accounturi` (the regular expression only checks the CA name today).
- About **110 MiB** of memory, which fits the budget of [ADR 0005](0005-storage-layout-and-filesystem.md).
