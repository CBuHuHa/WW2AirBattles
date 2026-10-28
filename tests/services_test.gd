# services_test.gd
# Purpose: Гейт M8b — локальная аналитика и адаптеры Ads/IAP со заглушками. Проверяет:
#            • свежий профиль: ads_enabled=false, shop_enabled=false, Ads.is_available()=false,
#              Iap.is_available()=false, каталог пуст, show_rewarded()/purchase() = false и
#              колбэк НЕ вызывается (награды нет);
#            • поднятые флаги: Ads.is_available()=true, но show_rewarded() по-прежнему false
#              (SDK нет); shop_enabled=true → каталог непустой (3 скина-заглушки), purchase()
#              false; флаги пишутся в [flags] и переживают перезапись профиля; неизвестный
#              флаг не читается и не пишется; reset() возвращает флаги к false;
#            • Analytics: выключенная не пишет и не копит; включённая с temp-путём пишет JSONL
#              (ts/event, по строке на событие), get_events() видит run_start/wave_started/
#              run_end, буфер ≤200 (старые вытесняются), clear() очищает, выключение
#              останавливает запись; реальный user://analytics.log не тронут (слепок);
#            • main.tscn: ReviveButton («Продолжить за рекламу») и DoubleSupplyButton
#              («Снабжение ×2 за рекламу») скрыты на брифинге, не пересекаются со строками
#              оверлеев и с кнопками исхода (M11/T3), остаются скрытыми и при показанных
#              оверлеях (флаги false); M11/T2: тап по свободному месту экрана поражения
#              ничего не делает, рестарт кампании даёт кнопка «Повторить».
#          Изоляция: профиль — user://qa_services_*.cfg, аналитика — user://qa_analytics_*.log;
#          реальные user://ww2_air_battles.cfg и user://analytics.log не читаются и не пишутся
#          (слепки до/после).
# Запуск: godot --headless --path . res://tests/services_test.tscn
# Dependencies: Analytics, Ads, Iap, SaveGame, RunRecord, LevelController (main.tscn),
#               DeathOverlay, WinOverlay, GameConfig.
# Author: Mechanics Developer Agent (M8b)

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")

const M1 := "m1_airfield"

## Ожидаемые тексты скрытых слотов (RU, player-facing).
const REVIVE_TEXT := "Продолжить за рекламу"
const DOUBLE_SUPPLY_TEXT := "Снабжение ×2 за рекламу"

## Флаги: имена и значения из GDD «Монетизация» (по умолчанию оба false).
const FLAG_ADS := "ads_enabled"
const FLAG_SHOP := "shop_enabled"
const UNKNOWN_FLAG := "not_a_flag"

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальные qa-файлы прогона: реальный профиль и реальный лог аналитики не трогаются.
var _save_path: String = ""
var _analytics_path: String = ""
var _real_save_snapshot: Dictionary = {}
var _real_analytics_snapshot: Dictionary = {}
var _level: LevelController


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	# Слепки ДО любой работы: доказываем, что реальные файлы не изменены.
	_real_save_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_real_analytics_snapshot = _file_snapshot(Analytics.DEFAULT_SINK_PATH)
	_save_path = "user://qa_services_%d.cfg" % Time.get_ticks_msec()
	_analytics_path = "user://qa_analytics_%d.log" % Time.get_ticks_msec()
	SaveGame.set_save_path(_save_path)
	Analytics.clear()
	Analytics.set_sink_path(_analytics_path)
	await _run()
	# Уборка: тестовый уровень, файлы прогона, пути к профилю/аналитике.
	if _level != null:
		_level.stop_waves()
		for child in _level.enemies_root.get_children():
			child.queue_free()
		_level.bullets.clear_all()
		_level.queue_free()
		_level = null
	await get_tree().process_frame
	await get_tree().process_frame
	_remove_file(_save_path)
	_remove_file(_analytics_path)
	Analytics.reset_sink_path()
	Analytics.set_enabled(false)
	RunRecord.reset_save_path()
	_check("изоляция: пути профиля и аналитики вернулись к дефолтным, qa-файлы удалены",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH
		and Analytics.get_sink_path() == Analytics.DEFAULT_SINK_PATH
		and not FileAccess.file_exists(_save_path)
		and not FileAccess.file_exists(_analytics_path),
		"%s / %s" % [SaveGame.get_save_path(), Analytics.get_sink_path()])
	var real_save_after := _file_snapshot(RunRecord.DEFAULT_PATH)
	var real_log_after := _file_snapshot(Analytics.DEFAULT_SINK_PATH)
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_save_snapshot, real_save_after),
		"%s → %s" % [_snapshot_brief(_real_save_snapshot), _snapshot_brief(real_save_after)])
	_check("изоляция: реальный user://analytics.log не тронут прогоном",
		_snapshots_equal(_real_analytics_snapshot, real_log_after),
		"%s → %s" % [_snapshot_brief(_real_analytics_snapshot), _snapshot_brief(real_log_after)])
	print("SERVICES_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("SERVICES_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_fresh()
	_check_fresh_profile()
	_check_flags()
	_check_analytics()
	_check_ui_slots()
	await _check_main_scene()


# ─── 1. Свежий профиль: заглушки выключены ──────────────────────────────────
func _check_fresh_profile() -> void:
	_check("свежий профиль: флаги ads_enabled/shop_enabled выключены",
		not SaveGame.get_flag(FLAG_ADS) and not SaveGame.get_flag(FLAG_SHOP),
		"ads=%s shop=%s" % [SaveGame.get_flag(FLAG_ADS), SaveGame.get_flag(FLAG_SHOP)])
	_check("свежий профиль: Ads.is_available() == false и Iap.is_available() == false",
		not Ads.is_available() and not Iap.is_available(),
		"ads=%s iap=%s" % [Ads.is_available(), Iap.is_available()])
	_check("свежий профиль: каталог IAP пуст", Iap.get_catalog().is_empty(),
		str(Iap.get_catalog()))
	# Колбэк-награда: заглушка не имеет права «выдать» ничего даже при вызове.
	var calls: Array = []
	var callback := func() -> void: calls.append(1)
	var revive_shown := Ads.show_rewarded(Ads.REVIVE, callback)
	var double_shown := Ads.show_rewarded(Ads.DOUBLE_SUPPLY, callback)
	_check("заглушка Ads: show_rewarded(REVIVE/DOUBLE_SUPPLY) == false, колбэк не вызван",
		not revive_shown and not double_shown and calls.is_empty(),
		"revive=%s double=%s calls=%d" % [revive_shown, double_shown, calls.size()])
	var purchased := Iap.purchase(Iap.SKIN_LIVERY_1, callback)
	_check("заглушка IAP: purchase(SKIN_LIVERY_1) == false, колбэк не вызван",
		not purchased and calls.is_empty(), "purchase=%s calls=%d" % [purchased, calls.size()])
	_check("плейсменты Ads: revive/supply известны, неизвестный тип — пустая строка",
		Ads.get_placement(Ads.REVIVE) == "revive_after_death"
		and Ads.get_placement(Ads.DOUBLE_SUPPLY) == "supply_double_after_win"
		and Ads.get_placement("nope") == "",
		"%s / %s / «%s»" % [Ads.get_placement(Ads.REVIVE),
			Ads.get_placement(Ads.DOUBLE_SUPPLY), Ads.get_placement("nope")])
	# Материализуем профиль записью «значение == дефолт»: _ensure_defaults кладёт оба флага
	# в файл явными false — иначе на отсутствующем файле «false» неотличим от «нет ключа».
	SaveGame.set_flag(FLAG_SHOP, false)
	var text := _file_text(_save_path)
	_check("свежий профиль: [flags] пишет ads_enabled=false и shop_enabled=false",
		text.contains("[" + SaveGame.SECTION_FLAGS + "]")
		and text.contains("%s=false" % FLAG_ADS)
		and text.contains("%s=false" % FLAG_SHOP),
		_snapshot_brief(_file_snapshot(_save_path)))


# ─── 2. Флаги: запись, перезапись, сброс ────────────────────────────────────
func _check_flags() -> void:
	SaveGame.set_flag(FLAG_ADS, true)
	_check("флаг ads_enabled=true: записан и читается из профиля",
		SaveGame.get_flag(FLAG_ADS, false) and Ads.is_available(),
		"flag=%s available=%s" % [SaveGame.get_flag(FLAG_ADS, false), Ads.is_available()])
	# Даже при поднятом флаге показ — заглушка: слот можно показать, награды нет.
	var calls: Array = []
	var shown := Ads.show_rewarded(Ads.REVIVE, func() -> void: calls.append(1))
	_check("флаг включён: show_rewarded всё равно false (SDK нет), колбэк не вызван",
		not shown and calls.is_empty(), "shown=%s calls=%d" % [shown, calls.size()])
	# Перезапись профиля другим действием не должна терять флаг.
	SaveGame.add_supply(1)
	_check("флаг переживает перезапись профиля (add_supply, чужая секция не стёрта)",
		SaveGame.get_flag(FLAG_ADS, false) and SaveGame.get_supply() == 1,
		"ads=%s supply=%d" % [SaveGame.get_flag(FLAG_ADS, false), SaveGame.get_supply()])
	SaveGame.set_flag(FLAG_SHOP, true)
	var catalog := Iap.get_catalog()
	var skus: Array = []
	for item in catalog:
		skus.append(String((item as Dictionary).get("sku", "")))
	_check("флаг shop_enabled=true: каталог непустой (3 скина-заглушки, порядок SKIN_IDS)",
		Iap.is_available() and catalog.size() == Iap.SKIN_IDS.size()
		and skus == Iap.SKIN_IDS,
		"size=%d %s" % [catalog.size(), str(skus)])
	var purchase_calls: Array = []
	var bought := Iap.purchase(Iap.SKIN_LIVERY_2, func() -> void: purchase_calls.append(1))
	_check("флаг включён: purchase всё равно false (SDK нет), колбэк не вызван",
		not bought and purchase_calls.is_empty(),
		"bought=%s calls=%d" % [bought, purchase_calls.size()])
	_check("каталог: has_sku() знает три скина и не знает чужой",
		Iap.has_sku(Iap.SKIN_LIVERY_1) and Iap.has_sku(Iap.SKIN_LIVERY_3)
		and not Iap.has_sku("skin_unknown"))
	# Неизвестный флаг не пишется в профиль и не читается как настоящий.
	SaveGame.set_flag(UNKNOWN_FLAG, true)
	_check("неизвестный флаг: не читается (default), чужие имена в файл не попадают",
		not SaveGame.get_flag(UNKNOWN_FLAG, false)
		and not _file_text(_save_path).contains(UNKNOWN_FLAG),
		"flag=%s" % SaveGame.get_flag(UNKNOWN_FLAG, false))
	_check("профиль: секция [flags] содержит оба флага = true",
		_file_text(_save_path).contains("[" + SaveGame.SECTION_FLAGS + "]")
		and _file_text(_save_path).contains("%s=true" % FLAG_ADS)
		and _file_text(_save_path).contains("%s=true" % FLAG_SHOP),
		_snapshot_brief(_file_snapshot(_save_path)))
	# Сброс прогресса удаляет файл: флаги снова выключены (дефолт), как и весь профиль.
	SaveGame.reset()
	_check("после reset(): флаги снова false (слоты Ads/IAP скрыты)",
		not SaveGame.get_flag(FLAG_ADS) and not SaveGame.get_flag(FLAG_SHOP)
		and not Ads.is_available() and not Iap.is_available()
		and Iap.get_catalog().is_empty())


# ─── 3. Аналитика: JSONL, буфер, выключение ─────────────────────────────────
func _check_analytics() -> void:
	_remove_file(_analytics_path)
	Analytics.clear()
	Analytics.set_enabled(false)
	Analytics.log_event("should_not_be_written", {"x": 1})
	_check("аналитика выключена: событие не копится и файл не создаётся",
		Analytics.get_events().is_empty() and not FileAccess.file_exists(_analytics_path),
		"events=%d exists=%s" % [Analytics.get_events().size(),
			FileAccess.file_exists(_analytics_path)])

	Analytics.set_enabled(true)
	Analytics.log_event("run_start", {"mode": "campaign", "mission": M1, "plane": "la5"})
	Analytics.log_event("wave_started", {"mode": "campaign", "wave": 2})
	Analytics.log_event("run_end", {"mode": "campaign", "won": true, "score": 1234})
	var events := Analytics.get_events()
	var names: Array = []
	for event in events:
		names.append(String((event as Dictionary).get("event", "")))
	_check("аналитика включена: буфер видит run_start/wave_started/run_end",
		names == ["run_start", "wave_started", "run_end"], str(names))
	_check("формат события: ts (int) + event (строка) + плоские поля",
		events.size() == 3 and int(events[0].get("ts", -1)) > 0
		and String(events[0].get("mission", "")) == M1
		and int(events[0].get("ts", 0)) <= int(events[2].get("ts", 0)),
		str(events[0]))
	var lines := _json_lines(_analytics_path)
	var parsed_ok := lines.size() == 3
	for line in lines:
		if typeof(line) != TYPE_DICTIONARY:
			parsed_ok = false
			continue
		var record := line as Dictionary
		if not record.has("ts") or not record.has("event") or int(record.get("ts", 0)) <= 0:
			parsed_ok = false
	_check("файл analytics.log: JSONL, по строке на событие, ts/event в каждой",
		parsed_ok and String((lines[2] as Dictionary).get("event", "")) == "run_end",
		"%d строк" % lines.size())

	# Потолок буфера: 200 последних, старые вытесняются.
	Analytics.clear()
	for index in 250:
		Analytics.log_event("flood", {"i": index})
	var flood := Analytics.get_events()
	_check("буфер ≤ %d: самые старые вытеснены (первое событие i=50)" % Analytics.MAX_EVENTS,
		flood.size() == Analytics.MAX_EVENTS and int(flood[0].get("i", -1)) == 50
		and int(flood[flood.size() - 1].get("i", -1)) == 249,
		"size=%d first=%s last=%s" % [flood.size(),
			str(flood[0].get("i", -1)), str(flood[flood.size() - 1].get("i", -1))])
	Analytics.clear()
	_check("clear(): буфер пуст", Analytics.get_events().is_empty(),
		"events=%d" % Analytics.get_events().size())

	# Выключение останавливает и буфер, и запись в файл.
	var lines_before := _non_empty_lines(_analytics_path)
	Analytics.set_enabled(false)
	for index in 5:
		Analytics.log_event("ignored", {"i": index})
	_check("выключение: новые события не копятся и не пишутся",
		Analytics.get_events().is_empty()
		and _non_empty_lines(_analytics_path) == lines_before,
		"events=%d строк %d→%d" % [Analytics.get_events().size(), lines_before,
			_non_empty_lines(_analytics_path)])
	Analytics.log_event("still_ignored")
	_check("выключение: повторный лог не появился ни в буфере, ни в файле",
		Analytics.get_events().is_empty()
		and _non_empty_lines(_analytics_path) == lines_before,
		"events=%d строк %d" % [Analytics.get_events().size(),
			_non_empty_lines(_analytics_path)])
	# QA-путь: пустая строка возвращает дефолт, затем снова temp-файл.
	Analytics.set_sink_path("")
	var default_path := Analytics.get_sink_path()
	Analytics.set_sink_path(_analytics_path)
	_check("set_sink_path(\"\"): возвращает путь по умолчанию, пустой строкой не пишет",
		default_path == Analytics.DEFAULT_SINK_PATH
		and Analytics.get_sink_path() == _analytics_path,
		"%s → %s" % [default_path, Analytics.get_sink_path()])


# ─── 4. Скрытые UI-слоты: тексты заглушек ───────────────────────────────────
## Отдельных сцен death/win у проекта нет (оверлеи живут в main.tscn), поэтому геометрия и
## видимость кнопок проверяются в _check_main_scene(). Здесь — только константы контракта:
## тексты слотов заданы и совпадают с тем, что ожидает UI-агент.
func _check_ui_slots() -> void:
	_check("слоты: тексты заглушек заданы (revive/×2) и не пусты",
		not REVIVE_TEXT.is_empty() and not DOUBLE_SUPPLY_TEXT.is_empty()
		and REVIVE_TEXT != DOUBLE_SUPPLY_TEXT,
		"%s / %s" % [REVIVE_TEXT, DOUBLE_SUPPLY_TEXT])


# ─── 5. main.tscn: кнопки скрыты, события идут, тап-рестарт прежний ─────────
func _check_main_scene() -> void:
	# Аналитика включена на temp-путь: проверяем, что штатные точки LevelController реально
	# пишут события (app_start/run_start/wave_started/run_end), а не только прямой log_event.
	Analytics.clear()
	Analytics.set_enabled(true)
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	await get_tree().physics_frame
	var death := _level.death_overlay
	var win := _level.win_overlay
	_check("LevelController: app_start записан при создании сцены",
		_event_names().has("app_start"), str(_event_names()))
	_check("main.tscn: ReviveButton есть в сцене, текст «%s»" % REVIVE_TEXT,
		death.revive_button != null and death.get_revive_text() == REVIVE_TEXT,
		death.get_revive_text())
	_check("main.tscn: DoubleSupplyButton есть в сцене, текст «%s»" % DOUBLE_SUPPLY_TEXT,
		win.double_supply_button != null and win.get_double_supply_text() == DOUBLE_SUPPLY_TEXT,
		win.get_double_supply_text())
	_check("main.tscn: на брифинге оба слота скрыты (флаги false)",
		not death.is_revive_visible() and not win.is_double_supply_visible()
		and not death.visible and not win.visible)
	# Показанные оверлеи при выключенных флагах кнопок не включают.
	death.show_overlay()
	win.show_result(1000, 61.0, 900, false, 2, 150)
	_check("оверлеи показаны: слоты остаются скрытыми без флага",
		death.visible and win.visible
		and not death.is_revive_visible() and not win.is_double_supply_visible())
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var revive_rect := death.revive_button.get_global_rect()
	var double_rect := win.double_supply_button.get_global_rect()
	_check("слот revive: в поле, не наезжает на заголовок и не перекрывает 3 кнопки исхода",
		_rect_inside(revive_rect, field)
		and not _rects_overlap(revive_rect, (death.get_node(^"Title") as Label).get_global_rect())
		and _death_buttons_below_slot(death, revive_rect, field),
		"%s" % revive_rect)
	_check("слот ×2: внутри поля и не наезжает на строки итогов, звёзды и кнопку «Повторить»",
		_rect_inside(double_rect, field)
		and not _rects_overlap(double_rect, win.supply_line.get_global_rect())
		and not _rects_overlap(double_rect, win.stars_line.get_global_rect())
		and not _rects_overlap(double_rect, win.replay_button.get_global_rect()),
		"%s" % double_rect)
	# Прямой вызов API: кнопка показывается, но награды нет (заглушка).
	death.set_revive_available(true)
	win.set_double_supply_available(true)
	var revive_tap := death.tap_revive()
	var double_tap := win.tap_double_supply()
	_check("заглушка: показанный слот принимает тап, но награды нет (false)",
		death.is_revive_visible() and win.is_double_supply_visible()
		and not revive_tap and not double_tap,
		"revive=%s double=%s" % [revive_tap, double_tap])
	death.set_revive_available(false)
	win.set_double_supply_available(false)
	_check("hide_overlay(): слоты снова скрыты (состояние не переживает экран)",
		not death.is_revive_visible() and not win.is_double_supply_visible())
	death.hide_overlay()
	win.hide_overlay()

	# Реальный забег: смерть в кампании → прежний экран и прежний тап-рестарт.
	_check("main.tscn: состояние BRIEFING, волны не запущены",
		_level.get_state() == LevelController.State.BRIEFING,
		str(_level.get_state()))
	_level.start_mission(M1)
	await get_tree().process_frame
	_level.set_perks_enabled(false)
	await get_tree().process_frame
	var run_start_event := _last_event("run_start")
	var wave_event := _last_event("wave_started")
	_check("LevelController: run_start (campaign/m1/la5) и wave_started (волна 1) записаны",
		String(run_start_event.get("mode", "")) == "campaign"
		and String(run_start_event.get("mission", "")) == M1
		and String(run_start_event.get("plane", "")) == "la5"
		and String(wave_event.get("mode", "")) == "campaign"
		and int(wave_event.get("wave", 0)) == 1,
		"%s / %s" % [str(run_start_event), str(wave_event)])
	_level.player.grant_invulnerability(999.0)
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	var died := await _wait_until(
		func() -> bool: return _level.death_overlay.visible, 2.0)
	var run_end_event := _last_event("run_end")
	_check("смерть кампании: экран «Аэродром потерян», ReviveButton скрыт",
		died and _level.get_state() == LevelController.State.DEAD
		and not death.is_endless_view() and not death.is_revive_visible(),
		"died=%s state=%d revive=%s" % [died, _level.get_state(),
			death.is_revive_visible()])
	_check("LevelController: run_end поражения (campaign, won=false, hp=0, волна) записан один раз",
		String(run_end_event.get("mode", "")) == "campaign"
		and not bool(run_end_event.get("won", true))
		and int(run_end_event.get("hp", -1)) == 0
		and int(run_end_event.get("wave", 0)) >= 1
		and _event_names().count("run_end") == 1,
		"%s (run_end × %d)" % [str(run_end_event), _event_names().count("run_end")])
	# Дальше аналитика выключена: рестарт не должен добавлять строк в лог.
	Analytics.set_enabled(false)
	var lines_before := _non_empty_lines(_analytics_path)
	# M11/T2: тап по свободному месту экрана поражения больше ничего не делает (тап-шорткатов
	# нет — LevelController._unhandled_input удалён), рестарт даёт только кнопка «Повторить».
	var free_touch := _touch_event(true)
	free_touch.position = Vector2(270.0, 480.0)
	_level.get_viewport().push_input(free_touch)
	await get_tree().process_frame
	_check("тап на экране поражения ничего не делает (DEAD, экран жив, пауза)",
		_level.get_state() == LevelController.State.DEAD and death.visible
		and get_tree().paused,
		"state=%d, death=%s, paused=%s" % [_level.get_state(), death.visible,
			get_tree().paused])
	_check("кнопка «Повторить» на экране поражения принята", death.request_replay())
	await get_tree().process_frame
	_check("«Повторить» на экране поражения: рестарт кампании (PLAYING, волны идут)",
		_level.get_state() == LevelController.State.PLAYING
		and _level.get_mode() == LevelController.Mode.CAMPAIGN
		and not death.visible and not death.is_revive_visible()
		and not get_tree().paused,
		"state=%d mode=%d" % [_level.get_state(), _level.get_mode()])
	_check("main.tscn при выключенной аналитике не пишет ни строки",
		_non_empty_lines(_analytics_path) == lines_before,
		"%d → %d" % [lines_before, _non_empty_lines(_analytics_path)])


# ─── Помощники ──────────────────────────────────────────────────────────────
func _fresh() -> void:
	_remove_file(_save_path)


## Имена событий в буфере аналитики (в порядке записи).
func _event_names() -> Array:
	var names: Array = []
	for event in Analytics.get_events():
		names.append(String((event as Dictionary).get("event", "")))
	return names


## Последнее событие с данным именем ({} — такого не было).
func _last_event(name: String) -> Dictionary:
	var found := {}
	for event in Analytics.get_events():
		var record := event as Dictionary
		if String(record.get("event", "")) == name:
			found = record
	return found


func _touch_event(pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = Vector2(270.0, 480.0)
	return event


func _rect_inside(rect: Rect2, field: Rect2) -> bool:
	return rect.position.x >= field.position.x - 0.5 and rect.position.y >= field.position.y - 0.5 \
		and rect.end.x <= field.end.x + 0.5 and rect.end.y <= field.end.y + 0.5


func _rects_overlap(left: Rect2, right: Rect2) -> bool:
	return left.intersects(right)


## M11/T3: три кнопки экрана поражения видны, 320×88, внутри поля и не перекрывают слот revive.
func _death_buttons_below_slot(death: DeathOverlay, slot: Rect2, field: Rect2) -> bool:
	if death.get_visible_action_button_count() != 3:
		return false
	for button: Button in [death.replay_button, death.campaign_button, death.home_button]:
		if button == null or not button.visible:
			return false
		var rect := button.get_global_rect()
		if not _rect_inside(rect, field) or not is_equal_approx(rect.size.x, 320.0) \
				or not is_equal_approx(rect.size.y, 88.0):
			return false
		if _rects_overlap(rect, slot):
			return false
	return true


func _wait_until(condition: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return bool(condition.call())


func _remove_file(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _file_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


## Сколько НЕпустых строк в файле (JSONL: одна строка = одно событие).
func _non_empty_lines(path: String) -> int:
	var count := 0
	for raw_line in _file_text(path).split("\n"):
		if not raw_line.strip_edges().is_empty():
			count += 1
	return count


## Разобранные строки файла (Variant из JSON.parse_string; null — строка битая).
func _json_lines(path: String) -> Array:
	var parsed: Array = []
	for raw_line in _file_text(path).split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		parsed.append(JSON.parse_string(line))
	return parsed


func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": -1, "mtime": -1, "text": ""}
	return {
		"exists": true,
		"size": _file_text(path).length(),
		"mtime": FileAccess.get_modified_time(path),
		"text": _file_text(path),
	}


func _snapshots_equal(left: Dictionary, right: Dictionary) -> bool:
	return bool(left.get("exists")) == bool(right.get("exists")) \
		and int(left.get("size")) == int(right.get("size")) \
		and int(left.get("mtime")) == int(right.get("mtime")) \
		and String(left.get("text")) == String(right.get("text"))


func _snapshot_brief(snapshot: Dictionary) -> String:
	if not bool(snapshot.get("exists")):
		return "<нет файла>"
	return "%d B, mtime %d" % [int(snapshot.get("size")), int(snapshot.get("mtime"))]


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
