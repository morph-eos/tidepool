#!/usr/bin/env python3
"""The documents hold together: every relative link points at a file, every script named in a document exists, every decision record and every lab tool is indexed, there is one list of what is
left to do. Run by the CI (`nix flake check`, check `docs`) and by hand: .github/scripts/check-docs.py [repository root]."""
import os, re, sys
root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", ".."))
os.chdir(root)
problems = []
def bad(msg): problems.append(msg)
mds = []
for dp, dn, fn in os.walk("."):
    dn[:] = [d for d in dn if d not in (".git", "result")]
    mds += [os.path.join(dp, f)[2:] for f in fn if f.endswith(".md")]
read = lambda p: open(p, encoding="utf-8").read()
nocode = lambda t: re.sub(r"```.*?```", "", t, flags=re.S)

# 1. relative links
for f in mds:
    for m in re.finditer(r"\]\(([^)#\s]+)(#[^)]*)?\)", nocode(read(f))):
        u = m.group(1)
        if u.startswith(("http://", "https://", "mailto:")): continue
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(f), u))): bad(f"{f}: broken link {u}")

# 2. scripts named as lab/..., outside the repository on purpose: the lab's own folder (~/lab/tidepool) and the VMs' home
OUTSIDE = ("lab/tools/", "lab/ptest/")
srcs = mds + [os.path.join(dp, f)[2:] for dp, dn, fn in os.walk(".") if ".git" not in dp for f in fn if f.endswith((".sh", ".nix", ".py", ".yml"))]
for f in srcs:
    try: t = read(f)
    except Exception: continue
    for m in re.finditer(r"(?<![A-Za-z0-9_.~/$-])lab/([A-Za-z0-9_./-]+\.(?:sh|py|sql))", t):
        p = "lab/" + m.group(1)
        if not p.startswith(OUTSIDE) and not os.path.exists(p): bad(f"{f}: names {p}, which does not exist")

# 3. the indexes
if os.path.exists("docs/README.md"):
    idx = read("docs/README.md")
    for f in sorted(os.listdir("docs/decisions")):
        if re.match(r"\d{4}-.*\.md$", f) and f != "0000-template.md" and f not in idx: bad(f"docs/README.md does not index docs/decisions/{f}")
    for f in sorted(os.listdir("docs")):
        if f.endswith(".md") and f != "README.md" and f not in idx: bad(f"docs/README.md does not mention docs/{f}")
if os.path.exists("lab/README.md"):
    idx = read("lab/README.md")
    for f in sorted(os.listdir("lab")):
        if f == "README.md" or os.path.isdir(os.path.join("lab", f)) and f in ("experiments",): continue
        if f not in idx: bad(f"lab/README.md does not mention lab/{f}")
if os.path.exists("lab/experiments/README.md"):
    idx = read("lab/experiments/README.md")
    for f in sorted(os.listdir("lab/experiments")):
        if f != "README.md" and f not in idx: bad(f"lab/experiments/README.md does not list {f}")

# 4. one list of what is left to do: nothing else keeps a TODO, and the decision records say what they decided, not what is left
for f in mds:
    if f.startswith("docs/decisions/") or f == "docs/pending.md": continue
    for i, l in enumerate(read(f).split("\n"), 1):
        if re.search(r"\b(TODO|FIXME)\b", l) or re.match(r"#+\s*(pending|to do|todo)\b", l, re.I): bad(f"{f}:{i}: a to-do outside docs/pending.md: {l.strip()[:80]}")

if problems:
    print("\n".join(problems)); print(f"{len(problems)} problem(s)"); sys.exit(1)
print(f"{len(mds)} documents: links, scripts and indexes hold")
