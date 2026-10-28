# level_controller.gd
# Purpose: Уровневый движок M2. Владеет забегом: волны (через WaveManager), бомба, счёт,
#          подборы, пауза, победа/поражение/рестарт. Единая точка спавна врагов и подписок на
#          их сигналы — игрок, враги и пули о волнах и боссе ничего не знают.
# Dependencies: Player, EnemyBase/сцены врагов, WaveManager, BulletLayer, Pickup, BossBomb,
#               BombButton, DeathOverlay, WinOverlay, PauseOverlay, PauseButton, Hud, BombFlash,
#               BriefingOverlay, HintsOverlay (M3-B), MissionSelect (M5.3b — выбор миссии),
#               Home (M8c1 — домашний экран-хаб при запуске), Hangar (M6.2b — самолёт/ливрея
#               ангара: apply_plane + apply_livery на старте),
#               Settings (M8a — экран настроек; сброс прогресса → гейт endless + миссия),
#               MissionData/CampaignProgress/SaveGame (M5.1/M5.3a — миссия, звёзды, снабжение,
#               рекорд миссии); Player.apply_perks/PerkData (M6.1a — оружие перков, ракеты);
#               PlaneData/SaveGame.get_selected_plane (M6.2a — самолёт ангара на старте забега);
#               PerkSystem/PerkChoice (M6.1b — выбор перка после волн 2/3/4, пауза, HUD-слоты);
#               Analytics (M8b — локальные события), Ads (M8b — видимость скрытых слотов);
#               juice (M4): ScreenShake, HitStop, HitFlash, Explosions, MuzzleFlash, PlayerDamageFx.
# Author: Mechanics Developer Agent (M2–M6.1b, M8b), UI/UX Agent (M5.3b: выбор миссии, итоги)
#
# ─── ПЕРКИ (M6.1b) ─────────────────────────────────────────────────────────
# GDD «Временные перки»: выбор 1 из 2 карт после волн 2, 3 и 4 (3 выбора за миссию), игра
# на паузе, карта применяется сразу. Поток:
#   waves.wave_cleared(index) → _try_offer_perks(index)
#     → roll_offers(2) → perk_choice.show_offers(offers) → get_tree().paused = true
#   игрок тапает карточку → PerkChoice.perk_chosen(id) → _on_perk_chosen(id)
#     → perks.take(id) → perks.apply_to(player) → hud.set_max_hp/set_hp/set_perks
#     → hide_choice() → get_tree().paused = false → клик UI.
# Пауза выбора — состояние PLAYING + флаг _pending_perk_wave; отдельного State нет, поэтому
# PauseButton на это время заглушён. Других входов в забег, кроме кнопок, нет (M11/T2).
# Сброс набора — только на старте миссии/брифинга/рестарта (_reset_perks_for_run), пауза
# и сам выбор перки НЕ сбрасывают.
#
# ─── ПУТЬ ИГРОКА (M8c1; M5.3b — выбор миссии) ────────────────────────────────
# Запуск приложения → show_home() (Home, State.BRIEFING)
#   → «Кампания» (home.campaign_requested) → MissionSelect
#   → карточка (MissionSelect.mission_chosen) → _mission_id + briefing.set_mission(id)
#   → «В бой» (briefing.start_requested) → start_level() — забег выбранной миссии.
# «Назад» в выборе возвращает Home, если открыли с Home, и брифинг ТЕКУЩЕЙ миссии, если
# открыли с брифинга (_menu_context). Победа → win_overlay.show_result(...,
# stars, supply) из засчёта CampaignProgress (M5.3a). Поражение по-прежнему ничего не пишет.
#
# ─── ИТОГИ МИССИИ (M10, bug 1 / bug 5) ──────────────────────────────────────
# Тексты экранов исхода — данные миссии (data/missions.json → result, MissionData.get_result):
#   m1 «Аэродром спасён» / «Аэродром потерян», m2 «Переправа …», m3 «Город …».
# set_mission() зовётся в _start_run() ДО waves.start(); в endless ветке он НЕ зовётся —
# бесконечный забег не переписывает кампанийные тексты (и получает базовую тему аэродрома).
# На экране победы три действия (WinOverlay): «Повторить» → start_level() (та же миссия),
# «Кампания» → _on_win_campaign() (выход в BRIEFING + выбор миссии; контекст возврата —
# HOME, если кампанийный поток начался с домашнего экрана, иначе BRIEFING), «В ангар» →
# show_home(). M11/T3: те же три действия есть на ЭКРАНЕ ПОРАЖЕНИЯ (DeathOverlay:
# _on_death_replay/_on_death_campaign/_on_death_home; «Повторить» в endless → start_endless,
# в кампании → start_level). Тап-шорткатов нет (M11/T2): исходы покидаются только кнопками,
# а касание мимо них не меняет состояние. Строки-подсказки «Тап — рестарт» удалены (M11/T3).
#
# ─── БЕСКОНЕЧНЫЙ РЕЖИМ (M6.3a, UI — M6.3b) ──────────────────────────────────
# Второй режим забега: ModeENDLESS. Вход — кнопка «Бесконечный» на брифинге
# (briefing.endless_requested → _on_briefing_endless; гейт — SaveGame.is_endless_unlocked).
#   * волны/боссы/сложность — WaveManager в режиме ENDLESS (EndlessRules);
#   * счёт: множитель EndlessRules.score_multiplier(waves_cleared) применяется к убийствам,
#     бонусу за волну и ремкомплекту при полном HP (round); в кампании множитель 1.0;
#   * перки — после КАЖДОЙ 2-й волны (пока есть свободные слоты), в кампании — волны 2/3/4;
#   * HUD: строка «Волна N» (hud.set_wave) — только в endless, в кампании hide_wave();
#   * гибель босса забег НЕ завершает: очки + waves.continue_after_boss();
#   * исход только по смерти игрока: SaveGame.record_endless(очки, волна), снабжение
#     score / 60 (GDD «Счёт, звёзды, снабжение») и экран итогов DeathOverlay.show_endless_result
#     после FINISH_DELAY_LOSS; рестарт endless — только кнопками экрана поражения (режим
#     сохраняется), тап-шорткатов нет (M11/T2).
# Кампания (ModeCAMPAIGN) — весь прежний путь start_level()/start_mission() без изменений:
# прежний экран поражения, никакого endless-снабжения и строк волны.
#
# ─── НАСТРОЙКИ И ВИБРАЦИЯ (M8a, GDD «Оболочка» → «Настройки») ───────────────
# «⚙» на брифинге (briefing.settings_requested) → Settings (состояние остаётся BRIEFING),
# «Назад» (settings.closed) → брифинг текущей миссии. Сброс прогресса (settings.progress_reset)
# обновляет зависящий от профиля UI: гейт endless и выбранную миссию (_ensure_mission_unlocked).
# Вибрация — только здесь: _on_player_damaged → _vibrate_on_damage(), 40 мс, если
# SaveGame.get_setting("vibration"). Звук — AudioManager.set_muted (Settings зовёт его сам).
#
# ─── ЛОКАЛЬНАЯ АНАЛИТИКА (M8b, GDD «Монетизация» → «Аналитика») ──────────────
# События пишутся ТОЛЬКО в точки смены состояния, не в _process: app_start (_ready),
# run_start (_start_run), wave_started (_on_wave_started), perk_pick (_on_perk_chosen),
# boss_start (_on_boss_node_spawned), boss_end (_on_enemy_died, ветка босса), run_end
# (_finish_run, ровно один раз благодаря гварду WON/DEAD), unlock (победа кампании: новые
# миссии/самолёты из CampaignProgress + первый переход гейта endless). Сеть/SDK/PII нет —
# Analytics пишет локальный JSONL в user://analytics.log (qa-тесты подменяют путь/выключают).
#
# ─── СЛОТЫ МОНЕТИЗАЦИИ (M8b, GDD «Монетизация (заложена, не включена)») ──────
# В оверлеях исходов есть СКРЫТЫЕ кнопки: DeathOverlay/ReviveButton (rewarded-revive) и
# WinOverlay/DoubleSupplyButton (rewarded ×2 снабжение). Видимость решает только этот файл
# в момент исхода: visible = Ads.is_available() (флаг профиля ads_enabled, по умолчанию
# false). Заглушка Ads.show_rewarded() всегда false и награды не выдаёт, поэтому при
# поднятом флаге кнопка лишь «не работает» — геймплей и кнопки оверлеев не меняются.
#
# ─── ДОМАШНИЙ ЭКРАН И ПАУЗА (M8c1, GDD «First 30 seconds» п.1, «Оболочка») ─────
# Запуск приложения → show_home() (Home, State.BRIEFING) вместо брифинга. Поток:
#   Home → «Кампания»   → MissionSelect → карточка → брифинг → «В бой» → start_level()
#   Home → «Бесконечный» → start_endless() (гейт SaveGame.is_endless_unlocked)
#   Home → «Ангар»      → Hangar      → «Назад» → Home
#   Home → «Настройки»   → Settings    → «Назад» → Home
# Кнопки брифинга («Миссии»/«Ангар»/«⚙») сохраняют прежнее поведение: их «Назад» возвращает
# брифинг текущей миссии. Куда возвращаться — решает _menu_context (HOME | BRIEFING),
# который выставляется тем экраном, откуда открыли MissionSelect/Hangar/Settings.
# begin_briefing() остаётся публичным (QA/тесты) и показывает брифинг напрямую.
# Пауза (PauseOverlay): «Продолжить» → resume_game(), «Заново» → рестарт ТЕКУЩЕГО режима,
# «В ангар» → show_home() (снимает паузу, останавливает волны, чистит пули/врагов).
# Других путей снятия паузы нет: тап мимо кнопок ничего не делает (M11/T2).
#
# ─── JUICE-КОНТРАКТ (M4) ────────────────────────────────────────────────────
# Juice-агенту подписываться ТОЛЬКО здесь. Механика от подписчиков не зависит.
# Интеграция M4 ВЫПОЛНЕНА здесь же: секция «Juice (M4)» (обёртка ScreenShake над World,
# подписки _connect_juice(), узлы вспышек и дыма/огня игрока).
#   enemy_destroyed(kind, at)        обычный враг сбит; kind — ArtStyle.KEY_ENEMY_*
#   enemy_damaged(enemy, hp, at)     обычный враг потерял HP (hp > 0) — hit-flash
#   boss_destroyed(at)               босс сбит (большой взрыв), отдельно от обычных врагов
#   boss_spawned(boss)               босс вошёл в уровень (тревога, аура — ссылка жива до смерти)
#   boss_phase_changed(phase)        1 → 2 (hit-stop/тряска)
#   boss_bomb_dropped(at, blast_at, radius)  сброс бомбы босса + БУДУЩАЯ зона детонации
#   boss_bomb_detonated(at, radius)  детонация сброшенной бомбы
#   bomb_detonated(at, radius)       игрок применил бомбу (радиус поражения)
#   pickup_collected(kind, at)       kind — Pickup.Kind; сейчас ВСЕГДА Pickup.Kind.REPAIR (0),
#                                    сигнатура с kind сохранена под аудио-M3 («подбор»)
#   player_damaged(hp, at)           попадание по игроку (тряска 4 px / 0.15 с)
#   player_died(at)                  игрок сбит — точка гибели Ла-5
#   player_shot_fired(origin, velocity, damage)  выстрел Ла-5 (M3-D: аудио, ~8 выстр./с)
#   wave_started(index, count)       index 0-based, count — сколько бортов в волне
#   wave_cleared(index)              волна закрыта (бонус начислен)
#   score_changed(score)             счёт изменился
#   run_finished(won, score, elapsed) исход забега — эмитится ДО паузы (см. _finish_run)
# ВАЖНО: сигналы приходят синхронно в кадре гибели. Узлы врагов удаляются queue_free в
# том же кадре — НЕ хранить enemy/босса после выхода из обработчика (для эффектов берите
# снимок позиции/kind). Пауза наступает через FINISH_DELAY_* ПОСЛЕ run_finished, поэтому
# в обработчике run_finished дерево ещё живое и взрыв/тряску можно отыграть.
# Тап в этом окне НЕ рестартит и вообще ничего не делает: исход уже решён, а оверлея ещё нет —
# касание в окне не должно проглатывать экран счёта (M11/T2: тап-шорткатов нет вовсе).

class_name LevelController
extends Node2D

enum State { BRIEFING, PLAYING, PAUSED, DEAD, WON }

## Режим забега (M6.3a): кампания (миссии из данных) или бесконечный (M6.3).
enum Mode { CAMPAIGN, ENDLESS }

## M8c1: откуда открыт экран выбора миссии/ангара/настроек — туда и возвращает «Назад».
## HOME — с домашнего экрана-хаба, BRIEFING — с брифинга текущей миссии.
enum MenuContext { HOME, BRIEFING }

# ─── Сигналы для HUD и juice ─────────────────────────────────────────────────
## Обычный враг уничтожен. kind — ключ ArtStyle (enemy_bf109 / enemy_ju87 / enemy_fw190),
## at — мировая точка гибели. Ссылка на узел НЕ передаётся намеренно: враг освобождается
## в конце кадра, поэтому контракт — снимок (kind, at). НЕ хранить ссылку на врага.
signal enemy_destroyed(kind: StringName, at: Vector2)
## Обычный враг потерял HP (hit-flash). hp всегда > 0: смертельный удар приходит
## в enemy_destroyed. Аргументы enemy/at валидны только до конца кадра — НЕ хранить ссылку.
signal enemy_damaged(enemy: EnemyBase, hp: int, at: Vector2)
## Босс уничтожен. Отдельный сигнал, чтобы juice не угадывал тип по узлу в enemy_destroyed.
signal boss_destroyed(at: Vector2)
## Босс вошёл в уровень. Ссылка живёт до гибели босса (тревога, аура, привязка эффектов).
signal boss_spawned(boss: EnemyBase)
signal boss_phase_changed(phase: int)
## Бомба босса сброшена: at — точка сброса, blast_at — БУДУЩАЯ детонация, radius — её радиус.
## Juice не лезет в константы BossBomb: зона предупреждения приходит готовой.
signal boss_bomb_dropped(at: Vector2, blast_at: Vector2, radius: float)
## Бомба босса детонировала (at — центр, radius — радиус воздушной зоны урона).
signal boss_bomb_detonated(at: Vector2, radius: float)
## Игрок применил бомбу (at — позиция игрока, radius — радиус поражения/флеша).
signal bomb_detonated(at: Vector2, radius: float)
## Подбор взят: kind — Pickup.Kind (в забеге только REPAIR = 0), at — мировая точка.
## Подборов бомбы нет (GDD «Бомба»: 1 заряд на забег без пополнений), поэтому поле kind
## сейчас всегда Pickup.Kind.REPAIR; параметр сохранён как контракт для аудио-M3.
signal pickup_collected(kind: int, at: Vector2)
signal player_damaged(hp: int, at: Vector2)
## Игрок сбит (at — точка гибели Ла-5). Эмитится перед run_finished(false).
signal player_died(at: Vector2)
## M3-D (GDD «Audio»): игрок выстрелил. origin/velocity/damage — те же значения, что пришли
## от Player.shot_fired (маршрут пули/вспышки уже отработал). Ссылок на узлы не несёт;
## эмитится на каждый выстрел автострельбы (~8/с), подписчик обязан не спамить.
## M6.1a: damage — float (перки меняют урон: 0.85 / 1.1 / 1.7 / 2.0).
signal player_shot_fired(origin: Vector2, velocity: Vector2, damage: float)
signal wave_started(index: int, count: int)
signal wave_cleared(index: int)
signal score_changed(score: int)
## Исход забега. Приходит ДО паузы и оверлея: окно FINISH_DELAY_* отдано juice
## (большой взрыв босса / взрыв Ла-5, тряска). Дерево в этот момент ещё не на паузе.
signal run_finished(won: bool, score: int, elapsed: float)

# ─── Тюнинг (GDD «Бомба») ────────────────────────────────────────────────────
## GDD «Бомба» (Changelog 2026-10-26): ровно 1 заряд на забег, пополнений нет. BOMBS_AT_START —
## это же и максимум: заряд выставляется ТОЛЬКО в start_level и только уменьшается
## (_on_bomb_pressed), поэтому _bombs физически не может превысить 1.
const BOMBS_AT_START := 1                        # GDD: 1 заряд в начале уровня, максимум 1
const BOMB_DAMAGE_TO_BOSS := 30                  # (tune) GDD: 30 урона боссу
const BOMB_INVULNERABILITY_TIME := 0.5           # (tune) GDD: 0.5 с неуязвимости на время взрыва
const BOMB_FLASH_RADIUS := 620.0                 # закрывает поле 540×960 от точки игрока

# ─── Настройки (M8a, GDD «Настройки») ────────────────────────────────────────
## Длительность вибрации на попадание по Ла-5 (мс). Короткий тактильный «толчок»:
## ощутим в руке и не раздражает — попаданий за забег не больше трёх (3 HP).
const VIBRATION_DURATION_MS := 40

# ─── Окно исхода забега (гейт M2, #2) ────────────────────────────────────────
## Пауза и оверлей наступают НЕ в момент гибели босса/игрока, а через это окно:
## run_finished эмитится сразу, juice успевает отыграть большой взрыв и тряску
## (GDD «Game feel»: тряска 8 px / 0.4 с при смерти босса), и только потом мир
## замирает и появляется экран исхода. Всё окно игрок неуязвим, вражеские пули
## очищены — смерть в фейдафе не может отменить уже засчитанный исход. Пули игрока
## тоже чистятся: добить врага в окне нельзя (очки/дропы в окне не нужны).
const FINISH_DELAY_WIN := 0.5                    # (tune) окно большого взрыва босса
const FINISH_DELAY_LOSS := 0.4                   # (tune) окно взрыва Ла-5

# ─── Счёт (GDD «Challenge and progression») ──────────────────────────────────
const WAVE_CLEAR_BONUS := 250                    # (tune) +250 за пройденную волну
const REMAINING_HP_BONUS := 250                  # (tune) +250 за каждое оставшееся HP на победе
const REPAIR_FULL_HP_SCORE := 500                # (tune) ремкомплект при полном HP даёт очки

# ─── Бесконечный режим: снабжение (M6.3b) ───────────────────────────────────
## GDD «Счёт, звёзды, снабжение»: «в endless — score / 60» (tune). Начисляется ОДИН раз за
## забег — в момент поражения (единственный исход endless), с округлением до целого.
## В кампании снабжение по-прежнему считает CampaignProgress по звёздам, здесь оно не трогается.
const ENDLESS_SUPPLY_DIVISOR := 60.0

# ─── Мета-прогресс (M3-C / M5.3a, GDD «Счёт, звёзды, снабжение») ─────────────
## Уровневая статистика забега (M3-C) и засчёт результата миссии (M5.3a) живут в
## CampaignProgress + SaveGame (user://ww2_air_battles.cfg, сейв v2). LevelController
## только передаёт исход в finish_mission() и отдаёт best/is_new в WinOverlay.
## Поражение не пишет НИЧЕГО: ни звёзд, ни снабжения, ни рекорда миссии.
## RunRecord (M3-C) остаётся рабочим классом, но в забеге больше не вызывается.

const ENEMY_BF109_SCENE: PackedScene = preload("res://scenes/enemy_bf109.tscn")

## M5.1: миссия по умолчанию. Пока выбора миссии нет (M5.3), забег идёт по m1_airfield;
## start_mission() позволяет тестам/QA запустить любую миссию из data/missions.json.
const DEFAULT_MISSION_ID := "m1_airfield"

# ─── Перки (M6.1b, GDD «Временные перки») ───────────────────────────────────
## GDD: «Выбор 1 из 2 карт после волн 2, 3 и 4 (3 выбора за миссию)». Индексы 0-based:
## волна 2 → 1, волна 3 → 2, волна 4 → 3.
const PERK_OFFER_WAVES := [1, 2, 3]
## GDD: «1 из 2» — сколько карт просим у PerkSystem.roll_offers().
const PERK_OFFER_COUNT := 2

@onready var background: BattlefieldBackground = $Background
@onready var world: Node2D = $World
@onready var enemies_root: Node2D = $World/Enemies
@onready var pickups_root: Node2D = $World/Pickups
@onready var player: Player = $World/Player
@onready var player_visual: Node2D = $World/Player/Visual
@onready var bullets: BulletLayer = $World/Bullets
@onready var effects_root: Node2D = $World/Effects
@onready var waves: WaveManager = $WaveManager
@onready var hud: Hud = $UI/HUD
@onready var bomb_button: BombButton = $UI/BombButton
@onready var death_overlay: DeathOverlay = $UI/DeathOverlay
@onready var win_overlay: WinOverlay = $UI/WinOverlay
@onready var pause_overlay: PauseOverlay = $UI/PauseOverlay
@onready var pause_button: PauseButton = $UI/PauseButton
## M3-B: брифинг при запуске приложения (ROOT: показывается только один раз за запуск).
@onready var briefing: BriefingOverlay = $UI/BriefingOverlay
## M8c1: домашний экран-хаб (GDD «First 30 seconds» п.1). Заменяет брифинг при запуске
## приложения; брифинг открывается кнопкой «Кампания» → выбор миссии → карточка.
@onready var home: Home = $UI/Home
## M5.3b: экран выбора миссии (скрыт по умолчанию). Открывается кнопкой «Миссии» на
## брифинге; выбор карточки возвращает в брифинг уже с выбранной миссией.
@onready var mission_select: MissionSelect = $UI/MissionSelect
## M6.2b: экран ангара (скрыт по умолчанию). Открывается кнопкой «Ангар» на брифинге;
## «Назад» возвращает брифинг текущей миссии. Выбор пишется в сейв и применяется
## следующим start_level() (apply_plane + apply_livery).
@onready var hangar: Hangar = $UI/Hangar
## M8a: экран настроек (скрыт по умолчанию). Открывается кнопкой «⚙» на брифинге;
## «Назад» возвращает брифинг текущей миссии. Сброс прогресса в нём обнуляет профиль —
## здесь же чинится выбранная миссия и гейт endless.
@onready var settings: Settings = $UI/Settings
## M3-B: подсказки первого забега «Веди пальцем / Стрельба автоматическая / Бомба — справа снизу».
@onready var hints: HintsOverlay = $UI/HintsOverlay
## M6.1b: оверлей выбора перка (скрыт по умолчанию; ALWAYS — работает при paused = true).
@onready var perk_choice: PerkChoice = $UI/PerkChoice

# ─── Juice (M4): узлы эффектов ──────────────────────────────────────────────
## Обёртка тряски (структура Level → ScreenShake → World; HUD в CanvasLayer не трясётся).
## ЯВНО PAUSABLE: обёртка — ребёнок ALWAYS-контроллера, но тряска обязана замирать вместе
## с миром на паузе и после окна исхода. World остаётся PAUSABLE (контракт AGENTS).
var shake: ScreenShake
## Hit-stop: Engine.time_scale = 0 на 2–3 кадра (GDD «Game feel»). Узел сам ставит ALWAYS.
var hit_stop: HitStop
## Единственный узел-вспышка игрока (8 выстр./с — узел переиспользуется, не аллоцируется).
var player_muzzle: MuzzleFlash
## Дым/огонь игрока по HP (GDD «Игрок»). Ребёнок Player внутри World → замирает на паузе.
var damage_fx: PlayerDamageFx

## (tune) GDD «Game feel»: hit-stop 2–3 кадра (попадание по игроку / смена фазы босса).
const PLAYER_HITSTOP_FRAMES := 2
const PHASE_HITSTOP_FRAMES := 3
## (tune) GDD «Game feel»: вспышки выстрелов — радиус звезды в px; цвет — палитра ArtStyle
## (игрок — кремовый под белые трассеры, враги/босс — #FFD166 под их жёлтые пули).
const PLAYER_MUZZLE_FLASH_SIZE := 11.0
const ENEMY_MUZZLE_FLASH_SIZE := 8.0
const BOSS_MUZZLE_FLASH_SIZE := 14.0

var _state: State = State.BRIEFING
## M6.3a: режим текущего забега. Стартует кампанией; start_endless() переключает.
var _mode: Mode = Mode.CAMPAIGN
## M8c1: куда вернёт «Назад» из выбора миссии/ангара/настроек (Home или брифинг).
var _menu_context: MenuContext = MenuContext.HOME
## M10: с какого экрана начался ТЕКУЩИЙ кампанийный поток — Home («Кампания» → выбор
## миссии → брифинг) или сам брифинг (begin_briefing/QA/«Миссии»). Нужно экрану победы:
## «Кампания» выходит в выбор миссии, и «Назад» обязан вернуть туда, где поток начался.
var _briefing_from_home: bool = false
## M6.3a: пройдено волн endless (для множителя счёта) и сам множитель (1.0 в кампании).
var _waves_cleared: int = 0
var _score_multiplier: float = 1.0
## M6.3a: снимок последнего исхода endless для экрана итогов M6.3b.
var _endless_best: int = 0
var _endless_is_new: bool = false
var _endless_wave: int = 0
## M6.3b: снабжение, начисленное последним endless-забегом (0 до поражения/в кампании).
var _endless_supply_gained: int = 0
## M5.1: id миссии забега. Пусто = «не задана» → start_level() подставляет DEFAULT_MISSION_ID.
var _mission_id: String = ""
## M6.1b: система перков забега (узел `Perks`, создаётся в _ready). Она не знает про UI,
## паузу и волны — только «что можно взять» и «что активно» (см. perk_system.gd).
var perks: PerkSystem
## QA/smoke: выключенные перки не предлагаются вовсе (E2E-прогоны не должны вставать на паузу).
var _perks_enabled: bool = true
## Волна, чья карта сейчас ждёт выбора (-1 — выбора нет). Пока >= 0: дерево на паузе,
## PauseButton заглушён, таймер забега стоит, оверлей виден.
var _pending_perk_wave: int = -1
## Волны, которые уже предлагали карту в этом забеге: повторный wave_cleared не предлагает
## вторую карту за ту же волну.
var _perk_offered_waves: Array[int] = []
var _bombs: int = 0
var _score: int = 0
var _elapsed: float = 0.0
var _boss: EnemyBase = null
## Токен забега: рестарт во время окна FINISH_DELAY_* отменяет отложенную паузу/оверлей.
var _run_token: int = 0
## M3-B: подсказки показываются только в ПЕРВОМ забеге за запуск приложения.
## Флаг не сбрасывается рестартом (GDD: «тап → мгновенный рестарт»), только вместе с процессом.
var _first_run_done: bool = false
## M5.3a: снимок последнего ЗАСЧИТАННОГО исхода для будущего UI/QA (экран итогов M5.3b).
## Обнуляется на старте забега, заполняется только на победе (см. _finish_run).
var _last_stars: int = 0
var _last_supply_gained: int = 0
var _total_stars: int = 0
## M8b: был ли гейт endless уже открыт на момент старта процесса/после сброса профиля.
## Нужен, чтобы unlock-событие эмитилось один раз — в момент ПЕРВОГО открытия.
var _endless_unlocked: bool = false


func _ready() -> void:
	# Ввод/состояние должны работать, когда мир заморожен паузой или экраном победы.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# M6.1b: система перков — узел забега (имя Perks: QA/тесты ищут её по имени).
	perks = PerkSystem.new()
	perks.name = "Perks"
	add_child(perks)
	# Juice-узлы ставятся ДО подписок и до begin_briefing(); @onready-пути $World/* разрешены
	# к этому моменту (репарен World происходит уже после них).
	_install_shake_wrapper()
	_install_player_juice()
	# M4: маршрут выстрела игрока = пуля + вспышка дула (тот же узел на все 8 выстр./с).
	player.shot_fired.connect(_on_player_shot_fired)
	# M6.1a: ракеты «РС-82» — отдельный маршрут (свой урон/радиус), пушки не выключаются.
	player.rocket_fired.connect(_on_player_rocket_fired)
	player.died.connect(_on_player_died)
	player.health_changed.connect(hud.set_hp)
	player.damaged.connect(_on_player_damaged)
	bomb_button.bomb_pressed.connect(_on_bomb_pressed)
	pause_button.pause_requested.connect(_on_pause_requested)
	score_changed.connect(hud.set_score)
	waves.host = self
	waves.wave_started.connect(_on_wave_started)
	waves.wave_cleared.connect(_on_wave_cleared)
	waves.boss_spawned.connect(_on_boss_node_spawned)
	briefing.start_requested.connect(_on_briefing_start)
	# M5.3b: «Миссии» на брифинге → выбор миссии; карточка → брифинг выбранной миссии;
	# «Назад» → брифинг текущей миссии. Состояние всё это время остаётся BRIEFING.
	briefing.missions_requested.connect(_on_briefing_missions)
	mission_select.mission_chosen.connect(_on_mission_chosen)
	mission_select.closed.connect(_on_mission_select_closed)
	# M6.2b: «Ангар» на брифинге → экран ангара; «Назад» → брифинг текущей миссии.
	# Состояние остаётся BRIEFING: волны не стартуют, таймер стоит.
	briefing.hangar_requested.connect(_on_briefing_hangar)
	hangar.closed.connect(_on_hangar_closed)
	# M8a: «⚙» на брифинге → экран настроек; «Назад» → брифинг текущей миссии.
	# Состояние остаётся BRIEFING. Сброс прогресса обновляет гейт endless и выбранную миссию.
	briefing.settings_requested.connect(_on_briefing_settings)
	settings.closed.connect(_on_settings_closed)
	settings.progress_reset.connect(_on_settings_progress_reset)
	# M6.3b: «Бесконечный» на брифинге → endless-забег без брифинга (start_endless).
	# Гейт открытия уже проверен брифингом (disabled-кнопка) — здесь повторная проверка.
	briefing.endless_requested.connect(_on_briefing_endless)
	# M8c1: домашний экран-хаб — четыре входа (GDD «First 30 seconds» п.1). Home только
	# эмитит сигналы; решения (какой экран открыть/стартовать ли endless) — здесь.
	home.campaign_requested.connect(_on_home_campaign)
	home.endless_requested.connect(_on_home_endless)
	home.hangar_requested.connect(_on_home_hangar)
	home.settings_requested.connect(_on_home_settings)
	# M8c1: кнопки паузы. «Продолжить»/«Заново»/«В ангар» — гвард по состоянию PAUSED;
	# это единственный выход из паузы (M11/T2: тап мимо кнопок ничего не делает).
	pause_overlay.resume_requested.connect(_on_pause_resume)
	pause_overlay.restart_requested.connect(_on_pause_restart)
	pause_overlay.home_requested.connect(_on_pause_home)
	# M10: действия экрана победы. Оверлей только эмитит — решения принимает этот файл:
	# «Повторить» — та же миссия, «Кампания» — выбор миссии, «В ангар» — Home.
	win_overlay.replay_requested.connect(_on_win_replay)
	win_overlay.campaign_requested.connect(_on_win_campaign)
	win_overlay.home_requested.connect(_on_win_home)
	# M11/T3: те же три действия на экране поражения (до T3 экран покидался только тапом,
	# который удалён в T2). «Повторить» рестартит ТЕКУЩИЙ режим.
	death_overlay.replay_requested.connect(_on_death_replay)
	death_overlay.campaign_requested.connect(_on_death_campaign)
	death_overlay.home_requested.connect(_on_death_home)
	# M6.1b: решение игрока по карте — единственный вход «взять перк» в забеге.
	perk_choice.perk_chosen.connect(_on_perk_chosen)
	_connect_juice()
	# M8b: единственное «событие запуска приложения» (не в _process). Гейт endless снимаем
	# с профиля здесь же: unlock логируется только при ПЕРЕХОДЕ гейта, а не на каждом исходе.
	_endless_unlocked = SaveGame.is_endless_unlocked()
	Analytics.log_event("app_start", {"version": Settings.GAME_VERSION})
	# M3-B (GDD «First 30 seconds»): при запуске приложения сначала домашний экран-хаб,
	# не забег и не брифинг (M8c1). Брифинг открывается путём «Кампания → миссия»
	# (или публичным begin_briefing() в QA/тестах). Рестарт идёт через start_level().
	show_home()
	# M11 (T8): QA-кнопка «QA» в левом нижнем углу поля — только debug-сборка на реальном
	# экране (в релизе и в headless-тестах узла нет). Нужна, чтобы дойти до экрана победы
	# на устройстве: m1 скриптовым вводом не проходится.
	_create_qa_force_win_button()


func _process(delta: float) -> void:
	if _state != State.PLAYING:
		return
	# M6.1b: время выбора перка — пауза по GDD («игра на паузе»), таймер забега не растёт.
	if _pending_perk_wave >= 0:
		return
	_elapsed += delta


# ─── Жизненный цикл уровня ───────────────────────────────────────────────────
## M3-B: экран брифинга. Забег ещё не идёт: таймер стоит, волны не запущены, Ла-5 не
## стреляет и не слушает палец (автострельба/драг выключены).
## M8c1: при запуске приложения вызывается show_home(), поэтому брифинг открывается
## путём «Кампания → миссия» или публичным вызовом отсюда (QA/тесты). Рестарт его не повторяет.
## «Назад» с выбора миссии/ангара/настроек возвращает ИМЕННО брифинг (_menu_context).
func begin_briefing() -> void:
	_enter_idle_state()
	_menu_context = MenuContext.BRIEFING
	# M10: прямой вход в брифинг — поток начался не с домашнего экрана.
	_briefing_from_home = false
	briefing.set_mission(_briefing_mission_id())
	home.hide_overlay()
	briefing.show_overlay()


## M8c1: домашний экран-хаб (GDD «First 30 seconds» п.1 — главный экран при запуске,
## GDD «Оболочка»). Чистит уровень тем же путём, что брифинг, но показывает Home:
## забега нет, таймер стоит, волны остановлены, пули/враги удалены, дерево разморожено.
## Публичный вход: _ready (запуск), «В ангар» из паузы, QA/тесты.
func show_home() -> void:
	_enter_idle_state()
	_menu_context = MenuContext.HOME
	# M10: у домашнего экрана нет «брифинга за спиной»: следующий кампанийный поток
	# начинается заново (флаг поднимет _on_home_campaign).
	_briefing_from_home = false
	briefing.set_mission(_briefing_mission_id())
	briefing.hide_overlay()
	home.show_overlay()


## Общее «меню-состояние» для брифинга и Home (M8c1): забега нет, всё игровое скрыто.
## Порядок действий прежний (как был в begin_briefing M3-B): сначала мир и состояние,
## потом UI, потом игрок и HUD-данные, в конце — скрытие экранов меню.
func _enter_idle_state() -> void:
	_run_token += 1
	get_tree().paused = false
	shake.stop()
	_clear_level()
	_state = State.BRIEFING
	# M6.3a: и брифинг, и Home — всегда кампания (endless стартует без меню, start_endless).
	_mode = Mode.CAMPAIGN
	_waves_cleared = 0
	_score_multiplier = 1.0
	waves.set_mode(WaveManager.Mode.MISSION)
	_bombs = BOMBS_AT_START
	_score = 0
	_elapsed = 0.0
	_boss = null
	# UI забега под меню скрыт: HUD, кнопки, все оверлеи исхода/паузы, подсказки.
	hud.visible = false
	bomb_button.visible = false
	# Инвариант _bombs == счётчик кнопки держим и в меню (кнопка скрыта, но состояние
	# должно быть готово к старту: 1 заряд, активный вид).
	bomb_button.set_charges(_bombs)
	pause_button.visible = false
	death_overlay.hide_overlay()
	win_overlay.hide_overlay()
	pause_overlay.hide_overlay()
	hints.hide_hints()
	# reset() сам включает process/input — поэтому выключаем ПОСЛЕ него.
	player.reset(Player.START_POSITION)
	player.set_process(false)
	player.set_process_unhandled_input(false)
	# M6.1b: перки сбрасываются на старте миссии (HUD готов к «HP 3/3» без слотов).
	_reset_perks_for_run()
	# HUD-данные готовим к старту заранее (в забеге он появится уже с HP 3/3 и счётом 0).
	hud.set_hp(player.hp)
	hud.set_score(_score)
	hud.hide_boss()
	# M6.3b: в меню волн нет — строка «Волна N» скрыта (в endless её включит wave_started).
	hud.hide_wave()
	score_changed.emit(_score)
	# Экраны меню при входе в «idle» всегда закрыты: их откроет явный переход.
	mission_select.hide_overlay()
	hangar.hide_overlay()
	settings.hide_overlay()


## Старт/рестарт забега кампании. Вход — кнопка «В бой», «Повторить» на экранах победы и
## поражения, публичный вызов QA/тестов. Брифинг здесь только СКРЫВАЕТСЯ, не показывается.
func start_level() -> void:
	_start_run(Mode.CAMPAIGN)


## M6.3a: старт/рестарт бесконечного забега. Без брифинга и подсказок; игрок, самолёт,
## ливрея, перки, счёт и бомба сбрасываются тем же путём, что в кампании. Миссия кампании
## (_mission_id) не меняется — после endless «В бой» играет ту же миссию, что и до него.
## M6.3b: вход из брифинга («Бесконечный» → _on_briefing_endless) и «Повторить» на экране
## поражения endless (M11/T3). Гейт открытия (SaveGame.is_endless_unlocked) — у кнопки
## брифинга; сам движок режим не закрывает, чтобы QA/тесты могли запустить забег напрямую.
func start_endless() -> void:
	_start_run(Mode.ENDLESS)


## Общая подготовка забега обоих режимов (M6.3a вынесено из start_level без изменения
## порядка действий: сначала чистим уровень, потом состояние, потом UI и игрок).
func _start_run(mode: Mode) -> void:
	_run_token += 1  # отменяет возможную отложенную паузу прошлого исхода
	get_tree().paused = false
	# M4: рестарт без остаточной тряски — на паузе обёртка замирает со смещением и
	# сама себя не вернёт (start_level гарантирует чистый старт).
	shake.stop()
	_clear_level()
	_state = State.PLAYING
	_mode = mode
	_waves_cleared = 0
	_score_multiplier = 1.0
	_endless_best = 0
	_endless_is_new = false
	_endless_wave = 0
	_endless_supply_gained = 0
	_bombs = BOMBS_AT_START
	_score = 0
	_elapsed = 0.0
	_boss = null
	_last_stars = 0
	_last_supply_gained = 0
	_total_stars = 0
	briefing.hide_overlay()
	mission_select.hide_overlay()
	hangar.hide_overlay()
	settings.hide_overlay()
	# M8c1: забег стартует только из меню — домашний экран-хаб закрывается вместе с ним.
	home.hide_overlay()
	hints.hide_hints()
	# M6.2a: база оружия/хитбоксов — выбранный в ангаре самолёт (сейв v2). Зовётся ДО reset():
	# reset() сбрасывает перки в базу, и база должна быть уже самолётной. Выбор самолёта
	# между миссиями не сбрасывается (save читается один раз на старт забега).
	player.apply_plane(SaveGame.get_selected_plane())
	# M6.2b: ливрея ангара — тинт Visual.modulate (0 — без ливреи). После apply_plane: ключ
	# арта и перекраска применяются к одному и тому же узлу. reset() ниже тинт не трогает.
	player.apply_livery(SaveGame.get_selected_livery())
	player.reset(Player.START_POSITION)
	# BRIEFING гасил process/input игрока — забег обязан вернуть и то и другое.
	player.set_process(true)
	player.set_process_unhandled_input(true)
	# M6.1b: новый забег = базовый Ла-5 и пустые слоты перков (GDD: «сбрасываются в начале
	# каждой миссии и каждого забега»). Пауза/выбор карты перки НЕ сбрасывают.
	_reset_perks_for_run()
	bomb_button.set_charges(_bombs)
	bomb_button.visible = true
	# #13: кнопка паузы живёт только в игровых состояниях (PAUSED — в том числе).
	pause_button.visible = true
	hud.visible = true
	death_overlay.hide_overlay()
	win_overlay.hide_overlay()
	pause_overlay.hide_overlay()
	hud.set_hp(player.hp)
	hud.set_score(_score)
	hud.hide_boss()
	# M6.3b: номер волны знает только endless (wave_started сразу перезапишет значение;
	# в кампании строка останется скрытой).
	hud.hide_wave()
	score_changed.emit(_score)
	# M8b: старт забега — ПОСЛЕ apply_plane/apply_livery, чтобы plane был фактическим.
	_log_run_start()
	if _mode == Mode.ENDLESS:
		# M10: endless не наследует вид последней кампании — базовая тема аэродрома (та же,
		# что у миссии 1 / DEFAULT_MISSION_ID); тексты экранов исхода кампании тоже НЕ
		# переписываются (их ставит только кампанийная ветка ниже).
		background.set_theme_for_mission("m1_airfield")
		waves.set_mode(WaveManager.Mode.ENDLESS)
		waves.start()
		return
	# M5.1: волны, босс и ремкомплект читаются из данных миссии. Пока миссия не задана
	# (первый запуск/рестарт), играем миссию 1 — поведение M1–M4 не меняется.
	if _mission_id.is_empty():
		_mission_id = DEFAULT_MISSION_ID
	# M10: тексты экранов победы/поражения — из данных миссии (result). Ставятся ДО старта
	# волн: экран исхода может появиться в любом кадре забега.
	win_overlay.set_mission(_mission_id)
	death_overlay.set_mission(_mission_id)
	# M7d: земля вида сверху под тему миссии (bg_airfield/bg_crossing/bg_city).
	background.set_theme_for_mission(_mission_id)
	waves.set_mode(WaveManager.Mode.MISSION)
	waves.set_mission(_mission_id)
	waves.start()
	# Подсказки — только в первом забеге за запуск приложения (после рестарта молчим).
	if not _first_run_done:
		_first_run_done = true
		hints.show_hints()


## M5.1: запуск конкретной миссии кампании (data/missions.json). Единственное отличие от
## start_level() — выбранный id: брифинг/подсказки/рестарт идут тем же путём. Остаётся
## публичным входом для QA и кампанийных тестов: UI выбирает миссию через MissionSelect
## (M5.3b), но запускает её всё равно start_level() из «В бой».
func start_mission(id: String) -> void:
	_mission_id = id if not id.is_empty() else DEFAULT_MISSION_ID
	start_level()


## Кнопка «В бой» на брифинге. Гвард по состоянию: поздний/двойной эмит не перезапускает забег.
func _on_briefing_start() -> void:
	if _state != State.BRIEFING:
		return
	start_level()


# ─── Выбор миссии (M5.3b) ────────────────────────────────────────────────────
## id миссии, чей брифинг показать: выбранная в кампании, иначе первая (GDD).
func _briefing_mission_id() -> String:
	return _mission_id if not _mission_id.is_empty() else DEFAULT_MISSION_ID


## «Миссии» на брифинге: брифинг скрывается, открывается выбор миссии.
## Состояние остаётся BRIEFING — забег не идёт, тап мимо UI ничего не делает.
func _on_briefing_missions() -> void:
	if _state != State.BRIEFING:
		return
	_menu_context = MenuContext.BRIEFING
	briefing.hide_overlay()
	mission_select.refresh()
	mission_select.show_overlay()


## Карточка миссии: ставим её в брифинг (забег стартует уже существующей кнопкой «В бой»,
## тем же путём start_level()). Закрытую миссию не запускаем даже при программном эмите —
## тот же гейт, что в MissionSelect.request_mission().
func _on_mission_chosen(id: String) -> void:
	if _state != State.BRIEFING:
		return
	if id.is_empty() or not SaveGame.is_mission_unlocked(id):
		return
	_mission_id = id
	briefing.set_mission(_mission_id)
	mission_select.hide_overlay()
	# M8c1: после выбора миссии всегда открывается брифинг — «Назад» на ангаре/настройках
	# отсюда вернёт уже брифинг, а не домашний экран.
	_menu_context = MenuContext.BRIEFING
	briefing.show_overlay()


## «Назад» на выборе миссии: возвращаем туда, откуда пришли — брифинг текущей миссии
## (M5.3b) или домашний экран-хаб (M8c1, кнопка «Кампания»). Выбор забег не менял.
func _on_mission_select_closed() -> void:
	if _state != State.BRIEFING:
		return
	mission_select.hide_overlay()
	if _menu_context == MenuContext.HOME:
		home.show_overlay()
		return
	briefing.set_mission(_briefing_mission_id())
	briefing.show_overlay()


# ─── Ангар (M6.2b) ──────────────────────────────────────────────────────────
## «Ангар» на брифинге: брифинг скрывается, открывается экран ангара.
## Состояние остаётся BRIEFING — волны не идут, таймер стоит, игрок не управляется.
func _on_briefing_hangar() -> void:
	if _state != State.BRIEFING:
		return
	_menu_context = MenuContext.BRIEFING
	briefing.hide_overlay()
	hangar.show_overlay()


## «Назад» в ангаре: возвращаем туда, откуда пришли — брифинг текущей миссии (M6.2b)
## или домашний экран-хаб (M8c1). Выбранный самолёт/ливрея уже записаны в сейв и
## применятся при следующем start_level() — забег не перезапускается.
func _on_hangar_closed() -> void:
	if _state != State.BRIEFING:
		return
	hangar.hide_overlay()
	if _menu_context == MenuContext.HOME:
		home.show_overlay()
		return
	briefing.set_mission(_briefing_mission_id())
	briefing.show_overlay()


# ─── Настройки (M8a) ────────────────────────────────────────────────────────
## «⚙» на брифинге: брифинг скрывается, открывается экран настроек.
## Состояние остаётся BRIEFING — волны не идут, таймер стоит, игрок не управляется.
func _on_briefing_settings() -> void:
	if _state != State.BRIEFING:
		return
	_menu_context = MenuContext.BRIEFING
	briefing.hide_overlay()
	settings.show_overlay()


## «Назад» в настройках: возвращаем туда, откуда пришли — брифинг текущей миссии (M8a)
## или домашний экран-хаб (M8c1). Настройки звука/вибрации уже записаны и применены
## (AudioManager.set_muted), забег не перезапускается.
func _on_settings_closed() -> void:
	if _state != State.BRIEFING:
		return
	settings.hide_overlay()
	if _menu_context == MenuContext.HOME:
		home.show_overlay()
		return
	briefing.set_mission(_briefing_mission_id())
	briefing.show_overlay()


## M8a: прогресс стёрт из настроек. Зависящий от профиля UI обязан обновиться:
##   * гейт «Бесконечный» на брифинге снова закрыт (у миссий больше нет звёзд);
##   * выбранная миссия могла стать закрытой (m2/m3) — возвращаемся на m1, иначе
##     «В бой» после сброса запускал бы миссию без звёзд-разблокировки.
## Экран ангара/выбора миссии перечитывают профиль сами в refresh() при показе.
func _on_settings_progress_reset() -> void:
	_ensure_mission_unlocked()
	briefing.set_mission(_briefing_mission_id())
	briefing.refresh_endless_state()
	# M8c1: домашний экран тоже зависит от профиля (звёзды/снабжение/самолёт/гейт endless).
	home.refresh()
	# M8b: гейт endless снова закрыт — первый следующий переход будет залогирован как unlock.
	_endless_unlocked = SaveGame.is_endless_unlocked()


# ─── Домашний экран-хаб (M8c1) ──────────────────────────────────────────────
## «Кампания»: выбор миссии поверх Home (как «Миссии» с брифинга). «Назад» вернёт Home —
## _menu_context уже HOME; выбор карточки переводит контекст в брифинг.
func _on_home_campaign() -> void:
	if _state != State.BRIEFING:
		return
	_menu_context = MenuContext.HOME
	# M10: кампанийный поток начался с домашнего экрана — экран победы вернёт «Назад» сюда.
	_briefing_from_home = true
	home.hide_overlay()
	mission_select.refresh()
	mission_select.show_overlay()


## «Бесконечный» с домашнего экрана. Гейт продублирован: сигнал мог прийти программно,
## а закрытый профиль не должен запускать режим (GDD: после прохождения кампании).
func _on_home_endless() -> void:
	if _state != State.BRIEFING:
		return
	if not SaveGame.is_endless_unlocked():
		return
	start_endless()


## «Ангар» с домашнего экрана: «Назад» в ангаре вернёт Home, а не брифинг.
func _on_home_hangar() -> void:
	if _state != State.BRIEFING:
		return
	_menu_context = MenuContext.HOME
	home.hide_overlay()
	hangar.refresh()
	hangar.show_overlay()


## «Настройки» с домашнего экрана: «Назад» вернёт Home.
func _on_home_settings() -> void:
	if _state != State.BRIEFING:
		return
	_menu_context = MenuContext.HOME
	home.hide_overlay()
	settings.refresh()
	settings.show_overlay()


## Выбранная миссия обязана быть открытой: после сброса прогресса m2/m3 закрываются
## (GDD «Счёт, звёзды, снабжение»: 1 и 3 звезды суммарно), а _mission_id хранит выбор
## игрока с прошлого профиля. Возврат на миссию 1 — единственная безопасная замена.
func _ensure_mission_unlocked() -> void:
	if _mission_id.is_empty():
		return
	if SaveGame.is_mission_unlocked(_mission_id):
		return
	_mission_id = DEFAULT_MISSION_ID


# ─── Бесконечный режим (M6.3b): вход из брифинга ────────────────────────────
## «Бесконечный» на брифинге: сразу endless-забег, без брифинга и подсказок (GDD: режим
## отдельный от кампании). Гейт продублирован: сигнал мог прийти программно, а закрытый
## профиль не должен запускать режим. Миссия кампании (_mission_id) не меняется.
func _on_briefing_endless() -> void:
	if _state != State.BRIEFING:
		return
	if not SaveGame.is_endless_unlocked():
		return
	start_endless()


## Очистка всех игровых объектов: пули, враги (включая босса), подборы, эффекты, волны.
func _clear_level() -> void:
	waves.stop()
	for child in enemies_root.get_children():
		var enemy := child as EnemyBase
		if enemy != null:
			enemy.despawn()
		else:
			child.queue_free()
	for child in pickups_root.get_children():
		child.queue_free()
	for child in effects_root.get_children():
		child.queue_free()
	bullets.clear_all()


# ─── Спавн врагов ────────────────────────────────────────────────────────────
## Универсальный спавн врага: цель, подписка на сигналы, группа — настраиваются здесь.
## Здесь же форвардится HP обычных врагов (enemy_damaged) — у босса свой health_changed.
func spawn_enemy(scene: PackedScene, spawn_position: Vector2) -> EnemyBase:
	var enemy: EnemyBase = scene.instantiate()
	enemy.position = spawn_position
	enemy.target = player
	enemy.died.connect(_on_enemy_died)
	enemy.bomb_dropped.connect(_on_boss_bomb_dropped)
	enemy.health_changed.connect(_on_enemy_health_changed.bind(enemy))
	# M4: один переиспользуемый узел-вспышка на борт (у босса — ОДИН общий на все турели).
	# Узел создаётся на спавн, НЕ на выстрел — в hot-path нет аллокаций (GDD «Game feel»).
	var muzzle := MuzzleFlash.new()
	muzzle.name = "MuzzleFlash"
	muzzle.setup(
		BOSS_MUZZLE_FLASH_SIZE if enemy.is_boss else ENEMY_MUZZLE_FLASH_SIZE,
		ArtStyle.BULLET_ENEMY
	)
	enemy.add_child(muzzle)
	# M4: маршрут выстрела врага = пуля + вспышка дула.
	enemy.shot_fired.connect(_on_enemy_shot_fired.bind(enemy, muzzle))
	enemies_root.add_child(enemy)
	return enemy


## M4: вспышка дула врага. Узел валиден только пока жив борт — гвард по is_instance_valid.
func _on_enemy_shot_fired(
	origin: Vector2, velocity: Vector2, damage: int, enemy: EnemyBase, muzzle: MuzzleFlash
) -> void:
	bullets.fire_enemy(origin, velocity, damage)
	if muzzle == null or not is_instance_valid(enemy) or not muzzle.is_inside_tree():
		return
	muzzle.trigger_at(enemy.to_local(origin))


## M4: вспышка дула игрока (тот же единственный узел на все 8 выстрелов/с).
## M3-D: здесь же эмитится player_shot_fired — единственный маршрут «выстрел игрока» для аудио.
## M6.1a: модификаторы перков берутся у игрока в момент спавна (сигнал остаётся 3-аргументным):
## урон по боссу («Тяжёлый калибр») и осколки («Осколочные») общие для всех пуль игрока.
func _on_player_shot_fired(origin: Vector2, velocity: Vector2, damage: float) -> void:
	bullets.fire_player(origin, velocity, damage, player.boss_damage_mult,
		player.splash_radius, player.splash_ratio, player.bullet_hit_radius)
	player_shot_fired.emit(origin, velocity, damage)
	if player_muzzle != null and player_muzzle.is_inside_tree():
		player_muzzle.trigger_at(player.to_local(origin))


## M6.1a «РС-82»: ракета — тот же Bullet (урон 4, радиус 40, своя отрисовка).
## Juice-подписки не добавляются: у ракеты нет своего звука/вспышки в GDD «Audio».
func _on_player_rocket_fired(origin: Vector2, velocity: Vector2, damage: float, radius: float) -> void:
	bullets.spawn_rocket(origin, velocity, damage, radius, player.boss_damage_mult)


## HP обычного врага → enemy_damaged для hit-flash. Босс исключён: у него отдельный
## health_changed (полоса HP/фаза), дублировать его в общий поток не нужно.
## hp == 0 отфильтрован: смертельный удар приходит в enemy_destroyed, флешить нечего.
func _on_enemy_health_changed(hp: int, enemy: EnemyBase) -> void:
	if enemy.is_boss or hp <= 0:
		return
	enemy_damaged.emit(enemy, hp, enemy.global_position)


# ─── Волны ──────────────────────────────────────────────────────────────────
func _on_wave_started(index: int, count: int) -> void:
	# M6.3b: номер волны бесконечного забега — в HUD («Волна N»); в кампании строки нет.
	# Номер берётся у WaveManager (1-based), чтобы босс-волна 10 показывалась как «Волна 10».
	if _mode == Mode.ENDLESS:
		hud.set_wave(waves.get_wave_number())
	else:
		hud.hide_wave()
	# M8b: волна — по одному событию на волну (не в _process).
	Analytics.log_event("wave_started", {"mode": _mode_name(), "wave": waves.get_wave_number()})
	wave_started.emit(index, count)


func _on_wave_cleared(index: int) -> void:
	# M6.3a: в endless каждая пройденная волна ПОВЫШАЕТ множитель счёта (GDD: «счёт ×1.05 за
	# каждую пройденную волну»), поэтому бонус волны начисляется уже по новому множителю.
	# В кампании множитель остаётся 1.0 — счёт не меняется (smoke/итоги миссий те же).
	if _mode == Mode.ENDLESS:
		_waves_cleared += 1
		_score_multiplier = EndlessRules.score_multiplier(_waves_cleared)
	# GDD «Challenge and progression»: +250 за каждую пройденную волну.
	_add_scaled_score(WAVE_CLEAR_BONUS)
	wave_cleared.emit(index)
	# M6.1b: карта — ПОСЛЕ начисления очков (счёт в HUD успевает обновиться до паузы).
	_try_offer_perks(index)


# ─── Перки (M6.1b): сброс, предложение, применение ──────────────────────────
## Сброс набора перков и HUD-слотов. Зовётся на старте миссии/брифинга/рестарта.
## player.reset() уже сбрасывает поля оружия, но порядок задан явно: система → игрок → HUD,
## чтобы HUD не показал «HP 4/4» от прошлого забега ни одного кадра.
func _reset_perks_for_run() -> void:
	perks.reset()
	player.reset_perks()
	perk_choice.hide_choice()
	_pending_perk_wave = -1
	_perk_offered_waves.clear()
	var no_perks: Array[String] = []
	hud.set_max_hp(player.max_hp)
	hud.set_perks(no_perks)


## GDD «Временные перки»: после волн 2/3/4 — «1 из 2» на паузе. Пустое предложение
## (слоты уже заняты/нет доступных карт) оверлей не открывает: забег продолжается.
## M6.3a: в endless карта предлагается после КАЖДОЙ 2-й волны (GDD «Бесконечный режим»),
## пока есть свободные слоты — пустой руллон (3 карты уже взяты) молча пропускается.
func _try_offer_perks(index: int) -> void:
	if not _perks_enabled or _state != State.PLAYING:
		return
	if not _should_offer_perks(index) or _perk_offered_waves.has(index):
		return
	# Волна считается «предложившей» даже при пустом руллонe: повторного предложения
	# за ту же волну не будет (правило «одна карта за волну»).
	_perk_offered_waves.append(index)
	var offers: Array[String] = perks.roll_offers(PERK_OFFER_COUNT)
	if offers.is_empty():
		return
	_pending_perk_wave = index
	perk_choice.show_offers(offers)
	# Пауза ПОСЛЕ показа: PerkChoice — ALWAYS, мир волн/игрока/фона — PAUSABLE.
	get_tree().paused = true


## Волна предлагает карту: кампания — 2/3/4, endless — каждая чётная (номер волны 1-based).
func _should_offer_perks(index: int) -> bool:
	if _mode == Mode.ENDLESS:
		return EndlessRules.is_perk_wave(index + 1)
	return PERK_OFFER_WAVES.has(index)


## Выбор карты игроком. Единственный путь применения перка в забеге.
## take() возвращает false для дубля/занятого слота/неизвестного id — тогда оверлей
## остаётся на экране и решение можно принять ещё раз.
func _on_perk_chosen(id: String) -> void:
	if _pending_perk_wave < 0 or _state != State.PLAYING:
		return
	if not perks.take(id):
		return
	# M8b: выбор карты (id + номер волны 1-based). Пишется только при успешном take().
	Analytics.log_event("perk_pick", {"id": id, "wave": _pending_perk_wave + 1})
	perks.apply_to(player)
	# Порядок важен: «Ремонт» уже поднял потолок HP (heal_on_apply → health_changed(4)),
	# hud.set_hp до set_max_hp клампился бы по старому максимуму и врал в строке HP.
	hud.set_max_hp(player.max_hp)
	hud.set_hp(player.hp)
	hud.set_perks(perks.get_active())
	perk_choice.hide_choice()
	_pending_perk_wave = -1
	get_tree().paused = false
	_play_ui_click()


## M6.1b: клик выбора карты — существующий SFX ui_click (GDD «Audio»; новый ассет не нужен).
## AudioManager играет его и при снятой паузе (голоса — ALWAYS, пауза снята строкой выше).
func _play_ui_click() -> void:
	var audio := get_node_or_null(^"Audio")
	if audio != null and audio.has_method(&"play_ui_click"):
		audio.play_ui_click()


## M6.1b (гвард): снять незавершённый выбор перка БЕЗ применения карты. Используется
## исходом забега; плановый выход — _on_perk_chosen(). Пауза снимается: экран исхода
## живёт в том же окне FINISH_DELAY_*, что и всегда.
func _abort_perk_choice() -> void:
	if _pending_perk_wave < 0 and (perk_choice == null or not perk_choice.visible):
		return
	if perk_choice != null:
		perk_choice.hide_choice()
	_pending_perk_wave = -1
	get_tree().paused = false


# ─── Урон, смерть врагов, подборы ───────────────────────────────────────────
func _on_enemy_died(enemy: EnemyBase) -> void:
	if _state == State.DEAD or _state == State.WON:
		# Окно исхода: исход уже решён — очки, дропы и исход босса не трогаем, но взрыв
		# отыгрываем. Иначе сбитый в окне враг «пропадал без эффекта» (мир нечестен).
		if not enemy.is_boss:
			enemy_destroyed.emit(enemy.asset_key, enemy.global_position)
		return
	var at := enemy.global_position
	# M6.3a: в endless очки умножаются на EndlessRules.score_multiplier (в кампании 1.0).
	_add_scaled_score(enemy.score_value)
	if enemy.is_boss:
		# #3: у босса отдельный сигнал — juice не угадывает тип по узлу.
		boss_destroyed.emit(at)
		# M8b: босс сбит (в endless — не конец забега, в кампании — победа).
		Analytics.log_event("boss_end", {"type": String(enemy.asset_key), "mode": _mode_name()})
		# M6.3a: гибель босса endless НЕ завершает забег — забег идёт дальше следующей
		# волной (LevelController остаётся в PLAYING, экрана победы нет).
		if _mode == Mode.ENDLESS:
			_boss = null
			hud.hide_boss()
			waves.continue_after_boss()
			return
		_finish_run(true, at)
		return
	# Контракт — снимок (kind, at): узел врага удаляется queue_free в этом же кадре.
	enemy_destroyed.emit(enemy.asset_key, at)
	# Ремкомплект здесь больше не создаётся: GDD «Волны и враги» — «последний Ju 87 волны 4»,
	# правило целиком принадлежит WaveManager (см. _try_drop_repair), иначе флаг на враге
	# переезжал на следующего живого и за уровень падало несколько подборов.


func _on_player_damaged(hp: int, at: Vector2) -> void:
	# M6.1b «Аварийный сброс»: урон — триггер очистки вражеских пуль вокруг Ла-5.
	# Порядок: сначала сброс (пули исчезают до подписки juice/audio), потом сигнал.
	_try_emergency_clear()
	# M8a: вибрация — единственный отклик железа в игре (GDD «Настройки»: «вибрация»).
	_vibrate_on_damage()
	player_damaged.emit(hp, at)


## M8a (GDD «Настройки»): короткая вибрация на попадание по Ла-5, ЕСЛИ настройка включена.
## Настройка читается из профиля в момент события: попаданий за забег не больше HP (3),
## поэтому чтение файла здесь не «в кадре». Headless/десктоп: Input.vibrate_handheld —
## валидный вызов, платформа без вибромотора просто ничего не делает (гвард has_method —
## на случай сборки без Input-метода).
func _vibrate_on_damage() -> void:
	if not SaveGame.get_setting("vibration"):
		return
	if not Input.has_method(&"vibrate_handheld"):
		return
	Input.vibrate_handheld(VIBRATION_DURATION_MS)


## «Аварийный сброс» (GDD «Временные перки»): при уроне уничтожает вражеские пули в радиусе
## 120 px, не чаще раза в 6 с. Состояние (флаг/радиус/кулдаун) держит Player — здесь только
## триггер и очистка, чтобы механику можно было проверить без уровня.
func _try_emergency_clear() -> void:
	if not player.emergency_clear or not player.can_use_emergency_clear():
		return
	player.mark_emergency_clear_used()
	bullets.clear_enemy_bullets_in_radius(
		player.global_position, player.emergency_clear_radius)


## Создать подбор в мировой точке. Публичный: единственный ремкомплект уровня создаёт
## WaveManager (правило «последний живой Ju 87 волны 4»), причём и для сбитого, и для
## ушедшего за нижний край борта. LevelController сам подборы не роняет.
func spawn_pickup(kind: Pickup.Kind, at: Vector2) -> void:
	var pickup := Pickup.new()
	pickup.collected.connect(_on_pickup_collected)
	pickups_root.add_child(pickup)
	pickup.setup(kind, at)


## Подбор в забеге один — ремкомплект (GDD «Бомба»: подборов бомбы нет). Заряд бомбы
## пополняется ТОЛЬКО в start_level, поэтому ветки «+1 заряд» с клампом здесь больше нет:
## запас не может вырасти мимо BOMBS_AT_START.
func _on_pickup_collected(kind: int, at: Vector2) -> void:
	if not player.heal(1):
		# GDD: при полном HP ремкомплект даёт 500 очков (в endless — с множителем счёта).
		_add_scaled_score(REPAIR_FULL_HP_SCORE)
	# Контракт сигнала сохранён (kind приходит из Pickup): аудио-M3 подписывается здесь.
	pickup_collected.emit(kind, at)


# ─── Бомба игрока ───────────────────────────────────────────────────────────
func _on_bomb_pressed() -> void:
	if _state != State.PLAYING or _bombs <= 0:
		return
	_bombs -= 1
	bomb_button.set_charges(_bombs)
	use_bomb()


## Взрыв бомбы: неуязвимость, очистка вражеских пуль, мгновенная смерть обычных врагов,
## 30 урона боссу (если он есть), функциональный флеш.
func use_bomb() -> void:
	player.grant_invulnerability(BOMB_INVULNERABILITY_TIME)
	bullets.clear_enemy_bullets()
	for node in get_tree().get_nodes_in_group(GameConfig.GROUP_ENEMIES):
		var enemy := node as EnemyBase
		if enemy != null and enemy.is_active:
			enemy.on_bomb_hit()
	bomb_hit_boss(BOMB_DAMAGE_TO_BOSS)
	_spawn_bomb_flash(player.global_position)
	# #5: контракт полный — точка и радиус поражения (не заставляем juice лезть в константы).
	bomb_detonated.emit(player.global_position, BOMB_FLASH_RADIUS)


## Бомба наносит урон боссу через общий интерфейс EnemyBase (босс не в GROUP_ENEMIES).
func bomb_hit_boss(damage: int) -> void:
	var boss := get_boss()
	if boss == null:
		return
	boss.take_damage(damage)


func get_boss() -> EnemyBase:
	if _boss != null and is_instance_valid(_boss) and _boss.is_active:
		return _boss
	var nodes := get_tree().get_nodes_in_group(GameConfig.GROUP_BOSS)
	if nodes.is_empty():
		return null
	return nodes[0] as EnemyBase


## Функциональный флеш зоны бомбы ИГРОКА (620 px — всё поле). M4: оставлен ТОЛЬКО здесь;
## гибель босса и Ла-5 теперь рисуются Explosions через подписки boss_destroyed/player_died.
func _spawn_bomb_flash(center: Vector2, radius: float = BOMB_FLASH_RADIUS) -> void:
	var flash := BombFlash.new()
	flash.setup(center, radius)
	effects_root.add_child(flash)


# ─── Босс ───────────────────────────────────────────────────────────────────
func _on_boss_node_spawned(boss: EnemyBase) -> void:
	_boss = boss
	hud.show_boss(boss.max_hp, boss.hp)
	boss.health_changed.connect(hud.set_boss_hp)
	if boss.has_signal(&"phase_changed"):
		boss.phase_changed.connect(_on_boss_phase_changed)
	# M8b: тип босса — стабильный ключ арта (boss_he111 / boss_ju88 / boss_fw200).
	Analytics.log_event("boss_start", {"type": String(boss.asset_key), "mode": _mode_name()})
	boss_spawned.emit(boss)


func _on_boss_phase_changed(phase: int) -> void:
	boss_phase_changed.emit(phase)


## Бомба босса создаётся здесь: только LevelController знает про эффекты и игрока.
## #5: сигнал отдаёт точку сброса И будущую зону детонации с радиусом — juice не лезет
## в константы BossBomb (высота детонации считается от игрока, см. boss_bomb.gd).
func _on_boss_bomb_dropped(origin: Vector2) -> void:
	var bomb := BossBomb.new()
	bomb.detonated.connect(_on_boss_bomb_detonated)
	effects_root.add_child(bomb)
	bomb.setup(origin, player)
	boss_bomb_dropped.emit(origin, bomb.get_blast_point(), bomb.get_blast_radius())


func _on_boss_bomb_detonated(at: Vector2, radius: float) -> void:
	boss_bomb_detonated.emit(at, radius)


# ─── Juice (M4): установка узлов и подписки ────────────────────────────────
## Обёртка тряски НАД World (Level → ScreenShake → World), как в juice_lab.
## @onready-пути $World/* уже разрешены, когда этот метод вызывается из _ready().
func _install_shake_wrapper() -> void:
	shake = ScreenShake.new()
	shake.name = "ScreenShake"
	# ЯВНО PAUSABLE: наследование дало бы ALWAYS от Level — тряска не замирала бы на паузе.
	shake.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(shake)
	# keep_global_transform (default): World не смещается при переподчинении.
	# HUD остаётся в CanvasLayer и не трясётся — трясётся только игровой мир.
	world.reparent(shake)
	hit_stop = HitStop.new()
	hit_stop.name = "HitStop"
	add_child(hit_stop)


## Узлы juice, привязанные к игроку: одна вспышка дула + эмитеры дыма/огня.
## Создаются ОДИН раз здесь; внутри World → замирают на паузе вместе с миром.
func _install_player_juice() -> void:
	player_muzzle = MuzzleFlash.new()
	player_muzzle.name = "MuzzleFlash"
	player_muzzle.setup(PLAYER_MUZZLE_FLASH_SIZE, ArtStyle.CREAM)
	player.add_child(player_muzzle)
	damage_fx = PlayerDamageFx.new()
	damage_fx.name = "DamageFx"
	player.add_child(damage_fx)


## Все juice-подписки в одной точке (контракт: «подписываться ТОЛЬКО здесь»).
## Сигналы эмитируются синхронно в кадре события; ссылки на врагов не сохраняются.
func _connect_juice() -> void:
	player_damaged.connect(_on_juice_player_damaged)
	enemy_damaged.connect(_on_juice_enemy_damaged)
	enemy_destroyed.connect(_on_juice_enemy_destroyed)
	boss_destroyed.connect(_on_juice_boss_destroyed)
	boss_phase_changed.connect(_on_juice_boss_phase_changed)
	boss_bomb_detonated.connect(_on_juice_boss_bomb_detonated)
	bomb_detonated.connect(_on_juice_bomb_detonated)
	player_died.connect(_on_juice_player_died)
	player.health_changed.connect(_on_juice_player_health_changed)


## GDD «Game feel»: тряска 4 px / 0.15 с + hit-stop 2 кадра + белая вспышка Ла-5.
## HitFlash пишет self_modulate визуала — альфа-миг неуязвимости игрока не затирается.
func _on_juice_player_damaged(_hp: int, _at: Vector2) -> void:
	shake.shake(ScreenShake.SHAKE_PLAYER_HIT.x, ScreenShake.SHAKE_PLAYER_HIT.y)
	hit_stop.freeze(PLAYER_HITSTOP_FRAMES)
	HitFlash.flash(player_visual)


## Hit-flash врага: сигнал даёт узел, валидный до конца кадра — вспышку запускаем СРАЗУ,
## ссылку не сохраняем (контракт сигнала).
func _on_juice_enemy_damaged(enemy: EnemyBase, _hp: int, _at: Vector2) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	HitFlash.flash(enemy.get_node_or_null(^"Visual") as Node2D)


func _on_juice_enemy_destroyed(_kind: StringName, at: Vector2) -> void:
	Explosions.spawn(effects_root, at, false)


## GDD «Game feel»: большой взрыв босса + тряска 8 px / 0.4 с. ЕДИНСТВЕННЫЙ «взрыв исхода»:
## плейсхолдерный BombFlash в _finish_run убран (иначе был бы двойной взрыв).
func _on_juice_boss_destroyed(at: Vector2) -> void:
	Explosions.spawn(effects_root, at, true)
	shake.shake(ScreenShake.SHAKE_BOSS_DEATH.x, ScreenShake.SHAKE_BOSS_DEATH.y)


## GDD «Game feel»: hit-stop 2–3 кадра при смене фазы босса.
func _on_juice_boss_phase_changed(_phase: int) -> void:
	hit_stop.freeze(PHASE_HITSTOP_FRAMES)


## GDD «Game feel»: тряска 6 px / 0.25 с при бомбе игрока. Круг зоны поражения (620 px)
## остаётся функциональным BombFlash из use_bomb — взрывом его не заменяем.
func _on_juice_bomb_detonated(_at: Vector2, _radius: float) -> void:
	shake.shake(ScreenShake.SHAKE_BOMB.x, ScreenShake.SHAKE_BOMB.y)


## Точечный флеш детонации бомбы босса: БЕЗ тряски (GDD «Game feel» её не задаёт).
## Круг зоны с предупреждением рисует сам BossBomb (функционально) — искры добавляются
## поверх него как juice, второй «круг-флеш» НЕ создаётся.
func _on_juice_boss_bomb_detonated(at: Vector2, _radius: float) -> void:
	Explosions.spawn(effects_root, at, false)


## Взрыв Ла-5 на точке гибели — (tune)-замена плейсхолдерного флеша M2 (GDD «Game feel»
## задаёт большой взрыв босса; для игрока значение подобрано вручную).
func _on_juice_player_died(at: Vector2) -> void:
	Explosions.spawn(effects_root, at, false)


## GDD «Mechanics → Игрок»: 2 HP — дым, 1 HP — огонь; 3 HP и гибель — тихо.
func _on_juice_player_health_changed(hp: int) -> void:
	if damage_fx != null:
		damage_fx.set_hp(hp)


# ─── Счёт ───────────────────────────────────────────────────────────────────
func _add_score(points: int) -> void:
	if points == 0:
		return
	_score += points
	score_changed.emit(_score)


## Начисление с множителем endless (M6.3a): round(points × _score_multiplier).
## В кампании множитель 1.0 — значения и порядок прежние (smoke/итоги миссий не менялись).
func _add_scaled_score(points: int) -> void:
	if points == 0:
		return
	_add_score(int(round(float(points) * _score_multiplier)))


# ─── Аналитика (M8b): точки событий ─────────────────────────────────────────
## «campaign» / «endless» — строкой: JSONL должен быть читаемым без знания enum.
func _mode_name() -> String:
	return "endless" if _mode == Mode.ENDLESS else "campaign"


## Старт забега: режим, миссия (только кампания), самолёт из ангара. Миссию НЕ фиксируем
## в _mission_id — решение о подстановке DEFAULT_MISSION_ID остаётся за _start_run.
func _log_run_start() -> void:
	var mission := ""
	if _mode == Mode.CAMPAIGN:
		mission = _mission_id if not _mission_id.is_empty() else DEFAULT_MISSION_ID
	Analytics.log_event("run_start", {
		"mode": _mode_name(),
		"mission": mission,
		"plane": player.plane_id,
	})


## Исход забега: mode/won/score/stars/supply/duration/hp + wave (GDD «Аналитика»: «волна
## смерти»). Звёзды и снабжение — только кампанийные (в endless их нет: там рекорд и
## score/60); duration — целые секунды.
func _run_end_data(won: bool) -> Dictionary:
	var campaign := _mode == Mode.CAMPAIGN
	return {
		"mode": _mode_name(),
		"won": won,
		"score": _score,
		"stars": _last_stars if campaign else 0,
		"supply": _last_supply_gained if campaign else _endless_supply_gained,
		"duration": int(round(_elapsed)),
		"hp": maxi(0, player.hp),
		"wave": waves.get_wave_number(),
	}


## Открытия этого исхода: новые миссии, новые самолёты и ПЕРВЫЙ переход гейта endless
## (гейт помнится в _endless_unlocked — повторные победы его не логируют).
## Возвращает true, если ИМЕННО этот исход открыл бесконечный режим: экран победы показывает
## строку «Бесконечный режим открыт» (M10, bug 2 — вместо подсказки на Home).
func _log_unlocks(progress: Dictionary) -> bool:
	var missions: Array = progress.get("newly_unlocked", [])
	var planes: Array = progress.get("newly_unlocked_planes", [])
	var endless_now := SaveGame.is_endless_unlocked()
	var endless_opened := endless_now and not _endless_unlocked
	_endless_unlocked = endless_now
	if missions.is_empty() and planes.is_empty() and not endless_opened:
		return false
	Analytics.log_event("unlock", {
		"missions": _join_ids(missions),
		"planes": _join_ids(planes),
		"endless": endless_opened,
	})
	return endless_opened


## Массив id → строка через запятую: поле остаётся плоским (JSONL без вложенных массивов).
static func _join_ids(ids: Array) -> String:
	var parts := PackedStringArray()
	for id in ids:
		parts.append(str(id))
	return ",".join(parts)


# ─── Победа / поражение ─────────────────────────────────────────────────────
## Исход забега. ПОРЯДОК ВАЖЕН (гейт M2, #2): сначала run_finished, потом окно
## FINISH_DELAY_*, и только затем пауза + оверлей. Раньше paused=true выставлялся ДО
## эмита, и juice-подписчик получал сигнал в уже замороженном дереве — большой взрыв
## и тряску физически нельзя было отыграть.
## _at — точка исхода (босс/Ла-5); ЗАРЕЗЕРВИРОВАНО под будущие juice-связки: сами эффекты
## (Explosions) подписаны на boss_destroyed/player_died и отыгрываются в пределах окна.
func _finish_run(won: bool, _at: Vector2 = Vector2.ZERO) -> void:
	if _state == State.WON or _state == State.DEAD:
		return
	# M6.1b (гвард): исход во время выбора перка невозможен — дерево на паузе, — но если
	# сигнал всё же пришёл, обязательный выбор снимаем: экран исхода важнее карты.
	_abort_perk_choice()
	# M3-B: исход забега — подсказки скрываются немедленно (не висят над экраном исхода).
	hints.hide_hints()
	waves.stop()
	bullets.clear_enemy_bullets()
	# Окно исхода (#ревью): автострельба не должна добивать врагов после решения об исходе —
	# пули игрока чистятся вместе с вражескими (путь мёртвого игрока их всё равно не касается).
	bullets.clear_player_bullets()
	bomb_button.visible = false
	# #13: в исходах кнопка паузы скрыта — она не должна ловить тапы под оверлеем.
	pause_button.visible = false
	hud.hide_boss()
	# M6.3b: номер волны не висит под экраном итогов (в endless его показывает ResultLine).
	hud.hide_wave()
	_boss = null
	var token := _run_token
	# Снимок режима на момент исхода: рестарт в окне FINISH_DELAY_* поднимет _run_token и
	# вернёт нас раньше, но оверлей обязан показывать итоги ИМЕННО этого забега.
	var endless_run := _mode == Mode.ENDLESS
	if won:
		# GDD «Challenge and progression»: +250 за каждое оставшееся HP.
		_add_scaled_score(REMAINING_HP_BONUS * player.hp)
		_state = State.WON
		# M5.3a: засчёт миссии (GDD «Счёт, звёзды, снабжение»): звёзды по трём критериям,
		# рекорд миссии, снабжение и открытие следующей миссии. Порядок важен — засчёт идёт
		# ПОСЛЕ бонуса за оставшееся HP (иначе рекорд/звёзды отставали бы от показанного
		# счёта) и ДО оверлея (иначе строка рекорда была бы старой). Гвард состояния выше
		# (WON/DEAD) и ветка только для победы гарантируют: в DEAD/PAUSED/BRIEFING файл
		# сейва не трогается, повторной записи нет.
		var mission_id := _mission_id if not _mission_id.is_empty() else DEFAULT_MISSION_ID
		var progress: Dictionary = CampaignProgress.finish_mission(
			mission_id, true, player.hp, _score, MissionData.get_star_score(mission_id))
		_last_stars = int(progress.get("stars", 0))
		_last_supply_gained = int(progress.get("supply_gained", 0))
		_total_stars = int(progress.get("total_stars", 0))
		var record_best: int = int(progress.get("best", _score))
		var record_is_new: bool = bool(progress.get("is_new", false))
		# M8b: unlock — только то, что открылось ИМЕННО этим исходом (миссии/самолёты/
		# первый переход гейта endless). Повторная победа с открытой кампанией молчит.
		var endless_opened: bool = _log_unlocks(progress)
		# M8b: run_end — единственная точка исхода победы (гвард WON/DEAD выше запрещает дубль).
		Analytics.log_event("run_end", _run_end_data(true))
		# Страховка окна: бомбы босса ещё в воздухе, победа уже засчитана.
		player.grant_invulnerability(FINISH_DELAY_WIN + 0.2)
		# M4: большой взрыв босса + тряска 8 px отыгрывает подписчик boss_destroyed
		# в пределах этого же окна — отдельный плейсхолдерный флеш здесь больше НЕ создаётся.
		run_finished.emit(true, _score, _elapsed)
		await get_tree().create_timer(FINISH_DELAY_WIN).timeout
		if token != _run_token or _state != State.WON:
			return  # рестарт уже начался — отложенный оверлей не наш
		_clear_pending_boss_bombs()
		win_overlay.show_result(
			_score, _elapsed, record_best, record_is_new, _last_stars, _last_supply_gained)
		# M8b: скрытый слот ×2 снабжение — виден только при поднятом флаге ads_enabled
		# (по умолчанию false → кнопка не участвует ни в раскладке, ни в тапе).
		win_overlay.set_double_supply_available(Ads.is_available())
		# M10 (bug 2): «Бесконечный режим открыт» — только в забег, который открыл гейт
		# (≥1 звезда в каждой миссии). Подсказка с Home убрана, сообщение живёт здесь.
		win_overlay.set_unlock_notice(endless_opened)
		get_tree().paused = true
	else:
		_state = State.DEAD
		# M6.3a: в endless поражение пишет ОТДЕЛЬНЫЙ рекорд «очки + достигнутая волна»
		# (GDD «Бесконечный режим»); кампанийные звёзды/снабжение не трогаются. Снимок
		# best/is_new/wave отдаётся наружу для экрана итогов M6.3b.
		# M6.3b: здесь же начисляется снабжение endless — score / 60, один раз за забег
		# (GDD «Счёт, звёзды, снабжение»; поражение — единственный исход endless).
		if endless_run:
			_endless_wave = waves.get_wave_number()
			var record: Dictionary = SaveGame.record_endless(_score, _endless_wave)
			_endless_best = int(record.get("best", _score))
			_endless_is_new = bool(record.get("is_new", false))
			_endless_supply_gained = maxi(0, int(round(float(_score) / ENDLESS_SUPPLY_DIVISOR)))
			if _endless_supply_gained > 0:
				SaveGame.add_supply(_endless_supply_gained)
		# M8b: run_end поражения (в endless снабжение/волна уже посчитаны выше).
		Analytics.log_event("run_end", _run_end_data(false))
		# M4: взрыв Ла-5 на точке гибели отыгрывает подписчик player_died — двойного флеша нет.
		run_finished.emit(false, _score, _elapsed)
		await get_tree().create_timer(FINISH_DELAY_LOSS).timeout
		if token != _run_token or _state != State.DEAD:
			return
		_clear_pending_boss_bombs()
		# M6.3b: в endless — итоги режима (волна/счёт/рекорд); в кампании — экран
		# «Аэродром потерян». M11/T3: оба вида показывают три кнопки исхода (тап-шорткатов
		# и строки-подсказки «Тап — рестарт» больше нет — M11/T2/T3).
		if endless_run:
			death_overlay.show_endless_result(
				_score, _endless_wave, _endless_best, _endless_is_new)
		else:
			death_overlay.show_overlay()
		# M8b: скрытый слот rewarded-revive — виден только при флаге ads_enabled (default
		# false). Скрытый слот не мешает кнопкам исхода (он выше них, 552…616).
		death_overlay.set_revive_available(Ads.is_available())
		# #13 (решение): после поражения мир ПАУЗИТСЯ. Иначе враги и босс дрейфуют за
		# экраном «Аэродром потерян», а бомбы босса продолжают падать. UI/ввод живут:
		# LevelController — ALWAYS.
		get_tree().paused = true


## #13: перед паузой гасим только механические опасности — ещё не сдетонировавшие бомбы
## босса (иначе они рвутся уже поверх экрана исхода). Juice-эффекты в Effects НЕ трогаем:
## их окно — FINISH_DELAY_*, а флеши/взрывы убираются сами.
func _clear_pending_boss_bombs() -> void:
	for child in effects_root.get_children():
		if child is BossBomb:
			child.queue_free()


func _on_player_died() -> void:
	if _state != State.PLAYING:
		return
	# #4: форвардим смерть игрока — juice не должен искать сигнал на Player сам.
	player_died.emit(player.global_position)
	_finish_run(false, player.global_position)


# ─── Пауза ──────────────────────────────────────────────────────────────────
func _on_pause_requested() -> void:
	# M6.1b: во время выбора перка игра уже на паузе — кнопка не должна открывать
	# PauseOverlay поверх обязательного выбора (и не должна «продолжать» забег).
	if _pending_perk_wave >= 0:
		return
	match _state:
		State.PLAYING:
			pause_game()
		State.PAUSED:
			resume_game()


func pause_game() -> void:
	if _state != State.PLAYING or _pending_perk_wave >= 0:
		return
	_state = State.PAUSED
	# M3-B: подсказки НЕ прячем на паузе: HintsOverlay PAUSABLE — таймлайн замирает вместе
	# с миром и продолжается после resume. Скрыть их обязан только исход (см. _finish_run).
	pause_overlay.show_overlay()
	get_tree().paused = true


func resume_game() -> void:
	if _state != State.PAUSED:
		return
	get_tree().paused = false
	pause_overlay.hide_overlay()
	_state = State.PLAYING


# ─── Пауза: кнопки оверлея (M8c1, GDD «Оболочка» → «Пауза») ──────────────────
## «Продолжить» — единственный путь снятия паузы (M11/T2: тап-шорткатов нет).
func _on_pause_resume() -> void:
	if _state != State.PAUSED:
		return
	resume_game()


## «Заново» — рестарт ТЕКУЩЕГО режима (кампания → start_level, endless → start_endless),
## тем же путём, что «Повторить» на экране исхода: режим и выбранная миссия сохраняются.
func _on_pause_restart() -> void:
	if _state != State.PAUSED:
		return
	if _mode == Mode.ENDLESS:
		start_endless()
	else:
		start_level()


## «В ангар» — выход из забега на домашний экран (GDD «Пауза: … выйти в ангар»).
## show_home() сам снимает паузу, останавливает волны и очищает пули/врагов/эффекты.
func _on_pause_home() -> void:
	if _state != State.PAUSED:
		return
	show_home()


# ─── Экран победы: три действия (M10) ───────────────────────────────────────
## «Повторить» — рестарт ТОЙ ЖЕ миссии тем же путём, что «В бой» (start_level): гвард
## состояния не даёт позднему/двойному сигналу перезапустить уже идущий забег.
func _on_win_replay() -> void:
	if _state != State.WON:
		return
	start_level()


## «Кампания» — выйти из исхода в меню и открыть выбор миссии (тот же экран, что у кнопки
## «Миссии» на брифинге). Состояние → BRIEFING: забега больше нет, волны/враги/пули убраны,
## дерево разморожено (_enter_idle_state). Куда вернёт «Назад» в выборе (_menu_context):
## HOME, если кампанийный поток начался с домашнего экрана, иначе брифинг текущей миссии.
func _on_win_campaign() -> void:
	if _state != State.WON:
		return
	_enter_idle_state()
	_menu_context = MenuContext.HOME if _briefing_from_home else MenuContext.BRIEFING
	mission_select.refresh()
	mission_select.show_overlay()


## «В ангар» — выход на домашний экран (show_home: снимает паузу, чистит уровень, HUD скрыт).
func _on_win_home() -> void:
	if _state != State.WON:
		return
	show_home()


# ─── Экран поражения: три действия (M11/T3, решение D3) ──────────────────────
## «Повторить» — рестарт ТЕКУЩЕГО режима (как «Заново» в паузе): в endless — start_endless(),
## в кампании — start_level() той же миссии. Гвард состояния не даёт позднему/двойному
## сигналу перезапустить уже идущий забег.
func _on_death_replay() -> void:
	if _state != State.DEAD:
		return
	if _mode == Mode.ENDLESS:
		start_endless()
	else:
		start_level()


## «Кампания» — выход из поражения в выбор миссии (тот же путь, что у победы): забега больше
## нет, волны/враги/пули убраны, дерево разморожено (_enter_idle_state). Куда вернёт «Назад»
## в выборе (_menu_context): HOME, если кампанийный поток начался с домашнего экрана.
func _on_death_campaign() -> void:
	if _state != State.DEAD:
		return
	_enter_idle_state()
	_menu_context = MenuContext.HOME if _briefing_from_home else MenuContext.BRIEFING
	mission_select.refresh()
	mission_select.show_overlay()


## «В ангар» — выход на домашний экран (show_home: снимает паузу, чистит уровень, HUD скрыт).
func _on_death_home() -> void:
	if _state != State.DEAD:
		return
	show_home()


# ─── Доступ для тестов/QA ───────────────────────────────────────────────────
func get_state() -> State:
	return _state


func get_bombs() -> int:
	return _bombs


func get_score() -> int:
	return _score


func get_elapsed() -> float:
	return _elapsed


func get_pickup_count() -> int:
	return pickups_root.get_child_count()


## M5.1: id миссии текущего забега ("" до первого start_level).
func get_mission_id() -> String:
	return _mission_id


## M5.3a: звёзды последнего исхода (0 — поражение или забег ещё не засчитан).
func get_last_stars() -> int:
	return _last_stars


## M5.3a: снабжение, начисленное последним исходом (0 у поражения).
func get_last_supply_gained() -> int:
	return _last_supply_gained


## M5.3a: суммарные звёзды кампании после последнего исхода (снимок для UI/тестов).
func get_total_stars() -> int:
	return _total_stars


## Остановить волны (QA/тесты: изолированные проверки босса и E2E автострельбы).
func stop_waves() -> void:
	waves.stop()


## M11 (T8): QA-only принудительная победа — проверка экрана победы на устройстве
## (m1 скриптовым вводом не проходится). В релизной сборке — no-op.
func qa_force_win() -> void:
	if not OS.is_debug_build():
		return
	if _state != State.PLAYING:
		return
	_finish_run(true)


## M11 (T8): QA-кнопка принудительной победы. Только debug-сборка и только экран устройства
## (в headless-тестах узла нет, в релизе его тоже нет).
func _create_qa_force_win_button() -> void:
	if not OS.is_debug_build() or DisplayServer.get_name() == "headless":
		return
	var button := Button.new()
	button.name = "QAForceWinButton"
	button.text = "QA"
	button.focus_mode = Control.FOCUS_NONE
	button.position = Vector2(8.0, 904.0)
	button.size = Vector2(72.0, 48.0)
	button.add_theme_font_size_override("font_size", 20)
	$UI.add_child(button)
	# Android: emulate_mouse_from_touch=false → Button.pressed от тапа не приходит,
	# единственный рабочий путь — gui_input + InputEventScreenTouch.
	button.gui_input.connect(func(event: InputEvent) -> void:
		if not (event is InputEventScreenTouch):
			return
		button.accept_event()
		if (event as InputEventScreenTouch).pressed:
			qa_force_win())


# ─── Бесконечный режим: доступ для тестов/QA (M6.3a) ────────────────────────
func get_mode() -> Mode:
	return _mode


func is_endless() -> bool:
	return _mode == Mode.ENDLESS


## Номер текущей волны endless (1-based). В кампании — волна уровня + 1 (босс = 7).
func get_endless_wave() -> int:
	return waves.get_wave_number()


## Лучший счёт endless после последнего исхода (0 — рекорда ещё не было).
func get_endless_best() -> int:
	return _endless_best


## Последний исход endless улучшил рекорд счёта (для строки «Новый рекорд!» в M6.3b).
func get_endless_is_new() -> bool:
	return _endless_is_new


## M6.3b: снабжение, начисленное последним endless-забегом (score / 60; 0 в кампании,
## до поражения и при нулевом счёте).
func get_endless_supply_gained() -> int:
	return _endless_supply_gained


## Множитель счёта текущего забега (1.0 в кампании; 1.05^n в endless).
func get_score_multiplier() -> float:
	return _score_multiplier


## Сколько волн закрыто в endless (для множителя и экрана итогов M6.3b).
func get_waves_cleared() -> int:
	return _waves_cleared


# ─── Перки: доступ для тестов/QA (M6.1b) ────────────────────────────────────
## Включить/выключить предложение карт. smoke-тест выключает перки, чтобы E2E-прогон
## не вставал на паузу посреди волн (UI выбора проверяется в tests/perk_choice_test.tscn).
func set_perks_enabled(enabled: bool) -> void:
	_perks_enabled = enabled


func is_perks_enabled() -> bool:
	return _perks_enabled


func is_perk_choice_visible() -> bool:
	return perk_choice != null and perk_choice.visible


## Система перков забега (null до _ready).
func get_perk_system() -> PerkSystem:
	return perks


## Волна, чья карта ждёт выбора (-1 — выбора нет).
func get_pending_perk_wave() -> int:
	return _pending_perk_wave


## Волны, уже предложившие карту в этом забеге (индексы 0-based).
func get_perk_offered_waves() -> Array[int]:
	return _perk_offered_waves.duplicate()
