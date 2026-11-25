#!/usr/bin/env python3
"""Writes the addon's pictures into Media/.

    python3 tools/gen_media.py <site>/public/icon-512.png

icon.tga is everythingwow.com's own mark, made small, and minimap.tga the
same mark cut round with a gold rim, for the minimap button. dot.tga and ring.tga
are a white disc and a white ring, which the window tints for the places of
its map. All are 32 bit TGA files with sides that are powers of two, which
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

# The minimap button, whole: the mark cut round with a gold rim drawn on it
# and nothing outside the rim. One picture, set in the middle of the button,
# has no parts that a client could set apart from one another.
big = 256
full = Image.open(sys.argv[1]).convert("RGBA")
cut = int(full.size[0] * 0.13)
face = full.crop((cut, cut, full.size[0] - cut, full.size[0] - cut)).resize((big, big), Image.LANCZOS)
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
