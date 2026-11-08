#!/usr/bin/env python3
# A brand of another repository (nixos/brand/test/pippo-brand.json, the host lab-pippo), looked at by a browser: every program that takes a brand shows the name of its service, the footer, the sign-in text, the colours of that brand,
# and nothing of the default one ("Tidepool"). Usage: brand-alt.py <chromium> <screenshot dir>     (through the tunnel of lab/brand-alt.sh)
import asyncio, sys
from playwright.async_api import async_playwright
CHROME, SHOTS = sys.argv[1], sys.argv[2]
V, P = "127.0.0.1:18443", "127.0.0.1:18444"
MAP = ", ".join(f"MAP {n}.lab.test {V}" for n in ("metrics", "admin")) + ", " + ", ".join(f"MAP {n}.lab.test {P}" for n in ("cloud", "media", "photos", "track"))
fails = 0
def ok(cond, text):
    global fails
    print(("PASS " if cond else "FAIL ") + text)
    if not cond: fails += 1
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path=CHROME, args=["--host-resolver-rules=" + MAP])
        ctx = await b.new_context(ignore_https_errors=True, locale="en-US", viewport={"width": 1100, "height": 650}); pg = await ctx.new_page()
        async def visit(name, url, wait=2500):
            try: await pg.goto(url, wait_until="networkidle", timeout=30000)
            except Exception as e: print("note:", name, "did not go idle:", str(e)[:50])
            await pg.wait_for_timeout(wait)
            await pg.screenshot(path=f"{SHOTS}/alt-{name}.png")
            return " ".join((await pg.title()).split()), await pg.inner_text("body")
        # Nextcloud
        title, body = await visit("nextcloud", "https://cloud.lab.test/login")
        ok("Pippo Nuvola" in title, f"Nextcloud's tab is the name of the service ({title})")
        ok("Pippo – casa nostra" in body and "Pippo Nuvola –" not in body, "Nextcloud's footer is the brand's name and the tagline")
        ok("Tidepool" not in title + body, "Nextcloud shows nothing of the default brand")
        btn = await pg.evaluate("getComputedStyle(document.querySelector('button[type=submit], input[type=submit]')).backgroundColor")
        ok(btn == "rgb(170, 51, 85)", f"Nextcloud's button is the brand's primary ({btn})")
        # Immich
        title, body = await visit("immich", "https://photos.lab.test/auth/login")
        ok("Entra con Pippo" in body, "Immich's sign-in button is the brand's text")
        ok("Pippo, casa nostra" in body, "Immich's login message is the brand's name and tagline")
        ok(await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--immich-primary').trim()") == "170 51 85", "Immich's primary colour is the brand's")
        ok("Tidepool" not in body, "Immich shows nothing of the default brand")
        ok("Pippo Foto" in title and "Immich" not in title, f"Immich's tab is the name of the service ({title})")
        # Jellyfin
        title, body = await visit("jellyfin", "https://media.lab.test/web/#/login.html", 4500)
        ok("Pippo Film" in title, f"Jellyfin's tab is the name of the service ({title})")
        ok("Entra con Pippo" in body, "Jellyfin's sign-in button is the brand's text")
        ok("Pippo - casa nostra" in body, "Jellyfin's login line is the brand's name and tagline")
        ok(await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--jf-palette-primary-main').trim()") == "#ff8fa8", "Jellyfin's palette is the brand's")
        ok("Tidepool" not in title + body, "Jellyfin shows nothing of the default brand")
        # Floppy: a visitor with no session is sent to its login page
        title, body = await visit("floppy", "https://track.lab.test/accounts/login/")
        ok("Pippo Diario" in title and "Floppy" not in title, f"Floppy's tab is the name of the service ({title})")
        ok("Entra con Pippo" in body, "Floppy's sign-in button is the brand's text")
        accent = (await pg.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--color-accent')")).strip()
        ok(accent.lower() == "#ff8fa8", f"Floppy's accent is the brand's ({accent})")
        ok("Tidepool" not in title + body, "Floppy shows nothing of the default brand")
        # Prometheus and the admin page
        title, _ = await visit("prometheus", "https://metrics.lab.test/query")
        ok("Pippo Numeri" in title, f"Prometheus' title is the name of the service ({title})")
        title, body = await visit("admin", "https://admin.lab.test/", 9000)
        ok("Pippo Regia" in title or "Pippo Regia" in body, f"the admin page's title is the name of the service ({title})")
        ok("Tidepool" not in title, "the admin page shows nothing of the default brand")
        await b.close()
    print(f"{fails} failed")
    sys.exit(1 if fails else 0)
asyncio.run(main())
