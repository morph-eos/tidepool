#!/usr/bin/env python3
# The single sign-on, end to end in a browser: Immich's "Login with <brand>" button, Nextcloud's login, and back into Immich as a user created by the first login.
# Usage: sso-check.py <chromium> <screenshot dir> <nextcloud user> <password>     (through the tunnel of lab/brand-check.sh)
import asyncio, sys
from playwright.async_api import async_playwright
CHROME, SHOTS, USER, PASSWORD = sys.argv[1:5]
MAP = "MAP photos.lab.test 127.0.0.1:18444, MAP cloud.lab.test 127.0.0.1:18444"
fails = 0
def ok(cond, text):
    global fails
    print(("PASS " if cond else "FAIL ") + text)
    if not cond: fails += 1
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=CHROME, args=["--host-resolver-rules=" + MAP])
        ctx = await b.new_context(ignore_https_errors=True, viewport={"width": 1100, "height": 700}); pg = await ctx.new_page()
        await pg.goto("https://photos.lab.test/auth/login", wait_until="networkidle"); await pg.wait_for_timeout(1500)
        btn = pg.get_by_role("button", name="Login with Tidepool")
        ok(await btn.count() == 1, "Immich offers 'Login with Tidepool'")
        await btn.click()
        try:
            await pg.wait_for_url("**cloud.lab.test/login**", timeout=20000)
            ok(True, "the button leads to Nextcloud's login (the discovery and the client work)")
        except Exception:
            ok(False, "the button leads to Nextcloud's login (got " + pg.url[:80] + ")"); await b.close(); sys.exit(1)
        await pg.fill("#user", USER); await pg.fill("#password", PASSWORD)
        await pg.click("button[type=submit]")
        try:
            await pg.wait_for_url("**photos.lab.test/**", timeout=25000)
        except Exception:
            pass
        await pg.wait_for_timeout(3000)
        await pg.screenshot(path=f"{SHOTS}/sso-immich-in.png")
        body = await pg.inner_text("body")
        ok(pg.url.startswith("https://photos.lab.test/") and "/auth/login" not in pg.url, "Nextcloud sends the user back to Immich, logged in (" + pg.url[:60] + ")")
        ok("SSO Test" in body or USER in body, "Immich created the user from Nextcloud's account")
        await b.close()
    print(f"{fails} failed"); sys.exit(1 if fails else 0)
asyncio.run(main())
