# Experiments: the scripts that produced the numbers of the decision records

Each script was run **once**, to decide something (a tool against its alternatives, a mechanism against a failure); the decision record named in the second column quotes what it measured. They are **kept as evidence**, not maintained: they were run against the versions and the lab of the day, and some need a prepared VM (`lab/vm.sh`). The tools that are used again and again (`vm.sh`, the restore drill, `check-host.sh`, the brand and sign-on checks, `compute-names.sh`) are one level up, in [lab/](../README.md). A script here finds the lab's tools through `$HERE` (the `lab/` directory).

| Script | ADR | What it does |
|---|---|---|
| `acme-delegation-test.sh` | 0008 | ADR 0008, route 1: a certificate for test.<domain> by the DNS challenge, the challenge name delegated by CNAME to acme-dns, against Let's En |
| `deploy-u16.sh` | 0018 | ADR 0018: the server pulls and applies what was merged (system.autoUpgrade), the backups run BEFORE the change is activated (system.preSwitc |
| `deploy-u17.sh` | - | ADR 0018, after deploy-u16.sh: (a) the deploy key: the server reads the PRIVATE repository over ssh with a key that can do nothing else, as  |
| `deploy-u18.sh` | 0018 | ADR 0018: the private repository on GitHub, read over ssh with a deploy key kept as a sops secret and GitHub's host key pinned in the config |
| `deploy-u20-window.sh` | 0018 | ADR 0018 section 9: with the reboot allowed and a time window, a deploy that changes the kernel is only INSTALLED (nixos-rebuild boot) until |
| `deploy-u22-encrypted.sh` | 0018 | ADR 0018 with ADR 0005: the server pulls a merged kernel change, the backups run, the new boot image is installed and signed, the reboot wai |
| `edge-bakeoff.sh` | 0008 | the edge candidates under the same checks (ADR 0008). Runs INSIDE the lab VM, as root, right after the candidate is deployed |
| `fs-bakeoff.sh` | 0005 | ext4 (as in v0), btrfs and ZFS under the same four tests. Runs INSIDE a lab VM, as root. |
| `majors-u15-nextcloud.sh` | 0017 | ADR 0017 (the owner asked "can we already move Nextcloud and PostgreSQL?"): Nextcloud 33 -> 34 -> 35 on the lab host's data, one major at a  |
| `majors-u15-postgres-check.sh` | 0017 | after lab/experiments/majors-u15-postgres.sh: exact row counts of EVERY table in the old (17, untouched) and new (18) cluster, pgBackRest ve |
| `majors-u15-postgres.sh` | 0017 | ADR 0017: PostgreSQL 17 -> 18 on the lab host's data (Nextcloud, Vaultwarden, Immich with VectorChord indexes) with pg_upgrade, then pgBackR |
| `mirror-bakeoff.sh` | 0005 | a two-disk mirror on btrfs RAID1 and on ZFS, plain and on LUKS: damage, a dead member, its replacement, and a PostgreSQL toy run. |
| `nas-u14.sh` | 0017 | ADR 0017: the local NAS built into the flake (modules/nas.nix) with a Time Machine share, its Samba user, and its place in the Borg job of e |
| `observability-bakeoff.sh` | 0012 | the monitoring stack of ADR 0012 under real failures. Runs INSIDE the lab VM, as root, with modules/observability/stack.nix deployed. Lab sc |
| `offsite-bakeoff.sh` | 0007 | file-level offsite backup tools under the same scenario. Runs INSIDE a lab VM, as root. Lab scaffolding, not part of the system. |
| `pg-snapshot-check.sh` | 0004 | is a snapshot taken WHILE PostgreSQL is writing a valid backup? (runs inside a lab VM, as root) |
| `pitr-bakeoff.sh` | 0004 | PostgreSQL point-in-time recovery tools under the same scenario. Runs INSIDE a lab VM, as root. |
| `private-modules` | - | (a folder: the private-modules proof) |
| `private-modules-u26.sh` | - | a private repository adds a module of its own to the public host without replacing anything (private-repo-template/README.md, "Adding your o |
| `private-repo-u24.sh` | 0018 | the last test before the real deployment: the PRIVATE repository made from private-repo-template/ with test values, importing the REAL publi |
| `push-public-u13.sh` | 0017 | ADR 0017: push notifications WITHOUT the VPN (ntfy on the public side, behind nginx), tried in the lab host. |
| `renovate-u19.sh` | 0018 | ADR 0018: Renovate on the server through `services.renovate` (modules/renovate.nix). Runs INSIDE the lab host as root; /home/lab/nixos is th |
| `secrets-bakeoff.sh` | 0003 | the same scenario for every way of keeping secrets in a Git repository |
| `services-extra-bakeoff.sh` | 0011 | WebDAV for a backup app (two ways) and Nextcloud as the OpenID provider (ADR 0011). Runs INSIDE the lab VM, as root. Lab scaffolding. |
| `services-native-bakeoff.sh` | 0011 | the services through their NixOS modules (ADR 0011). Runs INSIDE the lab VM, as root, with nginx-simple.nix and native.nix deployed. Lab sca |
| `tpm-u21.sh` | 0005 | ADR 0005 (2026-10-05): the encrypted layout of the real machine, tried in a VM with UEFI + Secure Boot firmware (OVMF) and an emulated TPM 2 |
| `updates-u1.sh` | - | lab/experiments/updates-u1.sh <days:rev>... — phase 8 (ADR 0016), U1: what does an update of nixpkgs cost after N days: what changes, what i |
| `updates-u11.sh` | 0016, 0017 | phase 8 follow-up (ADR 0016), U11: the way out of a NixOS module. Nextcloud, which the module runs, is started from the OFFICIAL container i |
| `updates-u12.sh` | - | phase 8 follow-up (ADR 0016), U12: two things the owner asked for, built into the integrated flake as switchable modules and tried in the la |
| `updates-u1b.sh` | - | lab/experiments/updates-u1b.sh <days>... — phase 8 (ADR 0016), U1b: the COLD cost of an update. After updates-u1.sh: for each N, an empty st |
| `updates-u2.sh` | - | lab/experiments/updates-u2.sh <days> — phase 8 (ADR 0016), U2: what a real update does to the services while it is applied. Runs INSIDE the  |
| `updates-u2c.sh` | - | phase 8 (ADR 0016), U2c: an update that needs a REBOOT (a new kernel). Run from the WORKSTATION against the lab host-t after updates-u1.sh b |
| `updates-u3.sh` | - | phase 8 (ADR 0016), U3: deploy methods and what each does when a deploy locks the admin out. Run from the WORKSTATION against the lab host-v |
| `updates-u3d.sh` | - | phase 8 (ADR 0016), U3 d and e: the two PULL methods. Run from the WORKSTATION against the lab host-v, which has the small test flake of upd |
| `updates-u3e.sh` | - | phase 8 (ADR 0016), U3 d and e: the two PULL methods. Run from the WORKSTATION against the lab host-v, which has the small test flake of upd |
| `updates-u4.sh` | - | phase 8 (ADR 0016), U4: updates of services that keep STATE, and what can be undone. Runs INSIDE the lab host (the integrated host with the  |
| `updates-u4d.sh` | - | phase 8 (ADR 0016), U4d: a declared, native way to have a rollback point before an update: the NixOS sanoid module with a SHORT retention on |
| `updates-u7.sh` | - | phase 8 (ADR 0016), U7 and U9: (7) what a clean CI runner would need to run `nix flake check` on both hosts: time, download, disk, memory; |
| `updates-u8.sh` | - | phase 8 (ADR 0016), U8: how the private values (domain, disks, VPN peers, secrets) reach the real host without being in the public repositor |
| `vm-exposure-bakeoff.sh` | 0010 | how the services of Incus instances reach the outside (ADR 0010). Runs INSIDE the lab VM, as root, after vpn.nix and vm-exposure.nix are dep |
| `vms-bakeoff.sh` | 0013 | phase 6 (ADR 0013). Runs INSIDE the lab VM host-v, as root, with modules/vms/incus.nix deployed and the ZFS pool "zp" created. |
| `vms-cycle-bakeoff.sh` | 0013 | phase 6 (ADR 0013), R5: the throwaway cycle on Incus, on a ZFS pool against a plain directory pool, for a container and a VM. |
| `vms-engines-bakeoff.sh` | 0013 | lab/experiments/vms-engines-bakeoff.sh <docker|podman> — phase 6 (ADR 0013), R2: a container engine next to Incus, with the host firewall on |
| `vms-engines-run.sh` | 0013 | drives R2 (ADR 0013) from the workstation: for each variant, boots host-v into that specialisation, starts the Incus instances, runs lab/exp |
| `vms-lvm-vm-bakeoff.sh` | 0013 | the VM part of R5 on the thin-LVM pool (ADR 0013), with forced stops; run inside host-v as root after: modprobe dm_thin_pool dm_snapshot; in |
| `vms-others-bakeoff.sh` | 0013 | lab/experiments/vms-others-bakeoff.sh <libvirt|microvm> — phase 6 (ADR 0013), R3 and R4. Runs INSIDE host-v as root, booted into that specia |
| `vpn-bakeoff.sh` | 0009 | a WireGuard peer in a network namespace stands for a phone on the VPN; "outside" is the machine's own LAN address. ADR 0009. Lab scaffolding |
| `wifi-u23.sh` | 0019 | the server on WiFi (modules/wifi.nix): a virtual radio pair (mac80211_hwsim), a real hostapd access point with DHCP in a network namespace,  |
