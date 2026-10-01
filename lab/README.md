# lab/

Tooling for the throwaway VMs used by the experiments. See [the method](../docs/method.md) for why, and
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

## Scripts of the experiments

Every ADR names the script that produced its numbers (`lab/<phase>-bakeoff.sh` and friends); the ones that are generic (`nixos-install.sh`, `*-bakeoff.sh`, `immich-seed.sh`) are in this directory. The scripts that drive one rejected candidate (for example `lab/databasus/`, the UI automation of Databasus) stay on that candidate's experiment branch (`exp/<phase>-<candidate>`, tag `exp-<phase>-<candidate>`).
