#!/usr/bin/env python3
"""Erzeugt das App-Icon beim Bauen — ohne Fremdbibliotheken.

Zwei leuchtende Augen auf fast schwarzem Grund, dasselbe Motiv wie im
laufenden Programm. Wird von der GitHub-Action vor XcodeGen aufgerufen,
damit im Repo keine Binaerdatei liegen muss.
"""
import math, os, struct, zlib

S = 1024
W, H, R, GAP = 196, 296, 66, 126
Y0 = (S - H) // 2
X1 = (S - (2 * W + GAP)) // 2
X2 = X1 + W + GAP

GRUND = (6, 7, 10)
SCHEIN = (26, 150, 190)
OBEN = (182, 244, 255)
UNTEN = (28, 159, 196)


def abstand(px, py, x, y, w, h, r):
    """Vorzeichenbehafteter Abstand zu einem abgerundeten Rechteck."""
    cx, cy = x + w / 2, y + h / 2
    dx = abs(px - cx) - (w / 2 - r)
    dy = abs(py - cy) - (h / 2 - r)
    if dx > 0 and dy > 0:
        return math.hypot(dx, dy) - r
    return max(dx, dy) - r


def klemm(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


zeilen = bytearray()
for y in range(S):
    zeilen.append(0)  # PNG-Filter: keiner
    for x in range(S):
        d = min(abstand(x, y, X1, Y0, W, H, R),
                abstand(x, y, X2, Y0, W, H, R))

        schein = math.exp(-max(d, 0.0) / 85.0) * 0.62
        r = GRUND[0] + SCHEIN[0] * schein
        g = GRUND[1] + SCHEIN[1] * schein
        b = GRUND[2] + SCHEIN[2] * schein

        deckung = klemm(0.5 - d)
        if deckung > 0:
            t = klemm((y - Y0) / H)
            for i, (o, u) in enumerate(zip(OBEN, UNTEN)):
                wert = o + (u - o) * t
                if i == 0:
                    r = r + (wert - r) * deckung
                elif i == 1:
                    g = g + (wert - g) * deckung
                else:
                    b = b + (wert - b) * deckung

        zeilen += bytes((int(klemm(r, 0, 255)),
                         int(klemm(g, 0, 255)),
                         int(klemm(b, 0, 255))))


def block(typ, daten):
    roh = typ + daten
    return struct.pack(">I", len(daten)) + roh + struct.pack(">I", zlib.crc32(roh))


png = (b"\x89PNG\r\n\x1a\n"
       + block(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
       + block(b"IDAT", zlib.compress(bytes(zeilen), 9))
       + block(b"IEND", b""))

ordner = "Assets.xcassets/AppIcon.appiconset"
os.makedirs(ordner, exist_ok=True)
open(os.path.join(ordner, "icon1024.png"), "wb").write(png)
open("Assets.xcassets/Contents.json", "w").write(
    '{ "info" : { "author" : "xcode", "version" : 1 } }')
open(os.path.join(ordner, "Contents.json"), "w").write("""{
  "images" : [
    { "filename" : "icon1024.png", "idiom" : "universal",
      "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}""")
print("Icon erzeugt:", ordner)
