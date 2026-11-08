#!/usr/bin/env python3
"""Fill or upgrade the sidecar .lrc files of a music library with time-synced lyrics from LRCLIB (https://lrclib.net).

For each track (flac, mp3, m4a, opus, ogg) under the root: a .lrc that already has timestamps is left alone; a missing one, or a plain-text one, is written
from LRCLIB's synced lyrics when the service has them (looked up by artist, title, album and length, then by a search that accepts a length within 3 seconds).
A file is written whole under a temporary name and renamed, so a reader never sees half of one. Needs `ffprobe` (from ffmpeg) to read the tags and the length.

  lrc_fill.py ROOT [--dry] [--backup DIR] [--limit N]

  --dry        look up and count, write nothing
  --backup DIR before a plain .lrc is replaced, copy the old one under DIR with its path relative to ROOT (outside the library)
  --limit N    stop after N files are written
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

# an honest name for the service's operators, and a pause between requests: a library of thousands of tracks is thousands of calls
UA = {"User-Agent": "tidepool-lrc-fill/0.1 (a small script for a personal library)"}
PAUSE = 0.2
TRACKS = (".flac", ".mp3", ".m4a", ".opus", ".ogg")
TIMESTAMP = re.compile(r"\[\d{1,2}:\d{2}[.:]\d{2,3}\]")
FEAT = re.compile(r"\s*[\(\[]\s*(feat|ft|with)\.?[^\)\]]*[\)\]]", re.I)


def get(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=20))


def tags(path):
    out = subprocess.run(["ffprobe", "-v", "quiet", "-print_format", "json", "-show_entries", "format=duration:format_tags", path], capture_output=True).stdout
    fmt = json.loads(out)["format"]
    return {k.lower(): v for k, v in fmt.get("tags", {}).items()}, float(fmt.get("duration", 0))


def synced_lyrics(artist, title, album, seconds):
    clean = FEAT.sub("", title).strip()
    for a, t in [(artist, title), (artist, clean)]:
        try:
            r = get("https://lrclib.net/api/get?" + urllib.parse.urlencode(dict(artist_name=a, track_name=t, album_name=album, duration=int(seconds))))
            if r.get("syncedLyrics"):
                return r["syncedLyrics"]
        except urllib.error.HTTPError:
            pass
        time.sleep(PAUSE)
    try:
        found = [x for x in get("https://lrclib.net/api/search?" + urllib.parse.urlencode(dict(track_name=clean, artist_name=artist)))
                 if x.get("syncedLyrics") and abs((x.get("duration") or 0) - seconds) <= 3]
        if found:
            return found[0]["syncedLyrics"]
    except Exception:
        pass
    time.sleep(PAUSE)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root")
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--backup")
    ap.add_argument("--limit", type=int)
    a = ap.parse_args()
    written = 0
    stats = {"already_synced": 0, "upgraded_plain": 0, "filled_missing": 0, "not_found": 0}
    missing = []
    for d, _, files in os.walk(a.root):
        for f in sorted(files):
            if not f.lower().endswith(TRACKS):
                continue
            path = os.path.join(d, f)
            lrc = os.path.splitext(path)[0] + ".lrc"
            had = os.path.exists(lrc)
            if had and TIMESTAMP.search(open(lrc, encoding="utf8", errors="ignore").read()):
                stats["already_synced"] += 1
                continue
            t, seconds = tags(path)
            lyrics = synced_lyrics((t.get("artist") or "").split(";")[0].strip(), t.get("title") or "", t.get("album") or "", seconds)
            if not lyrics:
                stats["not_found"] += 1
                missing.append(f)
                continue
            if not a.dry:
                if had and a.backup:
                    dst = os.path.join(a.backup, os.path.relpath(lrc, a.root))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    if not os.path.exists(dst):
                        shutil.copy2(lrc, dst)
                fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
                os.write(fd, lyrics.encode("utf8"))
                os.fchmod(fd, 0o664)
                os.close(fd)
                os.replace(tmp, lrc)
                written += 1
            stats["upgraded_plain" if had else "filled_missing"] += 1
            if a.limit and written >= a.limit:
                break
        if a.limit and written >= a.limit:
            break
    print(json.dumps(stats))
    print("not found:", missing[:10])


if __name__ == "__main__":
    sys.exit(main())
