#!/usr/bin/env python3
"""A caching proxy for cache.nixos.org, for the lab's installs and drills.

Why: a lab VM reaches the Internet through QEMU's user-mode network, which drops big downloads now and then (a 250 MB archive failed twelve times in a row, and Nix's retries wait twice as long
each time). The workstation's own link is fine. This proxy runs on the workstation: the VM asks it (10.0.2.2:PORT), it fetches from cache.nixos.org with its own retries and resume, keeps what it
fetched on disk, and serves it. The archives are not changed, so their signatures stay valid.

Usage:  lab/nix-cache-proxy.py [port] [cache dir]        (defaults: 5001, ~/lab/tidepool/nixcache)
        TIDEPOOL_CACHE=http://10.0.2.2:5001 lab/nixos-install.sh host-t     # the installer then asks the proxy first
"""
import http.server, os, shutil, socketserver, sys, threading, time, urllib.error, urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5001
DIR = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/lab/tidepool/nixcache")
UPSTREAM = "https://cache.nixos.org"
os.makedirs(DIR, exist_ok=True)
locks, locks_guard = {}, threading.Lock()

def fetch(path, dest):
    """Download UPSTREAM+path into dest, resuming and retrying; returns the status (200, or an error for Nix to act on).
    A small file (a .narinfo) gets a few short tries, an archive more, with resume; a failure is a 502 (never a 404: Nix would take it for 'not in this cache')."""
    part = dest + ".part"
    small = path.endswith((".narinfo", "nix-cache-info"))
    tries, timeout = (6, 15) if small else (10, 30)
    for attempt in range(tries):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        req = urllib.request.Request(UPSTREAM + path, headers={"Range": f"bytes={have}-"} if have else {})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                if have and r.status == 200: have = 0   # the server ignored the range: start again
                want = int(r.headers["Content-Length"]) if r.headers.get("Content-Length") else None   # read(n) does not complain when the link drops early: the length is checked
                with open(part, "ab" if have else "wb") as f: shutil.copyfileobj(r, f, 1 << 20)
                if want is not None and os.path.getsize(part) - have != want: raise OSError("truncated")
            os.replace(part, dest); return 200
        except urllib.error.HTTPError as e:
            if e.code == 416 and os.path.exists(part): os.replace(part, dest); return 200   # it was complete
            if e.code in (403, 404): return e.code
            time.sleep(min(2 ** attempt, 10))
        except Exception:
            time.sleep(min(2 ** attempt, 10))
    return 502

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_HEAD(self): self.do_GET(head=True)
    def reply(self, code):
        self.send_response(code); self.send_header("Content-Length", "0"); self.end_headers()
    def serve_file(self, dest, head):
        size = os.path.getsize(dest); start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else 0; end = int(b) if b else size - 1; status = 206
        self.send_response(status)
        self.send_header("Content-Length", str(end - start + 1)); self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        if status == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head: return
        with open(dest, "rb") as f:
            f.seek(start); left = end - start + 1
            while left > 0:
                chunk = f.read(min(1 << 20, left))
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): return
                left -= len(chunk)
    def stream(self, path, dest):
        """The first asker of an archive gets it AS IT ARRIVES (Nix gives up on a download that sends nothing for a minute): the bytes go to the client and to the disk together;
        if the upstream link drops, the download resumes from the byte it had reached. Returns True when the answer has been sent."""
        part = dest + ".part"; sent = 0; total = None
        if os.path.exists(part): os.remove(part)
        for attempt in range(12):
            req = urllib.request.Request(UPSTREAM + path, headers={"Range": f"bytes={sent}-"} if sent else {})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    if total is None:
                        total = int(r.headers["Content-Length"])
                        self.send_response(200); self.send_header("Content-Length", str(total)); self.send_header("Content-Type", "application/octet-stream"); self.end_headers()
                    elif r.status != 206: raise OSError("the server ignored the range")
                    with open(part, "ab" if sent else "wb") as f:
                        while True:
                            chunk = r.read(1 << 16)
                            if not chunk: break
                            f.write(chunk); sent += len(chunk)
                            try: self.wfile.write(chunk)
                            except (BrokenPipeError, ConnectionResetError): self.close_connection = True   # the client left: keep filling the disk for the next one
                if sent == total: os.replace(part, dest); return True
                raise OSError("truncated")
            except urllib.error.HTTPError as e:
                if total is None:
                    self.reply(e.code if e.code in (403, 404) else 502); return True
                time.sleep(min(2 ** attempt, 10))
            except Exception:
                time.sleep(min(2 ** attempt, 10))
        self.close_connection = True   # the client's length is not met: it will see a short body and ask again
        return True
    def do_GET(self, head=False):
        path = self.path.split("?")[0]
        if ".." in path or not path.startswith("/"): self.send_error(400); return
        dest = os.path.join(DIR, path.lstrip("/").replace("/", "__"))
        with locks_guard: lock = locks.setdefault(dest, threading.Lock())
        with lock:
            if not os.path.exists(dest):
                if path.endswith(".nar.zst") and not head and not self.headers.get("Range"):
                    self.stream(path, dest); return
                code = fetch(path, dest)
                if code != 200: self.reply(code); return
        self.serve_file(dest, head)

class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True; allow_reuse_address = True; request_queue_size = 256
print(f"caching cache.nixos.org on 127.0.0.1:{PORT}, in {DIR}", flush=True)
S(("127.0.0.1", PORT), H).serve_forever()
