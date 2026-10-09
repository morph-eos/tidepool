# 0012. Observability: finding out that something broke without noticing by chance

- **Status:** accepted (2026-10-01): email only, Brevo as the relay, and Healthchecks.io (hosted free plan) as the outside heartbeat; the owner confirmed each on 2026-10-01
- **Date:** 2026-10-01
- **Phase:** 5, Observability
- **Update 2026-10-03:** push notifications were added **without the VPN** (ntfy on the public side, two least-privilege logins) and a **weekend version watch**, both in [ADR 0017](0017-version-watch-push-and-nas.md); the mail stays the base and is always sent.

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

`lab/experiments/observability-bakeoff.sh` in the NixOS lab VM. Real failures are made on purpose; the time is counted until the notification arrives in a **mail sink** (a small SMTP server logging to a file) and in **ntfy**. **The lab timings are short on purpose** (rule `for:` of 1-2 minutes, the evaluation every 15 s); the production values are in the decision.

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
- **Rules (declared as YAML, in the repository):** `UnitFailed`, `EndpointDown`, `CertificateExpiring` (production: **14 days**), `CaaMissing`, `DiskAlmostFull`, `MemoryPressure`, `PostgresArchiveFailing`, `TimerStale` (the pattern for every backup timer, with the "never triggered" guard) and the heartbeat `Watchdog`. **The disks (added 2026-10-09; not yet tried on a real disk, as A10 says):** `SmartFailing` (the drive's own verdict), `SmartUnreadable` (a disk that cannot be opened, or the exporter gone), `DiskErrorsGrowing` (reallocated, uncorrectable and pending sectors: it looks at **growth**, so a disk that arrived with a few does not alert forever), `DiskLinkErrors` (CRC errors on the SATA link: a cable), `NvmeMediaErrors`, `SsdWornOut` (NVMe percentage used, or the normalized wear value of SATA SSDs, below 20) and `DiskHot`. They read generic attributes, hold for SATA, NVMe and spinning disks, and never fire in the lab (virtual disks have no SMART data).
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

## Update 2026-10-02: a second path, to notice a broken mail relay

**The gap.** Alerts go by mail through Brevo. If the relay or its credentials break, alerts fire and **are not delivered**, and the heartbeat does not notice: it pings a webhook and says only that the machine and Alertmanager are alive.

**What was considered.** The push channel of the first round (**ntfy**, tested in the lab: the push arrived in the same second as the mail, about 16 MiB for the two services) was **not rejected for a defect**: the owner chose email only on 2026-10-01, and it was left out of the flake, to be added in a few lines. Its limits are those already noted: the phone must reach the server (the VPN, or a public name), and iOS needs the upstream relay. The owner now feels safe enough with Brevo, so the cheaper question is how to **notice** that Brevo fails, not how to add another way to receive alerts.

**What was built and tested (lab).** Alertmanager sends the always-firing `Watchdog` **twice**, on two routes (`continue: true`): a **webhook** ping every 2 minutes (a dead machine or a dead Alertmanager), and a **mail through the same relay as the real alerts**, to the address of a **second** Healthchecks.io check. Healthchecks accepts pings **by email** (its documentation: "any email received at the displayed address counts as a success signal"; whether the free plan includes it is not stated there: **to be seen when the account is made**). If the mail path breaks, the second check goes silent and **Healthchecks says so by its own mail**, which does not depend on our relay. It is declared in the Alertmanager configuration, **no script**; the check's address is a secret (whoever knows it can fake a ping) and `to` cannot be read from a file, so the file `alertmanager-env` of the sops secrets holds `HEALTHCHECKS_MAIL=` and the module's `environmentFile` substitutes it: **the substituted configuration holds the address, the copy in the Nix store holds only the placeholder** (checked).

**Production values:** the mail every 6 hours; the second check with a period of 12 hours and a grace of 6, so a broken relay is noticed within about 18 hours; the first check (the webhook) with a period of 10 minutes and a grace of 10. **Healthchecks.io now needs two checks** (the free plan allows 20).

**What the lab taught about Alertmanager timing.** It resends a notification only at a **`group_interval` tick**, and only if **`repeat_interval` has already elapsed**: with the two equal, the tick comes a few milliseconds early and a tick is skipped. Measured: with both at 2 minutes the heartbeat went **every 4 minutes**; with `repeat_interval` 1 minute and `group_interval` 2 minutes it goes **every 2 minutes**. (The 2-minute figure of the first round came from this same effect.) The routes now set both explicitly.

**Brevo's 300 mails a day** (the owner's question). What sends mail through the relay: the **mail-path heartbeat, 4 a day**; every real alert group, once when it starts (`group_wait` 30 s) and again every 12 hours while it keeps firing (`repeat_interval`); **no mail when an alert resolves** (`send_resolved` is false for email in the live configuration, checked). Alerts are grouped by name, so one mail covers all the instances of one alert.

| Day | Mails |
|---|---|
| A quiet day | 4 (heartbeat) and 0-3 alerts: **under 10, about 3% of the limit** |
| A bad day: **everything at once** (13 alert names, all firing for the whole day) | 13 groups x 2 (start and one repeat) + 4 = **about 30, 10%** |
| One alert flapping all day | each cycle needs the rule's wait to pass again; with the groups' interval at 5 minutes it could be about 130 a day, **43%** by itself. **The default route's `group_interval` is now 30 minutes**: at most one mail per half hour per alert name, **48 a day** at the very worst |

So **we are far under the limit**, even in a bad case. Two things the alerts do not count: **other mail through the same Brevo account** (Vaultwarden's and Nextcloud's own mail, v0's scripts): a few a day, to be added to the 4; and **if the limit is ever hit, the heartbeat mails are dropped too**, which Healthchecks then reports as a broken mail path, which would be true.

**Not tested:** a real mail through Brevo, Healthchecks receiving an email ping and alerting on its silence, the 18-hour detection time.

## Consequences

- The **Borg and pgBackRest jobs** must each expose a systemd timer that `TimerStale` watches, and **a failed backup unit is a `UnitFailed`**: that closes the "notification when a backup job fails" item without touching the Borg module. `borg check` and the verification restore remain phase 7.
- The **certificate-order failure** of phase 3 is caught by the probe of the served certificate and by `UnitFailed` on the order's unit.
- The CAA rule needs an update when the record gets its `accounturi` (the regular expression only checks the CA name today).
- About **110 MiB** of memory, which fits the budget of [ADR 0005](0005-storage-layout-and-filesystem.md).


**Correction (2026-10-03):** the rule for a silent certificate-renewal timer waited 2 days. The renewal timers are daily with a random delay of up to 24 hours and an accuracy of 4 hours, so two runs can be almost 48 hours apart and the rule could fire without a fault. It now waits 3 days.
