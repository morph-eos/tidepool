# G1 results (live USB on the real server)

Run on 2026-09-30 with the graphical ISO booted from a Ventoy stick, on the server's own screen. Nothing was installed and no server disk was mounted (`lsblk` showed only the live image and the stick as mounted).
Hardware models are left out on purpose, as everywhere in this repository.

| Check | Result |
|---|---|
| Boot from the Ventoy stick | **works**; the image's own boot menu appears and the default entry (GNOME, LTS kernel) starts |
| GNOME on the TV | **works**, at a usable resolution |
| Sound over HDMI | **works** |
| Wi-Fi in the live session | **works** (the network menu is there and `nix-shell` downloaded packages) |
| GPU found | an **Intel discrete GPU**, bound to the **`i915`** driver (the `xe` module is also present) |
| `/dev/dri` | `card1` and `renderD128` exist, and the render node is readable by everyone |
| `vainfo`, first try | failed: it looked for the `iHD` and `i965` drivers in the standard paths, found neither and gave up. The live image does not ship the VA-API user-space driver, so this said nothing about the hardware |
| `vainfo`, with the `iHD` driver supplied | **works**: the driver opens (Intel iHD 26.1.6) and lists **decode and low-power encode** entry points for MPEG-2 (decode), H.264, HEVC (Main, Main 10, Main 12, 4:2:2, 4:4:4 and the screen-content profiles), VP9 (profiles 0 to 3), JPEG and **AV1** |
| ffmpeg hardware encode | not run (the profile list already shows the encode entry points; the ffmpeg run is the practical confirmation, and can be done in the next maintenance window or on the installed system) |
| Disks | every disk visible, **nothing mounted** |
| Boot log | one red **`FAILED`: "Load Kernel Modules"**. **Harmless**: the live image tries to load the Hyper-V guest modules (`hv_vmbus`, `hv_netvsc`, `hv_utils`, `hv_storvsc`, `hv_balloon`), which answer "busy" or "no such device" on real hardware; the service succeeded on its second run. An installed system only loads what its configuration lists |

## Reading

**G1 passes for the GPU.** The machine boots the image, the desktop and the sound work, the GPU is bound to a current kernel driver with a render node, and the media driver opens and lists hardware decode and encode for
every codec the stack uses (H.264, HEVC, VP9, AV1). The one failure seen at boot is a known, cosmetic consequence of the live image, not of the machine.

What is **not** proved by G1 and is checked later, on the installed system or in the lab: the actual ffmpeg encode through `/dev/dri` from inside a container (gate G2), and the keyring behavior of the Proton Drive CLI in a real desktop session (gate G3).
