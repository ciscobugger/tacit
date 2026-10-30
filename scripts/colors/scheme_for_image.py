#!/usr/bin/env python3
import sys
import math
from PIL import Image

# Allowed scheme types
SCHEMES = [
    "scheme-content",
    "scheme-expressive",
    "scheme-fidelity",
    "scheme-fruit-salad",
    "scheme-monochrome",
    "scheme-neutral",
    "scheme-rainbow",
    "scheme-tonal-spot"
]

def image_colorfulness(image):
    # Based on Hasler and Süsstrunk's colorfulness metric
    data = image.tobytes()
    rg = [abs(r - g) for r, g in zip(data[0::3], data[1::3])]
    yb = [abs(0.5 * (r + g) - b) for r, g, b in zip(data[0::3], data[1::3], data[2::3])]
    n = len(rg)
    mean_rg = sum(rg) / n
    mean_yb = sum(yb) / n
    std_rg = math.sqrt(sum((v - mean_rg) ** 2 for v in rg) / n)
    std_yb = math.sqrt(sum((v - mean_yb) ** 2 for v in yb) / n)
    return math.sqrt(std_rg ** 2 + std_yb ** 2) + 0.3 * math.sqrt(mean_rg ** 2 + mean_yb ** 2)

# scheme-content respects the image's colors very well, but it might
# look too saturated, so we only use it for not very colorful images to be safe
def pick_scheme(colorfulness):
    if colorfulness < 40:
        return "scheme-neutral"
    else:
        return "scheme-tonal-spot"

def load_and_resize_image(img_path, max_dim=128):
    try:
        img = Image.open(img_path)
        img.draft("RGB", (max_dim, max_dim))
        img = img.convert("RGB")
    except Exception:
        return None
    if max(img.size) > max_dim:
        img.thumbnail((max_dim, max_dim), Image.Resampling.BOX)
    return img

def main():
    colorfulness_mode = False
    args = sys.argv[1:]
    if '--colorfulness' in args:
        colorfulness_mode = True
        args.remove('--colorfulness')
    if len(args) < 1:
        print("scheme-tonal-spot")
        sys.exit(1)
    img_path = args[0]
    img = load_and_resize_image(img_path)
    if img is None:
        print("scheme-tonal-spot")
        sys.exit(1)
    colorfulness = image_colorfulness(img)
    if colorfulness_mode:
        print(f"{colorfulness}")
    else:
        scheme = pick_scheme(colorfulness)
        print(scheme)

if __name__ == "__main__":
    main()
