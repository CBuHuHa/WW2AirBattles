# assets/art — пиксель-арт (SpriteCook)

Каталог для финальных PNG по ключам из таблицы ассетов `GDD.md`. С M7b спрайты самолётов и иконки перков подключены в игре через `scripts/art_assets.gd` (`ArtAssets`: кэш, `RENDER_KEYS` для временного переиспользования, `perk_icon_key`); код-силуэты `ArtStyle` остаются фолбэком, если файла нет или `ShipVisual.use_sprite_art = false`.

## Структура

```
assets/art/
  <gdd_key>.png        # финальный спрайт, имя = ключ GDD (player_la5, enemy_bf109, ...)
  source/              # исходные листы и нарезка (в APK не нужны, но лежат вне tools/)
  prompts.md           # журнал промптов и расход кредитов
  style-guide.md       # стиль-гайд и утверждённые reference asset_id
tools/spritecook-assets.json   # манифест: ключ → asset_id / sha12 / label / file
```

## Правила

- Ключи не переименовывать: код и GDD ссылаются на них.
- Мир — 1×: самолёты 64×64, боссы 160×96–192×128, фон 540×960 на слой; иконки HUD — 24×24, 1:1. (Сетка 2× через Pixel Engine проверена и отклонена.)
- Масштаб только целыми числами, фильтр nearest.
- Импорт в Godot: `compress/mode=0` (lossless), mipmaps off, nearest на узле.
- Скачивание: `api.spritecook.ai` напрямую недоступен — `python tools/fetch_spritecook_asset.py --url "<sprite_url>" --out <file>` (прямой запрос → wsrv-фолбэк).
- Генерация — только `sr_game_artist`, вставка в сцены — только `technical_artist`, приёмка — `qa_agent`.
- Перед партией — `get_credit_balance`; лимиты: ≤6 генераций за сессию, ≤30 кредитов на smoke-тест, ≤120 на пакет M7.
- После приёмки — обновить статус в таблице ассетов GDD и запись в `tools/spritecook-assets.json`.
- Никаких ключей API в файлах и чате; манифест хранит только `asset_id`, `sha12`, `label`, `file`.
