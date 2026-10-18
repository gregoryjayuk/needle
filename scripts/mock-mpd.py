#!/usr/bin/env python3
"""mock-mpd.py — a small fake MPD for testing Needle without touching the real server's music.

    python3 scripts/mock-mpd.py [port] [timeout]   # default 6601 and 60 s; listens on 127.0.0.1 only
    NEEDLE_HOST=127.0.0.1 NEEDLE_PORT=6601 NEEDLE_ALLOW_SECOND=1 .build/debug/Needle --show

Speaks enough of the protocol for every path Needle uses: status, currentsong, playlistinfo, idle
(with real change notifications), command lists, search/find/count/list, playlists, findadd/add/addid
(with +0), playback controls, readpicture (binary chunks of a generated cover), binarylimit.
It also reproduces a PipeWire quirk: playback started from stopped snaps the volume to 100
after ~1.5 s — which Needle is supposed to put back.
"""
import asyncio
import math
import random
import struct
import sys
import time
import zlib

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 6601
# Like MPD's connection_timeout (60 s by default): a client silent this long, and not in `idle`, is
# disconnected. Second argument, in seconds; the self-test uses a short one to catch stale sockets.
TIMEOUT = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0


def png(width, height, pixel):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))
    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def cover(seed):
    """A sunset over water, different per album: enough colour for Needle's palette to find."""
    rnd = random.Random(seed)
    hue = rnd.random()
    def hsv(h, s, v):
        i = int(h * 6) % 6
        f = h * 6 - int(h * 6)
        p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
        r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        return bytes((int(r * 255), int(g * 255), int(b * 255)))
    sun_x, sun_y, sun_r = 150 + rnd.randint(-40, 40), 120 + rnd.randint(-20, 20), 42 + rnd.randint(0, 20)
    def pixel(x, y):
        if y < 180:
            d = math.hypot(x - sun_x, y - sun_y)
            if d < sun_r:
                return hsv((hue + 0.12) % 1, 0.55, 1.0)
            t = y / 180
            return hsv((hue + 0.08 * t) % 1, 0.45 + 0.4 * t, 0.95 - 0.25 * t + 0.15 * max(0, 1 - d / 160))
        ripple = 0.08 * math.sin(y * 0.6 + x * 0.05)
        return hsv((hue + 0.55) % 1, 0.55, 0.35 + 0.15 * (1 - (y - 180) / 120) + ripple)
    return png(300, 300, pixel)


ALBUMS = [
    ("Nick Drake", "Bryter Layter", "1970", "Nick Drake/Bryter Layter (1970)", ["Introduction", "Hazey Jane II", "At the Chime of a City Clock", "One of These Things First", "Hazey Jane I", "Bryter Layter", "Fly", "Poor Boy", "Northern Sky", "Sunday"]),
    ("Joni Mitchell", "Blue", "1971", "Joni Mitchell/Blue (1971)", ["All I Want", "My Old Man", "Little Green", "Carey", "Blue", "California", "This Flight Tonight", "River", "A Case of You", "The Last Time I Saw Richard"]),
    ("Cocteau Twins", "Heaven or Las Vegas", "1990", "Cocteau Twins/Heaven or Las Vegas (1990)", ["Cherry-Coloured Funk", "Pitch the Baby", "Iceblink Luck", "Fifty-Fifty Clown", "Heaven or Las Vegas", "I Wear Your Ring"]),
    ("Tycho", "Dive", "2011", "Tycho/Dive (2011)", ["A Walk", "Hours", "Daydream", "Dive", "Coastal Brake", "Ascension"]),
    ("Bill Callahan", "Resuscitate!", "2024", "Bill Callahan/Resuscitate! (2024)", ["Wolf Moon", "Pigeons", "Drover", "Partition", "Coyotes"]),
]

LIBRARY = []
for artist, album, year, folder, titles in ALBUMS:
    rnd = random.Random(album)
    for n, title in enumerate(titles, 1):
        hires = folder.startswith("HD/")
        LIBRARY.append({
            "file": f"{folder}/{n:02d} {title}.{'flac' if hires else 'mp3'}",
            "Artist": artist, "AlbumArtist": artist, "Title": title, "Album": album, "Date": year,
            "Track": str(n), "Genre": "Folk", "duration": round(rnd.uniform(150, 320), 3),
            "Format": "96000:24:2" if hires else "44100:16:2",
        })
ART = {}
for artist, album, year, folder, titles in ALBUMS:
    if album != "Resuscitate!":   # one album without art, to exercise the fallback
        ART[folder] = cover(album)

PLAYLISTS = {
    "slow-evening": [s["file"] for s in LIBRARY if s["Title"] in ("Northern Sky", "A Case of You", "Heaven or Las Vegas", "A Walk", "Drover", "River", "Hazey Jane I", "Blue")],
    "mellow": [s["file"] for s in LIBRARY[::3]],
    "warm-welcome": [s["file"] for s in LIBRARY[1::4]],
}


class MPD:
    def __init__(self):
        self.queue = []          # songs with Id
        self.next_id = 1
        self.pos = None
        self.state = "stop"
        self.elapsed = 0.0
        self.started = 0.0
        self.volume = 70
        self.opts = {"repeat": 1, "random": 0, "single": 0, "consume": 0}
        self.lastloaded = ""
        self.waiters = []
        self.load("slow-evening")
        self.pos = 1
        self.play(1)

    # --- state helpers
    def now_elapsed(self):
        if self.state == "play":
            return self.elapsed + (time.time() - self.started)
        return self.elapsed

    def notify(self, *what):
        for w in list(self.waiters):
            w.update(what)

    def song(self):
        return self.queue[self.pos] if self.pos is not None and 0 <= self.pos < len(self.queue) else None

    def add(self, s, at=None):
        e = dict(s, Id=self.next_id)
        self.next_id += 1
        if at is None:
            self.queue.append(e)
        else:
            self.queue.insert(at, e)
            if self.pos is not None and at <= self.pos:
                self.pos += 1
        self.notify("playlist")
        return e["Id"]

    def load(self, name):
        for f in PLAYLISTS[name]:
            self.add(next(s for s in LIBRARY if s["file"] == f))
        self.lastloaded = name

    def play(self, pos=None):
        was_stopped = self.state == "stop"
        if pos is not None:
            self.pos = pos
        elif self.pos is None:
            self.pos = 0
        if not self.queue:
            return
        if pos is not None or self.state == "stop":
            self.elapsed = 0.0
        self.state = "play"
        self.started = time.time()
        self.notify("player")
        if was_stopped:
            try:
                asyncio.get_running_loop().call_later(1.5, self.quirk)
            except RuntimeError:
                pass   # the initial state, set before the server starts

    def quirk(self):
        if self.state == "play" and self.volume != 100:
            self.volume = 100
            self.notify("mixer")

    def pause(self, on):
        if on and self.state == "play":
            self.elapsed = self.now_elapsed()
            self.state = "pause"
        elif not on and self.state == "pause":
            self.state = "play"
            self.started = time.time()
        self.notify("player")

    def stop(self):
        self.state = "stop"
        self.elapsed = 0.0
        self.notify("player")

    def step(self, delta):
        if self.pos is None or not self.queue:
            return
        nxt = self.pos + delta
        if nxt >= len(self.queue):
            if self.opts["repeat"]:
                nxt = 0
            else:
                self.stop()
                return
        self.pos = max(0, nxt)
        self.elapsed = 0.0
        self.started = time.time()
        self.notify("player")

    async def ticker(self):
        while True:
            await asyncio.sleep(0.5)
            s = self.song()
            if self.state == "play" and s and self.now_elapsed() >= s["duration"]:
                if self.opts["single"] and self.opts["repeat"]:
                    self.elapsed, self.started = 0.0, time.time()
                    self.notify("player")
                else:
                    self.step(1)


mpd = MPD()


def tokens(line):
    out, i = [], 0
    while i < len(line):
        if line[i] == " ":
            i += 1
            continue
        if line[i] == '"':
            i += 1
            buf = []
            while i < len(line) and line[i] != '"':
                if line[i] == "\\" and i + 1 < len(line):
                    i += 1
                buf.append(line[i])
                i += 1
            out.append("".join(buf))
            i += 1
        else:
            j = line.find(" ", i)
            j = len(line) if j < 0 else j
            out.append(line[i:j])
            i = j
    return out


def song_lines(s, pos=None):
    lines = [f"file: {s['file']}"]
    for k in ("Artist", "AlbumArtist", "Title", "Album", "Track", "Date", "Genre", "Format"):
        if k in s:
            lines.append(f"{k}: {s[k]}")
    lines.append(f"Time: {int(s['duration'])}")
    lines.append(f"duration: {s['duration']:.3f}")
    if pos is not None:
        lines.append(f"Pos: {pos}")
        lines.append(f"Id: {s['Id']}")
    return lines


def window(args, items):
    if "window" in args:
        a, b = args[args.index("window") + 1].split(":")
        items = items[int(a):int(b)]
    return items


def matches(args, s, exact):
    if args and args[0].startswith("("):      # a filter expression; only (base "folder") is needed
        if args[0].startswith("(base") and '"' in args[0]:
            return s["file"].startswith(args[0].split('"')[1] + "/")
        return True
    pairs = []
    i = 0
    while i + 1 < len(args) and args[i] not in ("window", "sort", "position"):
        pairs.append((args[i].lower(), args[i + 1]))
        i += 2
    for tag, value in pairs:
        if tag.startswith("("):     # (base "folder")
            folder = tag.split('"')[1] if '"' in tag else ""
            if not s["file"].startswith(folder + "/"):
                return False
            continue
        fields = [s.get(k, "") for k in ("Artist", "AlbumArtist", "Title", "Album", "Genre")] + [s["file"]] if tag == "any" else [s.get({"albumartist": "AlbumArtist"}.get(tag, tag.capitalize()), "")]
        if exact:
            if not any(f == value for f in fields):
                return False
        elif not any(value.lower() in f.lower() for f in fields):
            return False
    return True


class Changes:
    """One per connection, for its whole life: like MPD, changes made while the client is busy between
    two `idle`s are kept and reported by the next one, not lost."""
    def __init__(self):
        self.what = set()
        self.event = asyncio.Event()

    def update(self, what):
        self.what.update(what)
        self.event.set()

    def take(self):
        out = sorted(self.what)
        self.what.clear()
        self.event.clear()
        return out


async def run(cmd, args, conn):
    m = mpd
    if cmd == "status":
        s = m.song()
        out = [f"volume: {m.volume}", f"repeat: {m.opts['repeat']}", f"random: {m.opts['random']}", f"single: {m.opts['single']}",
               f"consume: {m.opts['consume']}", "partition: default", f"playlistlength: {len(m.queue)}", f"state: {m.state}"]
        if m.lastloaded:
            out.append(f"lastloadedplaylist: {m.lastloaded}")
        if s:
            out += [f"song: {m.pos}", f"songid: {s['Id']}"]
            if m.state != "stop":
                out += [f"elapsed: {m.now_elapsed():.3f}", f"duration: {s['duration']:.3f}",
                        f"bitrate: {1411 if s['file'].endswith('flac') else 320}", f"audio: {s['Format']}"]
        return out
    if cmd == "currentsong":
        s = m.song()
        return song_lines(s, m.pos) if s else []
    if cmd == "playlistinfo":
        return [l for i, s in enumerate(m.queue) for l in song_lines(s, i)]
    if cmd == "listplaylists":
        return [l for n in PLAYLISTS for l in (f"playlist: {n}", "Last-Modified: 2026-10-18T14:00:00Z")]
    if cmd == "listplaylistinfo":
        return [l for f in PLAYLISTS[args[0]] for l in song_lines(next(s for s in LIBRARY if s["file"] == f))]
    if cmd == "stats":
        return [f"artists: {len(ALBUMS)}", f"albums: {len(ALBUMS)}", f"songs: {len(LIBRARY)}", "uptime: 98765", "playtime: 100",
                "db_playtime: 9999", "db_update: 1792031450"]
    if cmd in ("search", "find"):
        await asyncio.sleep(0.15)
        return [l for s in window(args, [s for s in LIBRARY if matches(args, s, cmd == "find")]) for l in song_lines(s)]
    if cmd == "count":
        hits = [s for s in LIBRARY if matches(args, s, True)]
        return [f"songs: {len(hits)}", f"playtime: {int(sum(s['duration'] for s in hits))}"]
    if cmd == "list" and args[:3] == ["album", "group", "albumartist"]:
        out = []
        for artist, album, *_ in ALBUMS:
            out += [f"AlbumArtist: {artist}", f"Album: {album}"]
        return out
    if cmd == "play":
        m.play(int(args[0]) if args else None)
        return []
    if cmd == "playid":
        m.play(next(i for i, s in enumerate(m.queue) if s["Id"] == int(args[0])))
        return []
    if cmd == "pause":
        m.pause(args[0] == "1" if args else m.state == "play")
        return []
    if cmd == "stop":
        m.stop()
        return []
    if cmd in ("next", "previous"):
        m.step(1 if cmd == "next" else -1)
        return []
    if cmd == "seekcur":
        m.elapsed, m.started = float(args[0]), time.time()
        m.notify("player")
        return []
    if cmd == "setvol":
        m.volume = int(args[0])
        m.notify("mixer")
        return []
    if cmd in ("repeat", "random", "single", "consume"):
        m.opts[cmd] = int(args[0] in ("1", "oneshot"))
        m.notify("options")
        return []
    if cmd == "clear":
        m.queue, m.pos, m.lastloaded = [], None, ""
        m.stop()
        m.notify("playlist")
        return []
    if cmd == "load":
        if args[0] not in PLAYLISTS:
            raise KeyError("No such playlist")
        m.load(args[0])
        return []
    if cmd == "shuffle":
        random.shuffle(m.queue)
        m.notify("playlist")
        return []
    if cmd in ("add", "findadd"):
        hits = [s for s in LIBRARY if (s["file"] == args[0] or s["file"].startswith(args[0] + "/"))] if cmd == "add" else [s for s in LIBRARY if matches(args, s, True)]
        for s in hits:
            m.add(s)
        return []
    if cmd == "addid":
        s = next(s for s in LIBRARY if s["file"] == args[0])
        at = None
        if len(args) > 1 and args[1].startswith("+") and m.pos is not None:
            at = m.pos + 1 + int(args[1][1:])
        return [f"Id: {m.add(s, at)}"]
    if cmd == "deleteid":
        i = next(i for i, s in enumerate(m.queue) if s["Id"] == int(args[0]))
        m.queue.pop(i)
        if m.pos is not None and i < m.pos:
            m.pos -= 1
        m.notify("playlist")
        return []
    if cmd == "readpicture":
        folder = args[0].rsplit("/", 1)[0]
        data = ART.get(folder)
        if not data:
            return []
        offset = int(args[1])
        chunk = data[offset:offset + conn["binarylimit"]]
        return [f"size: {len(data)}", "type: image/png", ("binary", chunk)]
    if cmd == "albumart":
        raise KeyError("No file exists")
    if cmd == "binarylimit":
        conn["binarylimit"] = int(args[0])
        return []
    if cmd in ("ping", "password"):
        return []
    raise KeyError(f"unknown command \"{cmd}\"")


async def handle(reader, writer):
    conn = {"binarylimit": 8192}
    # One reader feeds a queue, so `idle` can wait on "next line" and "something changed" at once
    # without cancelling a half-finished readline (which breaks asyncio's StreamReader).
    lines = asyncio.Queue()

    async def pump():
        while True:
            raw = await reader.readline()
            await lines.put(raw)
            if not raw:
                return

    pump_task = asyncio.ensure_future(pump())
    changes = Changes()
    mpd.waiters.append(changes)
    writer.write(b"OK MPD 0.24.0\n")
    await writer.drain()
    in_list = None
    try:
        while True:
            try:
                raw = await asyncio.wait_for(lines.get(), TIMEOUT)
            except asyncio.TimeoutError:
                return          # silent too long: hang up, as MPD does
            if not raw:
                return
            line = raw.decode().rstrip("\n")
            if line in ("command_list_ok_begin", "command_list_begin"):
                in_list = []
                continue
            if in_list is not None and line != "command_list_end":
                in_list.append(line)
                continue
            batch = in_list if line == "command_list_end" else [line]
            listed = line == "command_list_end"
            in_list = None
            out = b""
            failed = False
            for n, c in enumerate(batch):
                parts = tokens(c)
                if not parts:
                    continue
                cmd, args = parts[0], parts[1:]
                if cmd == "close":
                    return
                if cmd == "noidle":
                    continue
                if cmd == "idle":
                    if not changes.what:
                        changed = asyncio.ensure_future(changes.event.wait())
                        nxt = asyncio.ensure_future(lines.get())
                        done, _ = await asyncio.wait({changed, nxt}, return_when=asyncio.FIRST_COMPLETED)
                        if nxt in done:
                            changed.cancel()
                            if not nxt.result():
                                return          # client went away mid-idle
                        else:
                            nxt.cancel()
                    out += "".join(f"changed: {w}\n" for w in changes.take()).encode()
                    continue
                try:
                    for item in await run(cmd, args, conn):
                        if isinstance(item, tuple):
                            out += f"binary: {len(item[1])}\n".encode() + item[1] + b"\n"
                        else:
                            out += (item + "\n").encode()
                    if listed:
                        out += b"list_OK\n"
                except (KeyError, StopIteration, IndexError, ValueError) as e:
                    msg = str(e).strip("'\"") or "No such song"
                    out += f"ACK [50@{n}] {{{cmd}}} {msg}\n".encode()
                    failed = True
                    break
            if not failed:
                out += b"OK\n"
            writer.write(out)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        pump_task.cancel()
        mpd.waiters.remove(changes)
        writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    asyncio.ensure_future(mpd.ticker())
    print(f"mock MPD on 127.0.0.1:{PORT} — {len(LIBRARY)} songs, playing, connection_timeout {TIMEOUT:g} s", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
