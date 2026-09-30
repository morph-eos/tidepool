# Gate G1: does the real machine work with NixOS? (live USB, nothing installed)

[ADR 0002](../decisions/0002-host-as-code.md) chose NixOS, and the lab has proved the host layer. It could not prove **this machine**: its GPU, the desktop, the drivers. This gate answers that in about
30 minutes, and **changes nothing on the server**: you boot from a USB stick, look, and power off. The disks are never mounted.

## Before you start

- [ ] A maintenance window of about 30 minutes (Immich, Jellyfin, Nextcloud and the rest are down while the machine runs the live system). Tell the household.
- [ ] A USB stick of 8 GB or more, prepared with Ventoy. **Everything on it is erased when Ventoy is installed.**
- [ ] A keyboard and a screen on the server (it is next to the TV: use it).
- [ ] The server is in a state you can restore by simply rebooting it. Nothing here changes that, but note the time of the last backup anyway (v0: 03:00 offsite, 04:00 local).
- [ ] Choose the image. The **minimal** ISO (1.7 GB) has no desktop: it answers the GPU questions. The **graphical** ISO (about 3 GB, GNOME) also answers "does the desktop start". If you want both answers, take the graphical one.

## 1. Prepare the stick (on the workstation), with Ventoy

With [Ventoy](https://www.ventoy.net/) the stick is formatted once and the images are then simply **copied** onto it as files: no `dd`, and both the minimal and the graphical ISO can live on the same stick.
The images are in `~/lab/tidepool/base/`; their checksums are verified after the download.

```bash
ls -la ~/lab/tidepool/base/nixos-26.05-minimal.iso ~/lab/tidepool/base/nixos-26.05-graphical.iso
```

Copy them to the big data partition that Ventoy creates on the stick (its label is `Ventoy`), then check the copy, because a half-written file is a classic cause of "it does not boot":

```bash
cp ~/lab/tidepool/base/nixos-26.05-*.iso /media/$USER/Ventoy/
sync
cd /media/$USER/Ventoy && sha256sum nixos-26.05-minimal.iso nixos-26.05-graphical.iso
#   compare with the two .sha256 files next to the originals
```

Installing Ventoy erases the stick, and choosing the wrong device there has the same danger as `dd`. You do that step yourself, from Ventoy's own tool, which shows the device and its size
before it writes; make sure it is the USB stick and not a disk.

**Two things to know about Ventoy and NixOS** ([ventoy: GRUB2 mode](https://www.ventoy.net/en/doc_grub2boot.html), [nixpkgs issue 245101](https://github.com/NixOS/nixpkgs/issues/245101)):

- NixOS installer ISOs have been reported not to boot in Ventoy's default mode after some GRUB updates. If it fails, at the Ventoy menu select the ISO, press **Enter**, and when it offers the boot mode choose
  **"Boot in grub2 mode"** (or press **Ctrl+R** on the list before choosing).
- **Secure Boot:** Ventoy and the NixOS image are not signed by the machine's keys. If the firmware has Secure Boot on, either turn it off for the test (and back on afterwards), or enrol Ventoy's key when the blue MOK screen appears.
  Look at the firmware settings first, so you know what you will be facing.

If a Ventoy boot keeps failing, the fallback is to write the minimal ISO alone with `dd` (`sudo dd if=nixos-26.05-minimal.iso of=/dev/sdX bs=4M status=progress conv=fsync`, after identifying the stick with `lsblk`
before and after plugging it in). That is the most boring way to boot, and it tells us whether the problem is Ventoy or the machine.

## 2. Boot the live system on the server

1. Plug the stick into the server, reboot, and open the one-time boot menu (usually F12, F11, F8 or Esc; the key is shown at power-on).
2. Pick the USB entry. On the NixOS menu choose the first entry (the default LTS kernel).
3. The minimal ISO logs in as `nixos` on its own. The graphical one starts a GNOME session.

Write down anything odd: a black screen, a resolution that is wrong, a boot that hangs. Those are results too.

## 3. What to check (read-only)

Open a terminal (on the minimal ISO you are already in one). Run these in order and note the answers.

**The machine, without touching any disk**

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS     # your data disks should appear; nothing should be mounted
nproc; free -h | head -2
```

**The GPU (this is the point of the gate)**

```bash
lspci -k | grep -EA3 'VGA|Display|3D'                  # which GPU, and which kernel driver is bound (i915, xe, amdgpu, ...)
ls -l /dev/dri/                                        # card0 and renderD128 must exist
nix-shell -p libva-utils --run vainfo                  # needs the network; lists the VA-API profiles
```

`vainfo` should list profiles such as `VAProfileH264Main`, `VAProfileHEVCMain`, `VAProfileAV1Profile0` with entrypoints `VAEntrypointVLD` (decode) and `VAEntrypointEncSlice` (encode).
If it says it cannot open the driver, try the driver by name:

```bash
LIBVA_DRIVER_NAME=iHD nix-shell -p libva-utils intel-media-driver --run vainfo     # Intel, Broadwell and newer
LIBVA_DRIVER_NAME=radeonsi nix-shell -p libva-utils --run vainfo                   # AMD
```

**Hardware transcoding the way the containers will do it**

```bash
nix-shell -p ffmpeg-full --run "ffmpeg -hide_banner -vaapi_device /dev/dri/renderD128 -f lavfi -i testsrc=duration=5:size=1280x720:rate=30 -vf 'format=nv12,hwupload' -c:v h264_vaapi -y /tmp/vaapi-test.mp4 && ls -l /tmp/vaapi-test.mp4"
```

A non-empty `/tmp/vaapi-test.mp4` and no error means the GPU can encode. This is the same path Jellyfin uses.

**Only on the graphical ISO: the desktop**

- Does GNOME start, at the right resolution, on the TV?
- Does sound come out over HDMI?
- Do a video and a window animation play without tearing?

**Network and the rest**

```bash
ip -br addr; ping -c2 1.1.1.1                           # the connection the server really uses, WiFi or cable
```

## 4. Finish

```bash
sudo poweroff
```

Remove the stick, power on, and check that the services are back (a browser on `immich`, `jellyfin`, `cloud` is enough). Nothing was changed, so nothing needs undoing.

## What to bring back

Paste me, as text or a photo of the screen:

1. the `lspci -k` block for the GPU, and the `ls -l /dev/dri/` line;
2. the profile list from `vainfo` (or the error);
3. whether the ffmpeg test produced a file;
4. for the graphical ISO, yes or no to each desktop question;
5. anything odd at boot.

## Decision rule

| Result | What it means |
|---|---|
| `/dev/dri` present, `vainfo` lists H.264 and HEVC, the ffmpeg test works | **G1 and G2 pass.** The GPU side of NixOS is fine, and the containers will get the same device |
| The GPU is found but `vainfo` fails for one driver and works with another | passes, with the right driver recorded in the configuration |
| No `/dev/dri`, or the driver is not bound | **stop**: the kernel or firmware needs work first (`hardware.enableAllFirmware`, a newer kernel); we look together before going on |
| GNOME does not start or the display is wrong | not fatal for the server side; it decides how the media-center part is done |
