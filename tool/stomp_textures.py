"""Writes the tileable finish textures the stomp pedals are painted with.

The pedal design (segno-design docs/design/own-art/pedal_faces_v3.py) draws
its hammertone, metal flake, brushed metal and marble finishes with SVG
feTurbulence filters, which Flutter has no equivalent of. This writes one
small tile per finish, and one for the grain over every body, instead: white, with the finish in the alpha channel,
which the app repeats over a pedal body with an ImageShader.

The noise is filtered in the frequency domain, so every tile wraps without
a seam. A tile pixel is one unit of the pedal's 450-wide drawing space,
except marble's, which the app paints at twice that (its large veins at
half the resolution): keep FxStompTextures.scales in
lib/looper/view/fx/stomp/fx_stomp_textures.dart in step with SCALES.

Usage: python3 tool/stomp_textures.py   (needs numpy and Pillow)
"""
import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'images', 'stomp')

# Tile size in pixels.
SIZE = 256

# Drawing-space units per tile pixel, where it is not 1. The noise
# frequencies below are per tile pixel, so they already allow for it.
SCALES = {'marble': 2}

FINISHES = ('hammer', 'flake', 'brush', 'marble', 'grain')

# Tiles written black rather than white.
DARK = {'grain'}


def band_noise(size, fx, fy, octaves, seed, turbulence=False):
    """Periodic noise with energy near spatial frequency (fx, fy) cycles per px."""
    rng = np.random.default_rng(seed)
    ky = np.fft.fftfreq(size)[:, None]
    kx = np.fft.fftfreq(size)[None, :]
    total = np.zeros((size, size))
    amp = 1.0
    for o in range(octaves):
        white = rng.standard_normal((size, size))
        sx, sy = fx * 2 ** o, fy * 2 ** o
        # A Gaussian low-pass at the octave's frequency: smooth noise of
        # that feature size, as fractal noise builds it.
        mask = np.exp(-((kx / sx) ** 2 + (ky / sy) ** 2))
        layer = np.real(np.fft.ifft2(np.fft.fft2(white) * mask))
        layer /= np.abs(layer).max() + 1e-9
        total += amp * (np.abs(layer) if turbulence else layer)
        amp /= 2
    total -= total.min()
    return total / total.max()


def hammer(size):
    # A bumpy surface lit from the top left (azimuth 235, elevation 55), as
    # the design's diffuse lighting; white where the dents fall in shadow.
    h = band_noise(size, .03, .03, 3, 5) * 2.2 * 8
    # Central differences that wrap, so the shading is as seamless as the
    # height map.
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) / 2
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) / 2
    az, el = np.radians(235), np.radians(55)
    light = np.array([np.cos(az) * np.cos(el), np.sin(az) * np.cos(el), np.sin(el)])
    n = np.stack([-gx, -gy, np.ones_like(h)])
    n /= np.linalg.norm(n, axis=0)
    diffuse = np.clip(np.tensordot(light, n, axes=1), 0, 1)
    return np.clip(.62 - .6 * diffuse, 0, 1)


def flake(size):
    # Sparse bright specks.
    v = band_noise(size, .5, .5, 1, 11)
    # The design's alpha row: 9 * noise - 7.6.
    return np.clip(9 * v - 7.6, 0, 1)


def brush(size):
    # Long horizontal streaks, faint.
    v = band_noise(size, .004 * 4, .9, 2, 7)
    return .10 * v


def marble(size):
    # Veins where the turbulence is low.
    # The design's frequencies, per drawing-space unit, per tile pixel.
    k = SCALES['marble']
    v = band_noise(size, .006 * k, .012 * k, 4, 21, turbulence=True)
    return np.clip(1.25 - 2.4 * v, 0, 1)


def grain(size):
    # The faint grain the design lays over every body: fine noise at 7%, in
    # black (the design's filter zeroes the colour).
    v = band_noise(size, .45, .45, 2, 3)
    return .07 * v


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in FINISHES:
        alpha = globals()[name](SIZE)
        a = np.round(alpha * 255).astype(np.uint8)
        # White with the texture in its alpha; the grain is black.
        white = np.full_like(a, 0 if name in DARK else 255)
        path = os.path.join(OUT, f'{name}.png')
        Image.fromarray(np.stack([white, a], axis=-1), 'LA').save(path, optimize=True)
        print(path, os.path.getsize(path), 'bytes')


if __name__ == '__main__':
    main()
