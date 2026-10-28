# home_test.gd
# Purpose: Гейт M8c1 — домашний экран-хаб и пауза с выходом в ангар. Проверяет:
#            • чистый профиль: Home скрыт по умолчанию, заголовок игры «WW2 Air Battles»,
#              подзаголовка нет (M10, bug 4), 4 кнопки («Кампания»/«Бесконечный»/«Ангар»/
#              «Настройки»), «Звёзды: 0/9», «Снабжение: 0», имя «Ла-5», превью player_la5 2×
#              без ливреи;
#            • гейт endless: кнопка disabled, request_endless() по закрытому гейту → false без
#              сигнала; после 1 звезды в каждой миссии + refresh() кнопка активна;
#              M10 (bug 2): подсказки «Откроется после прохождения кампании» на Home НЕТ —
#              сообщение об открытии режима показывает экран победы (mission_select_test);
#            • раскладка: заголовок «WW2 Air Battles» влезает в 540, превью под заголовком без
#              наложения (M10: контент сдвинут вверх после удаления подзаголовка), 4 кнопки
#              320×88 внутри 540×960, без наложений; root/Dim IGNORE, кнопки STOP, экран
#              ALWAYS; латч одного касания;
#            • профиль: снабжение/звёзды в строках, выбранный Як-3 в имени и превью,
#              ливрея-тинт на превью;
#            • main.tscn: при запуске Home (брифинг скрыт, HUD/бомба/пауза/волны нет);
#              «Кампания» → MissionSelect → «Назад» → Home; «Ангар»/«Настройки» → экран →
#              «Назад» → Home; с брифинга те же кнопки возвращают брифинг, а не Home;
#            • endless с Home: гейт открыт → request_endless() → mode ENDLESS/PLAYING,
#              Home скрыт, HUD виден;
#            • пауза: оверлей и 3 кнопки (320×88) не накрывают центр поля; «Продолжить» →
#              PLAYING; «Заново» рестартит ТЕКУЩИЙ режим; «В ангар» → Home (пауза снята,
#              волны/враги/HUD скрыты); M11/T2: тап мимо кнопок ничего не делает — паузу
#              снимает только «Продолжить».
#          Изоляция: сейв живёт в user://qa_home_*.cfg, реальный
#          user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/home_test.tscn
# Dependencies: Home, PauseOverlay, LevelController (main.tscn), SaveGame, PlaneData,
#               ArtStyle, Player, RunRecord, GameConfig.
# Author: UI/UX Agent (M8c1)

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const HOME_SCENE: PackedScene = preload("res://scenes/home.tscn")

const LA5 := "la5"
const YAK3 := "yak3"
const M1 := "m1_airfield"
const M2 := "m2_crossing"
const M3 := "m3_city"

const HOME_TITLE := "WW2 Air Battles"
## M10 (bug 2): строка убрана с Home — проверяем, что её нигде нет (ни узла, ни текста).
const REMOVED_ENDLESS_HINT := "Откроется после прохождения кампании"
const BUTTON_TEXTS := ["Кампания", "Бесконечный", "Ангар", "Настройки"]

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}
var _home: Home
var _level: LevelController


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_home_%d.cfg" % Time.get_ticks_msec()
	SaveGame.set_save_path(_path)
	await _run()
	# Уборка: тестовые узлы, файл прогона и путь к сейву.
	if _level != null:
		_level.stop_waves()
		for child in _level.enemies_root.get_children():
			child.queue_free()
		_level.bullets.clear_all()
		_level.queue_free()
		_level = null
	if _home != null:
		_home.queue_free()
		_home = null
	await get_tree().process_frame
	_remove_file(_path)
	RunRecord.reset_save_path()
	_check("изоляция: путь вернулся к DEFAULT_PATH и qa-файл удалён",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH and not FileAccess.file_exists(_path),
		SaveGame.get_save_path())
	var real_after := _file_snapshot(RunRecord.DEFAULT_PATH)
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_snapshot, real_after),
		"%s → %s" % [_snapshot_brief(_real_snapshot), _snapshot_brief(real_after)])
	print("HOME_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("HOME_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	await _check_fresh_profile()
	await _check_layout_and_input()
	await _check_profile_refresh()
	await _check_main_scene_boot()
	_check_navigation()
	await _check_endless_from_home()
	await _check_pause()


# ─── Чистый профиль ─────────────────────────────────────────────────────────
func _check_fresh_profile() -> void:
	_fresh()
	_home = HOME_SCENE.instantiate()
	add_child(_home)
	await get_tree().process_frame
	await get_tree().process_frame

	_check("свежий профиль: экран скрыт по умолчанию", not _home.visible)
	_check("свежий профиль: заголовок «%s»" % HOME_TITLE,
		_label("Title") == HOME_TITLE, _label("Title"))
	# M10 (bug 4): подзаголовка нет — узел удалён из сцены, «Оборона аэродрома» живёт только
	# на брифинге (заголовок миссии 1).
	_check("свежий профиль: подзаголовка нет (узел Subtitle удалён)",
		_home.get_node_or_null(^"Subtitle") == null,
		"узел Subtitle на месте")
	_check("свежий профиль: «Оборона аэродрома» на домашний экран не попала",
		_label("Title") != "Оборона аэродрома", _label("Title"))
	_check("свежий профиль: 4 кнопки и подписи «Кампания»/«Бесконечный»/«Ангар»/«Настройки»",
		_home.get_visible_button_count() == 4 and _button_texts() == BUTTON_TEXTS,
		"%d / %s" % [_home.get_visible_button_count(), str(_button_texts())])
	_check("свежий профиль: «Звёзды: 0/9» и «Снабжение: 0»",
		_home.get_stars_text() == "Звёзды: 0/9" and _home.get_supply_text() == "Снабжение: 0",
		"%s / %s" % [_home.get_stars_text(), _home.get_supply_text()])
	var preview := _preview()
	_check("свежий профиль: «Ла-5», превью player_la5 2× без ливреи",
		_home.get_plane_name() == "Ла-5" and preview != null
		and preview.asset_key == &"player_la5" and preview.scale == Vector2(2.0, 2.0)
		and preview.modulate.is_equal_approx(Color(1, 1, 1)),
		"%s / %s" % [_home.get_plane_name(), "<нет превью>" if preview == null
			else "%s %s" % [preview.asset_key, preview.modulate]])
	# M10 (bug 2): подсказки «Откроется после прохождения кампании» на Home больше нет —
	# владелец: текст стоял под «Кампанией» и читался как условие кампании. Сообщение об
	# открытии режима переехало на экран победы (проверяется в mission_select_test).
	_check("свежий профиль: endless закрыт (кнопка disabled), подсказки на Home нет",
		not _home.is_endless_enabled() and _endless_button().disabled
		and _home.get_node_or_null(^"EndlessHint") == null
		and not _has_text_like(_home, REMOVED_ENDLESS_HINT),
		"enabled=%s disabled=%s" % [_home.is_endless_enabled(), _endless_button().disabled])

	# Закрытый режим не запускается даже программным запросом: сигнала нет.
	var endless_events: Array[int] = []
	var counter := func() -> void: endless_events.append(1)
	_home.endless_requested.connect(counter)
	var closed_request := _home.request_endless()
	_home.endless_requested.disconnect(counter)
	_check("свежий профиль: request_endless() по закрытому гейту → false без сигнала",
		not closed_request and endless_events.is_empty(), str(endless_events.size()))

	_home.show_overlay()
	_check("показ: show_overlay() делает экран видимым и обновляет строки",
		_home.visible and _home.get_supply_text() == "Снабжение: 0", _home.get_supply_text())


# ─── Раскладка и ввод ───────────────────────────────────────────────────────
func _check_layout_and_input() -> void:
	# Контейнеры раскладывают детей только у видимого экрана: показываем и ждём кадр.
	_home.show_overlay()
	await get_tree().process_frame
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var buttons_inside := true
	var buttons_size := true
	for button: Button in _buttons():
		var rect := button.get_global_rect()
		buttons_inside = buttons_inside and _rect_inside(rect, field)
		buttons_size = buttons_size and rect.size.x >= 320.0 and rect.size.y >= 88.0
	_check("раскладка: 4 кнопки 320×88 внутри поля 540×960",
		buttons_inside and buttons_size, str(_endless_button().get_global_rect()))

	var titles: Array[Label] = [
		_home.get_node(^"Title") as Label, _home.get_node(^"PlaneName") as Label,
		_home.get_node(^"StarsLine") as Label, _home.get_node(^"SupplyLine") as Label,
	]
	var overlap_details := ""
	var rects: Array[Rect2] = []
	for button: Button in _buttons():
		rects.append(button.get_global_rect())
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if _rects_overlap(rects[i], rects[j]):
				overlap_details += "%d×%d " % [i, j]
	for label: Label in titles:
		for rect: Rect2 in rects:
			if _rects_overlap(label.get_global_rect(), rect):
				overlap_details += "%s×%s " % [String(label.name), str(rect)]
	# M10: превью и строки профиля тоже не должны липнуть к кнопкам — контент пере-разложен
	# после удаления подзаголовка, поэтому проверяем весь блок целиком.
	var preview_rect := (_home.get_node(^"PreviewPanel") as Control).get_global_rect()
	for rect: Rect2 in rects:
		if _rects_overlap(preview_rect, rect):
			overlap_details += "PreviewPanel×%s " % str(rect)
	_check("раскладка: кнопки не накладываются друг на друга и на строки/подсказку",
		overlap_details.is_empty(), overlap_details)
	_check("раскладка: превью и заголовок не накладываются друг на друга",
		not _rects_overlap(preview_rect, (_home.get_node(^"Title") as Label).get_global_rect())
		and _rect_inside(preview_rect, field)
		and preview_rect.position.y >= (_home.get_node(^"Title") as Label).get_global_rect().end.y - 0.5,
		"%s / %s" % [preview_rect,
			(_home.get_node(^"Title") as Label).get_global_rect()])
	var title_width := _label_text_width(_home.get_node(^"Title") as Label)
	_check("раскладка: заголовок «%s» влезает в поле 540 (реальный шрифт)" % HOME_TITLE,
		title_width <= field.size.x, "%.1f px" % title_width)

	_check("ввод: корень и затемнение прозрачны для тапов, кнопки — STOP",
		_home.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (_home.get_node(^"Dim") as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE
		and _campaign_button().mouse_filter == Control.MOUSE_FILTER_STOP
		and _endless_button().mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("ввод: экран живёт ALWAYS (не зависает от паузы дерева)",
		_home.process_mode == Node.PROCESS_MODE_ALWAYS)

	# Латч: двойной обработчик одного касания = один campaign_requested.
	var campaign_events: Array[int] = []
	var counter := func() -> void: campaign_events.append(1)
	_home.campaign_requested.connect(counter)
	_home.show_overlay()
	_home._on_campaign_gui_input(_touch_event())
	_home._on_campaign_gui_input(_touch_event())
	_check("ввод: «Кампания» эмитит один сигнал за касание (латч)",
		campaign_events.size() == 1, "событий %d" % campaign_events.size())
	_home.campaign_requested.disconnect(counter)
	_home.hide_overlay()


# ─── Профиль: снабжение, звёзды, самолёт, ливрея ────────────────────────────
func _check_profile_refresh() -> void:
	SaveGame.add_supply(1000)
	SaveGame.record_stars(M1, 3)
	SaveGame.unlock_plane(YAK3)
	SaveGame.select_plane(YAK3)
	SaveGame.buy_livery(1)
	SaveGame.select_livery(1)
	_home.refresh()
	_check("профиль: снабжение 700 (1000 − 300 за ливрею) и 3 звезды в строках",
		_home.get_supply_text() == "Снабжение: 700" and _home.get_stars_text() == "Звёзды: 3/9",
		"%s / %s" % [_home.get_supply_text(), _home.get_stars_text()])
	_check("профиль: выбранный Як-3 — имя и превью player_yak3",
		_home.get_plane_name() == "Як-3" and _preview().asset_key == &"player_yak3",
		"%s / %s" % [_home.get_plane_name(), _preview().asset_key])
	_check("профиль: ливрея 1 даёт тинт #6B7F5A на превью",
		_preview().modulate.is_equal_approx(ArtStyle.livery_tint(1)),
		str(_preview().modulate))


# ─── main.tscn: запуск = Home ───────────────────────────────────────────────
func _check_main_scene_boot() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	await get_tree().physics_frame

	_check("старт: Home виден, брифинг скрыт, состояние BRIEFING",
		_level.get_state() == LevelController.State.BRIEFING
		and _level.home.visible and not _level.briefing.visible,
		"state=%d, home=%s, briefing=%s" % [_level.get_state(),
			_level.home.visible, _level.briefing.visible])
	_check("старт: HUD/бомба/пауза скрыты, волн нет, игрок без управления",
		not _level.hud.visible and not _level.bomb_button.visible
		and not _level.pause_button.visible and not _level.waves.is_active()
		and _level.enemies_root.get_child_count() == 0
		and not _level.player.is_processing()
		and not _level.player.is_processing_unhandled_input(),
		"hud=%s, волн %d" % [_level.hud.visible, _level.enemies_root.get_child_count()])
	_check("старт: строки Home читаются из профиля (Як-3 / 700 / 3 из 9)",
		_level.home.get_plane_name() == "Як-3"
		and _level.home.get_supply_text() == "Снабжение: 700"
		and _level.home.get_stars_text() == "Звёзды: 3/9",
		"%s / %s / %s" % [_level.home.get_plane_name(), _level.home.get_supply_text(),
			_level.home.get_stars_text()])
	# Гейт открывается только после звёзд во ВСЕХ трёх миссиях.
	_check("гейт: endless закрыт, пока не пройдена вся кампания (звёзды только в m1)",
		not SaveGame.is_endless_unlocked() and not _level.home.is_endless_enabled())
	_level.home.endless_requested.emit()
	_check("гейт: программный запрос endless с Home на закрытом профиле игнорируется",
		_level.get_state() == LevelController.State.BRIEFING and not _level.is_endless()
		and not _level.waves.is_active(),
		"state=%d, mode=%d" % [_level.get_state(), _level.get_mode()])

	SaveGame.record_stars(M2, 1)
	SaveGame.record_stars(M3, 1)
	_level.home.refresh()
	_check("гейт: 1 звезда в каждой миссии + refresh() → кнопка активна",
		SaveGame.is_endless_unlocked() and _level.home.is_endless_enabled()
		and not _level.home.endless_button.disabled)


# ─── Переходы Home ↔ экраны и брифинг ──────────────────────────────────────
func _check_navigation() -> void:
	_level.home.campaign_requested.emit()
	_check("Home → «Кампания»: выбор миссии открыт, Home и брифинг скрыты",
		_level.mission_select.visible and not _level.home.visible
		and not _level.briefing.visible
		and _level.get_state() == LevelController.State.BRIEFING,
		"select=%s, home=%s" % [_level.mission_select.visible, _level.home.visible])
	_level.mission_select.closed.emit()
	_check("«Кампания» → «Назад»: снова Home (не брифинг)",
		_level.home.visible and not _level.mission_select.visible
		and not _level.briefing.visible)

	_level.home.hangar_requested.emit()
	_check("Home → «Ангар»: ангар открыт, Home скрыт",
		_level.hangar.visible and not _level.home.visible)
	_level.hangar.closed.emit()
	_check("«Ангар» → «Назад»: снова Home (не брифинг)",
		_level.home.visible and not _level.hangar.visible and not _level.briefing.visible)

	_level.home.settings_requested.emit()
	_check("Home → «Настройки»: настройки открыты, Home скрыт",
		_level.settings.visible and not _level.home.visible)
	_level.settings.closed.emit()
	_check("«Настройки» → «Назад»: снова Home (не брифинг)",
		_level.home.visible and not _level.settings.visible and not _level.briefing.visible)

	_level.begin_briefing()
	_check("брифинг: begin_briefing() показывает брифинг, Home скрыт",
		_level.briefing.visible and not _level.home.visible
		and _level.get_state() == LevelController.State.BRIEFING)
	_level.briefing.hangar_requested.emit()
	_level.hangar.closed.emit()
	_check("брифинг: «Ангар» → «Назад» возвращает брифинг, а не Home",
		_level.briefing.visible and not _level.home.visible and not _level.hangar.visible)
	_level.briefing.settings_requested.emit()
	_level.settings.closed.emit()
	_check("брифинг: «Настройки» → «Назад» возвращает брифинг, а не Home",
		_level.briefing.visible and not _level.home.visible and not _level.settings.visible)
	_level.briefing.missions_requested.emit()
	_level.mission_select.closed.emit()
	_check("брифинг: «Миссии» → «Назад» возвращает брифинг, а не Home",
		_level.briefing.visible and not _level.home.visible
		and not _level.mission_select.visible)


# ─── Endless с Home (гейт открыт) ──────────────────────────────────────────
func _check_endless_from_home() -> void:
	_level.show_home()
	_check("prep: show_home() показывает Home, состояние BRIEFING",
		_level.home.visible and not _level.briefing.visible
		and _level.get_state() == LevelController.State.BRIEFING)
	_check("Home → «Бесконечный»: request_endless() при открытом гейте → true",
		_level.home.request_endless())
	await get_tree().process_frame
	_check("Home → «Бесконечный»: mode ENDLESS, PLAYING, Home скрыт, HUD виден",
		_level.get_mode() == LevelController.Mode.ENDLESS
		and _level.get_state() == LevelController.State.PLAYING
		and not _level.home.visible and _level.hud.visible
		and _level.waves.is_active(),
		"mode=%d, state=%d, home=%s" % [_level.get_mode(), _level.get_state(),
			_level.home.visible])


# ─── Пауза: 3 кнопки, рестарт, выход в ангар ───────────────────────────────
func _check_pause() -> void:
	_level.player.grant_invulnerability(999.0)
	_level.pause_game()
	var overlay := _level.pause_overlay
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var buttons: Array[Button] = [overlay.resume_button, overlay.restart_button,
		overlay.home_button]
	var inside := true
	var big_enough := true
	for button: Button in buttons:
		var rect := button.get_global_rect()
		inside = inside and _rect_inside(rect, field)
		big_enough = big_enough and rect.size.x >= 320.0 and rect.size.y >= 88.0
	_check("пауза: оверлей показан, 3 кнопки 320×88 внутри поля 540×960",
		overlay.visible and inside and big_enough
		and String(overlay.resume_button.text) == "Продолжить"
		and String(overlay.restart_button.text) == "Заново"
		and String(overlay.home_button.text) == "В ангар")
	var center := Vector2(270.0, 480.0)
	var covers_center := false
	for button: Button in buttons:
		covers_center = covers_center or button.get_global_rect().has_point(center)
	_check("пауза: центр поля (270,480) свободен от кнопок (тап мимо — ничего не делает)",
		not covers_center)
	_check("ввод: оверлей прозрачен для тапов, кнопки — STOP и ALWAYS",
		overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and overlay.resume_button.mouse_filter == Control.MOUSE_FILTER_STOP
		and overlay.process_mode == Node.PROCESS_MODE_ALWAYS)

	_check("пауза: «Продолжить» → PLAYING и дерево разморожено",
		overlay.request_resume() and _level.get_state() == LevelController.State.PLAYING
		and not get_tree().paused and not overlay.visible,
		"state=%d, paused=%s" % [_level.get_state(), get_tree().paused])

	# «Заново» в endless рестартит ТОТ ЖЕ режим.
	_level.pause_game()
	_check("пауза: «Заново» рестартит текущий режим (endless остаётся endless)",
		overlay.request_restart()
		and _level.get_mode() == LevelController.Mode.ENDLESS
		and _level.get_state() == LevelController.State.PLAYING
		and not get_tree().paused and _level.waves.is_active(),
		"mode=%d, state=%d" % [_level.get_mode(), _level.get_state()])

	# «В ангар» — выход из забега на Home: пауза снята, мир очищен, HUD скрыт.
	_level.pause_game()
	var went_home := overlay.request_home()
	# Враги уходят через queue_free (despawn) — очистку проверяем на следующем кадре.
	await get_tree().process_frame
	_check("пауза: «В ангар» → Home, пауза снята, волны/HUD/враги убраны",
		went_home
		and _level.home.visible and _level.briefing.visible == false
		and _level.get_state() == LevelController.State.BRIEFING
		and not get_tree().paused and not overlay.visible
		and not _level.waves.is_active() and _level.enemies_root.get_child_count() == 0
		and not _level.hud.visible and not _level.bomb_button.visible
		and not _level.pause_button.visible,
		"state=%d, home=%s, волн %d" % [_level.get_state(), _level.home.visible,
			_level.enemies_root.get_child_count()])

	# M11/T2: тап мимо кнопок паузы больше ничего не делает — возобновляет только кнопка
	# «Продолжить» (LevelController._unhandled_input удалён).
	_level.start_level()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_level.pause_game()
	await _tap(center)
	_check("пауза: тап мимо кнопок забег не возобновляет (оверлей и пауза живы)",
		_level.get_state() == LevelController.State.PAUSED and get_tree().paused
		and overlay.visible,
		"state=%d, paused=%s, overlay=%s" % [_level.get_state(), get_tree().paused,
			overlay.visible])
	var resumed := overlay.request_resume()
	await get_tree().process_frame
	_check("пауза: «Продолжить» возобновляет забег",
		resumed and _level.get_state() == LevelController.State.PLAYING
		and not get_tree().paused and not overlay.visible,
		"state=%d, paused=%s" % [_level.get_state(), get_tree().paused])


# ─── Помощники ──────────────────────────────────────────────────────────────
func _fresh() -> void:
	_remove_file(_path)


func _preview() -> ShipVisual:
	return _home.get_node_or_null(^"PreviewPanel/Preview") as ShipVisual


func _buttons() -> Array[Button]:
	return [_campaign_button(), _endless_button(), _home.get_node(^"Buttons/HangarButton") as Button,
		_home.get_node(^"Buttons/SettingsButton") as Button]


func _campaign_button() -> Button:
	return _home.get_node(^"Buttons/CampaignButton") as Button


func _endless_button() -> Button:
	return _home.get_node(^"Buttons/EndlessButton") as Button


func _button_texts() -> Array:
	var texts: Array = []
	for button: Button in _buttons():
		texts.append(String(button.text))
	return texts


func _label(path: NodePath) -> String:
	var label := _home.get_node_or_null(path) as Label
	return String(label.text) if label != null else "<нет метки>"


## Есть ли в поддереве видимый текст с этой подстрокой (M10, bug 2: подсказки на Home нет).
func _has_text_like(root: Node, needle: String) -> bool:
	for node in root.find_children("*", "Label", true, false):
		var label := node as Label
		if label != null and needle in String(label.text):
			return true
	return false


## Ширина строки реальным шрифтом темы и её размером (M10: заголовок — имя игры).
func _label_text_width(label: Label) -> float:
	if label == null:
		return 0.0
	var font := label.get_theme_font(&"font")
	if font == null:
		return 0.0
	return font.get_string_size(String(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1,
		label.get_theme_font_size(&"font_size")).x


func _touch_event() -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = true
	event.position = Vector2(270.0, 48.0)
	return event


## Реальный тап через Input.parse_input_event — тот же путь, что у Android
## (включая gui_input → _unhandled_input LevelController).
func _tap(canvas_position: Vector2) -> void:
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.pressed = true
	down.position = get_viewport().get_final_transform() * canvas_position
	Input.parse_input_event(down)
	await get_tree().process_frame
	await get_tree().physics_frame
	var up := InputEventScreenTouch.new()
	up.index = 0
	up.pressed = false
	up.position = down.position
	Input.parse_input_event(up)
	await get_tree().process_frame
	await get_tree().physics_frame


func _rect_inside(rect: Rect2, field: Rect2) -> bool:
	return rect.position.x >= field.position.x - 0.5 and rect.position.y >= field.position.y - 0.5 \
		and rect.end.x <= field.end.x + 0.5 and rect.end.y <= field.end.y + 0.5


func _rects_overlap(left: Rect2, right: Rect2) -> bool:
	return left.intersects(right)


func _remove_file(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": -1, "mtime": -1, "text": ""}
	var snapshot := {
		"exists": true, "size": -1, "mtime": FileAccess.get_modified_time(path), "text": ""
	}
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		snapshot["text"] = file.get_as_text()
		snapshot["size"] = int(file.get_length())
		file.close()
	return snapshot


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
