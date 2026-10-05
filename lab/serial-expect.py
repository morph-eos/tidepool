#!/usr/bin/env python3
"""lab/serial-expect.py — answer prompts on a lab VM's serial console (the initrd asking for a LUKS passphrase) until a final pattern shows.
usage: serial-expect.py <serial.sock> <final-regex> [--send REGEX=TEXT ...] [--timeout S]
Each --send waits for REGEX in the console output and types TEXT and a newline (every time it shows again). Prints what it saw; exit 0 when the final pattern appears, 1 on timeout."""
import re, socket, sys, time
sock, final = sys.argv[1], re.compile(sys.argv[2])
sends, timeout, i = [], 600, 3
while i < len(sys.argv):
    if sys.argv[i] == "--send":
        r, t = sys.argv[i + 1].split("=", 1); sends.append((re.compile(r), t)); i += 2
    elif sys.argv[i] == "--timeout":
        timeout = int(sys.argv[i + 1]); i += 2
    else:
        i += 1
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(1)
buf, answered, t0 = "", [0] * len(sends), time.time()
seen_len = 0
while time.time() - t0 < timeout:
    try:
        d = s.recv(4096)
        if not d: break
        buf += d.decode(errors="replace")
    except socket.timeout:
        pass
    for k, (r, t) in enumerate(sends):
        m = list(r.finditer(buf))
        if len(m) > answered[k]:
            answered[k] = len(m)
            time.sleep(0.5); s.send((t + "\n").encode())
            print(f"[{int(time.time()-t0)} s] answered prompt {r.pattern!r}", flush=True)
    if final.search(buf):
        print(f"[{int(time.time()-t0)} s] final pattern seen", flush=True)
        tail = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", buf)[-600:]
        print(tail)
        sys.exit(0)
print("timeout; last console output:\n" + re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", buf)[-800:]); sys.exit(1)
