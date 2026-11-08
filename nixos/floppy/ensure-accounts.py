#!/usr/bin/env python3
"""Make sure every enabled Nextcloud user has a Floppy account, linked to their single sign-on identity.

Nextcloud is the list of people. For each enabled user, Floppy gets an account with the same name (no password: the only way in
is the sign-in through Nextcloud), and a social-account row that ties it to the identity Nextcloud sends (provider `sso`, the
user id as `sub`), so the person's first sign-in lands in this account instead of making another. A user that already has
an account (made by a first sign-in, or by an earlier run) is left alone. Disabled users get nothing; accounts are never deleted.

Runs as root: it asks Nextcloud's command line for the users and Floppy's container to make the rows.
  ensure-accounts.py --occ PATH --podman PATH [--container floppy] [--dry-run]
"""
import argparse
import json
import subprocess
import sys

DJANGO = r'''
import json
from django.contrib.auth import get_user_model
from django.db import transaction
from allauth.socialaccount.models import SocialAccount
U = get_user_model()
users = json.loads(%r)
made = linked = 0
for u in users:
    name = u["id"]
    with transaction.atomic():
        user = U.objects.filter(username__iexact=name).first()
        if user is None:
            user = U(username=name, email=u.get("email") or "")
            user.set_unusable_password()
            user.save()
            made += 1
        if not SocialAccount.objects.filter(provider="sso", uid=name).exists() and not SocialAccount.objects.filter(user=user, provider="sso").exists():
            SocialAccount.objects.create(user=user, provider="sso", uid=name, extra_data={})
            linked += 1
print("floppy-accounts: made %%d, linked %%d, of %%d Nextcloud users" %% (made, linked, len(users)))
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--occ", required=True)
    ap.add_argument("--podman", required=True)
    ap.add_argument("--container", default="floppy")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    running = subprocess.run([a.podman, "inspect", "-f", "{{.State.Running}}", a.container], capture_output=True, text=True)
    if running.returncode != 0 or running.stdout.strip() != "true":
        print("Floppy is not running: nothing to do now")   # a restart (a deploy) is not a failure; the next run finds it up
        return
    out = subprocess.run([a.occ, "user:list", "--output=json", "--info"], capture_output=True, text=True, check=True).stdout
    users = [{"id": v["user_id"], "email": v.get("email") or ""} for v in json.loads(out).values() if v.get("enabled") and v.get("user_id")]
    if a.dry_run:
        print(f"{len(users)} enabled Nextcloud users: {', '.join(u['id'] for u in users)}")
        return
    r = subprocess.run([a.podman, "exec", "-i", a.container, "python", "manage.py", "shell"], input=DJANGO % json.dumps(users), capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.startswith("floppy-accounts:")]
    if r.returncode != 0 or not lines:
        sys.exit("Floppy did not make the accounts:\n" + (r.stderr or r.stdout)[-800:])
    print(lines[-1])


if __name__ == "__main__":
    main()
