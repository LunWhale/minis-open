#!/usr/bin/env python3
# Workload for recording the Pillow-stack AOT images (_imaging, libwebp,
# libjpeg-turbo, zlib) and for timing AOJIT on/off on a device.
#
# The work an agent's image scripts do: decode PNG, resize with Lanczos,
# sharpen and blur, encode and decode JPEG and WebP, plus Python's zlib and
# gzip (which also cover pip unpacking wheels). Images are generated here, so
# no network or sample files are needed.
#
# usage: python3 pillow.py [rounds]      (prints one line per stage + total)
import gzip, io, os, sys, time, zlib
from PIL import Image, ImageFilter

rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 3
W, H = 1024, 768


def make_image(seed):
    # A gradient with some structure (not flat, not pure noise), like a photo.
    img = Image.linear_gradient("L").resize((W, H))
    r = img.rotate(seed * 37 % 360)
    g = Image.effect_noise((W, H), 40 + seed % 20)
    b = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    return Image.merge("RGB", (r, g, b))


t = {}
def timed(name, fn):
    s = time.perf_counter(); out = fn(); t[name] = t.get(name, 0) + time.perf_counter() - s
    return out


start = time.perf_counter()
for rnd in range(rounds):
    for seed in range(4):
        src = timed("generate", lambda: make_image(seed + rnd * 4))
        png = timed("png_encode", lambda: (lambda b: (src.save(b, "PNG"), b.getvalue())[1])(io.BytesIO()))
        img = timed("png_decode", lambda: Image.open(io.BytesIO(png)).convert("RGB"))
        small = timed("resize_lanczos", lambda: img.resize((W // 2, H // 2), Image.Resampling.LANCZOS))
        sharp = timed("unsharp", lambda: small.filter(ImageFilter.UnsharpMask(radius=2, percent=150, threshold=3)))
        timed("blur", lambda: small.filter(ImageFilter.GaussianBlur(2)))
        jpg = timed("jpeg_encode", lambda: (lambda b: (sharp.save(b, "JPEG", quality=85), b.getvalue())[1])(io.BytesIO()))
        webp = timed("webp_encode", lambda: (lambda b: (sharp.save(b, "WEBP", quality=80), b.getvalue())[1])(io.BytesIO()))
        timed("jpeg_decode", lambda: Image.open(io.BytesIO(jpg)).load())
        timed("webp_decode", lambda: Image.open(io.BytesIO(webp)).load())
        raw = img.tobytes()
        z = timed("zlib", lambda: zlib.compress(raw, 6))
        timed("zlib", lambda: zlib.decompress(z))
        timed("gzip", lambda: gzip.decompress(gzip.compress(raw[: len(raw) // 2], 6)))
total = time.perf_counter() - start

for k, v in t.items():
    print(f"{k:16s} {v:7.2f}s")
print(f"{'total':16s} {total:7.2f}s  rounds={rounds} pillow={Image.__version__} zlib={zlib.ZLIB_RUNTIME_VERSION}")
