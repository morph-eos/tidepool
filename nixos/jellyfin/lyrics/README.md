# Time-synced lyrics for a music library

Two small scripts that prepare the lyrics a player shows line by line. They are **prototypes**: written for one library, run by hand, not part of the system's configuration ([ADR 0023](../../../docs/decisions/0023-floppy.md)).

| Script | What it does |
|---|---|
| `lrc_fill.py ROOT` | For each track under `ROOT`, writes a sidecar `.lrc` (same name, next to the file) with the time-synced lyrics from [LRCLIB](https://lrclib.net), a free, open lyrics service. A `.lrc` that already has timestamps is left alone; a missing one is filled; a plain-text one is replaced. |
| `lrc2ttml.py SRC.lrc DST.ttml [LANG]` | Turns a time-synced `.lrc` into a TTML file with a Latin transliteration track beside the original lines, for a client that can show it. |

## Use

```sh
nixos/jellyfin/lyrics/lrc_fill.py /path/to/music --dry                 # look up and count, write nothing
nixos/jellyfin/lyrics/lrc_fill.py /path/to/music --backup ~/lrc-old    # write; a plain .lrc that is replaced is copied to ~/lrc-old first
nixos/jellyfin/lyrics/lrc_fill.py /path/to/music --limit 50            # stop after 50 files written
nixos/jellyfin/lyrics/lrc2ttml.py song.lrc song.ttml ko
```

`lrc_fill.py` prints what it did (`already_synced`, `upgraded_plain`, `filled_missing`, `not_found`) and the first tracks that LRCLIB had nothing for (instrumentals and little-known covers, mostly). A second run over the same library finds nothing to do.

## Dependencies

- Python 3 (standard library only) and `ffprobe` (part of ffmpeg), for `lrc_fill.py`.
- `lrc2ttml.py` romanizes Korean with the third-party library [`korean_romanizer`](https://pypi.org/project/korean-romanizer/) (`pip install korean_romanizer`); it is **not** in the standard library and nothing else needs it.

## Where to run them

The media directories are mounted **read-only** into Jellyfin's container ([ADR 0011](../../../docs/decisions/0011-services.md)), so these scripts do not run in the container and Jellyfin never writes to the library. Run them as a user that can write to the library, on the machine or on any computer that has the files, then let Jellyfin rescan the library so that it picks the `.lrc` files up.

## Being a good client

LRCLIB is run by volunteers. The script names itself in its `User-Agent`, waits a fraction of a second between requests and writes nothing it did not find; a library of thousands of tracks is thousands of requests, so run it once, with `--limit` while trying it, and not in a loop.

## What was tried

On a small made-up library (a few silent tracks with the tags of well-known songs, one with a plain `.lrc`, one with a timed one, one that no service knows): `--dry` counted and wrote nothing; a real run filled the missing file, replaced the plain one after copying it to the backup directory, left the timed one alone and reported the unknown track; a second run found nothing to do; `--limit 1` stopped after one file. `lrc2ttml.py` was run on a two-line Korean file and the result is well-formed XML with the romanization (`annyeonghaseyo`, `saranghaeyo`). How a given client shows the TTML was not tried here.
