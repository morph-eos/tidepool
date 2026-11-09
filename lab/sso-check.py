#!/usr/bin/env python3
# The single sign-on, end to end in a browser: Immich's sign-in button, Nextcloud's login, and back into Immich as a user created by the first login; then the same for Floppy
# (track.<domain>), in a browser that has no session: its login page offers only the sign-on, and the first login makes the account.
# Usage: sso-check.py <chromium> <screenshot dir> <nextcloud user> <password>     (through the tunnel of lab/brand-check.sh)
import asyncio, sys
from playwright.async_api import async_playwright
CHROME, SHOTS, USER, PASSWORD = sys.argv[1:5]
MAP = "MAP photos.lab.test 127.0.0.1:18444, MAP cloud.lab.test 127.0.0.1:18444, MAP track.lab.test 127.0.0.1:18444, MAP media.lab.test 127.0.0.1:18444"
fails = 0
def ok(cond, text):
    global fails
    print(("PASS " if cond else "FAIL ") + text)
    if not cond: fails += 1
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=CHROME, args=["--host-resolver-rules=" + MAP])
        ctx = await b.new_context(locale="en-US", ignore_https_errors=True, viewport={"width": 1100, "height": 700}); pg = await ctx.new_page()
        await pg.goto("https://photos.lab.test/auth/login", wait_until="networkidle"); await pg.wait_for_timeout(1500)
        btn = pg.get_by_role("button", name="Sign in with SSO")
        try: await btn.first.wait_for(timeout=20000)   # the page may still be loading its settings
        except Exception: pass
        ok(await btn.count() == 1, "Immich offers 'Sign in with SSO'")
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
        # Floppy: a fresh browser (no Nextcloud session), the sign-on is the only way in
        ctx2 = await b.new_context(locale="en-US", ignore_https_errors=True, viewport={"width": 1100, "height": 700}); fp = await ctx2.new_page()
        await fp.goto("https://track.lab.test/", wait_until="networkidle"); await fp.wait_for_timeout(1500)
        await fp.screenshot(path=f"{SHOTS}/sso-floppy-login.png")
        ok("/accounts/login" in fp.url, "Floppy sends a visitor to its login page (" + fp.url[:60] + ")")
        page_text = await fp.inner_text("body")
        ok("Sign in with SSO" in page_text, "Floppy's login page offers the sign-on under the generic text")
        ok("Tidepool Track" in await fp.title() and "Floppy" not in await fp.title(), "Floppy's tab carries the name of the service (" + " ".join((await fp.title()).split()) + ")")
        ok(await fp.locator("input[type=password]").count() == 0, "Floppy's login page has no password form")
        accent = (await fp.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--color-accent')")).strip()
        ok(accent.lower() == "#4fc3d4", "Floppy's sign-in page carries the brand's accent (" + accent + ")")
        # the interface's own colours too: the sign-on button (Tailwind's indigo in the page's markup) is the brand's primary, and the logo is the brand's, not Floppy's
        button = await fp.evaluate("getComputedStyle(document.querySelector('button[type=submit]')).backgroundColor")
        ok(button == "rgb(15, 122, 140)", "Floppy's sign-on button is the brand's primary (" + button + ")")
        logo = await fp.evaluate("(() => { const i = document.querySelector('img[src*=\"/floppy-logo\"]'); return i ? [i.naturalWidth, i.currentSrc.slice(0, 40)] : null })()")
        ok(logo is not None and "data:image/svg+xml" in str(await fp.evaluate("getComputedStyle(document.querySelector('img[src*=\"/floppy-logo\"]')).content")), "Floppy's logo is the brand's (" + str(logo)[:60] + ")")
        px = "async (u) => { const r = await fetch(u); const bm = await createImageBitmap(await r.blob()); const c = document.createElement('canvas'); c.width = bm.width; c.height = bm.height; const x = c.getContext('2d'); x.drawImage(bm, 0, 0); const d = x.getImageData(Math.floor(bm.width / 2), Math.floor(bm.height * 0.08), 1, 1).data; return 'rgb(' + d[0] + ', ' + d[1] + ', ' + d[2] + ')' }"
        ok(await fp.evaluate(px, "/static/favicon/apple-touch-icon.png") == "rgb(11, 60, 73)" and await fp.evaluate(px, "/static/favicon/android-chrome-512x512.png") == "rgb(11, 60, 73)", "Floppy's favicon and app icons are the brand's mark")
        link = fp.get_by_text("Sign in with SSO", exact=False).first
        await link.click()
        await fp.wait_for_timeout(2500)
        await fp.screenshot(path=f"{SHOTS}/sso-floppy-step.png")
        if "/accounts/oidc/" in fp.url:   # allauth's own page between the two: one button to continue to the provider
            await fp.locator("button[type=submit]").first.click()
        try:
            await fp.wait_for_url("**cloud.lab.test/**", timeout=20000)
            ok(True, "Floppy's button leads to Nextcloud (the discovery and the client work)")
        except Exception:
            ok(False, "Floppy's button leads to Nextcloud (got " + fp.url[:80] + ")"); await b.close(); sys.exit(1)
        # allauth may ask for a confirmation before it leaves; then Nextcloud asks for the login
        if await fp.locator("#user").count() == 0: await fp.wait_for_selector("#user", timeout=15000)
        await fp.fill("#user", USER); await fp.fill("#password", PASSWORD); await fp.click("button[type=submit]")
        try:
            await fp.wait_for_url("**track.lab.test/**", timeout=30000)
        except Exception:
            pass
        await fp.wait_for_timeout(5000)
        await fp.screenshot(path=f"{SHOTS}/sso-floppy-in.png")
        ok(fp.url.startswith("https://track.lab.test/") and "/accounts/login" not in fp.url, "Nextcloud sends the user back to Floppy, logged in (" + fp.url[:70] + ")")
        ok("/accounts/3rdparty/signup" not in fp.url, "Floppy made the account without asking for more")
        # Jellyfin: the button of its login page leads to Nextcloud, and Nextcloud's login brings the user back as a Jellyfin user (the plugin makes it, from Nextcloud's account)
        ctx3 = await b.new_context(locale="en-US", ignore_https_errors=True, viewport={"width": 1100, "height": 800}); jp = await ctx3.new_page()
        await jp.goto("https://media.lab.test/web/#/login.html", wait_until="networkidle"); await jp.wait_for_timeout(4000)
        sso = jp.get_by_role("button", name="Sign in with SSO")
        ok(await sso.count() == 1, "Jellyfin's login page offers 'Sign in with SSO'")
        await sso.scroll_into_view_if_needed(); await jp.screenshot(path=f"{SHOTS}/sso-jellyfin-login.png")
        await sso.click()
        try:
            await jp.wait_for_url("**cloud.lab.test/**", timeout=25000)
            ok(True, "Jellyfin's button leads to Nextcloud (the plugin found its settings, the discovery and the client work)")
        except Exception:
            ok(False, "Jellyfin's button leads to Nextcloud (got " + jp.url[:80] + ")"); await b.close(); sys.exit(1)
        if await jp.locator("#user").count() == 0: await jp.wait_for_selector("#user", timeout=15000)
        await jp.fill("#user", USER); await jp.fill("#password", PASSWORD); await jp.click("button[type=submit]")
        try:
            await jp.wait_for_url("**media.lab.test/**", timeout=30000)
        except Exception:
            pass
        await jp.wait_for_timeout(6000)
        await jp.screenshot(path=f"{SHOTS}/sso-jellyfin-in.png")
        ok(jp.url.startswith("https://media.lab.test/"), "Nextcloud sends the user back to Jellyfin (" + jp.url[:70] + ")")
        who = await jp.evaluate("""(async () => { try { const c = JSON.parse(localStorage.getItem('jellyfin_credentials')).Servers[0]; const r = await fetch('/Users/' + c.UserId, { headers: { 'Authorization': 'MediaBrowser Token="' + c.AccessToken + '"' } }); const t = await r.text(); try { return JSON.parse(t).Name } catch (e) { return r.status + ' ' + t.slice(0, 60) } } catch (e) { return String(e) } })()""")
        ok(who == USER, "Jellyfin has a session for the Nextcloud user (" + str(who)[:60] + ")")
        await b.close()
    print(f"{fails} failed"); sys.exit(1 if fails else 0)
asyncio.run(main())
