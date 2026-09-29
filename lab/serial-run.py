#!/usr/bin/env python3
"""Run shell commands on a VM's serial console socket and wait for them to finish.

Usage: serial-run.py <serial.sock> [--timeout SECONDS] <command> [<command> ...]

Used to bring up sshd on an installer that has no SSH access yet.  Each command is sent to the shell
followed by a unique end marker carrying the exit status; the script prints the output and exits with the
status of the last command.  It expects an already logged-in shell (the NixOS installer logs in automatically).
"""
import argparse
import re
import socket
import sys
import time
import uuid

ap = argparse.ArgumentParser()
ap.add_argument("sock")
ap.add_argument("commands", nargs="+")
ap.add_argument("--timeout", type=int, default=120)
args = ap.parse_args()

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(args.sock)
s.settimeout(1.0)


def read_until(pattern, timeout):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = s.recv(4096)
            if chunk:
                buf += chunk
                if re.search(pattern, buf.decode("utf-8", "replace")):
                    return buf.decode("utf-8", "replace")
        except socket.timeout:
            pass
    raise SystemExit("timeout waiting for %r; last output:\n%s" % (pattern, buf.decode("utf-8", "replace")[-800:]))


# Wake the console and wait until there is a shell prompt
# The prompt ends with colour escapes, so allow them (and trailing blanks) after the $ or #
s.sendall(b"\n")
read_until(r"[$#](?:\x1b\[[0-9;]*m)*\s*$", 300)

status = 0
for cmd in args.commands:
    mark = uuid.uuid4().hex[:8]
    s.sendall(f"{cmd}; echo __END{mark}__$?\n".encode())
    out = read_until(rf"__END{mark}__(\d+)\r?\n", args.timeout)
    m = re.search(rf"__END{mark}__(\d+)", out.split(f"echo __END{mark}", 1)[-1])
    status = int(m.group(1)) if m else 1
    text = re.sub(rf"__END{mark}__\d+", "", out.split(f"__END{mark}__$?", 1)[-1])
    print(re.sub(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", text).strip())
sys.exit(status)
