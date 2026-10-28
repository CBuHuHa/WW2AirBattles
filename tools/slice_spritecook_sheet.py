#!/usr/bin/env python3
"""Slice a SpriteCook grid sheet into named PNG sprites.

Equal cells, alpha-bbox trim, optional nearest-neighbour fit into a square
canvas, centered on transparent padding. Output names are GDD asset keys.

Usage:
    python tools/slice_spritecook_sheet.py \
        --input assets/art/source/2026-10-27_smoke_sheet.png \
        --rows 3 --cols 3 \
        --keys player_la5,player_yak3,player_p39,enemy_bf109,enemy_ju87,enemy_fw190,ui_star,ui_bomb,pickup_repair \
        --size 64 --out assets/art
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image


def alpha_bbox(image: Image.Image, threshold: int = 8):
    alpha = image.getchannel("A").point(lambda v: 255 if v > threshold else 0)
    return alpha.getbbox()


def fit_square(image: Image.Image, size: int) -> Image.Image:
    """Fit the trimmed sprite into a size x size transparent canvas."""
    w, h = image.size
    if w > size or h > size:
        scale = min(size / w, size / h)
        nw = max(1, int(round(w * scale)))
        nh = max(1, int(round(h * scale)))
        image = image.resize((nw, nh), Image.NEAREST)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(image, ((size - image.width) // 2, (size - image.height) // 2))
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--rows", type=int, default=3)
    parser.add_argument("--cols", type=int, default=3)
    parser.add_argument("--keys", required=True, help="comma-separated GDD keys, row-major")
    parser.add_argument("--size", type=int, default=64)
    parser.add_argument("--out", default="assets/art")
    parser.add_argument("--threshold", type=int, default=8)
    args = parser.parse_args()

    keys = [k.strip() for k in args.keys.split(",") if k.strip()]
    if len(keys) != args.rows * args.cols:
        raise SystemExit(f"expected {args.rows * args.cols} keys, got {len(keys)}")

    sheet = Image.open(args.input).convert("RGBA")
    w, h = sheet.size
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    report = []
    index = 0
    for row in range(args.rows):
        for col in range(args.cols):
            x0, x1 = round(col * w / args.cols), round((col + 1) * w / args.cols)
            y0, y1 = round(row * h / args.rows), round((row + 1) * h / args.rows)
            cell = sheet.crop((x0, y0, x1, y1))
            bbox = alpha_bbox(cell, args.threshold)
            key = keys[index]
            index += 1
            if bbox is None:
                report.append({"key": key, "status": "empty"})
                continue
            trimmed = cell.crop(bbox)
            sprite = fit_square(trimmed, args.size)
            path = out_dir / f"{key}.png"
            sprite.save(path, optimize=True)
            report.append(
                {
                    "key": key,
                    "status": "ok",
                    "cell": [x0, y0, x1, y1],
                    "source_bbox": [bbox[0] + x0, bbox[1] + y0, bbox[2] + x0, bbox[3] + y0],
                    "source_size": [trimmed.width, trimmed.height],
                    "output": str(path).replace("\\", "/"),
                    "output_size": [sprite.width, sprite.height],
                }
            )

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
