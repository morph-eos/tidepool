# 0002. The host as code

- **Status:** proposed (experiments not run yet)
- **Date:** 2026-09-29
- **Phase:** 1, Foundations

## Context

In v0 the host layer is 34 shell scripts that have to be idempotent by discipline, with no way to test them and no rebuild ever rehearsed. The README's lessons
say the same thing three times: a change that lives only in a shell history, a manual edit nobody can detect, `/etc` that no backup covers.
The new host must be reproducible from an empty machine with one command, and tell me when it has drifted.

## Requirements

- **Must:** reach the state of [the host specification](../specs/host.md) (H01-H09) from an empty Ubuntu 24.04 machine; idempotent (a second run changes nothing);
  run from the workstation, not on the server; keep working with a desktop session (the server is also a media center); no secret in clear text in the repository.
- **Should:** show drift; be understandable by someone reading the repo for the first time; a rebuild measured in minutes.
- **Won't:** Kubernetes, and any hypervisor with exclusive GPU passthrough (the machine is used daily as a media center).

## Options considered

| Option | Branch / tag | Time box | Result in one line |
|---|---|---|---|
| A. Ansible (roles, run from the workstation over SSH) | `exp/host-ansible` | one evening | |
| B. NixOS (declarative system, flake) | `exp/host-nixos` | one evening | |

"Keep the v0 shell scripts" is not a candidate: v0 is the baseline the numbers are compared with, not a contender.

## Criteria

Decided before testing, in this order of importance (from the owner: the priorities are a fast, repeatable rebuild and reliability/security; teaching value comes
after, and only for things that are best practice):

1. **Rebuild speed and repeatability:** time from the `empty` snapshot to all checks green, manual steps, idempotency (changes reported by a second run), survives a reboot.
2. **Security and reliability:** secrets handling, how a bad change is rolled back, how many ways there are to lock myself out of the server.
3. **Best practice and teachability:** is this what people who run this seriously actually do, and can a newcomer follow it.
4. **Effort and moving parts:** how long it took to get working within the time box, and how many tools have to be learned and kept up to date.
5. **Fit with the machine:** desktop session, GPU drivers, udev rules and disks by serial keep working.

## Results

Both candidates were measured in the lab with the same checker ([the host spec](../specs/host.md), 24 checks) from the same clean baseline: a 4-core, 6 GB VM with a second disk,
both disks snapshotted. Ansible 2.21 ran from the workstation; NixOS 26.05 was installed from its official ISO with the flake in `nixos/`.

| Measure | A. Ansible on Ubuntu 24.04 | B. NixOS 26.05 (flake) |
|---|---|---|
| Checks green | **24 of 24** | **24 of 24** |
| Rebuild, blank to green | **134 s** from an already installed Ubuntu (a cloud image). The manual installation of the OS is **not counted** | **229 s** of `nixos-install`, **312 s** from the installer to a booted system, **including** the OS |
| Manual steps | 2 (export the secret, run the playbook), after installing Ubuntu by hand and installing Ansible once (53 s, no root) | about 5 on real hardware (boot the installer, partition, put the key in place, `nixos-install`), automated by `lab/nixos-install.sh` in the lab |
| Second run | 19 s, **0 changes** | 13 s, the **same system path**, no new generation: idempotent by construction |
| Reboot | 24 of 24 | 24 of 24 |
| Drift | 4 manual changes put back in 28 s | 4 manual changes put back in 5 s |
| Undo a bad change | none built in: recover from a snapshot or the console | a bad SSH port change applied with `test` locked me out; a reboot returned to the previous generation, 24 of 24 |
| Package versions | latest from apt at run time: **not pinned** | pinned by `flake.lock` (nixpkgs and sops-nix) |
| Firewall | none (as v0: UFW inactive) | on by default, only the SSH port open |
| Secrets | delivered by the play (value from the environment, `no_log`); how they are stored in the repo is ADR 0003 | sops-nix decrypts at activation into a `root`-only file; the value never enters the Nix store, which is world-readable |
| Moving parts | Ansible on the workstation, 8 roles, nothing extra on the server | Nix and flakes, nixpkgs channel, sops-nix, a lock file, and the Nix language |
| Effort to get working | four problems found and fixed (below), about 18 minutes of wall clock | the configuration evaluated and built at the first attempt; the effort went into the installer automation (ISO layout, serial prompt, flake lock), which a real installation does not need |

### What went wrong on the way

**Ansible**

1. **Not re-runnable at first.** After the first run sshd only listens on 2222, so a playbook that always connects to 22 could never run twice. It now probes which port answers.
2. **The probe lied.** A plain TCP connect succeeds through QEMU's port forwarder even when nothing listens in the guest. The probe now waits for a real `SSH-2.0` greeting.
3. **Role order.** A directory created under `/mnt/nas` before the data disk is mounted is hidden by the mount. The disk is now mounted first.
4. **A regression from v0, found by a stricter checker.** kdump-tools adds its own `crashkernel=512M` after ours and the last one wins; v0's `setup_kdump.sh` stripped the old value first. Fixed in r2, tag `exp-host-ansible-r2`.

**Both**

5. **The checker was wrong several times** (`sshd -T` prints `without-password`; the first NTP sync takes seconds; Ubuntu-only checks for the admin group and for `dpkg`; symlinked secrets). Test tools get tested too.
6. **"Empty" was not empty.** Snapshots covered only the system disk, so the data disk kept its filesystem and the formatting step was never re-tested after the first run. Snapshots now cover every disk, and the Ansible numbers above were re-measured from a truly blank baseline.

### What a VM cannot show (open risk for B)

The lab has no GPU, no desktop session and none of the server's software. NixOS on this machine is untested where it matters most:

- **The media center:** GNOME on the TV, hardware transcoding (VA-API) for Jellyfin and Immich, Docker containers that use `/dev/dri`.
- **Software that is not packaged for Nix:** the official Proton Drive CLI and the desktop AI client are shipped for Debian/Ubuntu. They would need packaging or a compatibility layer.
- **Incus:** available in NixOS, but not tried here.

Ansible keeps all of that exactly as it is today, since the machine stays Ubuntu.

### Field evidence (read, not run)

Collected on 2026-09-29 from documentation and forums. None of it was tested here.

- **The video that prompted the search:** "What's on my Home Server 2025 - NixOS Edition" by Wolfgang's Channel (April 2025). The page could not be read from here,
  so nothing is claimed about its content beyond what its author publishes: a public [NixOS configuration](https://github.com/notthebee/nix-config) that runs
  Immich, Jellyfin, Vaultwarden, Syncthing and Nextcloud, close to this stack. It uses NixOS's own service modules (not Docker) and agenix for secrets.
- **GPU is documented.** The NixOS wiki has a [Jellyfin page](https://wiki.nixos.org/wiki/Jellyfin) with the VA-API setup for Intel (`hardware.graphics`, the `iHD` driver,
  `vainfo` to verify) and lists known problems, such as firmware loading on some Intel chips. A [nixpkgs issue](https://github.com/NixOS/nixpkgs/issues/356535)
  shows Jellyfin hardware acceleration breaking after an update, which is what a pinned `flake.lock` is for.
- **Containers lower the GPU risk.** This stack runs Jellyfin and Immich in Docker, so the libva and OpenVINO userspace ships in the images. The host only has to provide the kernel
  driver and `/dev/dri`, which is a smaller thing to get wrong than a native Jellyfin on NixOS. It still has to be checked on the real GPU.
- **Software that is not packaged for Nix** is a known, documented case: [nix-ld](https://wiki.nixos.org/wiki/Nix-ld) and FHS environments run downloaded binaries. It is workable,
  and it is still work (a candidate to test is the Proton Drive CLI).
- **Against NixOS:** the learning curve is described as steep and the errors as hard to read
  ([Pierre Zemb, three years of NixOS](https://pierrezemb.fr/posts/nixos-good-bad-ugly/), [DEV Community](https://dev.to/pedroltz/nixos-on-servers-what-changes-when-your-os-becomes-code-4a99)),
  and the community is smaller than Ubuntu's. **For NixOS:** idempotent by design where Ansible is idempotent by discipline, rollback by generations, and "one command to rebuild"
  ([NixOS Discourse: NixOS vs Ansible](https://discourse.nixos.org/t/nixos-vs-ansible/16757), [HomeLab Starter](https://homelabstarter.com/homelab-nixos-immutable-infrastructure/)).

### A cheap test that reduces the risk of B

Boot the NixOS live ISO from a USB stick on the real server, without installing (nothing is changed on the disks), and check the GPU and the desktop: `vainfo` must list the VA-API profiles, GNOME must start, `/dev/dri` must be there. About 20 minutes in a maintenance window.

## Decision

_Pending._

## Consequences

_Pending._
