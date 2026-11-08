#!/usr/bin/env python3
"""Wrapped: the year in everything that was watched, heard, read and played, as one email.

It reads Floppy's REST API (the history, one endpoint) and nothing else: no database access, no other service.
Python standard library only, so it runs from a systemd unit with a bare `python3` and from a laptop for a preview.

What it borrows, and from whom (the way the hosted recaps are built, not their look):
  - Spotify Wrapped: one big number per card, ranked top five lists, a "character" derived from habits by plain rules,
    discoveries (artists heard for the first time this year), the day you listened most.
  - Last.fm "Year in Music": the listening clock (hour of day), month by month, plays per day, the repeat champion.
  - Letterboxd and Trakt year reviews: films and hours, first and last of the year, rewatches, busiest month, genres, best rated, the longest binge.
  - Goodreads "Year in Books": books finished, pages, the longest and the best rated, the average score.
  - Steam Replay: hours per game, the games that took the year, month by month activity.
  - All of them: a fixed calendar window, the change against the year before, the longest streak of days with something in it.

Everything is computed here from the entries of the year (and the year before, for the comparison); nothing is stored.

Usage:
  FLOPPY_URL=https://track.example.org FLOPPY_TOKEN_FILE=/path/token  wrapped.py --year 2026 --out wrapped.html          # preview only
  ... wrapped.py --year 2026 --send --to me@example.org --from "Recap <recap@example.org>" --smtp-host smtp.example.org --smtp-user USER --smtp-password-file /path/pw
"""
import argparse
import collections
import datetime as dt
import html
import json
import os
import smtplib
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage
from zoneinfo import ZoneInfo

# --- what the kinds are called, and their colour (the same palette in the bars and the cards) ---------------------------------
KIND = {  # media_type in Floppy -> our group
    "music": "music", "movie": "movie", "tv": "tv", "season": "tv", "episode": "tv", "anime": "anime",
    "book": "read", "comic": "read", "comicissue": "read", "manga": "read", "game": "game", "boardgame": "board",
    "podcast": "podcast", "video": "video",
}
LABEL = {"music": "Musica", "movie": "Film", "tv": "Serie", "anime": "Anime", "read": "Letture", "game": "Giochi",
         "board": "Giochi da tavolo", "podcast": "Podcast", "video": "Video"}
COLOR = {"music": "#7c5cff", "movie": "#e5484d", "tv": "#e08a00", "anime": "#d6409f", "read": "#2f9e6b", "game": "#0f8fd1",
         "board": "#8b6f47", "podcast": "#b44fe0", "video": "#64748b"}
TIMED = {"music", "movie", "tv", "anime", "podcast", "video"}   # the entries whose clock time is a real moment (a game or a book is logged by day)
MONTHS = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"]
WEEKDAYS = ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"]


EXTRA_HEADERS = {}   # e.g. the Host header, when Floppy is reached on the loopback by a program on the same machine


def hm(minutes):
    minutes = int(round(minutes))
    if minutes < 60:
        return f"{minutes} min"
    h, m = divmod(minutes, 60)
    return f"{h} h {m:02d}" if m else f"{h} h"


def hours(minutes):
    return f"{minutes / 60:.0f}" if minutes >= 600 else f"{minutes / 60:.1f}".replace(".0", "")


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


def day_name(d):
    return f"{d.day} {MONTHS[d.month - 1]}"


# --- reading Floppy ------------------------------------------------------------------------------------------------------------
def fetch_history(base, token, start, end, media_types=None, timeout=300):
    """All the entries between two dates (flat list, newest first), paged 200 at a time."""
    out, offset = [], 0
    while True:
        q = {"flat": "1", "limit": "200", "offset": str(offset), "start_date": start.isoformat(), "end_date": end.isoformat()}
        if media_types:
            q["media_type"] = ",".join(media_types)
        req = urllib.request.Request(f"{base}/api/v1/history/?{urllib.parse.urlencode(q)}", headers={"Authorization": f"Token {token}", "Accept": "application/json", **EXTRA_HEADERS})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                page = json.load(r)
        except urllib.error.HTTPError as e:
            sys.exit(f"Floppy answered {e.code} for the history ({e.reason}); is the token right?")
        rows = page.get("results", [])
        out.extend(rows)
        offset += len(rows)
        if not rows or not page.get("pagination", {}).get("next"):
            return out


def fetch_pages(base, token, timeout=300):
    """{(source, media_id): number of pages} for the books of the library (the history does not carry it)."""
    out, offset = {}, 0
    while True:
        req = urllib.request.Request(f"{base}/api/v1/media/book/?limit=200&offset={offset}", headers={"Authorization": f"Token {token}", "Accept": "application/json", **EXTRA_HEADERS})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                page = json.load(r)
        except urllib.error.HTTPError:
            return out   # the pages are an extra: no recap is lost for want of them
        rows = page.get("results", [])
        for row in rows:
            it = row.get("item") or {}
            if it.get("number_of_pages"):
                out[(it.get("source"), str(it.get("media_id")))] = int(it["number_of_pages"])
        offset += len(rows)
        if not rows or not page.get("pagination", {}).get("next"):
            return out


class Entry:
    __slots__ = ("kind", "title", "sub", "at", "minutes", "plays", "score", "genres", "pages", "status", "show")

    def __init__(self, row, tz, pages=None):
        mt = row.get("media_type", "")
        self.kind = KIND.get(mt, "video")
        item = row.get("item") or {}
        self.plays = max(int(row.get("play_count") or 1), 1)
        self.minutes = float(row.get("runtime_minutes") or 0)
        self.score = row.get("score")
        self.status = row.get("status")
        genres = row.get("genres") or item.get("genres") or []
        self.genres = [g for g in genres if g][:3]   # a track can carry ten tags: the first ones say what it is
        raw = row.get("end_date") or row.get("played_at_local") or row.get("start_date")
        self.at = dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(tz)
        self.pages = (pages or {}).get((item.get("source"), str(item.get("media_id")))) if self.kind == "read" else None
        if self.kind == "music":
            self.title, self.sub = item.get("title") or row.get("title"), row.get("artist_name") or (row.get("album") or {}).get("artist_name") or ""
            self.show = row.get("title")   # the album
        elif self.kind in ("tv", "anime"):
            # an episode entry: `show` is the series, the item the episode
            self.show = (row.get("show") or {}).get("title") or row.get("title") or item.get("title")
            self.title, self.sub = row.get("title") or item.get("title"), row.get("episode_code") or row.get("episode_label") or ""
        else:
            self.title, self.sub, self.show = row.get("title") or item.get("title"), "", None

    @property
    def day(self):
        return self.at.date()

    @property
    def total_minutes(self):
        return self.minutes   # Floppy already gives the time of the entry (a game's is the whole span, a music entry its plays)


# --- the numbers ---------------------------------------------------------------------------------------------------------------
def top(counter, n=5):
    return counter.most_common(n)


def streak(days):
    best = cur = 0
    prev = None
    best_end = None
    for d in sorted(days):
        cur = cur + 1 if prev is not None and (d - prev).days == 1 else 1
        if cur > best:
            best, best_end = cur, d
        prev = d
    return best, best_end


def compute(entries, previous, older_music, year, tz):
    s = {"year": year, "kinds": {}}
    by_kind = collections.defaultdict(list)
    for e in entries:
        by_kind[e.kind].append(e)
    total = sum(e.minutes for e in entries)
    s["total_minutes"], s["entries"] = total, len(entries)
    prev_by_kind = collections.defaultdict(float)
    for e in previous:
        prev_by_kind[e.kind] += e.minutes
    s["previous_minutes"] = sum(prev_by_kind.values())
    s["prev_by_kind"] = dict(prev_by_kind)

    per_day = collections.defaultdict(float)
    per_day_items = collections.defaultdict(lambda: collections.defaultdict(float))
    month = collections.defaultdict(lambda: collections.defaultdict(float))
    for e in entries:
        per_day[e.day] += e.minutes
        per_day_items[e.day][e.kind] += e.minutes
        month[e.day.month][e.kind] += e.minutes
    s["month"] = month
    s["active_days"] = len(per_day)
    s["streak"], s["streak_end"] = streak(per_day.keys())
    if per_day:
        d, m = max(per_day.items(), key=lambda kv: kv[1])
        s["busiest_day"], s["busiest_minutes"] = d, m
        s["busiest_kind"] = max(per_day_items[d].items(), key=lambda kv: kv[1])[0]
    # clock and week, from the entries that have a real time of day
    timed = [e for e in entries if e.kind in TIMED and e.minutes > 0]
    clock = [0.0] * 24
    week = [0.0] * 7
    for e in timed:
        clock[e.at.hour] += e.minutes
        week[e.at.weekday()] += e.minutes
    s["clock"], s["week"], s["timed_minutes"] = clock, week, sum(clock)
    s["persona"] = persona(s, by_kind)

    for kind, es in by_kind.items():
        s["kinds"][kind] = kind_stats(kind, es, older_music if kind == "music" else None, year)
    return s


def kind_stats(kind, es, older, year):
    k = {"n": len(es), "minutes": sum(e.minutes for e in es), "plays": sum(e.plays for e in es)}
    gen = collections.Counter()
    for e in es:
        for g in e.genres:
            gen[g] += e.plays
    k["genres"] = top(gen, 4)
    scored = [e for e in es if e.score]
    k["avg_score"] = sum(e.score for e in scored) / len(scored) if scored else None
    k["best"] = sorted(scored, key=lambda e: (-e.score, -e.minutes))[:5]
    k["first"], k["last"] = min(es, key=lambda e: e.at), max(es, key=lambda e: e.at)
    by_month = collections.Counter()
    for e in es:
        by_month[e.day.month] += e.minutes if e.minutes else e.plays
    k["busiest_month"] = by_month.most_common(1)[0] if by_month else None
    if kind == "music":
        k["artists"] = collections.Counter()
        k["artist_min"] = collections.Counter()
        k["tracks"] = collections.Counter()
        k["albums"] = collections.Counter()
        track_day = collections.Counter()
        for e in es:
            k["artists"][e.sub] += e.plays
            k["artist_min"][e.sub] += e.minutes
            k["tracks"][(e.title, e.sub)] += e.plays
            k["albums"][(e.show, e.sub)] += e.plays
            track_day[(e.title, e.sub, e.day)] += e.plays
        k["n_artists"], k["n_tracks"] = len(k["artists"]), len(k["tracks"])
        if track_day:
            (t, a, d), c = track_day.most_common(1)[0]
            k["repeat"] = (t, a, d, c)
        per_day = collections.Counter()
        for e in es:
            per_day[e.day] += e.plays
        k["plays_per_active_day"] = k["plays"] / len(per_day) if per_day else 0
        k["top_day"] = per_day.most_common(1)[0] if per_day else None
        # the discoveries: artists whose first listen ever is in this year (only meaningful if the history goes back before it)
        k["discoveries"] = None
        if older is not None:
            known = {e.sub for e in older}
            if older:
                new = {a for a in k["artists"] if a and a not in known}
                k["discoveries"] = sorted(new, key=lambda a: -k["artists"][a])
    elif kind in ("movie", "tv", "anime", "podcast", "video"):
        titles = collections.Counter()
        titles_min = collections.Counter()
        for e in es:
            titles[e.show or e.title] += e.plays
            titles_min[e.show or e.title] += e.minutes
        k["titles"], k["titles_min"] = titles, titles_min
        k["n_titles"] = len(titles)
        k["rewatched"] = [(t, c) for t, c in titles.most_common() if c > 1 and kind == "movie"]
        perday = collections.defaultdict(list)
        for e in es:
            perday[e.day].append(e)
        if perday:
            d, day_es = max(perday.items(), key=lambda kv: sum(x.minutes for x in kv[1]))
            k["binge"] = (d, len(day_es), sum(x.minutes for x in day_es))
        k["longest"] = max(es, key=lambda e: e.minutes)
    elif kind == "read":
        k["pages"] = sum(e.pages or 0 for e in es)
        k["with_pages"] = sum(1 for e in es if e.pages)
        k["longest"] = max(es, key=lambda e: (e.pages or 0, e.minutes))
        k["titles"] = collections.Counter(e.title for e in es)
    elif kind in ("game", "board"):
        titles_min = collections.Counter()
        for e in es:
            titles_min[e.title] += e.minutes
        k["titles_min"] = titles_min
        k["n_titles"] = len(titles_min)
        k["longest"] = max(titles_min.items(), key=lambda kv: kv[1])
    return k


def persona(s, by_kind):
    """A character from plain rules (no scoring system hidden here): at most two, each with the fact behind it."""
    out = []
    t = s["timed_minutes"]
    if t > 0:
        clock = s["clock"]
        night = sum(clock[h] for h in (22, 23, 0, 1, 2, 3, 4)) / t
        morning = sum(clock[h] for h in range(5, 10)) / t
        weekend = (s["week"][5] + s["week"][6]) / t
        if night >= 0.30:
            out.append(("Nottambulo", f"{night:.0%} di quello che hai guardato e ascoltato è tra le 22 e le 5"))
        if morning >= 0.25:
            out.append(("Mattiniero", f"{morning:.0%} dei tuoi minuti è prima delle 10"))
        if weekend >= 0.50:
            out.append(("Da fine settimana", f"{weekend:.0%} del tuo tempo è sabato e domenica"))
    if s.get("busiest_minutes", 0) >= 360:
        out.append(("Maratoneta", f"il {day_name(s['busiest_day'])} hai passato {hm(s['busiest_minutes'])} tra schermi e cuffie"))
    big = [k for k, es in by_kind.items() if sum(e.minutes for e in es) >= 0.10 * max(s["total_minutes"], 1)]
    if len(big) >= 4:
        out.append(("Eclettico", f"{len(big)} generi di cose, ognuno oltre un decimo del tuo anno"))
    if not out and s["streak"] >= 14:
        out.append(("Costante", f"{s['streak']} giorni di fila con qualcosa di tuo"))
    if not out:
        out.append(("Regolare", "nessuna abitudine che spicca: un anno ben distribuito"))
    return out[:2]


# --- the page ------------------------------------------------------------------------------------------------------------------
def esc(x):
    return html.escape(str(x))


def card(title, color, body, big=None, caption=None):
    big_html = ""
    if big:
        big_html = f'<div style="font-size:44px;line-height:1.05;font-weight:800;color:{color};margin:2px 0 2px">{esc(big)}</div>'
    cap_html = f'<div style="color:#5b6472;font-size:14px;margin-bottom:10px">{esc(caption)}</div>' if caption else ""
    return (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 18px"><tr><td style="background:#ffffff;border-radius:16px;border-top:6px solid {color};padding:20px 22px">'
            f'<div style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:{color};font-weight:700">{esc(title)}</div>{big_html}{cap_html}{body}</td></tr></table>')


def ranked(items, color, fmt_count, empty=""):
    if not items:
        return empty
    top_v = max(v for _, v in items) or 1
    rows = []
    for i, (label, v) in enumerate(items, 1):
        w = max(int(100 * v / top_v), 4)
        name, sub = (label if isinstance(label, tuple) else (label, ""))
        rows.append(
            f'<tr><td style="padding:5px 10px 5px 0;width:22px;color:#98a1ae;font-weight:700;font-size:15px;vertical-align:top">{i}</td>'
            f'<td style="padding:5px 0;font-size:15px;color:#1c2330"><div>{esc(name)}{(" <span style=color:#7b8492>· " + esc(sub) + "</span>") if sub else ""}</div>'
            f'<div style="height:5px;background:#eef0f4;border-radius:3px;margin-top:3px"><div style="height:5px;width:{w}%;background:{color};border-radius:3px"></div></div></td>'
            f'<td style="padding:5px 0 5px 12px;text-align:right;font-size:14px;color:#5b6472;white-space:nowrap;vertical-align:top">{esc(fmt_count(v))}</td></tr>')
    return '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:6px">' + "".join(rows) + "</table>"


def facts(rows):
    rows = [r for r in rows if r]
    if not rows:
        return ""
    return '<ul style="margin:12px 0 0;padding:0 0 0 18px;color:#1c2330;font-size:15px;line-height:1.55">' + "".join(f"<li>{r}</li>" for r in rows) + "</ul>"


def b(x):
    return f"<b>{esc(x)}</b>"


def change(now, before):
    """Against the year before; a large jump reads better as a multiple than as a percentage."""
    if not before:
        return None
    r = now / before
    if r >= 3:
        return f"{r:.0f} volte l'anno prima"
    return f"{(r - 1):+.0%} rispetto all'anno prima".replace("-", "−")


def section_music(k, s, color):
    out = []
    big = f"{hours(k['minutes'])} ore"
    cap = f"{plural(k['plays'], 'ascolto', 'ascolti')} · {plural(k['n_artists'], 'artista', 'artisti')} · {plural(k['n_tracks'], 'brano', 'brani')}"
    body = "<div style='margin-top:12px;font-weight:700;color:#1c2330'>Gli artisti dell'anno</div>"
    body += ranked(top(k["artists"]), color, lambda v: f"{v} ascolti")
    body += "<div style='margin-top:14px;font-weight:700;color:#1c2330'>I brani che hai consumato</div>"
    body += ranked([((t, a), c) for (t, a), c in top(k["tracks"])], color, lambda v: f"{v}×")
    body += "<div style='margin-top:14px;font-weight:700;color:#1c2330'>Gli album</div>"
    body += ranked([((al, a), c) for (al, a), c in top(k["albums"], 3)], color, lambda v: f"{v} ascolti")
    if k["genres"]:
        out.append("Generi: " + ", ".join(b(g) for g, _ in k["genres"]))
    if k.get("repeat") and k["repeat"][3] >= 3:
        t, a, d, c = k["repeat"]
        out.append(f"Il campione delle ripetizioni: {b(t)} di {esc(a)}, {c} volte il {day_name(d)}")
    if k.get("top_day"):
        d, c = k["top_day"]
        out.append(f"Il giorno più musicale: {b(day_name(d))}, {plural(c, 'ascolto', 'ascolti')}")
    out.append(f"In media {k['plays_per_active_day']:.0f} ascolti nei giorni in cui hai ascoltato")
    if k["discoveries"] is not None:
        n = len(k["discoveries"])
        if n:
            out.append(f"Nuovi artisti per te: {b(n)}; il primo per ascolti è {b(k['discoveries'][0])}")
    ch = change(k["minutes"], s["prev_by_kind"].get("music", 0))
    if ch:
        out.append(f"Tempo di ascolto: {esc(ch)}")
    return card(LABEL["music"], color, body + facts(out), big, cap)


def section_screen(kind, k, s, color):
    label = LABEL[kind]
    noun = {"movie": ("film", "film"), "tv": ("episodio", "episodi"), "anime": ("episodio", "episodi"), "podcast": ("episodio", "episodi"), "video": ("video", "video")}[kind]
    big = f"{k['n']} {noun[1] if k['n'] != 1 else noun[0]}"
    cap = f"{hours(k['minutes'])} ore · {plural(k['n_titles'], 'titolo', 'titoli')}"
    body = ""
    if kind == "movie":
        if k["best"]:
            body += "<div style='margin-top:12px;font-weight:700;color:#1c2330'>I più amati (il tuo voto)</div>"
            body += ranked([(e.title, e.score) for e in k["best"]], color, lambda v: f"{v:g}/10")
    else:
        body += "<div style='margin-top:12px;font-weight:700;color:#1c2330'>Quello che ti ha preso più tempo</div>"
        body += ranked([(t, m) for t, m in top(k["titles_min"])], color, hm)
    out = []
    if k["genres"]:
        out.append("Generi: " + ", ".join(b(g) for g, _ in k["genres"]))
    if k.get("avg_score"):
        out.append("Voto medio: " + b(format(k["avg_score"], ".1f")))
    f, l = k["first"].show or k["first"].title, k["last"].show or k["last"].title
    if k["n"] > 1 and f != l:
        out.append(f"Il primo dell'anno: {b(f)} ({day_name(k['first'].day)}); l'ultimo: {b(l)} ({day_name(k['last'].day)})")
    if k.get("binge") and (k["binge"][1] > 1 or kind == "movie"):
        d, n, m = k["binge"]
        out.append(f"La giornata più piena: {b(day_name(d))}, {hm(m)}" + (f" ({n} titoli)" if n > 1 else ""))
    if k.get("rewatched"):
        t, c = k["rewatched"][0]
        out.append(f"Rivisto: {b(t)}, {c} volte" + (f" (e altri {len(k['rewatched']) - 1})" if len(k["rewatched"]) > 1 else ""))
    if kind == "movie" and k.get("longest") and k["longest"].minutes:
        out.append(f"Il più lungo: {b(k['longest'].title)}, {hm(k['longest'].minutes)}")
    if k["busiest_month"] and k["n"] >= 4:
        out.append(f"Il mese più pieno: {b(MONTHS[k['busiest_month'][0] - 1])}")
    ch = change(k["minutes"], s["prev_by_kind"].get(kind, 0))
    if ch:
        out.append(f"Tempo: {esc(ch)}")
    return card(label, color, body + facts(out), big, cap)


def section_read(k, s, color):
    big = f"{k['n']} {'lettura' if k['n'] == 1 else 'letture'}"
    cap = f"{k['pages']} pagine" if k["pages"] else "pagine non registrate"
    body = ""
    if k["best"]:
        body += "<div style='margin-top:12px;font-weight:700;color:#1c2330'>I più amati (il tuo voto)</div>"
        body += ranked([(e.title, e.score) for e in k["best"]], color, lambda v: f"{v:g}/10")
    out = []
    if k.get("avg_score"):
        out.append("Voto medio: " + b(format(k["avg_score"], ".1f")))
    if k["pages"] and k["with_pages"] > 1:
        out.append(f"La più lunga: {b(k['longest'].title)}, {k['longest'].pages} pagine; in media {k['pages'] // k['with_pages']} a libro")
    if k["n"] > 1 and k["first"].title != k["last"].title:
        out.append(f"La prima dell'anno: {b(k['first'].title)}; l'ultima: {b(k['last'].title)}")
    if k["busiest_month"] and k["n"] >= 4:
        out.append(f"Il mese in cui hai finito di più: {b(MONTHS[k['busiest_month'][0] - 1])}")
    return card(LABEL["read"], color, body + facts(out), big, cap)


def section_game(kind, k, s, color):
    big = f"{hours(k['minutes'])} ore"
    cap = f"{plural(k['n_titles'], 'gioco', 'giochi')}"
    body = "<div style='margin-top:12px;font-weight:700;color:#1c2330'>I giochi che si sono presi l'anno</div>" + ranked(top(k["titles_min"]), color, hm)
    out = []
    if k["best"]:
        out.append(f"Il tuo voto più alto: {b(k['best'][0].title)} ({k['best'][0].score:g}/10)")
    if k["busiest_month"] and k["n_titles"] >= 3:
        out.append(f"Il mese più giocato: {b(MONTHS[k['busiest_month'][0] - 1])}")
    ch = change(k["minutes"], s["prev_by_kind"].get(kind, 0))
    if ch:
        out.append(f"Tempo: {esc(ch)}")
    return card(LABEL[kind], color, body + facts(out), big, cap)


def month_chart(s):
    kinds = [k for k in COLOR if any(s["month"][m].get(k) for m in range(1, 13))]
    peak = max((sum(s["month"][m].values()) for m in range(1, 13)), default=0) or 1
    rows = []
    for m in range(1, 13):
        tot = sum(s["month"][m].values())
        cells = "".join(f'<td style="background:{COLOR[k]};height:12px;width:{max(100 * s["month"][m].get(k, 0) / peak, 0):.1f}%;font-size:1px;line-height:1px">&nbsp;</td>' for k in kinds if s["month"][m].get(k))
        bar = f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>{cells}<td style="font-size:1px">&nbsp;</td></tr></table>' if tot else ""
        rows.append(f'<tr><td style="padding:3px 10px 3px 0;font-size:13px;color:#5b6472;width:78px">{MONTHS[m - 1][:3].capitalize()}</td><td style="padding:3px 0">{bar}</td>'
                    f'<td style="padding:3px 0 3px 10px;font-size:13px;color:#5b6472;text-align:right;white-space:nowrap;width:60px">{hours(tot) + " h" if tot else ""}</td></tr>')
    legend = " ".join(f'<span style="color:{COLOR[k]};font-weight:700;font-size:13px">■ {esc(LABEL[k])}</span>' for k in kinds)
    return f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{"".join(rows)}</table><div style="margin-top:8px">{legend}</div>'


def clock_chart(s):
    peak = max(s["clock"]) or 1
    cols = "".join(f'<td valign="bottom" style="padding:0 1px"><div style="background:#4b5565;border-radius:2px 2px 0 0;height:{max(2, int(48 * v / peak))}px"></div></td>' for v in s["clock"])
    labels = "".join(f'<td style="font-size:10px;color:#98a1ae;text-align:center">{h if h % 6 == 0 else ""}</td>' for h in range(24))
    return f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:8px"><tr>{cols}</tr><tr>{labels}</tr></table>'


def build(s, name):
    year = s["year"]
    tot = s["total_minutes"]
    parts = []
    days = tot / 60 / 24
    hero_cap = f"{plural(s['entries'], 'cosa', 'cose')} guardate, ascoltate, lette o giocate in {plural(s['active_days'], 'giorno', 'giorni')}"
    ch = change(tot, s["previous_minutes"])
    hero = (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 18px"><tr><td style="background:#16131f;border-radius:20px;padding:30px 26px;color:#fff">'
            f'<div style="font-size:13px;letter-spacing:.14em;text-transform:uppercase;color:#b9a8ff;font-weight:700">Il tuo {year}</div>'
            f'<div style="font-size:56px;line-height:1.02;font-weight:800;margin:6px 0 4px">{esc(hours(tot))} ore</div>'
            f'<div style="color:#d6d0ea;font-size:16px;line-height:1.45">{esc(hero_cap)}.'
            f'{" Sono " + esc(f"{days:.1f}".replace(".0", "")) + " giorni interi." if days >= 1 else ""}{(" " + esc(ch) + ".") if ch else ""}</div></td></tr></table>')
    parts.append(hero)

    # the split between kinds
    order = sorted(s["kinds"].items(), key=lambda kv: -kv[1]["minutes"])
    split = "".join(f'<td style="background:{COLOR[k]};height:14px;width:{100 * v["minutes"] / max(tot, 1):.1f}%;font-size:1px">&nbsp;</td>' for k, v in order if v["minutes"])
    rows = "".join(f'<tr><td style="padding:3px 0;font-size:15px;color:{COLOR[k]};font-weight:700">{esc(LABEL[k])}</td><td style="padding:3px 0;text-align:right;font-size:15px;color:#1c2330">{esc(hm(v["minutes"]))}'
                   f'<span style="color:#98a1ae"> · {100 * v["minutes"] / max(tot, 1):.0f}%</span></td></tr>' for k, v in order if v["minutes"])
    parts.append(card("Dove è andato il tempo", "#4b5565", f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:6px 0 8px"><tr>{split}</tr></table><table role="presentation" width="100%" cellpadding="0" cellspacing="0">{rows}</table>'))

    # the character
    pers = "".join(f'<div style="margin-top:8px"><span style="font-size:24px;font-weight:800;color:#16131f">{esc(n)}</span><div style="color:#5b6472;font-size:14px">{esc(why)}</div></div>' for n, why in s["persona"])
    parts.append(card("Il tuo carattere", "#7c5cff", pers))

    for kind in ("music", "movie", "tv", "anime", "read", "game", "board", "podcast", "video"):
        k = s["kinds"].get(kind)
        if not k:
            continue
        if kind == "music":
            parts.append(section_music(k, s, COLOR[kind]))
        elif kind == "read":
            parts.append(section_read(k, s, COLOR[kind]))
        elif kind in ("game", "board"):
            parts.append(section_game(kind, k, s, COLOR[kind]))
        else:
            parts.append(section_screen(kind, k, s, COLOR[kind]))

    # the year as a whole
    out = []
    if s.get("busiest_day"):
        out.append(f"Il giorno più pieno: {b(day_name(s['busiest_day']))} ({esc(WEEKDAYS[s['busiest_day'].weekday()])}), {hm(s['busiest_minutes'])} di {esc(LABEL[s['busiest_kind']].lower())}")
    if s["streak"] > 1:
        out.append(f"La serie più lunga: {b(plural(s['streak'], 'giorno', 'giorni'))} di fila, fino al {day_name(s['streak_end'])}")
    if s["timed_minutes"] > 0:
        h = max(range(24), key=lambda i: s["clock"][i])
        wd = max(range(7), key=lambda i: s["week"][i])
        out.append("L'ora in cui ti fermi di più: " + b(str(h) + ":00") + "; il giorno della settimana: " + b(WEEKDAYS[wd]))
    parts.append(card("L'anno, mese per mese", "#4b5565", month_chart(s) + facts(out)))
    if s["timed_minutes"] > 0:
        parts.append(card("L'orologio di un anno", "#4b5565", clock_chart(s), None, "Quanto tempo di film, serie, musica e podcast in ogni ora del giorno"))

    foot = f'<div style="color:#98a1ae;font-size:12px;text-align:center;margin:6px 0 24px;line-height:1.5">Calcolato dal tuo tracker, per il {year}. Niente di questo esce dal server.<br>{esc(name)}</div>'
    return (f'<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Il tuo {year}</title></head>'
            f'<body style="margin:0;background:#f1f2f6;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:20px 12px">'
            f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px"><tr><td>{"".join(parts)}{foot}</td></tr></table></td></tr></table></body></html>')


def text_version(s):
    lines = [f"Il tuo {s['year']}", f"{hours(s['total_minutes'])} ore, {s['entries']} voci, {s['active_days']} giorni attivi."]
    for k, v in sorted(s["kinds"].items(), key=lambda kv: -kv[1]["minutes"]):
        lines.append(f"- {LABEL[k]}: {hm(v['minutes'])} ({v['n']} voci)")
    lines.append("Il carattere: " + ", ".join(n for n, _ in s["persona"]))
    lines.append("Apri la versione HTML per il resto.")
    return "\n".join(lines)


# --- main ----------------------------------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--year", type=int, default=dt.date.today().year)
    ap.add_argument("--url", default=os.environ.get("FLOPPY_URL"))
    ap.add_argument("--token-file", default=os.environ.get("FLOPPY_TOKEN_FILE"))
    ap.add_argument("--host-header", help="send this Host header (Floppy answers only to its own name: use it with --url http://127.0.0.1:PORT)")
    ap.add_argument("--tz", default=os.environ.get("TZ") or "UTC")
    ap.add_argument("--name", default="", help="shown in the footer")
    ap.add_argument("--out", help="write the HTML here")
    ap.add_argument("--send", action="store_true")
    ap.add_argument("--to"); ap.add_argument("--from", dest="sender")
    ap.add_argument("--smtp-host"); ap.add_argument("--smtp-port", type=int, default=587)
    ap.add_argument("--smtp-user"); ap.add_argument("--smtp-password-file")
    ap.add_argument("--smtp-plain", action="store_true", help="no TLS (a local mail sink)")
    ap.add_argument("--subject")
    a = ap.parse_args()
    if not a.url or not a.token_file:
        sys.exit("FLOPPY_URL and FLOPPY_TOKEN_FILE (or --url, --token-file) are needed")
    if a.host_header:
        EXTRA_HEADERS["Host"] = a.host_header
    base = a.url.rstrip("/")
    token = open(a.token_file).read().strip()
    tz = ZoneInfo(a.tz)
    y = a.year
    first, last = dt.date(y, 1, 1), dt.date(y, 12, 31)
    pages = fetch_pages(base, token)
    cur = [Entry(r, tz, pages) for r in fetch_history(base, token, first, last)]
    cur = [e for e in cur if e.day.year == y]
    if not cur:
        print(f"nothing tracked in {y}: no recap")
        return
    prev = [Entry(r, tz) for r in fetch_history(base, token, dt.date(y - 1, 1, 1), dt.date(y - 1, 12, 31))]
    older = [Entry(r, tz) for r in fetch_history(base, token, dt.date(1990, 1, 1), dt.date(y - 1, 12, 31), ["music"])]
    s = compute(cur, prev, older, y, tz)
    page = build(s, a.name)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(page)
        print(f"wrote {a.out} ({len(page)} bytes)")
    if a.send:
        if not (a.to and a.sender and a.smtp_host):
            sys.exit("--send needs --to, --from and --smtp-host")
        m = EmailMessage()
        m["Subject"] = a.subject or f"Il tuo {y}: {hours(s['total_minutes'])} ore tra film, musica, letture e giochi"
        m["From"], m["To"] = a.sender, a.to
        m.set_content(text_version(s))
        m.add_alternative(page, subtype="html")
        pw = open(a.smtp_password_file).read().strip() if a.smtp_password_file else None
        with smtplib.SMTP(a.smtp_host, a.smtp_port, timeout=60) as c:
            if not a.smtp_plain:
                c.starttls(context=ssl.create_default_context())
            if a.smtp_user and pw:
                c.login(a.smtp_user, pw)
            c.send_message(m)
        print("sent to", a.to)
    if not a.out and not a.send:
        print(text_version(s))


if __name__ == "__main__":
    main()
