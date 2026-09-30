# G1 results (live USB on the real server), partial

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
| `vainfo` | **failed, but not as a hardware verdict**: it looked for the `iHD` and `i965` drivers in the standard paths, found neither and gave up. The live image does not ship the VA-API user-space driver. To repeat with the driver supplied |
| ffmpeg hardware encode | not run yet |
| Disks | every disk visible, **nothing mounted** |
| Boot log | one red **`FAILED`: "Load Kernel Modules"** (`systemd-modules-load.service`) in the initrd. The system carried on and reached the desktop. Which module failed is not known yet |

## Still to do in the same session

```bash
# 1. the VA-API driver for Intel GPUs from this generation, supplied explicitly
P=$(nix-build '<nixpkgs>' -A intel-media-driver --no-out-link); echo "$P"
LIBVA_DRIVERS_PATH=$P/lib/dri LIBVA_DRIVER_NAME=iHD nix-shell -p libva-utils --run vainfo

# 2. the encode test (same path Jellyfin uses)
LIBVA_DRIVERS_PATH=$P/lib/dri LIBVA_DRIVER_NAME=iHD nix-shell -p ffmpeg-full --run "ffmpeg -hide_banner -vaapi_device /dev/dri/renderD128 -f lavfi -i testsrc=duration=5:size=1280x720:rate=30 -vf 'format=nv12,hwupload' -c:v h264_vaapi -y /tmp/vaapi-test.mp4 && ls -l /tmp/vaapi-test.mp4"

# 3. which module failed to load
journalctl -b -u systemd-modules-load --no-pager | tail -20
```

## Reading

G1 is **half answered**: the machine boots the image, shows the desktop and has a GPU with a render node and a current kernel driver. The part that decides the gate, **hardware encode**, is still unproven.
A failed `vainfo` on a live image without the driver says nothing about the hardware, which is why the driver is supplied by hand in step 1.
