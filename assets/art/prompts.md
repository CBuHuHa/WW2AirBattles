# Журнал промптов SpriteCook

Одна запись на генерацию: что просили, какой моделью, сколько стоили кредиты, какой `asset_id` получили. Нужен, чтобы не платить дважды и держать стиль.

## Бюджет (решение владельца)

- ≤ 6 генераций за сессию.
- ≤ 30 кредитов на smoke-тест пайплайна (Ла-5 + Bf 109 + одна иконка).
- ≤ 120 кредитов на весь пакет M7 до нового согласования.
- Перед партией — `get_credit_balance`; ниже 20 кредитов — стоп.

## База промпта

```
Top-down view World War II aircraft, nose pointing up, single complete subject,
centered in its cell, generous empty spacing, transparent background,
crisp 1 px outline, upper-left lighting, limited palette (#8FA6B2, #3B4A57,
#D9D2C3, #4A5D3A, #6B7F5A, #4F4F4F, #FFD166, #B23A2E, #F2EDE2),
readable silhouette at 48 px, flat vector-like pixel art, no text, no labels,
no grid lines, no overlap, no insignia with prohibited symbols.
```

3×3 лист: перечислить объекты по строкам, по одному на ячейку, одинаковый масштаб и ракурс. Параметры: `pixel=true`, `resolution="1K"`, `width=32`, `height=32`, `bg_mode="transparent"`, `smart_crop_mode="tightest"`.

## Записи

| Дата | Ключ(и) | Модель | Кредиты | asset_id | Статус |
| --- | --- | --- | --- | --- | --- |
| 2026-10-27 | smoke: player_la5, player_yak3, player_p39, enemy_bf109, enemy_ju87, enemy_fw190, ui_star, ui_bomb, pickup_repair (лист 3×3) | gemini-nano-banana-2.1 | 12 | 0303583f-066a-4af0-a0e8-bb408f238c5f | нарезано, 64×64, импорт |
| 2026-10-27 | player_la5 (тест Pixel Engine, 32×32) | pixel-engine-image-v1 | 6 | b96a9791-3823-487d-ae90-f693234190f8 | отклонён: хуже читаемость/палитра, чем NB2.1 |
| 2026-10-28 | M7a: ui_perk_sparka, ui_perk_ap, ui_perk_rockets, ui_perk_shatter, ui_perk_accuracy, ui_perk_heavy, ui_perk_repair, ui_perk_coolhead, ui_perk_emergency (лист 3×3) | gemini-nano-banana-2.1 | 12 | af90abf9-ba7e-497d-a946-11f987b7cf95 | нарезано, 24×24, ждёт интеграции (technical_artist) |

### M7a — иконки перков (2026-10-28)

- Баланс до/после: 22 → 10 кредитов (лист NB2.1 1K = 12). Одна генерация, повторов не было.
- Параметры: `pixel=true`, `resolution="1K"`, `width=32`, `height=32` (подсказка на ячейку), `bg_mode="transparent"`, `smart_crop=false` (сохранить сетку), `outline_repair=true`, `mode="assets"`, палитра GDD 9 hex. `style_asset_ids` намеренно не передавались: эталонный лист — тоже 3×3 с самолётами, риск переноса их содержимого в иконки при единственной попытке на весь бюджет; стиль держат палитра, `outline_repair` и текстовый промпт.
- Результат: 100×100 px, ячейки ~33×33, иконки 21–29 px, альфа строго бинарная (0/255, полупрозрачных пикселей — 0) → halo-полировка `set_asset_alpha_cutoff` не понадобилась.
- Промпт (дословно):

```
Nine game UI icons in a regular 3x3 grid, one icon per cell, centered, transparent background.
Crisp 16-bit pixel art, 1px cream outline (#D9D2C3), muted WW2 palette, high contrast, readable at 24x24, no text, no labels, no grid lines, no overlap.
Row 1: twin-linked cannon barrels firing (sparka), armor-piercing bullet with penetrator core (ap), two rockets (rockets).
Row 2: shrapnel explosion burst (shatter), crosshair/reticle (accuracy), heavy large-caliber shell (heavy).
Row 3: wrench (repair), snowflake/calm shield (coolhead), bullet-clearing shockwave (emergency).
Flat iconic silhouettes, identical scale and stroke weight in every cell, generous empty spacing, no scenery.
```

- Нарезка: `tools/slice_spritecook_sheet.py --size 24` (9/9 непустых, 24×24 RGBA). Ограничения: иконки «вписаны» в 24 px без внутреннего отступа (на плейте 26 px это даёт нужный 1 px зазор), `ui_perk_coolhead` 21×25 не растягивался → визуально мельче остальных на ~12 %, 1–2 px мусорные точки в `sparka` (1 px) и `rockets` (2×2 px) — на 24 px почти не видны.
- Замечания к интеграции: у `ui_perk_accuracy` (и тёмных частей `sparka`) контур тёмно-синий `#0F1B27` — на тёмной плашке слота перка контраст низкий, нужен более светлый фон ячейки или кремовая обводка в HUD; `ui_perk_coolhead` — снежинка и щит сливаются в одно пятно на 24 px; у `ui_perk_emergency` 49 px чистого белого `#FFFFFF` (по стиль-гайду белый зарезервирован за снарядами игрока) — допустимо как «волна», но кандидат на перекраску в кремовый при следующем бюджете.


Итог smoke-теста: 18 из 40 кредитов, остаток 22. OAuth с VPN, но скачивание ассетов
(`api.spritecook.ai`) с этой сети недоступно — используем `tools/fetch_spritecook_asset.py`
(прямой запрос → фолбэк на wsrv.nl, байты идентичны).

## Smoke-тест пайплайна

1. `get_credit_balance` + `list_generation_models`.
2. Один лист 3×3: Ла-5, Bf 109, звезда итогов.
3. Скачать, нарезать nearest, записать манифест, импортировать в Godot.
4. Показать в игре вместо код-силуэта под флагом `use_sprite_art`.
5. Скриншот 540×960 + отчёт по кредитам и качеству нарезки.
