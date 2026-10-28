#!/usr/bin/env python3
# build_app_icon.py
# Purpose: M10 (bug 1) — иконка приложения из УЖЕ сгенерированного арта Ла-5.
#          Владелец: «изображение Ла-5 на иконке не соответствует тому, что сейчас в игре».
#          Раньше иконкой был плоский вектор icon.svg (снят с производства в M7), теперь
#          иконка собирается из того же PNG, что рисуется в игре — assets/art/player_la5.png.
#          Генераций SpriteCook НЕ требуется: 0 кредитов, только целочисленный масштаб
#          пиксель-арта (AGENTS «Art pipeline»: дробный масштаб запрещён).
#
#          Состав (все файлы кладутся в assets/art/, ключ GDD — app_icon):
#            app_icon.png                     512×512  фон неба + самолёт 6×  (application/config/icon)
#            app_icon_192.png                 192×192  фон неба + самолёт 3×  (legacy launcher, API 24–25)
#            app_icon_adaptive_fg_432.png     432×432  прозрачный фон + самолёт 4× (adaptive foreground)
#            app_icon_adaptive_bg_432.png     432×432  сплошное небо (adaptive background)
#          Adaptive-слои обязательны: realme 11 (Android 15) кроит legacy-иконку в маску и
#          подставляет белую подложку. Безопасная зона adaptive — центральные 66 % канвы
#          (285 px из 432): самолёт 4× = 240×220 по контенту, вписывается с запасом.
#
#          Палитра — ArtStyle: SKY #8fa6b2. Других цветов нет: иконка не должна вводить
#          новую палитру рядом с игрой.
# Usage: python tools/build_app_icon.py   (идемпотентно, перезаписывает файлы)
# Author: Technical Artist Agent (M10)
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "art" / "player_la5.png"
OUT_DIR = ROOT / "assets" / "art"

# ArtStyle.SKY (#8fa6b2) — единственный цвет фона иконки.
SKY = (0x8F, 0xA6, 0xB2, 0xFF)

# (файл, размер канвы, целочисленный масштаб спрайта, рисовать ли небо)
# 192 (legacy, API 24–25): 2× = 120 px контента из 192 (62 %) — тот же воздушный запас, что
# у adaptive-слоя (240 из 432, 55 %). При 3× самолёт занимал 94 % кадра, крылья упирались
# в край и лаунчер с закруглением мог их подрезать.
VARIANTS = [
    ("app_icon.png", 512, 6, True),
    ("app_icon_192.png", 192, 2, True),
    ("app_icon_adaptive_fg_432.png", 432, 4, False),
    ("app_icon_adaptive_bg_432.png", 432, 0, True),
]


def load_sprite() -> Image.Image:
    if not SRC.exists():
        raise SystemExit(f"нет исходного арта: {SRC}")
    sprite = Image.open(SRC).convert("RGBA")
    if sprite.size != (64, 64):
        raise SystemExit(f"ожидался спрайт 64×64, получен {sprite.size}")
    if sprite.getbbox() is None:
        raise SystemExit("спрайт полностью прозрачный")
    return sprite


def compose(sprite: Image.Image, canvas: int, scale: int, draw_sky: bool) -> Image.Image:
    bg = Image.new("RGBA", (canvas, canvas), SKY if draw_sky else (0, 0, 0, 0))
    if scale == 0:
        return bg  # только подложка (adaptive background)
    scaled = sprite.resize((64 * scale, 64 * scale), Image.NEAREST)
    box = scaled.getbbox()
    if box is None:
        raise SystemExit("масштабированный спрайт пуст")
    # Центр по КОНТЕНТУ, а не по канве спрайта: у Ла-5 поля сверху/снизу разные
    # (bbox 2,4–62,59), иначе самолёт уезжает вправо-вниз на 8–20 px.
    content_w = box[2] - box[0]
    content_h = box[3] - box[1]
    offset_x = (canvas - content_w) // 2 - box[0]
    offset_y = (canvas - content_h) // 2 - box[1]
    bg.alpha_composite(scaled, (offset_x, offset_y))
    return bg


def main() -> None:
    sprite = load_sprite()
    for name, canvas, scale, draw_sky in VARIANTS:
        image = compose(sprite, canvas, scale, draw_sky)
        path = OUT_DIR / name
        image.save(path, "PNG", optimize=True)
        bbox = image.getbbox()
        print(f"{path.relative_to(ROOT)} {image.size} bbox={bbox} {path.stat().st_size} B")


if __name__ == "__main__":
    main()
