#!/usr/bin/env python3
"""Turn a time-synced .lrc into a TTML file that carries a Latin transliteration track beside the lyrics (a client that reads TTML can show the romanized line under the original).

Korean is romanized with the third-party Python library `korean_romanizer` (pip install korean_romanizer): it is not in the standard library and is needed only for this script.

  lrc2ttml.py SRC.lrc DST.ttml [LANG]        LANG is the language code of the lyrics, `ko` by default
"""
import argparse
import html
import re
import sys

from korean_romanizer.romanizer import Romanizer


def seconds(m):
    return int(m.group(1)) * 60 + float(m.group(2))


def stamp(t):
    return "%02d:%06.3f" % (int(t // 60), t % 60)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("lang", nargs="?", default="ko")
    a = ap.parse_args()
    rows = []
    for line in open(a.src, encoding="utf8"):
        m = re.match(r"\[(\d+):(\d+(?:\.\d+)?)\](.*)", line.rstrip("\n"))
        if m and m.group(3).strip():
            rows.append((seconds(m), m.group(3).strip()))
    lines, romanized = [], []
    for i, (t, text) in enumerate(rows):
        end = rows[i + 1][0] if i + 1 < len(rows) else t + 4
        lines.append(f'      <p begin="{stamp(t)}" end="{stamp(end)}" itunes:key="L{i + 1}">{html.escape(text)}</p>')
        romanized.append(f'            <text for="L{i + 1}">{html.escape(Romanizer(text).romanize())}</text>')
    with open(a.dst, "w", encoding="utf8") as out:
        out.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
  <head><metadata>
    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
      <transliterations>
        <transliteration xml:lang="{a.lang}-Latn">
''' + "\n".join(romanized) + f'''
        </transliteration>
      </transliterations>
    </iTunesMetadata>
  </metadata></head>
  <body xml:lang="{a.lang}"><div>
''' + "\n".join(lines) + '''
  </div></body>
</tt>
''')
    print(len(rows), "lines")


if __name__ == "__main__":
    sys.exit(main())
