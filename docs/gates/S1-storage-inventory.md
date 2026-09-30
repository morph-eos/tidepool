# S1: what is on the disks today (read-only)

The disk layout ([ADR 0005](../decisions/0005-storage-layout-and-filesystem.md)) cannot be decided from opinions: it depends on how big each kind of data is, how fast it grows, and what must be
protected how. This gate collects those numbers. It runs on the **real server**, changes nothing, and takes about ten minutes. No maintenance window is needed.

Run the commands in a terminal on the server. **You do not need to paste file names**: sizes and the top-level folder names are enough, and you can replace any name you do not want to share with `X`.

## 1. The disks and what they are

```bash
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS | grep -v loop
df -h / /mnt/nas /mnt/nas2 /mnt/timemachine 2>/dev/null
```

## 2. How full each one is, by top-level folder

```bash
sudo du -xsh /mnt/nas/* 2>/dev/null | sort -h | tail -15
sudo du -xsh /mnt/nas2/* 2>/dev/null | sort -h | tail -15
sudo du -xsh /mnt/nas2/docker/data/* 2>/dev/null | sort -h | tail -15      # where the services keep their data
```

## 3. The data that matters most, separately

```bash
sudo du -sh /mnt/nas2/docker/data/immich /mnt/nas2/docker/data/nextcloud /mnt/nas2/docker/data/vaultwarden /mnt/nas2/docker/data/syncthing 2>/dev/null
sudo du -sh /mnt/nas/backup 2>/dev/null
sudo du -sh /mnt/timemachine 2>/dev/null
```

## 4. How fast the important data grows

```bash
# photos added in the last 90 days, by size (works if the Immich library is a plain folder tree)
sudo find /mnt/nas2/docker/data/immich -type f -mtime -90 -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {printf "%.1f GB in the last 90 days\n", s/1073741824}'
```

## 5. The health of the disks

```bash
docker logs --tail 12 smartcheck 2>&1        # the v0 container reports SMART status and temperature
```

## What to bring back

The output of steps 1 to 4 (step 5 if it shows a warning), with any name you do not want to share replaced. With it I can fill the table below and propose a layout with real numbers.

| Kind of data | Where today | Size today | Growth | Must it be protected how? |
|---|---|---|---|---|
| Photos (Immich) | | | | offsite + local, near-zero loss for the database |
| Nextcloud files | | | | offsite + local |
| Databases and Vaultwarden | | | | near-zero loss (tier 1) |
| Phone backups (WebDAV), Syncthing | | | | local + offsite |
| Time Machine | | | | local only, replaceable |
| Media library | | | | local on two disks, **not** offsite |
| Docker volumes, VM disks | | | | rebuilt from code where possible; VM disks are in no backup today |
| Backups themselves | | | | the target, not a source |
