# store/ — материалы для публикации (M8c2 → M9 → M11)

Пакет: `com.ww2airbattles.defense` · версия 1.0.0 (versionCode 1) · Android, портрет, RU
Целевой магазин на момент M9 — **RuStore** (Android 15, sideload/APK). Материалы Play
(`privacy_policy.md`, `data_safety.md`, `listing_ru.md`) остаются в силе как черновики
листинга, но форматы RuStore (feature graphic, публичный URL политики, почта поддержки)
пока не делались — отложены решением владельца 2026-10-28.

| Файл | Что это | Куда идёт в RuStore |
| --- | --- | --- |
| `privacy_policy.md` | Политика конфиденциальности (RU) | Публикуется по HTTPS-URL → карточка приложения |
| `data_safety.md` | Ответы про данные + возрастной рейтинг (IARC-совместимо) | «Безопасность данных», возрастной рейтинг |
| `listing_ru.md` | Название, краткое/полное описание, категория, теги, «Что нового» | Карточка приложения |
| `screenshots/01_home.png` … `05_win.png` | 5 скриншотов 1080×1920 (9:16), RGB PNG: Home, выбор миссии, бой миссии 1, ангар, экран победы (ряд пиксельных звёзд и три кнопки исхода) | Скриншоты телефона |
| `README.md` | Этот файл: сборка, подпись, чек-лист | — |

## 1. Сборка

Инструменты на машине сборки (проверено 2026-10-28):

- **non-mono** Godot **4.7.2.stable** для релизов:
  `C:\Users\cvin\tools\godot\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe`
  + шаблоны `%APPDATA%\Godot\export_templates\4.7.2.stable` (35 файлов);
- **mono** Godot 4.7.2 (`godot` в PATH) — только для тестов и debug APK; GDScript-проекту
  .NET-сборка не нужна, а mono-шаблон почти удваивает размер;
- JDK **21.0.12** (Microsoft Build of OpenJDK), `JAVA_HOME=C:\Program Files\Microsoft\jdk-21.0.12.8-hotspot`;
- Android SDK `C:\Users\cvin\AppData\Local\Android\Sdk`, build-tools 36.1.0, платформа 36;
  шаблон Android-сборки 4.7.2 генерируется в `android/` (папка проекта, не редактируется).

Gradle на 21-м JDK работает: `AGP` из шаблона Godot 4.7.2 поддерживает его, отдельный JDK 17
не понадобился.

### Debug APK (тесты и прогоны на эмуляторе)

```
godot --headless --path D:\WW2AirBattles --export-debug "Android" build\ww2airbattles-debug.apk
```

Пресет `Android` (`[preset.0]`): без gradle, `export_format=0`, ABI
armeabi-v7a + arm64-v8a + x86_64 (эмулятор `Medium_Phone_API_37.0`), отладочная подпись
Godot. Меняется только тем, что добавилось `permissions/vibrate=true`.

### Release APK и AAB (RuStore) — один скрипт

```
powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Target all
```

- `-Target apk` → `build\ww2airbattles-release.apk` (пресет `Android Release`, `[preset.2]`,
  без gradle, APK для RuStore/sideload);
- `-Target aab` → `build\ww2airbattles-release.aab` (пресет `Android AAB`, `[preset.1]`,
  gradle, `export_format=1`, для магазинов, принимающих AAB);
- ABI релизов — **arm64-v8a + armeabi-v7a** (x86_64 отключён: эмулятор гоняет debug APK);
- скрипт подставляет пароль из `%USERPROFILE%\.android-keys\ww2airbattles-release.credentials.txt`
  в `export_presets.cfg` на время сборки и восстанавливает файл в `finally`; в репозитории
  стоит placeholder `__RELEASE_PASSWORD__`, пароля там нет;
- `--install-android-build-template` работает **только вместе** с `--export-release`/
  `--export-debug`: отдельным вызовом Godot просто запускает игру и висит.

Результат последней сборки (2026-10-28 после UI-пакета M11, non-mono + release-ключ):

| Файл | Размер | Подпись |
| --- | --- | --- |
| `ww2airbattles-release.apk` | 56 261 481 B ≈ 53.66 MiB (15:25:06, 308 записей) | release-ключ проекта, SHA-256 `E6:F2:69:2F:…:75:66:75:AD` |
| `ww2airbattles-release.aab` | 56 197 240 B ≈ 53.59 MiB (15:26:07, 343 записи, `BundleConfig.pb`) | тот же ключ |

Было на mono-шаблоне с x86_64 — 82 310 066 B (78.5 MiB); переход на non-mono + две ABI
сократил бандл примерно на 32%.

Артефакты выше собраны уже **после** UI-пакета M11 (тап-шорткаты убраны, экран
поражения с тремя кнопками, звёзды только иконками, отрисовка самолётов +25 %). Любая
следующая правка UI или контента требует новой сборки тем же скриптом: старая APK/AAB
не содержит изменений.

## 2. Что внутри сборки (проверено `aapt2` / `zipfile`)

- Манифест: `minSdkVersion=24`, `targetSdkVersion=36`, `allowBackup=false`, `isGame=true`,
  `appCategory=game`, единственное разрешение — `android.permission.VIBRATE`
  (нужно для `Input.vibrate_handheld()` из настроек); INTERNET/камера/геолокация отсутствуют;
- `native-code: 'arm64-v8a' 'armeabi-v7a'` в APK;
- AAB: Godot 4.7 кладёт игру в install-time asset pack `assetPackInstallTime/`
  (`dist:type="asset-pack"`, `dist:delivery/install-time`, `fusing include=true`) — это
  штатная схема Play Asset Delivery, а не ошибка; `base/` содержит только код и манифест;
- внутрь попадают `data/*.json` (3 файла), `assets/.godot/imported/*.ctex`, `scripts/**/*.gdc`,
  `scenes/*.tscn.remap`, `assets/audio/*.sample`, `.fontdata`;
- **нет** `tests/`, `tools/`, `store/`, `graphify-out/`, `build/`, `assets/art/source/`,
  `*.md`, `opencode*`, `__pycache__`, `*.ica`, `juice_lab`.

## 3. Подпись

Release-ключ проекта (создан 2026-10-28 по решению владельца):

- keystore: `C:\Users\cvin\.android-keys\ww2airbattles-release.keystore` (RSA 4096, срок до 2054);
- alias: `ww2airbattles`; пароль — в `…\ww2airbattles-release.credentials.txt` рядом
  (в репозиторий не попадает, в чат не выводится);
- SHA-256 сертификата: `E6:F2:69:2F:0A:6D:CE:76:54:83:94:2C:23:E4:0E:6D:FA:97:69:D9:5D:E1:A5:04:0F:5C:56:2B:75:66:75:AD`
  (совпадает у APK и AAB).

**Keystore нельзя потерять**: без него невозможно обновить приложение в RuStore под тем же
пакетом. Нужен бэкап обоих файлов вне машины сборки.

## 4. Чек-лист публикации (RuStore)

- [x] Release APK с release-подписью (`tools\build_release.ps1 -Target apk`)
- [x] Release AAB с release-подписью (`-Target aab`)
- [x] В сборке нет dev-файлов (`tests/`, `tools/`, `store/`, `*.md`, `graphify-out/`)
- [x] `android.permission.VIBRATE` в манифесте
- [x] Прогон на реальном устройстве: realme 11 (RMX3636, Android 15, 1080×2400), release APK
- [x] Lifecycle на устройстве: HOME → возврат, `force-stop` → повторный запуск
- [x] Иконка: `assets/art/app_icon.png` 512×512 из арта Ла-5 (M10, `tools/build_app_icon.py`) + legacy 192 и adaptive-слои 432×432; прежняя плоская `icon.svg` больше не используется
- [x] 5 скриншотов телефона 1080×1920 (в M11 добавлен экран победы `05_win.png`)
- [ ] Публичный URL политики конфиденциальности (RuStore требует HTTPS)
- [ ] Контакт поддержки: в политике заглушка `support@example.com` — заменить
- [ ] Feature graphic / баннер карточки — отложено владельцем
- [ ] Скриншоты для планшета — не делались (сборка поддерживает large/xlarge)

## 5. Скриншоты: как перегенерировать

```
godot --path D:\WW2AirBattles --resolution 1080x1920 res://tools/capture_store_screenshots.tscn
```

- Сцена `tools/capture_store_screenshots.tscn` инстансит `scenes/main.tscn` и проходит
  реальные экраны: Home → «Кампания» → выбор миссии → «В бой» (забег m1 с настоящим
  драг-управлением через `InputEventScreenTouch/Drag`) → кадр победы через `qa_force_win()`
  (кнопка «QA» на кадре скрывается) → Home → «Ангар».
- Окно 1080×1920 → канва 540×960 рендерится в 2× (stretch `canvas_items`), поэтому PNG
  получаются сразу 1080×1920 без апскейла; текст чёткий, пиксель-арт без интерполяции.
- Профиль изолирован в `user://store_capture.cfg` и удаляется после прогона; аналитика
  выключена — реальные `user://ww2_air_battles.cfg` и `user://analytics.log` не трогаются.
- Забег играется «ботом» (синусоида + отход от ближайшей пули), иначе самолёт гибнет до
  середины миссии и в кадр попадает экран поражения. Скрипт делает до 3 попыток и снимает
  серию кадров каждые 1.5 с (`03_gameplay_1..11`); в repo оставлен лучший (враги в поле,
  HP не на нуле), переименованный в `03_gameplay.png`, остальные удалены.
- Viewport отдаёт RGBA PNG; для листинга кадры пересохраняются в RGB без альфы.
- Пересняты в M10 (2026-10-28) после удаления подсказки «Откроется после прохождения
  кампании» с Home: прежний `01_home.png` показывал текст, которого в игре больше нет.
- Пересняты в M11 (2026-10-28) после UI-пакета: `01_home.png` 81 627 B (без подсказки),
  `02_mission_select.png` 98 964 B, `03_gameplay.png` 80 773 B (самолёты на 25 % крупнее,
  игрок не перекрыт кнопкой бомбы), `04_hangar.png` 149 105 B, новый `05_win.png` 115 076 B
  (ряд пиксельных звёзд и три кнопки «Повторить»/«Кампания»/«В ангар»). Все 5 файлов —
  1080×1920 RGB. Подкручен додж бота, чтобы самолёт доживал до 18 с.
- `tools/*` исключён из APK и AAB, поэтому инструмент не попадает в сборку.

## 6. Ограничения, которые надо помнить

- **Открыто:** пакет M11 на реальном устройстве не прогонялся — realme 11 не был подключён
  к adb, вместо него снимали на эмуляторе `Medium_Phone_API_37.0` (debug APK): победа,
  поражение, пауза, отсутствие тап-шорткатов, масштаб 1.25 — без `SCRIPT ERROR`/`FATAL`,
  59–60 FPS. Прогон на стекле остаётся обязательным перед публикацией.
- Прогон на устройстве: realme 11 (RMX3636, arm64, Android 15) — Home → кампания → брифинг →
  бой, драг, бомба, пауза, настройки, сворачивание/возврат и `force-stop` прошли без
  FATAL/SCRIPT ERROR; в логе `BufferQueueProducer` — 59.8–59.8 FPS в меню и бою.
  Отдельно не замерялись: touch-latency на стекле, длительный нагрев, Mali/Adreno-поведение
  на других чипсетах.
- Реклама и покупки выключены (`ads_enabled`/`shop_enabled` = false) — в листинге это
  отражено, обещаний монетизации нет.
- `android/` — сгенерированный шаблон сборки (не редактировать руками); при обновлении
  Godot его нужно переустановить командой из раздела 1. Папка в релиз не попадает
  (внутри `android/build/.gdignore`).
- Если релиз когда-нибудь пойдёт в Google Play: нужен upload keystore + Play App Signing
  (текущий ключ можно использовать как upload key), а листинг дополнить feature graphic
  и скриншотом планшета.
