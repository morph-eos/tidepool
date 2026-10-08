#!/usr/bin/env python3
# The programs' pages, looked at by a browser: the brand's colours, logo and texts must be on them. This is the check to run at every update of Jellyfin, Immich, Nextcloud and Prometheus
# (docs/exceptions.md): a program that renames a variable, a class or a setting shows up here as a FAIL, and the screenshots are the human look.
# Usage: brand-check.py <chromium> <screenshot dir>     (the pages are reached through the tunnel of lab/brand-check.sh)
import asyncio, sys
from playwright.async_api import async_playwright
CHROME, SHOTS = sys.argv[1], sys.argv[2]
V, P = "127.0.0.1:18443", "127.0.0.1:18444"   # the VPN-only names, the public names
MAP = ", ".join(f"MAP {n}.lab.test {V}" for n in ("metrics", "admin")) + ", " + ", ".join(f"MAP {n}.lab.test {P}" for n in ("cloud", "media", "photos"))
PRIMARY, DEEP = "rgb(15, 122, 140)", "rgb(11, 60, 73)"
fails = 0
def ok(cond, text):
    global fails
    print(("PASS " if cond else "FAIL ") + text)
    if not cond: fails += 1
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=CHROME, args=["--host-resolver-rules=" + MAP])
        ctx = await b.new_context(ignore_https_errors=True, viewport={"width": 1100, "height": 650}); pg = await ctx.new_page()
        async def visit(name, url, wait=2500):
            try: await pg.goto(url, wait_until="networkidle", timeout=30000)
            except Exception as e: print("note:", name, "did not go idle:", str(e)[:50])
            await pg.wait_for_timeout(wait)
            await pg.screenshot(path=f"{SHOTS}/{name}.png")
        # Nextcloud
        await visit("nextcloud", "https://cloud.lab.test/login")
        ok("Tidepool" in await pg.title() or "Tidepool" in await pg.inner_text("body"), "Nextcloud's login page carries the name")
        ok(await pg.evaluate("(() => { const e = document.querySelector('.logo'); return !!e && getComputedStyle(e).backgroundImage.includes('theming/image/logo') })()"), "Nextcloud's login page shows the brand's logo")
        # Immich
        await visit("immich", "https://photos.lab.test/auth/login")
        ok(await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--immich-primary').trim()") == "15 122 140", "Immich's primary colour is the brand's")
        ok("Tidepool, your own cloud" in await pg.inner_text("body"), "Immich's login page carries the brand's message")
        ok("Login with Tidepool" in await pg.inner_text("body"), "Immich offers the single sign-on under the brand's name")
        ok(await pg.evaluate("(() => { const i = document.querySelector('img.h-24.aspect-square'); return !!i && getComputedStyle(i).content.includes('data:image/svg+xml') })()"), "Immich's logo is the brand's")
        # Jellyfin
        await visit("jellyfin", "https://media.lab.test/web/#/login.html", 4000)
        ok(await pg.evaluate("[...document.images].some(i => getComputedStyle(i).content.includes('data:image/svg+xml'))"), "Jellyfin's login logo is the brand's")
        ok("Tidepool" in await pg.evaluate("fetch('/Branding/Configuration').then(r => r.text())"), "Jellyfin's login text carries the name")
        ok(await pg.evaluate("[...document.querySelectorAll('link[rel=stylesheet]')].some(l => l.href.includes('themes/tidepool/theme.css'))"), "Jellyfin uses the brand's theme by default")
        ok(await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--jf-palette-primary-main').trim()") == "#4fc3d4", "Jellyfin's palette is the brand's")
        # Prometheus: its title is a setting
        await visit("prometheus", "https://metrics.lab.test/query")
        ok("Tidepool metrics" in await pg.title(), "Prometheus' title carries the name")
        # the admin page (Homepage): the private tools in one place, each with its status
        await visit("admin", "https://admin.lab.test/", 9000)
        body = await pg.inner_text("body")
        ok("Tidepool admin" in await pg.title() or "Tidepool admin" in body, "the admin page carries the name")
        ok(all(n in body for n in ("Prometheus", "Alertmanager", "Syncthing", "Incus", "Nextcloud", "Immich", "Jellyfin", "Vaultwarden")), "the admin page lists the private tools and the services")
        ok(await pg.evaluate("[...document.querySelectorAll('a')].some(a => a.href === 'https://metrics.lab.test/')"), "the admin page links to Prometheus' own address")
        await b.close()
    print(f"{fails} failed")
    sys.exit(1 if fails else 0)
asyncio.run(main())
