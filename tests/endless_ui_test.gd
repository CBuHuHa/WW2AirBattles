# endless_ui_test.gd
# Purpose: Гейт M6.3b — UI бесконечного режима (GDD «Бесконечный режим», «Win, fail, restart»,
#          «UI / HUD», «Счёт, звёзды, снабжение»). Проверяет:
#            • кнопку «Бесконечный» на брифинге: 160×64 в поле 540×960, ряд «Миссии» «Ангар»
#              «Бесконечный» без перекрытий, не задевает «В бой» и строки, root IGNORE,
#              интерактив STOP, оверлей ALWAYS;
#            • гейт SaveGame.is_endless_unlocked(): чистый профиль — disabled, программный эмит
#              закрытого режима не стартует; после 1 звезды в каждой из трёх миссий +
#              refresh_endless_state() кнопка открыта. M11/T6 (D7): текстовой подсказки условия
#              на брифинге нет — узла EndlessHint нет и текста нет ни в одном Label;
#            • старт через кнопку (латч один сигнал за касание): mode ENDLESS, PLAYING,
#              брифинг/выбор миссии/ангар скрыты, подсказки не показываются, HUD «Волна 1»;
#            • HUD: «Волна N» в endless (смена волны через реальный start_at_wave), в кампании
#              строка скрыта (get_wave_text() == "");
#            • экран итогов endless: волна/счёт/«Новый рекорд: N» и три кнопки исхода
#              (M11/T3: 320×88, вместо удалённой строки «Тап — повторить»), снабжение
#              score / 60 один раз, «Повторить» — рестарт endless (не кампании);
#            • повторная слабая смерть: рекорд не понижается, строка «Рекорд: N» без «Новый»;
#            • M11/T2: тап в свободную точку (270,480) на экранах исхода ничего не делает —
#              их покидают только кнопки (у LevelController нет _unhandled_input);
#            • кампанийная смерть не изменилась: «Аэродром потерян», три кнопки, без
#              endless-строк, снабжение не начисляется, «Повторить» — рестарт кампании;
#            • M10 (bug 5): после забега m3 экран итогов endless по-прежнему «Аэродром
#              потерян» («Город потерян» из данных миссии в endless не протекает);
#            • геометрия итогов: строки и кнопки в поле 540×960, не перекрывают друг друга,
#              слот revive (552…616) кнопки не задевает.
#          Изоляция: сейв живёт в user://qa_endless_ui_*.cfg, реальный
#          user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/endless_ui_test.tscn
# Dependencies: LevelController (main.tscn), BriefingOverlay, Hud, DeathOverlay, SaveGame,
#               RunRecord, GameConfig, Player, WaveManager.
# Author: UI/UX Agent (M6.3b)

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")

const M1 := "m1_airfield"
const M2 := "m2_crossing"
const M3 := "m3_city"

const ENDLESS_BUTTON_TEXT := "Бесконечный"
const CAMPAIGN_DEATH_TITLE := "Аэродром потерян"

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}
var _level: LevelController


func _ready() -> void:
	# Тест живёт и при get_tree().paused (экран поражения ставит дерево на паузу).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_endless_ui_%d.cfg" % _started_msec
	RunRecord.set_save_path(_path)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
	await _run()
	if _level != null:
		_level.queue_free()
		_level = null
	await get_tree().process_frame
	_remove_run_file()
	RunRecord.reset_save_path()
	_check("изоляция: путь вернулся к DEFAULT_PATH и qa-файл удалён",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH and not FileAccess.file_exists(_path),
		SaveGame.get_save_path())
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_snapshot, _file_snapshot(RunRecord.DEFAULT_PATH)),
		"%s → %s" % [_snapshot_brief(_real_snapshot),
			_snapshot_brief(_file_snapshot(RunRecord.DEFAULT_PATH))])
	_check("изоляция: дерево не осталось на паузе", not get_tree().paused,
		str(get_tree().paused))
	print("ENDLESS_UI_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("ENDLESS_UI_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	await _boot_level()
	await _check_button_locked()
	await _check_unlock_gate()
	await _check_start_from_button()
	await _check_hud_wave()
	await _check_endless_death()
	await _check_second_endless_death()
	await _check_campaign_death()
	await _check_endless_title_after_city()


func _remove_run_file() -> void:
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))


# ─── Брифинг: кнопка есть, гейт закрыт ──────────────────────────────────────
func _boot_level() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	# M8c1: при запуске приложения показан Home; брифинг открывается явно (публичный вход).
	_level.begin_briefing()
	await get_tree().process_frame
	_level.set_perks_enabled(false)
	_check("старт: состояние BRIEFING, брифинг виден, профиль пуст (endless закрыт)",
		_level.get_state() == LevelController.State.BRIEFING and _level.briefing.visible
		and not SaveGame.is_endless_unlocked(),
		"state=%d briefing=%s" % [_level.get_state(), _level.briefing.visible])


func _check_button_locked() -> void:
	var brief := _level.briefing
	var button := brief.get_node_or_null(^"EndlessButton") as Button
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	_check("брифинг: кнопка «Бесконечный» есть и подписана",
		button != null and String(button.text) == ENDLESS_BUTTON_TEXT,
		"нет кнопки" if button == null else String(button.text))
	if button == null:
		return
	var rect := button.get_global_rect()
	_check("брифинг: «Бесконечный» 160×64 внутри поля 540×960 и ≥64 px",
		_approx(rect.size.x, 160.0) and _approx(rect.size.y, 64.0)
		and rect.size.y >= 64.0 and _rect_inside(rect, field),
		str(rect))
	_check("брифинг: заголовок кнопки влезает (22 px в 160 px)",
		_text_width(button, ENDLESS_BUTTON_TEXT) <= rect.size.x - 8.0,
		"%.1f px текста" % _text_width(button, ENDLESS_BUTTON_TEXT))
	_check("брифинг: минимальный размер кнопки не больше её рамки (текст не обрезан)",
		button.get_minimum_size().x <= rect.size.x + 0.5
		and button.get_minimum_size().y <= rect.size.y + 0.5,
		"%s в %s" % [button.get_minimum_size(), rect.size])
	var missions := brief.get_node_or_null(^"MissionsButton") as Button
	var hangar := brief.get_node_or_null(^"HangarButton") as Button
	_check("брифинг: ряд «Миссии» / «Ангар» / «Бесконечный» без перекрытий",
		missions != null and hangar != null
		and not _rects_overlap(rect, missions.get_global_rect())
		and not _rects_overlap(rect, hangar.get_global_rect())
		and not _rects_overlap(missions.get_global_rect(), hangar.get_global_rect()))
	_check("брифинг: «Бесконечный» не перекрывает «В бой» и строки брифинга",
		not _rects_overlap(rect, brief.start_button.get_global_rect())
		and not _rects_overlap(rect, (brief.get_node(^"Title") as Label).get_global_rect())
		and not _rects_overlap(rect, (brief.get_node(^"Line1") as Label).get_global_rect())
		and not _rects_overlap(rect, (brief.get_node(^"Line2") as Label).get_global_rect())
		and not _rects_overlap(rect, (brief.get_node(^"Line3") as Label).get_global_rect()))
	_check("брифинг: корень прозрачен для тапов (IGNORE), кнопка ловит тап (STOP), оверлей ALWAYS",
		brief.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and button.mouse_filter == Control.MOUSE_FILTER_STOP
		and brief.process_mode == Node.PROCESS_MODE_ALWAYS,
		"root=%d button=%d" % [brief.mouse_filter, button.mouse_filter])
	_check("гейт: чистый профиль — кнопка disabled, is_endless_enabled() = false",
		button.disabled and not brief.is_endless_enabled(),
		"disabled=%s enabled=%s" % [button.disabled, brief.is_endless_enabled()])
	# M11/T6 (решение D7): подсказка условия удалена вместе с узлом, гейт остался на кнопке.
	var removed_text := "Откроется после прохождения кампании"
	_check("брифинг: узла EndlessHint нет и текста «%s» нет ни в одном Label оверлея" % removed_text,
		brief.get_node_or_null(^"EndlessHint") == null
		and not _all_label_text(brief).contains(removed_text),
		"узел=%s" % str(brief.get_node_or_null(^"EndlessHint")))
	# Закрытый режим не запускается даже программным эмитом сигнала.
	brief.endless_requested.emit()
	await get_tree().process_frame
	_check("гейт: программный запрос endless на закрытом профиле игнорируется",
		_level.get_state() == LevelController.State.BRIEFING and not _level.is_endless()
		and not _level.waves.is_active(),
		"state=%d mode=%d" % [_level.get_state(), _level.get_mode()])
	# Латч закрытой кнопки: касание не эмитит сигнал.
	var blocked: Array[int] = []
	var blocked_counter := func() -> void: blocked.append(1)
	brief.endless_requested.connect(blocked_counter)
	brief._on_endless_button_gui_input(_touch_event(true))
	brief.endless_requested.disconnect(blocked_counter)
	_check("гейт: касание закрытой кнопки не эмитит endless_requested", blocked.is_empty(),
		str(blocked))


# ─── Открытие: 1 звезда в каждой миссии + refresh_endless_state() ───────────
func _check_unlock_gate() -> void:
	var brief := _level.briefing
	var button := brief.get_node(^"EndlessButton") as Button
	SaveGame.record_stars(M1, 1)
	brief.refresh_endless_state()
	_check("открытие: одна звезда m1 мало — кнопка всё ещё disabled",
		button.disabled and not brief.is_endless_enabled(), str(button.disabled))
	SaveGame.record_stars(M2, 1)
	brief.refresh_endless_state()
	_check("открытие: m1 + m2 мало — кнопка всё ещё disabled",
		button.disabled and not brief.is_endless_enabled(), str(button.disabled))
	SaveGame.record_stars(M3, 1)
	brief.refresh_endless_state()
	_check("открытие: 1 звезда во всех трёх миссиях — кнопка открыта (гейт SaveGame)",
		not button.disabled and brief.is_endless_enabled() and SaveGame.is_endless_unlocked(),
		"disabled=%s enabled=%s" % [button.disabled, brief.is_endless_enabled()])


# ─── Старт из брифинга: латч + сигнал → endless-забег ───────────────────────
func _check_start_from_button() -> void:
	var brief := _level.briefing
	brief.show_overlay()
	var events: Array[int] = []
	var counter := func() -> void: events.append(1)
	brief.endless_requested.connect(counter)
	brief._on_endless_button_gui_input(_touch_event(true))
	brief._on_endless_button_gui_input(_touch_event(true))
	brief.endless_requested.disconnect(counter)
	await get_tree().process_frame
	_check("старт: двойное касание «Бесконечный» даёт один запрос (латч)",
		events.size() == 1, "событий %d" % events.size())
	_check("старт: режим ENDLESS, состояние PLAYING, волна 1 активна",
		_level.is_endless() and _level.get_mode() == LevelController.Mode.ENDLESS
		and _level.get_state() == LevelController.State.PLAYING
		and _level.waves.is_endless() and _level.waves.get_wave_number() == 1,
		"mode=%d state=%d wave=%d" % [_level.get_mode(), _level.get_state(),
			_level.waves.get_wave_number()])
	_check("старт: брифинг/выбор миссии/ангар скрыты, подсказки не показаны",
		not _level.briefing.visible and not _level.mission_select.visible
		and not _level.hangar.visible and not _level.hints.visible,
		"briefing=%s select=%s hangar=%s" % [_level.briefing.visible,
			_level.mission_select.visible, _level.hangar.visible])
	_check("старт: HUD, бомба и пауза на месте, игрок управляется",
		_level.hud.visible and _level.bomb_button.visible and _level.pause_button.visible
		and _level.player.is_processing() and _level.player.is_processing_unhandled_input())
	_check("старт: HUD «Волна 1»",
		_level.hud.get_wave_text() == "Волна 1" and _level.hud.is_wave_visible(),
		_level.hud.get_wave_text())
	_level.player.grant_invulnerability(999.0)


# ─── HUD волны: endless показывает, кампания скрывает ───────────────────────
func _check_hud_wave() -> void:
	# Волна 3 (0-based индекс 2) — штатный путь start_at_wave → wave_started → HUD.
	_level.waves.stop()
	_level._clear_level()
	_level.waves.start_at_wave(2)
	await get_tree().process_frame
	_check("HUD: волна 3 endless → «Волна 3» (номер берётся у WaveManager)",
		_level.waves.get_wave_number() == 3 and _level.hud.get_wave_text() == "Волна 3",
		"wave=%d hud=«%s»" % [_level.waves.get_wave_number(), _level.hud.get_wave_text()])
	_check("HUD: строка волны не перекрывает HP/счёт/перки/полосу босса",
		not _rects_overlap(_level.hud.wave_label.get_global_rect(),
			_level.hud.hp_label.get_global_rect())
		and not _rects_overlap(_level.hud.wave_label.get_global_rect(),
			_level.hud.score_label.get_global_rect())
		and not _rects_overlap(_level.hud.wave_label.get_global_rect(),
			_level.hud.boss_bar.get_global_rect())
		and not _rects_overlap(_level.hud.wave_label.get_global_rect(), _perk_slots_rect()),
		"%s" % _level.hud.wave_label.get_global_rect())
	# Кампания: строка волны скрыта (номер волны игроку не показывается).
	_level.start_mission(M1)
	await get_tree().process_frame
	_check("HUD: в кампании строка волны скрыта (get_wave_text() == \"\")",
		not _level.hud.is_wave_visible() and _level.hud.get_wave_text() == ""
		and not _level.is_endless() and _level.waves.get_wave_number() == 1,
		"hud=«%s» mode=%d" % [_level.hud.get_wave_text(), _level.get_mode()])


# ─── Итоги endless: рекорд, снабжение score/60, экран, тап ──────────────────
func _check_endless_death() -> void:
	var supply_before := SaveGame.get_supply()
	await _die_in_endless_at(2)  # волна 3
	var score_at_death := _level.get_score()
	var wave_at_death := 3
	_check("смерть endless: счёт и волна на момент гибели (%d очков, волна %d)"
		% [score_at_death, wave_at_death],
		score_at_death > 0 and _level.get_state() == LevelController.State.DEAD,
		"score=%d state=%d" % [score_at_death, _level.get_state()])
	_check("смерть endless: рекорд записан (очки + волна), is_new = true",
		SaveGame.get_endless_best() == score_at_death
		and SaveGame.get_endless_wave() == wave_at_death and _level.get_endless_is_new(),
		"best=%d wave=%d new=%s" % [SaveGame.get_endless_best(), SaveGame.get_endless_wave(),
			_level.get_endless_is_new()])
	var expected_supply := int(round(float(score_at_death) / LevelController.ENDLESS_SUPPLY_DIVISOR))
	_check("смерть endless: снабжение +score/60 (%d) начислено один раз" % expected_supply,
		_level.get_endless_supply_gained() == expected_supply
		and SaveGame.get_supply() == supply_before + expected_supply,
		"%d → %d, начислено %d" % [supply_before, SaveGame.get_supply(),
			_level.get_endless_supply_gained()])
	_check("смерть endless: HUD-строка волны скрыта под экраном итогов",
		not _level.hud.is_wave_visible() and _level.hud.get_wave_text() == "")
	var overlay := _level.death_overlay
	var shown := await _wait_until(func() -> bool: return overlay.visible, 2.0)
	_check("смерть endless: экран итогов показан, дерево на паузе",
		shown and get_tree().paused and overlay.is_endless_view())
	_check("итоги: заголовок прежний, строка волны и счёт",
		String((overlay.get_node(^"Title") as Label).text) == CAMPAIGN_DEATH_TITLE
		and overlay.get_result_text() == "Бесконечный: волна 3"
		and overlay.get_score_text() == "Счёт: %d" % score_at_death,
		"%s / %s / %s" % [String((overlay.get_node(^"Title") as Label).text),
			overlay.get_result_text(), overlay.get_score_text()])
	_check("итоги: «Новый рекорд: N», строки-подсказки нет — исход дают три кнопки",
		overlay.get_record_text() == "Новый рекорд: %d" % score_at_death
		and overlay.get_visible_action_button_count() == 3
		and overlay.get_node_or_null(^"Hint") == null,
		"%s / кнопок %d" % [overlay.get_record_text(),
			overlay.get_visible_action_button_count()])
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var rects: Array[Rect2] = [
		(overlay.get_node(^"Title") as Label).get_global_rect(),
		overlay.result_line.get_global_rect(),
		overlay.score_line.get_global_rect(),
		overlay.record_line.get_global_rect(),
	]
	var buttons: Array[Button] = [overlay.replay_button, overlay.campaign_button,
		overlay.home_button]
	var inside := true
	for rect: Rect2 in rects:
		inside = inside and _rect_inside(rect, field)
	for button: Button in buttons:
		inside = inside and _rect_inside(button.get_global_rect(), field)
	_check("итоги: четыре строки и три кнопки исхода внутри поля 540×960", inside, str(rects))
	var overlaps := false
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if _rects_overlap(rects[i], rects[j]):
				overlaps = true
	for i in buttons.size():
		for j in range(i + 1, buttons.size()):
			if _rects_overlap(buttons[i].get_global_rect(), buttons[j].get_global_rect()):
				overlaps = true
		for rect: Rect2 in rects:
			if _rects_overlap(rect, buttons[i].get_global_rect()):
				overlaps = true
	_check("итоги: строки не накладываются друг на друга и на кнопки исхода",
		not overlaps, str(rects))
	# M11/T3: на экране итогов endless три реальные кнопки 320×88, скрытый слот revive
	# (552…616) стоит выше них и ничего не перекрывает.
	var buttons_ok := overlay.get_visible_action_button_count() == 3
	for button: Button in buttons:
		var button_rect := button.get_global_rect()
		buttons_ok = buttons_ok \
			and is_equal_approx(button_rect.size.x, 320.0) \
			and is_equal_approx(button_rect.size.y, 88.0) \
			and not _rects_overlap(button_rect, overlay.revive_button.get_global_rect())
	_check("итоги endless: 3 кнопки 320×88, слот revive их не перекрывает", buttons_ok,
		"видимых %d" % overlay.get_visible_action_button_count())
	_check("итоги: экран ALWAYS и прозрачен для тапа (IGNORE)",
		overlay.process_mode == Node.PROCESS_MODE_ALWAYS
		and overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"mode=%d filter=%d" % [overlay.process_mode, overlay.mouse_filter])
	# M11/T2: тап по свободному месту итогов больше ничего не делает (тап-шорткатов нет).
	_level.get_viewport().push_input(_touch_event(true))
	await get_tree().process_frame
	_check("тап на итогах endless ничего не делает (DEAD, экран жив, пауза)",
		_level.get_state() == LevelController.State.DEAD and overlay.visible
		and get_tree().paused,
		"state=%d overlay=%s" % [_level.get_state(), overlay.visible])
	_check("кнопка «Повторить» на итогах endless принята", overlay.request_replay())
	await get_tree().process_frame
	_check("«Повторить» на итогах: рестарт endless (mode ENDLESS, волна 1, PLAYING), не кампании",
		_level.is_endless() and _level.get_state() == LevelController.State.PLAYING
		and _level.waves.get_wave_number() == 1 and not _level.death_overlay.visible
		and not get_tree().paused and _level.hud.get_wave_text() == "Волна 1",
		"mode=%d state=%d wave=%d" % [_level.get_mode(), _level.get_state(),
			_level.waves.get_wave_number()])
	_level.player.grant_invulnerability(999.0)


# ─── Вторая слабая смерть: рекорд не падает, «Рекорд: N» ────────────────────
func _check_second_endless_death() -> void:
	var best_before := SaveGame.get_endless_best()
	var wave_before := SaveGame.get_endless_wave()
	var supply_before := SaveGame.get_supply()
	# Нулевой счёт: мгновенная гибель без единого убийства.
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	var died := await _wait_until(
		func() -> bool: return _level.get_state() == LevelController.State.DEAD, 2.0)
	var ok := await _wait_until(func() -> bool: return _level.death_overlay.visible, 2.0)
	_check("слабая смерть endless: DEAD и экран итогов",
		died and ok and _level.death_overlay.is_endless_view())
	_check("слабая смерть endless: рекорд не понижен, is_new = false, «Рекорд: N»",
		SaveGame.get_endless_best() == best_before
		and SaveGame.get_endless_wave() == wave_before and not _level.get_endless_is_new()
		and _level.death_overlay.get_record_text() == "Рекорд: %d" % best_before,
		"best=%d new=%s «%s»" % [SaveGame.get_endless_best(), _level.get_endless_is_new(),
			_level.death_overlay.get_record_text()])
	_check("слабая смерть endless: снабжение за 0 очков не начислено",
		_level.get_endless_supply_gained() == 0 and SaveGame.get_supply() == supply_before,
		"начислено %d" % _level.get_endless_supply_gained())
	# M11/T2: тап по свободному месту не перезапускает забег — рестарт даёт кнопка.
	_level.get_viewport().push_input(_touch_event(true))
	await get_tree().process_frame
	_check("слабая смерть endless: тап по свободному месту забег не запускает",
		_level.get_state() == LevelController.State.DEAD
		and _level.death_overlay.visible and get_tree().paused,
		"state=%d overlay=%s" % [_level.get_state(), _level.death_overlay.visible])
	var replay_accepted := _level.death_overlay.request_replay()
	await get_tree().process_frame
	_check("слабая смерть endless: «Повторить» снова запускает endless",
		replay_accepted and _level.is_endless()
		and _level.get_state() == LevelController.State.PLAYING,
		"accepted=%s mode=%d state=%d" % [replay_accepted, _level.get_mode(),
			_level.get_state()])
	_level.player.grant_invulnerability(999.0)


# ─── Кампания: прежний экран поражения, без endless-строк/снабжения ─────────
func _check_campaign_death() -> void:
	var supply_before := SaveGame.get_supply()
	var best_before := SaveGame.get_endless_best()
	_level.start_mission(M1)
	await get_tree().process_frame
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	var died := await _wait_until(
		func() -> bool: return _level.death_overlay.visible, 2.0)
	var overlay := _level.death_overlay
	_check("кампания: смерть → прежний экран «Аэродром потерян» и три кнопки исхода",
		died and not overlay.is_endless_view()
		and String((overlay.get_node(^"Title") as Label).text) == CAMPAIGN_DEATH_TITLE
		and overlay.get_visible_action_button_count() == 3
		and overlay.get_node_or_null(^"Hint") == null,
		"%s / кнопок %d" % [String((overlay.get_node(^"Title") as Label).text),
			overlay.get_visible_action_button_count()])
	_check("кампания: endless-строки скрыты, HUD-строка волны скрыта",
		overlay.get_result_text() == "" and overlay.get_score_text() == ""
		and overlay.get_record_text() == ""
		and not overlay.result_line.visible and not overlay.score_line.visible
		and not overlay.record_line.visible and not _level.hud.is_wave_visible(),
		"«%s» «%s» «%s»" % [overlay.get_result_text(), overlay.get_score_text(),
			overlay.get_record_text()])
	_check("кампания: рекорд endless и снабжение не тронуты",
		SaveGame.get_supply() == supply_before
		and SaveGame.get_endless_best() == best_before
		and _level.get_endless_supply_gained() == 0 and _level.get_last_supply_gained() == 0,
		"снабжение %d → %d" % [supply_before, SaveGame.get_supply()])
	# M11/T2: тап по свободному месту не рестартит — кнопка «Повторить» рестартит ту же миссию.
	_level.get_viewport().push_input(_touch_event(true))
	await get_tree().process_frame
	_check("кампания: тап по свободному месту экран поражения не закрывает",
		_level.get_state() == LevelController.State.DEAD
		and _level.death_overlay.visible and get_tree().paused,
		"state=%d overlay=%s" % [_level.get_state(), _level.death_overlay.visible])
	var replay_accepted := overlay.request_replay()
	await get_tree().process_frame
	_check("кампания: «Повторить» — рестарт миссии (CAMPAIGN, 6 волн, PLAYING)",
		replay_accepted and _level.get_mode() == LevelController.Mode.CAMPAIGN
		and _level.get_state() == LevelController.State.PLAYING
		and _level.waves.get_wave_count() == 6 and _level.waves.get_wave_number() == 1,
		"accepted=%s mode=%d waves=%d" % [replay_accepted, _level.get_mode(),
			_level.waves.get_wave_count()])


# ─── M10 (bug 5): экран endless не наследует кампанийные тексты ─────────────
## После забега m3 кампанийный экран поражения говорит «Город потерян»; экран итогов endless
## обязан остаться «Аэродром потерян» и предлагать те же три кнопки исхода (M11/T3).
func _check_endless_title_after_city() -> void:
	var overlay := _level.death_overlay
	_level.start_mission(M3)
	await get_tree().process_frame
	_check("M10: забег m3 выставил свои тексты (победа «Город спасён», поражение «Город потерян»)",
		overlay.get_mission_id() == M3
		and String((overlay.get_node(^"Title") as Label).text) == "Город потерян"
		and _level.win_overlay.get_mission_id() == M3
		and String(_level.win_overlay.title.text) == "Город спасён",
		"%s / %s / %s" % [overlay.get_mission_id(),
			String((overlay.get_node(^"Title") as Label).text),
			String(_level.win_overlay.title.text)])

	# Endless стартует без брифинга и НЕ переписывает кампанийные тексты (миссия остаётся m3).
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	var died := await _wait_until(func() -> bool: return overlay.visible, 2.0)
	_check("M10: итоги endless после m3 — заголовок «%s», три кнопки, подсказки нет"
		% CAMPAIGN_DEATH_TITLE,
		died and overlay.is_endless_view()
		and String((overlay.get_node(^"Title") as Label).text) == CAMPAIGN_DEATH_TITLE
		and overlay.get_visible_action_button_count() == 3,
		"%s / кнопок %d" % [String((overlay.get_node(^"Title") as Label).text),
			overlay.get_visible_action_button_count()])
	# M11/T2: тап ничего не делает; «Повторить» запускает endless — дерево размораживается.
	_level.get_viewport().push_input(_touch_event(true))
	await get_tree().process_frame
	_check("M10: тап на итогах endless ничего не делает (экран жив)",
		_level.get_state() == LevelController.State.DEAD and overlay.visible
		and get_tree().paused)
	_check("M10: «Повторить» на итогах после m3 снова запускает endless",
		overlay.request_replay())
	await get_tree().process_frame
	_check("M10: после «Повторить» endless в бою, экран скрыт",
		_level.is_endless() and _level.get_state() == LevelController.State.PLAYING
		and not overlay.visible)


# ─── Хелперы ────────────────────────────────────────────────────────────────
## Забег endless, сразу волна с индексом `index` (0-based), затем гибель игрока.
## Волны после зачистки останавливаются: номер смерти не должен «уехать» на следующую.
func _die_in_endless_at(index: int) -> void:
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_level.waves.stop()
	_level._clear_level()
	_level.waves.start_at_wave(index)
	await get_tree().process_frame
	_kill_all_enemies()
	await get_tree().process_frame
	_level.waves.stop()
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	await _wait_until(
		func() -> bool: return _level.get_state() == LevelController.State.DEAD, 2.0)


func _kill_all_enemies() -> void:
	for node in get_tree().get_nodes_in_group(GameConfig.GROUP_ENEMIES):
		var enemy := node as EnemyBase
		if enemy != null and enemy.is_active:
			enemy.take_damage(99999.0)


func _touch_event(pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = Vector2(270.0, 480.0)
	return event


## Ширина текста кнопки её реальным шрифтом и размером (проверка «подпись влезает»).
func _text_width(control: Control, text: String) -> float:
	var font := control.get_theme_font(&"font")
	if font == null:
		return 0.0
	var font_size := control.get_theme_font_size(&"font_size")
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


## Весь текст, который оверлей реально рисует (рекурсивно по всем Label): проверка «текста
## удалённой подсказки нет нигде» не зависит от имени узла.
func _all_label_text(root: Node) -> String:
	var parts: PackedStringArray = []
	for node in root.find_children("*", "Label", true, false):
		var label := node as Label
		if label != null:
			parts.append(String(label.text))
	return "\n".join(parts)


func _rect_inside(rect: Rect2, field: Rect2) -> bool:
	return rect.position.x >= field.position.x - 0.5 and rect.position.y >= field.position.y - 0.5 \
		and rect.end.x <= field.end.x + 0.5 and rect.end.y <= field.end.y + 0.5


func _rects_overlap(left: Rect2, right: Rect2) -> bool:
	return left.intersects(right)


## Зона слотов перков HUD (3 плашки под рядом HP) — та же геометрия, что рисует hud.gd._draw.
func _perk_slots_rect() -> Rect2:
	return Rect2(Hud.PERK_SLOT_ORIGIN,
		Vector2(Hud.PERK_SLOT_STEP * float(Hud.PERK_SLOT_COUNT - 1) + Hud.PERK_SLOT_SIZE.x,
			Hud.PERK_SLOT_SIZE.y))


func _wait_until(condition: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return bool(condition.call())


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")


func _approx(a: float, b: float, epsilon: float = 0.5) -> bool:
	return absf(a - b) <= epsilon


## Слепок файла: {существует, размер, sha256}. Чужой профиль не трогаем, но доказываем это.
func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": 0, "sha": ""}
	var bytes := FileAccess.get_file_as_bytes(path)
	return {"exists": true, "size": bytes.size(), "sha": bytes.get_string_from_utf8().sha256_text()}


func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	return bool(a.get("exists", false)) == bool(b.get("exists", false)) \
		and int(a.get("size", 0)) == int(b.get("size", 0)) \
		and String(a.get("sha", "")) == String(b.get("sha", ""))


func _snapshot_brief(snapshot: Dictionary) -> String:
	if not bool(snapshot.get("exists", false)):
		return "нет файла"
	return "%d B, %s" % [int(snapshot.get("size", 0)),
		String(snapshot.get("sha", "")).substr(0, 8)]
