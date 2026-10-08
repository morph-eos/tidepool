# lab/

The tooling for the throwaway VMs, and the tests that need a running machine. See [the method](../docs/method.md) for why, and
[ADR 0001](../docs/decisions/0001-lab-on-qemu-vms.md) for why QEMU.

```bash
lab/vm.sh create lab0 --cpus 4 --mem 6144 --disk 40   # overlay disk on the shared Ubuntu 24.04 cloud image
lab/vm.sh start lab0                                   # about 20 s to SSH
lab/vm.sh ssh lab0                                     # user "lab", passwordless sudo, your SSH key
lab/vm.sh stop lab0
lab/vm.sh snapshot lab0 baseline                       # stopped VMs only, instant
lab/vm.sh restore lab0 baseline
lab/vm.sh destroy lab0
```

- Everything the VMs need is in `~/lab/tidepool/` (override with `TIDEPOOL_LAB`), never in the repository.
- Each VM gets a block of localhost ports: SSH on `2200`, HTTP on `+1`, HTTPS on `+2` (then `2210`, `2220`, ... for the next VM).
- The guest sees the workstation as `10.0.2.2` and reaches the Internet through QEMU's user-mode NAT.
- Needs `qemu-system-x86_64`, `qemu-img`, `python3`, `curl`, `ssh` and read/write access to `/dev/kvm`. No root.

## Before a push or a merge to `main`: `lab/gate.sh`

The CI ([.github/workflows/check.yml](../.github/workflows/check.yml)) builds both hosts, runs the unit tests of the alert rules, the brand's overrides, the template and the documents' links, and scans for secrets, in about six minutes. **It cannot boot the machine.** The checks that can are here, behind one command:

```bash
lab/gate.sh          # the quick tier, about five minutes (4 measured), on one NixOS lab VM (host-m, started if stopped)
lab/gate.sh --full   # adds the restore drill, about an hour, on the VM host-t (made once, see the drill's header)
lab/gate.sh --only brand,names      # some of the steps
```

It prints `GO` or `NO GO` and keeps each step's log in `/tmp/gate`. Run it **when a change touches what a step covers** (the table says which); the full tier before a change to the backups, the storage, the boot or the deploy chain, and before the first deployment. A change to Proton Drive's copy is tried by hand ([proton-offsite/](proton-offsite/README.md): it needs a login).

| Step | Script | What it proves | Run it when you change |
|---|---|---|---|
| `smoke` | [smoke-test.sh](smoke-test.sh) | the host `lab` comes up whole: no failed unit, every name answers as it should, an unknown name gets no answer, Immich runs on its declared settings, the admin page answers on the VPN address, the database answers | anything in `nixos/modules/`, a version of nixpkgs, a container's digest |
| `brand` | [brand-test.sh](brand-test.sh), [brand-check.sh](brand-check.sh) with [brand-check.py](brand-check.py) and [sso-check.py](sso-check.py) | the brand is applied (Nextcloud, Immich, Jellyfin, Prometheus, the system), another repository's brand file overrides it, Jellyfin's web config is the image's but for the theme, the sign-on works from Immich through Nextcloud **in a browser**, Immich accepts its declared file | the brand, the single sign-on, Nextcloud, Immich, Jellyfin, Prometheus (**at every update of those**: [exceptions 4 to 6](../docs/exceptions.md)) |
| `names` | [compute-names.sh](compute-names.sh) | `<instance>.compute.<domain>` for a container and a VM (private, public, created later), the `.incus` DNS on the VPN address, silence for unknown names | `compute-names.nix`, `edge.nix`, Incus |
| `drill` (`--full`) | [restore-drill.sh](restore-drill.sh), with [drill-guest.sh](drill-guest.sh), [immich-seed.sh](immich-seed.sh) and [nixos-install.sh](nixos-install.sh) | the host is rebuilt from blank onto empty disks and restored from Borg and pgBackRest to the moment before the damage ([ADR 0014](../docs/decisions/0014-automation-and-restore-drill.md)) | storage, backup, encryption, the installer, the database |

## The tools

| | |
|---|---|
| [vm.sh](vm.sh) | the VMs (above) |
| [nixos-install.sh](nixos-install.sh) | installs a host of the flake onto a blank lab VM (disko, optionally LUKS and Secure Boot) |
| [serial-expect.py](serial-expect.py), [serial-run.py](serial-run.py), [serial-unlock.py](serial-unlock.py) | drive a VM through its serial console (a passphrase at boot, a command with no network) |
| [nix-cache-proxy.py](nix-cache-proxy.py) | a caching proxy for cache.nixos.org on the workstation. A lab VM reaches the Internet through QEMU's user-mode network, which drops big downloads and DNS lookups now and then (a 250 MB archive failed twelve times in a row), and the installer's retries wait twice as long each time. `TIDEPOOL_CACHE="http://10.0.2.2:5002 http://10.0.2.2:5001" lab/nixos-install.sh ...` makes the installer ask only the caches: port 5001 is this proxy; port 5002 is a directory served with `python3 -m http.server`, made on a lab VM that has already built the host with `nix copy --no-check-sigs --to "file:///home/lab/bincache?compression=zstd" <the host's toplevel and its disko script>` and copied out. The drill and a reinstall then take 5 minutes of downloads instead of an hour |
| [iso-boot-files.py](iso-boot-files.py) | pulls the kernel and initrd out of an installer ISO to boot it without a CD drive |
| [v0-migration-u25.sh](v0-migration-u25.sh), [v0-migration-u25-nextcloud-sequences.sql](v0-migration-u25-nextcloud-sequences.sql), [v0-replica/](v0-replica/) | the rehearsal of the move from v0 against a replica of its services ([the migration](../docs/migration-from-v0.md)); run it again before the real one |
| [proton-offsite/](proton-offsite/README.md) | the Proton Drive copy in a container, as it was tried |

## Experiments

[experiments/](experiments/README.md) holds the scripts that produced the numbers of the decision records: run once, kept as evidence, not maintained. Every ADR names the script behind its numbers; the table there maps them. The experiments of the dropped candidates are not published: the decision record says what was measured.
