#!/usr/bin/env python3
"""lab/serial-unlock.py — type a LUKS passphrase at every prompt of the initrd until the login prompt shows, whatever the timing.
usage: serial-unlock.py <serial.sock> <serial.log> <passphrase> <timeout> <log-offset>
The prompt is read from the VM's console log (from <log-offset> on), so a prompt that was printed BEFORE this script connected is answered too (serial-expect.py only sees
output that arrives after it connects, and a passphrase typed too early is lost). A prompt that stays unanswered for 15 s is answered again. Exit 0 when the login prompt shows, 1 on timeout."""
import socket, sys, time, re
sock, log, pp, timeout, off = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(1)
def tail():
    d = open(log, 'rb').read()[off:].decode(errors='replace')
    return re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', d).replace('\r', '')
t0 = time.time(); last = 0; sent = 0; seen_prompts = 0
while time.time() - t0 < timeout:
    try: s.recv(4096)
    except socket.timeout: pass
    t = tail()
    if re.search(r'\n\S+ login: ?$', t.rstrip(' ') + '') or re.search(r'login: $', t): print(f'login after {int(time.time()-t0)} s, passphrase typed {sent} times'); sys.exit(0)
    n = len(re.findall(r'Please enter passphrase', t))
    # a new prompt, or the last prompt has been waiting for 15 s without an answer
    if (n > seen_prompts) or (n and time.time() - last > 15 and re.search(r'Please enter passphrase[^\n]*$', t.split('\n')[-1] or t.split('\n')[-2] if t.strip() else '')):
        seen_prompts = max(seen_prompts, n); time.sleep(0.7); s.send((pp + '\n').encode()); sent += 1; last = time.time()
print(f'NO login after {timeout} s, passphrase typed {sent} times'); sys.exit(1)
