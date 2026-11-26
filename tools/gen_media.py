#!/usr/bin/env python3
"""Writes the addon's pictures into Media/.

    python3 tools/gen_media.py <site>/public/icon-512.png

icon.tga is everythingwow.com's own mark, made small, and minimap.tga the
mark's letter on a round face with a gold rim, for the minimap button.
dot.tga and ring.tga are a white disc and a white ring, which the window
tints for the places of its map. mark-ring.tga, mark-diamond.tga and
mark-square.tga are the hollow marks of the world map: a white band with a
dark edge inside and out and nothing in the middle, so the map shows through
and a tint colors the band alone. All are 32 bit TGA files with sides that are powers of two, which
is what the game reads. Needs Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw

here = os.path.dirname(os.path.abspath(__file__))
media = os.path.join(here, "..", "Media")
os.makedirs(media, exist_ok=True)

# The site's mark, with a little of its dark ground trimmed so the letter
# fills a small button.
mark = Image.open(sys.argv[1]).convert("RGBA")
side = mark.size[0]
trim = int(side * 0.09)
mark = mark.crop((trim, trim, side - trim, side - trim)).resize((64, 64), Image.LANCZOS)
mark.save(os.path.join(media, "icon.tga"))

# The minimap button, whole: the letter of the mark, small in the middle of
# a round dark face, with a gold rim drawn on it and nothing outside the rim.
# One picture, set in the middle of the button, has no parts that a client
# could set apart from one another. The letter is a little over half as wide
# as the face, as the pictures on the game's own round buttons are.
big = 256
full = Image.open(sys.argv[1]).convert("RGBA")
ground = full.getpixel((full.size[0] // 2, full.size[1] // 16))
# The letter and a little of the ground about it, cut square from the middle.
half = int(full.size[0] * 0.36)
middle = full.size[0] // 2
letter = full.crop((middle - half, middle - half, middle + half, middle + half))
wide = int(big * 0.62)
letter = letter.resize((wide, wide), Image.LANCZOS)
face = Image.new("RGBA", (big, big), ground)
face.paste(letter, ((big - wide) // 2, (big - wide) // 2))
disc = Image.new("L", (big, big), 0)
ImageDraw.Draw(disc).ellipse((6, 6, big - 6, big - 6), fill=255)
button = Image.new("RGBA", (big, big), (0, 0, 0, 0))
button.paste(face, (0, 0), disc)
rim = ImageDraw.Draw(button)
rim.ellipse((6, 6, big - 6, big - 6), outline=(92, 62, 14, 255), width=22)
rim.ellipse((10, 10, big - 10, big - 10), outline=(242, 169, 59, 255), width=12)
rim.ellipse((14, 14, big - 14, big - 14), outline=(255, 222, 140, 255), width=3)
button.resize((64, 64), Image.LANCZOS).save(os.path.join(media, "minimap.tga"))


def shape(name, size, draw_it):
    """Drawn four times over and shrunk, so its edge is smooth."""
    big = Image.new("L", (size * 4, size * 4), 0)
    draw_it(ImageDraw.Draw(big), size * 4)
    alpha = big.resize((size, size), Image.LANCZOS)
    picture = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    picture.putalpha(alpha)
    picture.save(os.path.join(media, name))


shape("dot.tga", 16, lambda d, s: d.ellipse((s * 0.06, s * 0.06, s * 0.94, s * 0.94), fill=255))
shape("ring.tga", 32, lambda d, s: d.ellipse((s * 0.08, s * 0.08, s * 0.92, s * 0.92), outline=255, width=int(s * 0.12)))


def mark(name, outline):
    """A hollow mark: a white band between two dark edges, clear in the
    middle. outline(draw, size, inset, width, fill) draws the shape's line."""
    size, over = 32, 8
    side = size * over
    white = Image.new("L", (side, side), 0)
    dark = Image.new("L", (side, side), 0)
    outline(ImageDraw.Draw(dark), side, 0.03, 0.25, 255)
    outline(ImageDraw.Draw(white), side, 0.08, 0.15, 255)
    white = white.resize((size, size), Image.LANCZOS)
    dark = dark.resize((size, size), Image.LANCZOS)
    picture = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = picture.load()
    for y in range(size):
        for x in range(size):
            w, d = white.getpixel((x, y)), dark.getpixel((x, y))
            pixels[x, y] = (w, w, w, max(w, int(d * 0.85)))
    picture.save(os.path.join(media, name))


def ring_line(d, s, inset, width, fill):
    d.ellipse((s * inset, s * inset, s * (1 - inset), s * (1 - inset)), outline=fill, width=int(s * width))


def square_line(d, s, inset, width, fill):
    inset += 0.05
    d.rectangle((s * inset, s * inset, s * (1 - inset), s * (1 - inset)), outline=fill, width=int(s * width * 0.9))


def diamond_line(d, s, inset, width, fill):
    a, b, m = s * inset, s * (1 - inset), s / 2
    d.polygon([(m, a), (b, m), (m, b), (a, m)], fill=fill)
    cut = s * (inset + width * 1.55)
    d.polygon([(m, cut), (s - cut, m), (m, s - cut), (cut, m)], fill=0)


mark("mark-ring.tga", ring_line)
mark("mark-square.tga", square_line)
mark("mark-diamond.tga", diamond_line)
