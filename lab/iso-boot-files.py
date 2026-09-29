#!/usr/bin/env python3
"""Extract the kernel, the initrd and the kernel command line of a NixOS installer ISO.

Usage: iso-boot-files.py <iso> <output-dir>

The installer can then be booted with QEMU's -kernel/-initrd/-append and a serial console, with no screen (the
boot menu inside the ISO only speaks VGA).  The first entry of isolinux.cfg (label "boot") is the default installer:
its LINUX, APPEND and INITRD lines give the files and the command line.  Writes <output-dir>/bzImage and
<output-dir>/initrd, and prints the command line on stdout (without any console= option).
"""
import io
import re
import sys

import pycdlib

iso_path, out = sys.argv[1], sys.argv[2]
iso = pycdlib.PyCdlib()
iso.open(iso_path)


def read(path):
    buf = io.BytesIO()
    iso.get_file_from_iso_fp(buf, rr_path=path)  # Rock Ridge keeps the long lowercase names
    return buf.getvalue()


cfg = read("/isolinux/isolinux.cfg").decode("utf-8", "replace")
block = re.search(r"^LABEL boot\s*$(.*?)(?=^LABEL )", cfg, re.M | re.S)
if not block:
    raise SystemExit("no 'LABEL boot' entry in isolinux.cfg")
entry = block.group(1)


def field(name):
    m = re.search(rf"^{name}\s+(.+?)\s*$", entry, re.M)
    if not m:
        raise SystemExit(f"no {name} line in the boot entry")
    return m.group(1)


kernel, initrd, append = field("LINUX"), field("INITRD"), field("APPEND")
for src, dest in ((kernel, "bzImage"), (initrd, "initrd")):
    with open(f"{out}/{dest}", "wb") as f:
        f.write(read(re.sub(r"/{2,}", "/", src)))

print(" ".join(re.sub(r"\bconsole=\S+", "", append).split()))
