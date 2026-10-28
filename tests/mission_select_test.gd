# mission_select_test.gd
# Purpose: Гейт M5.3b — экран выбора миссии и итоги миссии. Проверяет:
#            • чистый профиль: m1 открыта, m2/m3 закрыты, карточек 3, звёзды «☆☆☆»,
#              снабжение 0, у закрытой карточки видна строка «Нужно …» и кнопка disabled;
#            • refresh(): 1 звезда открывает m2, 3 суммарные — m3, звёзды карточки «★★★»;
#            • request_mission(): закрытая миссия НЕ эмитит mission_chosen, открытая эмитит;
#              двойное срабатывание кнопки (touch + pressed) даёт один сигнал;
#            • брифинг миссии: set_mission("m2_crossing") → заголовок «Переправа», строки
#              влезают в 492 px, возврат на m1 восстанавливает сценные тексты (smoke-контракт);
#            • латч кнопки «Миссии»: двойной вызов обработчика = один missions_requested;
#            • итоги: show_result(..., stars, supply) показывает «Звёзды:» + 3 пиксельные иконки
#              ui_star (M11/T4: без дубля глифами ★/☆) и «Снабжение: +600», старый
#              4-аргументный вызов не падает (0/0);
#              StarsLine/SupplyLine под RecordLine, выше кнопок, внутри поля, без наложений;
#            • M10 (bug 5): тексты исхода по миссии (set_mission: m2 → «Переправа цела» /
#              «Переправа потеряна», m1/m3 — свои, пустой id → текст сцены) и их ширина
#              реальным шрифтом (заголовок ≤ 520, остальные строки ≤ 540);
#            • M10 (bug 1): кнопки экрана победы «Повторить» / «Кампания» / «В ангар» —
#              видны только при показанном оверлее, 320×88, без наложений на строки, один
#              сигнал за касание; «Повторить» рестартит ту же миссию, «Кампания» открывает
#              выбор миссии («Назад» → брифинг или Home по тому, откуда начат поток),
#              «В ангар» → Home;
#            • M11 (T2): тап-шорткатов нет — касание в свободную точку экрана победы ничего не
#              делает (у LevelController нет _unhandled_input), рестарт только кнопкой;
#            • M11 (T1): РЕАЛЬНЫЙ путь ввода — press/release в `_on_*_gui_input`
#              (InputEventScreenTouch в центр кнопки), а не только `request_*()`: на Android
#              `Button.pressed` от касания не приходит (emulate_mouse_from_touch=false), а
#              двойной захват латча делал кнопки мёртвыми. Ровно один сигнал на press, ноль на
#              release, is_tap_available() false после press и true после release;
#            • main.tscn: MissionSelect скрыт при старте, BriefingOverlay виден, состояние
#              BRIEFING; «Миссии» → выбор миссии; выбор открытой карточки → брифинг миссии;
#              «Назад» → брифинг текущей миссии; закрытая миссия по программному эмиту
#              не запускается; «В бой» стартует выбранную миссию (6 волн у m2).
#          Изоляция: сейв живёт в user://qa_select_*.cfg, реальный
#          user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/mission_select_test.tscn
# Dependencies: MissionSelect, BriefingOverlay, WinOverlay, LevelController (main.tscn),
#               SaveGame/CampaignProgress/RunRecord, MissionData, GameConfig.
# Author: UI/UX Agent

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const SELECT_SCENE: PackedScene = preload("res://scenes/mission_select.tscn")
const BRIEFING_SCENE: PackedScene = preload("res://scenes/briefing_overlay.tscn")

const M1 := "m1_airfield"
const M2 := "m2_crossing"
const M3 := "m3_city"

## Тексты миссии 1, которые фиксирует smoke-тест: set_mission(m1) обязан их вернуть.
const M1_TITLE := "Оборона аэродрома"
const M1_LINES := [
	"1943 год. Восточный фронт.",
	"Немецкая авиация идёт бомбить аэродром.",
	"Перехвати He 111 до бомбардировки.",
]
## Лимит ширины body-строк брифинга: 540 − 2×24 (как в smoke-тесте и briefing_overlay.gd).
const BODY_CONTENT_WIDTH := 492.0
## M10 (bug 5): лимит ширины заголовка экрана исхода — Bold 48 px в поле 540 с запасом.
const TITLE_WIDTH_LIMIT := 520.0

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}
## Отдельный инстанс экрана выбора (вне LevelController) для проверок карточек/refresh.
var _select: MissionSelect
var _level: LevelController
var _chosen: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_select_%d.cfg" % Time.get_ticks_msec()
	SaveGame.set_save_path(_path)
	await _run()
	# Уборка: тестовые узлы, файл прогона и путь к сейву.
	if _level != null:
		_level.queue_free()
		_level = null
	if _select != null:
		_select.queue_free()
		_select = null
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
	print("MISSION_SELECT_TIME=",
		"%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("MISSION_SELECT_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	await _check_fresh_cards()
	await _check_main_scene_boot()
	_check_unlock_and_refresh()
	_check_request_mission()
	await _check_briefing_mission_texts()
	await _check_mission_flow()
	_check_win_overlay_results()
	_check_result_texts()
	_check_result_fonts()
	await _check_win_overlay_buttons()
	await _check_win_overlay_real_input()


# ─── Чистый профиль: карточки, замки, звёзды ────────────────────────────────
func _check_fresh_cards() -> void:
	_fresh()
	_select = SELECT_SCENE.instantiate()
	add_child(_select)
	await get_tree().process_frame
	await get_tree().process_frame
	_select.mission_chosen.connect(func(id: String) -> void: _chosen.append(id))

	_check("свежий сейв: экран скрыт по умолчанию", not _select.visible)
	_check("свежий сейв: карточек миссий 3", _select.get_visible_card_count() == 3,
		str(_select.get_visible_card_count()))
	_check("свежий сейв: заголовок «Кампания»", _label_text("Title") == "Кампания",
		_label_text("Title"))
	_check("свежий сейв: строка снабжения «Снабжение: 0»",
		_label_text("SupplyLine") == "Снабжение: 0", _label_text("SupplyLine"))

	var m1 := _select.get_card_state(M1)
	var m2 := _select.get_card_state(M2)
	var m3 := _select.get_card_state(M3)
	_check("свежий сейв: m1 открыта, m2 и m3 закрыты",
		bool(m1["unlocked"]) and not bool(m2["unlocked"]) and not bool(m3["unlocked"]),
		"m1=%s m2=%s m3=%s" % [m1["unlocked"], m2["unlocked"], m3["unlocked"]])
	_check("свежий сейв: звёзды всех миссий 0",
		int(m1["stars"]) == 0 and int(m2["stars"]) == 0 and int(m3["stars"]) == 0)
	_check("свежий сейв: звёзды карточки М1 — «☆☆☆»",
		_card_label(M1, "Inner/Row/StarsLabel") == "☆☆☆", _card_label(M1, "Inner/Row/StarsLabel"))
	_check("свежий сейв: лучший счёт карточки М1 — «Рекорд: 0»",
		_card_label(M1, "Inner/BestLabel") == "Рекорд: 0", _card_label(M1, "Inner/BestLabel"))
	_check("замок: у m2 «Нужно 1 звезда», у m3 «Нужно 3 звезды»",
		String(m2["lock_text"]) == "Нужно 1 звезда" and String(m3["lock_text"]) == "Нужно 3 звезды",
		"%s / %s" % [m2["lock_text"], m3["lock_text"]])
	_check("замок: закрытая карточка показывает строку требования",
		_card_node(M2, "Inner/LockLabel").visible
		and _card_label(M2, "Inner/LockLabel") == "Нужно 1 звезда",
		_card_label(M2, "Inner/LockLabel"))
	_check("замок: у открытой карточки строки требования нет (текст пуст)",
		_card_label(M1, "Inner/LockLabel").is_empty(),
		_card_label(M1, "Inner/LockLabel"))
	_check("замок: кнопка выбора у закрытой карточки disabled, у открытой — нет",
		_card_button(M2).disabled and not _card_button(M1).disabled)

	# Раскладка: карточки и «Назад» внутри поля 540×960, кнопка выбора ≥ 64 px.
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var cards_inside := true
	for id: String in MissionData.MISSION_IDS:
		var card := _select.get_node_or_null("Cards/Card_" + id) as Control
		if card == null or not _rect_inside(card.get_global_rect(), field):
			cards_inside = false
	var choose_rect := _card_button(M1).get_global_rect()
	var back_rect := (_select.get_node(^"BackButton") as Button).get_global_rect()
	var button_offsets: Array[float] = []
	for id: String in MissionData.MISSION_IDS:
		var panel := _select.get_node_or_null("Cards/Card_" + id) as Control
		if panel != null:
			button_offsets.append(
				_card_button(id).get_global_rect().position.y - panel.get_global_rect().position.y)
	var offsets_equal := button_offsets.size() == MissionData.MISSION_IDS.size()
	for offset: float in button_offsets:
		offsets_equal = offsets_equal and absf(offset - button_offsets[0]) <= 0.5
	_check("раскладка: три карточки внутри поля 540×960", cards_inside,
		str((_select.get_node(^"Cards") as Control).get_global_rect()))
	_check("раскладка: кнопка выбора на одной высоте во всех карточках",
		offsets_equal, str(button_offsets))
	_check("раскладка: кнопка выбора на карточке не ниже тач-минимума 64 px",
		choose_rect.size.y >= 64.0 and not _rects_overlap(choose_rect, back_rect),
		"%.0f×%.0f px" % [choose_rect.size.x, choose_rect.size.y])
	_check("раскладка: «Назад» 320×88 внутри поля",
		_rect_inside(back_rect, field) and back_rect.size.y >= 88.0 and back_rect.size.x >= 88.0,
		str(back_rect))
	_check("ввод: корень и затемнение прозрачны для тапов, кнопки — STOP",
		_select.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (_select.get_node(^"Dim") as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (_select.get_node(^"BackButton") as Button).mouse_filter == Control.MOUSE_FILTER_STOP
		and _card_button(M1).mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("ввод: экран живёт ALWAYS (не зависает от паузы дерева)",
		_select.process_mode == Node.PROCESS_MODE_ALWAYS)

	# Закрытая миссия не запускается: карточка не эмитит mission_chosen.
	_chosen.clear()
	_check("запрос: request_mission(закрытая m2) → false без эмита",
		not _select.request_mission(M2) and _chosen.is_empty(), str(_chosen))
	_check("запрос: неизвестный id → false без эмита",
		not _select.request_mission("nope") and _chosen.is_empty(), str(_chosen))

	# Показ экрана обновляет данные профиля (снабжение) и снимает латч.
	_select.hide_overlay()
	_select.show_overlay()
	_check("показ: show_overlay() делает экран видимым и обновляет данные",
		_select.visible and _label_text("SupplyLine") == "Снабжение: 0", _label_text("SupplyLine"))


# ─── main.tscn: старт как раньше, «Миссии» → выбор, «Назад» → брифинг ───────
func _check_main_scene_boot() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	# M8c1: при запуске приложения показан Home; брифинг открывается явно (публичный вход).
	_level.begin_briefing()
	await get_tree().process_frame

	_check("старт: состояние BRIEFING, брифинг виден, выбор миссии скрыт",
		_level.get_state() == LevelController.State.BRIEFING
		and _level.briefing.visible and not _level.mission_select.visible,
		"state=%d, briefing=%s, select=%s" % [_level.get_state(),
			_level.briefing.visible, _level.mission_select.visible])
	_check("старт: брифинг показывает миссию 1 (m1)",
		_level.briefing.get_mission_id() == M1
		and _briefing_text(^"Title") == M1_TITLE,
		"%s / «%s»" % [_level.briefing.get_mission_id(), _briefing_text(^"Title")])
	var missions_button := _level.briefing.get_node_or_null(^"MissionsButton") as Button
	_check("старт: кнопка «Миссии» есть на брифинге и не перекрывает «В бой»",
		missions_button != null and String(missions_button.text) == "Миссии"
		and not _rects_overlap(missions_button.get_global_rect(),
			_level.briefing.start_button.get_global_rect()),
		"нет кнопки" if missions_button == null else str(missions_button.get_global_rect()))

	# «Миссии»: брифинг скрывается, выбор открывается, состояние остаётся BRIEFING.
	_level.briefing.missions_requested.emit()
	_check("«Миссии»: открыт выбор миссии, брифинг скрыт, состояние BRIEFING",
		_level.mission_select.visible and not _level.briefing.visible
		and _level.get_state() == LevelController.State.BRIEFING,
		"select=%s, briefing=%s, state=%d" % [_level.mission_select.visible,
			_level.briefing.visible, _level.get_state()])
	_check("«Миссии»: Ла-5 не управляется, пока открыт выбор",
		not _level.player.is_processing() and not _level.player.is_processing_unhandled_input())

	# Закрытая миссия не запускается даже программным эмитом сигнала.
	_level.mission_select.mission_chosen.emit(M2)
	_check("замок: программный выбор закрытой m2 игнорируется",
		_level.get_mission_id().is_empty()
		and _level.get_state() == LevelController.State.BRIEFING
		and _level.mission_select.visible,
		"mission=%s, state=%d" % [_level.get_mission_id(), _level.get_state()])

	# «Назад»: брифинг текущей миссии (выбор её не менял) и закрытый выбор.
	_level.mission_select.closed.emit()
	_check("«Назад»: брифинг снова виден, выбор закрыт",
		_level.briefing.visible and not _level.mission_select.visible
		and _level.briefing.get_mission_id() == M1,
		"briefing=%s, select=%s" % [_level.briefing.visible, _level.mission_select.visible])


# ─── Звёзды: refresh() открывает m2 и m3 ────────────────────────────────────
func _check_unlock_and_refresh() -> void:
	SaveGame.record_stars(M1, 1)
	_select.refresh()
	var m2 := _select.get_card_state(M2)
	_check("звёзды: 1 звезда m1 → m2 открыта, m3 закрыта",
		bool(m2["unlocked"]) and not bool(_select.get_card_state(M3)["unlocked"]),
		"m2=%s" % m2["unlocked"])
	_check("refresh(): m2 — строка требования очищена, кнопка выбора активна",
		_card_label(M2, "Inner/LockLabel").is_empty() and not _card_button(M2).disabled,
		"%s / disabled=%s" % [_card_label(M2, "Inner/LockLabel"), _card_button(M2).disabled])
	_check("refresh(): звёзды карточки М1 — «★☆☆»", _card_label(M1, "Inner/Row/StarsLabel") == "★☆☆",
		_card_label(M1, "Inner/Row/StarsLabel"))

	SaveGame.record_stars(M1, 3)
	SaveGame.record_mission_result(M1, 4800)
	SaveGame.add_supply(75)
	_select.refresh()
	_check("звёзды: 3 суммарные звезды → m3 открыта",
		bool(_select.get_card_state(M3)["unlocked"]))
	_check("refresh(): звёзды карточки М1 — «★★★», рекорд 4800",
		_card_label(M1, "Inner/Row/StarsLabel") == "★★★"
		and _card_label(M1, "Inner/BestLabel") == "Рекорд: 4800",
		"%s / %s" % [_card_label(M1, "Inner/Row/StarsLabel"), _card_label(M1, "Inner/BestLabel")])
	_check("refresh(): строка снабжения «Снабжение: 75»",
		_label_text("SupplyLine") == "Снабжение: 75", _label_text("SupplyLine"))


# ─── request_mission: открытая миссия эмитит сигнал ─────────────────────────
func _check_request_mission() -> void:
	_chosen.clear()
	var emitted: Array[String] = []
	var handler := func(id: String) -> void: emitted.append(id)
	_select.mission_chosen.connect(handler)
	_check("запрос: request_mission(открытая m2) → true и mission_chosen(m2)",
		_select.request_mission(M2) and emitted.size() == 1 and emitted[0] == M2, str(emitted))
	# Латч UI: двойное срабатывание кнопки (touch + pressed) = один сигнал.
	_select.show_overlay()
	_select._on_choose_button_pressed(M2)
	_select._on_choose_button_pressed(M2)
	_check("ввод: двойное срабатывание кнопки карточки даёт один mission_chosen",
		emitted.size() == 2 and emitted[1] == M2, str(emitted))
	_select.mission_chosen.disconnect(handler)
	_select.hide_overlay()


# ─── Брифинг по миссии ──────────────────────────────────────────────────────
func _check_briefing_mission_texts() -> void:
	var brief: BriefingOverlay = BRIEFING_SCENE.instantiate()
	add_child(brief)
	await get_tree().process_frame

	brief.set_mission(M2)
	var title := String(brief.title_label.text)
	_check("брифинг: set_mission(m2) → заголовок «Переправа»", title == "Переправа", title)
	var body_labels: Array[Label] = [brief.line1, brief.line2, brief.line3]
	var body_text := ""
	var width_max := 0.0
	for label: Label in body_labels:
		if not label.visible:
			continue
		body_text += String(label.text) + " "
		width_max = maxf(width_max, _label_text_width(label))
	_check("брифинг: текст m2 разложен по строкам и не пуст",
		not body_text.strip_edges().is_empty() and brief.get_mission_id() == M2, body_text)
	_check("брифинг: строки m2 влезают в 540 − 2×24 = 492 px",
		width_max <= BODY_CONTENT_WIDTH, "%.1f px при лимите %.1f" % [width_max, BODY_CONTENT_WIDTH])
	var font := brief.line1.get_theme_font(&"font")
	_check("брифинг: шрифт строк m2 покрывает кириллицу",
		font != null and _font_covers(font, body_text))

	brief.set_mission(M1)
	var lines_ok := true
	for index in body_labels.size():
		var label: Label = body_labels[index]
		lines_ok = lines_ok and label.visible and String(label.text) == String(M1_LINES[index])
	_check("брифинг: возврат на m1 сохраняет сценные строки (smoke-контракт)",
		lines_ok and String(brief.title_label.text) == M1_TITLE, String(brief.title_label.text))
	brief.set_mission("")
	_check("брифинг: пустой id = миссия 1",
		brief.get_mission_id() == M1 and String(brief.title_label.text) == M1_TITLE)

	var missions_events: Array[int] = []
	var counter := func() -> void: missions_events.append(1)
	brief.missions_requested.connect(counter)
	brief.show_overlay()
	brief._on_missions_button_gui_input(_touch_event(true))
	brief._on_missions_button_gui_input(_touch_event(true))
	_check("брифинг: «Миссии» срабатывает один раз за касание (латч)",
		missions_events.size() == 1, "событий %d" % missions_events.size())
	brief.missions_requested.disconnect(counter)
	brief.hide_overlay()
	brief.queue_free()
	await get_tree().process_frame


# ─── «В бой» запускает выбранную миссию ─────────────────────────────────────
func _check_mission_flow() -> void:
	_level.briefing.missions_requested.emit()
	_level.mission_select.mission_chosen.emit(M2)
	_check("выбор карточки: брифинг m2, выбор скрыт, состояние BRIEFING",
		_level.briefing.visible and not _level.mission_select.visible
		and _level.get_mission_id() == M2
		and _briefing_text(^"Title") == "Переправа"
		and _level.get_state() == LevelController.State.BRIEFING,
		"mission=%s, briefing=%s, state=%d" % [_level.get_mission_id(),
			_level.briefing.visible, _level.get_state()])

	_level.briefing.start_requested.emit()
	await get_tree().process_frame
	_check("«В бой»: стартовала выбранная миссия m2 (6 волн, 5 бортов)",
		_level.get_state() == LevelController.State.PLAYING
		and _level.waves.get_mission_id() == M2
		and _level.waves.get_wave_count() == 6
		and _level.waves.get_alive_count() == 5
		and not _level.briefing.visible and not _level.mission_select.visible,
		"миссия %s, волн %d, живых %d" % [_level.waves.get_mission_id(),
			_level.waves.get_wave_count(), _level.waves.get_alive_count()])
	_level.stop_waves()
	for child in _level.enemies_root.get_children():
		child.queue_free()
	_level.bullets.clear_all()
	await get_tree().process_frame


# ─── Итоги: звёзды и снабжение ──────────────────────────────────────────────
## M11/T4 (решение D2): звёзды показываются ОДИН раз — StarsLine пишет только подпись
## «Звёзды:», ряд из 3 пиксельных иконок ui_star стоит сразу справа (зазор 8), группа
## «подпись + иконки» центрирована по полосе. Глифов ★/☆ в основном пути нет.
func _check_win_overlay_results() -> void:
	var overlay := _level.win_overlay
	var stars_line := overlay.get_node(^"StarsLine") as Label
	var supply_line := overlay.get_node(^"SupplyLine") as Label
	var record_line := overlay.get_node(^"RecordLine") as Label
	var replay_button := overlay.replay_button
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)

	overlay.show_result(1234, 65.0, 1234, true, 3, 600)
	await get_tree().process_frame
	_check("итоги: StarsLine — только подпись «Звёзды:» без глифов, 3 иконки залиты",
		String(stars_line.text) == WinOverlay.STARS_LABEL_TEXT
		and not String(stars_line.text).contains("★")
		and not String(stars_line.text).contains("☆")
		and overlay.get_star_icon_count() == 3 and overlay.get_star_filled_count() == 3,
		"%s / %d из %d" % [stars_line.text, overlay.get_star_filled_count(),
			overlay.get_star_icon_count()])
	_check("итоги: «Снабжение: +600»", String(supply_line.text) == "Снабжение: +600",
		String(supply_line.text))
	_check("итоги: тексты рекорда не изменились",
		String(record_line.text) == "Новый рекорд: 1234", String(record_line.text))
	_check("итоги: звёзды/снабжение сохранены для QA",
		overlay.stars == 3 and overlay.supply_gained == 600,
		"%d / %d" % [overlay.stars, overlay.supply_gained])

	var stars_rect := stars_line.get_global_rect()
	var supply_rect := supply_line.get_global_rect()
	var record_rect := record_line.get_global_rect()
	var replay_rect := replay_button.get_global_rect()
	_check("итоги: StarsLine и SupplyLine под RecordLine, выше кнопок исхода",
		stars_rect.position.y >= record_rect.end.y - 0.5
		and supply_rect.position.y >= stars_rect.end.y - 0.5
		and replay_rect.position.y >= supply_rect.end.y - 0.5,
		"%s / %s / %s / %s" % [record_rect, stars_rect, supply_rect, replay_rect])
	_check("итоги: новые строки внутри поля и не перекрывают друг друга",
		_rect_inside(supply_rect, field)
		and not _rects_overlap(stars_rect, supply_rect)
		and not _rects_overlap(stars_rect, record_rect)
		and stars_rect.position.y >= field.position.y
		and stars_rect.end.y <= field.end.y)
	# Группа «подпись + ряд»: ряд сразу за текстом с зазором 8, вся группа по центру поля 270.
	var row := overlay.star_icons
	var row_rect := row.get_global_rect()
	var text_width := _label_text_width(stars_line)
	var text_left := stars_rect.position.x + (stars_rect.size.x - text_width) * 0.5
	_check("итоги: ряд иконок 3×24 + 2×4 с зазором 8 сразу справа от подписи",
		overlay.is_star_row_visible()
		and is_equal_approx(row_rect.size.x, 24.0 * 3.0
			+ float(WinOverlay.STAR_ICON_SEPARATION) * 2.0)
		and is_equal_approx(row_rect.position.x - (text_left + text_width),
			WinOverlay.STAR_ICON_TEXT_GAP),
		"row=%s, конец текста=%.1f" % [row_rect, text_left + text_width])
	_check("итоги: группа «Звёзды: + 3 иконки» центрирована по полосе (±2 px) и в поле",
		absf((text_left + row_rect.end.x) * 0.5 - field.size.x * 0.5) <= 2.0
		and text_left >= field.position.x and row_rect.end.x <= field.end.x
		and _rect_inside(row_rect, field),
		"группа=%.1f…%.1f" % [text_left, row_rect.end.x])
	_check("итоги: ряд звёзд не наезжает на RecordLine/SupplyLine/кнопку «Повторить»",
		not _rects_overlap(row_rect, record_rect)
		and not _rects_overlap(row_rect, supply_rect)
		and not _rects_overlap(row_rect, replay_rect))
	_check("итоги: подпись звёзд при 28 px влезает в 540",
		_label_text_width(stars_line) <= field.size.x, "%.1f px" % _label_text_width(stars_line))
	_check("итоги: строки прозрачны для тапов (IGNORE)",
		stars_line.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and supply_line.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	# Старый 4-аргументный вызов остаётся валидным: 0/0 без падения.
	overlay.show_result(900, 60.0, 1234, false)
	_check("итоги: 4-аргументный show_result не падает, звёзды/снабжение 0",
		String(stars_line.text) == WinOverlay.STARS_LABEL_TEXT
		and overlay.get_star_filled_count() == 0
		and String(supply_line.text) == "Снабжение: +0"
		and String(record_line.text) == "Рекорд: 1234" and overlay.visible,
		"%s / %s" % [stars_line.text, supply_line.text])
	overlay.hide_overlay()

	# ── M10 (bug 2): «Бесконечный режим открыт» над заголовком ────────────────
	var unlock_line := overlay.get_node_or_null(^"UnlockLine") as Label
	_check("итоги: строка открытия режима есть в сцене и скрыта по умолчанию",
		unlock_line != null and not overlay.is_unlock_notice_visible(),
		"узел=%s" % str(unlock_line != null))
	overlay.show_result(1234, 65.0, 1234, true, 2, 300)
	overlay.set_unlock_notice(true)
	var unlock_rect := unlock_line.get_global_rect()
	var unlock_title_rect := (overlay.get_node(^"Title") as Label).get_global_rect()
	_check("итоги: set_unlock_notice(true) показывает «%s»" % WinOverlay.ENDLESS_UNLOCK_TEXT,
		overlay.is_unlock_notice_visible()
		and overlay.get_unlock_text() == WinOverlay.ENDLESS_UNLOCK_TEXT,
		overlay.get_unlock_text())
	_check("итоги: строка открытия режима над заголовком, в поле 540×960, без наложений",
		_rect_inside(unlock_rect, field)
		and unlock_rect.end.y <= unlock_title_rect.position.y + 0.5
		and not _rects_overlap(unlock_rect, unlock_title_rect)
		and not _rects_overlap(unlock_rect,
			(overlay.get_node(^"StarsLine") as Label).get_global_rect())
		and not _rects_overlap(unlock_rect, overlay.replay_button.get_global_rect()),
		"%s / %s" % [unlock_rect, unlock_title_rect])
	_check("итоги: строка открытия режима влезает в 540 и прозрачна для тапов",
		_label_text_width(unlock_line) <= field.size.x
		and unlock_line.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"%.1f px" % _label_text_width(unlock_line))
	overlay.hide_overlay()
	_check("итоги: hide_overlay() убирает строку открытия режима",
		not overlay.is_unlock_notice_visible())

	# M11/T4: глифы ★/☆ из основного пути убраны — звёзды рисует только ряд ui_star. Текстовый
	# фолбэк остаётся в format_stars() на случай отсутствия PNG, поэтому проверяем, что он жив,
	# но StarsLine им не пользуется (иначе дубль вернулся бы).
	var font: FontFile = load("res://assets/fonts/NotoSans-Regular.ttf")
	overlay.show_result(1234, 65.0, 1234, true, 2, 300)
	_check("шрифт: в StarsLine нет ★/☆ (фолбэк format_stars жив, но не используется)",
		WinOverlay.format_stars(2) == "★★☆"
		and font.allow_system_fallback and not font.has_char(0x2605)
		and not String(stars_line.text).contains("★")
		and not String(stars_line.text).contains("☆"),
		"format=%s, text=%s" % [WinOverlay.format_stars(2), stars_line.text])
	overlay.hide_overlay()


# ─── M10 (bug 5): тексты исхода по миссии ───────────────────────────────────
## set_mission() пишет Title оверлеев из data/missions.json → result (win_title/lose_title);
## пустой id и миссия без данных → текст сцены (фолбэк). Подсказок в данных нет (M11/T3, D4).
func _check_result_texts() -> void:
	var overlay := _level.win_overlay
	var death := _level.death_overlay
	var title := overlay.get_node(^"Title") as Label
	var death_title := death.get_node(^"Title") as Label
	# Забег m2 (см. _check_mission_flow) уже выставил тексты своей миссии.
	_check("итоги m2: заголовок победы «Переправа цела» (данные миссии)",
		overlay.get_mission_id() == M2 and String(title.text) == "Переправа цела",
		"%s / «%s»" % [overlay.get_mission_id(), title.text])
	_check("итоги m2: заголовок поражения «Переправа потеряна»",
		death.get_mission_id() == M2 and String(death_title.text) == "Переправа потеряна",
		"%s / «%s»" % [death.get_mission_id(), death_title.text])
	_check("итоги m2: узлов Hint нет ни на экране победы, ни на экране поражения (D4)",
		overlay.get_node_or_null(^"Hint") == null
		and death.get_node_or_null(^"Hint") == null)

	overlay.set_mission(M1)
	death.set_mission(M1)
	_check("итоги m1: «Аэродром спасён» / «Аэродром потерян» (замороженные тексты)",
		String(title.text) == "Аэродром спасён"
		and String(death_title.text) == "Аэродром потерян",
		"%s / %s" % [title.text, death_title.text])

	overlay.set_mission(M3)
	death.set_mission(M3)
	_check("итоги m3: «Город спасён» / «Город потерян»",
		String(title.text) == "Город спасён" and String(death_title.text) == "Город потерян",
		"%s / %s" % [title.text, death_title.text])

	# Пустой id и неизвестная миссия: тексты сцены (фолбэк), а не пустой заголовок.
	overlay.set_mission("")
	death.set_mission("")
	_check("итоги: пустой id → тексты сцены (фолбэк, не пустой заголовок)",
		overlay.get_mission_id().is_empty() and death.get_mission_id().is_empty()
		and String(title.text) == "Аэродром спасён"
		and String(death_title.text) == "Аэродром потерян",
		"%s / %s" % [title.text, death_title.text])
	overlay.set_mission("nope")
	death.set_mission("nope")
	_check("итоги: неизвестная миссия → тоже тексты сцены",
		String(title.text) == "Аэродром спасён"
		and String(death_title.text) == "Аэродром потерян")
	# Возврат на m2: следующие проверки ждут тексты миссии забега.
	overlay.set_mission(M2)
	death.set_mission(M2)


# ─── M10 (bug 5): влезает ли согласованный текст реальным шрифтом ────────────
## Заголовки — Bold 48 px в поле 540 (лимит 520 на запас). M11/T3 (D4): строк-подсказок
## больше нет, поэтому вторая проверка — «все оставшиеся строки исхода влезают в 540».
func _check_result_fonts() -> void:
	var overlay := _level.win_overlay
	var death := _level.death_overlay
	var title_ok := true
	var title_details := ""
	var lines_ok := true
	var lines_details := ""
	for id: String in MissionData.MISSION_IDS:
		overlay.set_mission(id)
		death.set_mission(id)
		var win_width := _label_text_width(overlay.get_node(^"Title") as Label)
		var lose_width := _label_text_width(death.get_node(^"Title") as Label)
		if win_width > TITLE_WIDTH_LIMIT or lose_width > TITLE_WIDTH_LIMIT:
			title_ok = false
			title_details += "%s: победа %.1f, поражение %.1f; " % [id, win_width, lose_width]
		for screen: Control in [overlay, death]:
			for child in screen.get_children():
				var label := child as Label
				if label == null or String(label.text).is_empty():
					continue
				var width := _label_text_width(label)
				if width > GameConfig.REFERENCE_SIZE.x:
					lines_ok = false
					lines_details += "%s.%s: %.1f; " % [String(screen.name),
						String(label.name), width]
	_check("шрифт: заголовки исхода всех миссий ≤ %d px (Bold 48 реальным шрифтом)"
		% int(TITLE_WIDTH_LIMIT), title_ok, title_details)
	_check("шрифт: все оставшиеся строки экранов исхода ≤ 540 px (реальным шрифтом)",
		lines_ok, lines_details)
	overlay.set_mission(M2)
	death.set_mission(M2)


# ─── M10 (bug 1): кнопки экрана победы ──────────────────────────────────────
## «Повторить» / «Кампания» / «В ангар»: видны только при показанном оверлее, 320×88, не
## перекрывают строки итогов и иконки звёзд, ловят только своё касание. M11/T2: тап мимо
## кнопок больше ничего не делает — исход покидается только этими кнопками.
func _check_win_overlay_buttons() -> void:
	var overlay := _level.win_overlay
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	overlay.hide_overlay()
	_check("кнопки исхода: на скрытом оверлее не видно ни одной (0 из 3)",
		overlay.get_visible_action_button_count() == 0
		and not overlay.replay_button.visible and not overlay.campaign_button.visible
		and not overlay.home_button.visible,
		str(overlay.get_visible_action_button_count()))

	overlay.show_result(1234, 65.0, 1234, true, 3, 600)
	_check("кнопки исхода: show_result() показывает 3 кнопки с подписями",
		overlay.get_visible_action_button_count() == 3
		and String(overlay.replay_button.text) == "Повторить"
		and String(overlay.campaign_button.text) == "Кампания"
		and String(overlay.home_button.text) == "В ангар",
		"%d / %s" % [overlay.get_visible_action_button_count(),
			str([overlay.replay_button.text, overlay.campaign_button.text,
				overlay.home_button.text])])

	var buttons: Array[Button] = [overlay.replay_button, overlay.campaign_button,
		overlay.home_button]
	var inside := true
	var big_enough := true
	for button: Button in buttons:
		var rect := button.get_global_rect()
		inside = inside and _rect_inside(rect, field)
		big_enough = big_enough and rect.size.x >= 320.0 and rect.size.y >= 88.0
	_check("кнопки исхода: три кнопки 320×88 внутри поля 540×960 (тач-минимум 64)",
		inside and big_enough, str(overlay.home_button.get_global_rect()))
	var no_overlap := true
	var overlap_details := ""
	for i in buttons.size():
		for j in range(i + 1, buttons.size()):
			if _rects_overlap(buttons[i].get_global_rect(), buttons[j].get_global_rect()):
				no_overlap = false
				overlap_details += "%d×%d " % [i, j]
	var lines: Array[Label] = [
		overlay.get_node(^"Title") as Label, overlay.score_line, overlay.time_line,
		overlay.record_line, overlay.stars_line, overlay.supply_line,
	]
	for label: Label in lines:
		for button: Button in buttons:
			if _rects_overlap(label.get_global_rect(), button.get_global_rect()):
				no_overlap = false
				overlap_details += "%s×%s " % [String(label.name),
					String(button.name)]
	if overlay.star_icons != null and overlay.is_star_row_visible():
		for button: Button in buttons:
			if _rects_overlap(overlay.star_icons.get_global_rect(), button.get_global_rect()):
				no_overlap = false
				overlap_details += "StarIcons×%s " % String(button.name)
	_check("кнопки исхода: не перекрывают строки итогов, иконки звёзд и друг друга",
		no_overlap, overlap_details)

	_check("кнопки исхода: корень и затемнение прозрачны (IGNORE), кнопки ловят тап (STOP), оверлей ALWAYS",
		overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (overlay.get_node(^"Dim") as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE
		and overlay.replay_button.mouse_filter == Control.MOUSE_FILTER_STOP
		and overlay.campaign_button.mouse_filter == Control.MOUSE_FILTER_STOP
		and overlay.home_button.mouse_filter == Control.MOUSE_FILTER_STOP
		and overlay.process_mode == Node.PROCESS_MODE_ALWAYS,
		"root=%d button=%d mode=%d" % [overlay.mouse_filter,
			overlay.replay_button.mouse_filter, overlay.process_mode])

	# Латч одного касания: touch + Button.pressed одного тапа = один сигнал.
	var events: Array[String] = []
	var counter := func() -> void: events.append("x")
	overlay.replay_requested.connect(counter)
	overlay.request_replay()
	overlay._on_replay_pressed()
	_check("кнопки исхода: один тап по «Повторить» даёт один сигнал (латч)",
		events.size() == 1, "событий %d" % events.size())
	overlay.replay_requested.disconnect(counter)
	overlay.hide_overlay()
	_check("кнопки исхода: hide_overlay() снова скрывает кнопки",
		overlay.get_visible_action_button_count() == 0)

	# ── Реальная победа m2: тексты миссии и три действия ─────────────────────
	var shown := await _win_current_run()
	_check("победа m2: экран показан, заголовок «Переправа цела», три кнопки",
		shown and overlay.visible and overlay.get_mission_id() == M2
		and String(overlay.title.text) == "Переправа цела"
		and overlay.get_visible_action_button_count() == 3,
		"shown=%s, mission=%s, кнопок %d" % [shown, overlay.get_mission_id(),
			overlay.get_visible_action_button_count()])
	_check("победа m2: гейт endless ещё закрыт (нет звезды в m3) → строки открытия нет",
		not SaveGame.is_endless_unlocked() and not overlay.is_unlock_notice_visible(),
		"unlocked=%s, notice=%s" % [SaveGame.is_endless_unlocked(),
			overlay.is_unlock_notice_visible()])

	# «Повторить»: та же миссия m2, забег пошёл заново, кнопки скрылись.
	_check("«Повторить»: сигнал ушёл", overlay.request_replay())
	await get_tree().process_frame
	_check("«Повторить»: рестарт той же миссии m2 (PLAYING, волны идут, кнопки скрыты)",
		_level.get_state() == LevelController.State.PLAYING
		and _level.get_mission_id() == M2 and _level.waves.is_active()
		and not overlay.visible and overlay.get_visible_action_button_count() == 0
		and not get_tree().paused,
		"state=%d, mission=%s, overlay=%s" % [_level.get_state(),
			_level.get_mission_id(), overlay.visible])

	# ── M10 (bug 2): победа, которая открыла гейт, показывает строку ───────────
	# Звезда в m3 делает гейт выполненным по данным; LevelController ещё не видел перехода
	# (_endless_unlocked=false с запуска сцены), поэтому ближайшая победа его зафиксирует.
	SaveGame.record_stars(M3, 1)
	shown = await _win_current_run()
	_check("победа открыла гейт endless: на экране победы «%s»" % WinOverlay.ENDLESS_UNLOCK_TEXT,
		shown and overlay.visible and SaveGame.is_endless_unlocked()
		and overlay.is_unlock_notice_visible()
		and overlay.get_unlock_text() == WinOverlay.ENDLESS_UNLOCK_TEXT,
		"unlocked=%s, notice=%s" % [SaveGame.is_endless_unlocked(),
			overlay.is_unlock_notice_visible()])
	_check("«Повторить» после открытия гейта: рестарт, строка скрыта",
		overlay.request_replay() and not overlay.is_unlock_notice_visible(),
		"notice=%s" % overlay.is_unlock_notice_visible())
	await get_tree().process_frame

	# «Кампания»: выход из WON в выбор миссии; «Назад» возвращает брифинг (поток начат
	# с брифинга — begin_briefing()).
	shown = await _win_current_run()
	_check("«Кампания»: экран победы показан перед тапом", shown and overlay.visible)
	_check("«Кампания»: повторная победа при открытом гейте не повторяет строку открытия",
		not overlay.is_unlock_notice_visible())
	_check("«Кампания»: сигнал ушёл", overlay.request_campaign())
	await get_tree().process_frame
	_check("«Кампания»: выбор миссии открыт, состояние BRIEFING, забег очищен",
		_level.mission_select.visible and not overlay.visible and not _level.home.visible
		and _level.get_state() == LevelController.State.BRIEFING
		and not get_tree().paused and not _level.waves.is_active()
		and _level.enemies_root.get_child_count() == 0 and not _level.hud.visible,
		"select=%s, state=%d, paused=%s" % [_level.mission_select.visible,
			_level.get_state(), get_tree().paused])
	_level.mission_select.closed.emit()
	_check("«Кампания» → «Назад»: брифинг (поток начался с брифинга), не Home",
		_level.briefing.visible and not _level.home.visible
		and not _level.mission_select.visible)

	# Поток с домашнего экрана: Home → «Кампания» → карточка → бой → победа → «Кампания»
	# → «Назад» возвращает HOME (контекст выбирает _briefing_from_home).
	_level.show_home()
	_level.home.campaign_requested.emit()
	_level.mission_select.mission_chosen.emit(M1)
	_check("Home → «Кампания» → m1: брифинг миссии 1 открыт",
		_level.briefing.visible and _level.get_mission_id() == M1,
		"briefing=%s mission=%s" % [_level.briefing.visible, _level.get_mission_id()])
	_level.start_level()
	await get_tree().process_frame
	shown = await _win_current_run()
	_check("поток с Home: победа m1, заголовок «Аэродром спасён»",
		shown and overlay.visible and String(overlay.title.text) == "Аэродром спасён",
		String(overlay.title.text))
	_check("поток с Home: «Кампания» принята", overlay.request_campaign())
	await get_tree().process_frame
	_level.mission_select.closed.emit()
	_check("поток с Home: «Кампания» → «Назад» возвращает Home",
		_level.home.visible and not _level.briefing.visible
		and not _level.mission_select.visible)

	# «В ангар» с экрана победы: Home, пауза снята, HUD скрыт.
	_level.begin_briefing()
	_level.start_level()
	await get_tree().process_frame
	shown = await _win_current_run()
	_check("«В ангар»: экран победы показан", shown and overlay.visible)
	_check("«В ангар»: сигнал ушёл", overlay.request_home())
	await get_tree().process_frame
	_check("«В ангар»: домашний экран, пауза снята, волны/HUD убраны",
		_level.home.visible and not overlay.visible
		and _level.get_state() == LevelController.State.BRIEFING
		and not get_tree().paused and not _level.waves.is_active()
		and not _level.hud.visible,
		"home=%s, state=%d, paused=%s" % [_level.home.visible,
			_level.get_state(), get_tree().paused])

	# M11/T2: тап-шорткатов больше нет — касание в свободную точку экрана победы НЕ рестартит
	# и не закрывает оверлей (LevelController._unhandled_input удалён). Рестарт даёт только
	# кнопка «Повторить».
	_level.start_level()
	await get_tree().process_frame
	shown = await _win_current_run()
	_check("тап мимо кнопок: экран победы показан", shown and overlay.visible)
	_check("тап-шорткатов нет: у LevelController больше нет _unhandled_input",
		not _level.has_method("_unhandled_input"))
	var free_touch := _touch_event(true)
	free_touch.position = Vector2(270.0, 480.0)
	var state_before := _level.get_state()
	_level.get_viewport().push_input(free_touch)
	var release_touch := free_touch.duplicate() as InputEventScreenTouch
	release_touch.pressed = false
	_level.get_viewport().push_input(release_touch)
	await get_tree().process_frame
	_check("тап мимо кнопок на экране победы ничего не делает (WON, оверлей жив, пауза)",
		_level.get_state() == state_before
		and _level.get_state() == LevelController.State.WON
		and overlay.visible and get_tree().paused,
		"state=%d, overlay=%s, paused=%s" % [_level.get_state(), overlay.visible,
			get_tree().paused])
	_check("кнопка «Повторить» после тапа по-прежнему работает", overlay.request_replay())
	await get_tree().process_frame
	_check("«Повторить» после тапа: снова бой (PLAYING), оверлей скрыт",
		_level.get_state() == LevelController.State.PLAYING and not overlay.visible
		and not get_tree().paused,
		"state=%d, overlay=%s" % [_level.get_state(), overlay.visible])


# ─── M11 (T1): реальный путь ввода кнопок исхода ────────────────────────────
## На Android `Button.pressed` от касания не приходит (project.godot:
## pointing/emulate_mouse_from_touch=false), поэтому единственный рабочий путь — как в
## pause_overlay.gd: button.gui_input + InputEventScreenTouch (+accept_event). Раньше общий
## латч занимался дважды (_route_action_touch + request_*) и кнопки были мёртвыми на 100 % —
## этот блок ловит регресс, потому что ходит через хендлеры, а не через request_*().
func _check_win_overlay_real_input() -> void:
	var overlay := _level.win_overlay
	var replay_events: Array[String] = []
	var campaign_events: Array[String] = []
	var home_events: Array[String] = []
	var replay_cb := func() -> void: replay_events.append("x")
	var campaign_cb := func() -> void: campaign_events.append("x")
	var home_cb := func() -> void: home_events.append("x")
	overlay.replay_requested.connect(replay_cb)
	overlay.campaign_requested.connect(campaign_cb)
	overlay.home_requested.connect(home_cb)

	# ── Латч одной кнопки: press → один сигнал, повторный press — нет, release — снят.
	# Оверлей показан, но LevelController вне WON (BRIEFING): обработчики сигналов ничего не
	# меняют, поэтому занятый латч видно через is_tap_available() и он не сбрасывается показом.
	_level.begin_briefing()
	overlay.show_result(1500, 40.0, 1500, true, 2, 250)
	_check("реальный ввод: после show_result() ввод свободен (is_tap_available)",
		overlay.is_tap_available())
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, true))
	_check("реальный ввод: press на «Кампанию» → ровно один campaign_requested",
		campaign_events.size() == 1, "событий %d" % campaign_events.size())
	_check("реальный ввод: после press латч занят (is_tap_available false)",
		not overlay.is_tap_available())
	var second_request := overlay.request_campaign()
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, true))
	overlay._on_campaign_pressed()
	_check("реальный ввод: повторный запрос/тап до отпускания сигналов не даёт",
		not second_request and campaign_events.size() == 1,
		"request=%s, событий %d" % [second_request, campaign_events.size()])
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, false))
	_check("реальный ввод: release сигналов не даёт и снимает латч",
		campaign_events.size() == 1 and overlay.is_tap_available(),
		"событий %d, available=%s" % [campaign_events.size(), overlay.is_tap_available()])
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, true))
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, false))
	_check("реальный ввод: после отпускания кнопка снова работает (2-й сигнал)",
		campaign_events.size() == 2, "событий %d" % campaign_events.size())
	overlay.hide_overlay()

	# ── «Повторить» реальным касанием: рестарт ТОЙ ЖЕ миссии, state PLAYING.
	_level.start_level()
	await get_tree().process_frame
	var mission_before := _level.get_mission_id()
	var shown := await _win_current_run()
	_check("реальный ввод: экран победы показан перед касанием «Повторить»",
		shown and overlay.visible and overlay.get_visible_action_button_count() == 3)
	_check("реальный ввод: перед касанием латчи сброшены показом (is_tap_available)",
		overlay.is_tap_available())
	var replay_before := replay_events.size()
	overlay._on_replay_gui_input(_button_touch(overlay.replay_button, true))
	await get_tree().process_frame
	overlay._on_replay_gui_input(_button_touch(overlay.replay_button, false))
	_check("реальный ввод «Повторить»: ровно один сигнал, отпускание не добавило",
		replay_events.size() - replay_before == 1,
		"событий %d" % (replay_events.size() - replay_before))
	_check("реальный ввод «Повторить»: та же миссия снова в бою (PLAYING), оверлей скрыт",
		_level.get_state() == LevelController.State.PLAYING
		and _level.get_mission_id() == mission_before
		and not overlay.visible and not get_tree().paused
		and _level.waves.is_active(),
		"state=%d, mission=%s, overlay=%s" % [_level.get_state(),
			_level.get_mission_id(), overlay.visible])

	# ── «Кампания» реальным касанием: выход в выбор миссии, состояние BRIEFING.
	_level.start_level()
	await get_tree().process_frame
	shown = await _win_current_run()
	var campaign_before := campaign_events.size()
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, true))
	await get_tree().process_frame
	overlay._on_campaign_gui_input(_button_touch(overlay.campaign_button, false))
	_check("реальный ввод «Кампания»: ровно один сигнал, отпускание не добавило",
		campaign_events.size() - campaign_before == 1,
		"событий %d" % (campaign_events.size() - campaign_before))
	_check("реальный ввод «Кампания»: выбор миссии открыт, BRIEFING, забег очищен",
		shown and _level.mission_select.visible and not overlay.visible
		and not _level.home.visible
		and _level.get_state() == LevelController.State.BRIEFING
		and not get_tree().paused and not _level.waves.is_active()
		and _level.enemies_root.get_child_count() == 0,
		"select=%s, state=%d, paused=%s" % [_level.mission_select.visible,
			_level.get_state(), get_tree().paused])

	# ── «В ангар» реальным касанием: домашний экран, пауза снята.
	_level.start_level()
	await get_tree().process_frame
	shown = await _win_current_run()
	var home_before := home_events.size()
	overlay._on_home_gui_input(_button_touch(overlay.home_button, true))
	await get_tree().process_frame
	overlay._on_home_gui_input(_button_touch(overlay.home_button, false))
	_check("реальный ввод «В ангар»: ровно один сигнал, отпускание не добавило",
		home_events.size() - home_before == 1,
		"событий %d" % (home_events.size() - home_before))
	_check("реальный ввод «В ангар»: домашний экран, пауза снята, волны/HUD убраны",
		shown and _level.home.visible and not overlay.visible
		and _level.get_state() == LevelController.State.BRIEFING
		and not get_tree().paused and not _level.waves.is_active()
		and not _level.hud.visible,
		"home=%s, state=%d, paused=%s" % [_level.home.visible,
			_level.get_state(), get_tree().paused])

	overlay.replay_requested.disconnect(replay_cb)
	overlay.campaign_requested.disconnect(campaign_cb)
	overlay.home_requested.disconnect(home_cb)


## Довести текущий забег до победы (без боя с боссом) и дождаться экрана исхода.
func _win_current_run() -> bool:
	_level._finish_run(true)
	return await _wait_until(func() -> bool: return _level.win_overlay.visible, 2.0)


## Ожидание условия с таймаутом (кадры): используется для отложенного показа оверлея.
func _wait_until(condition: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return bool(condition.call())


# ─── Помощники ──────────────────────────────────────────────────────────────
func _fresh() -> void:
	_remove_file(_path)


## Узел карточки по id и относительному пути («Inner/Row/StarsLabel»).
func _card_node(id: String, path: String) -> Node:
	return _select.get_node("Cards/Card_" + id + "/" + path)


func _card_label(id: String, path: String) -> String:
	var label := _card_node(id, path) as Label
	return String(label.text) if label != null else "<нет метки>"


func _card_button(id: String) -> Button:
	return _card_node(id, "Inner/ChooseButton") as Button


func _label_text(path: String) -> String:
	return String((_select.get_node(NodePath(path)) as Label).text)


func _briefing_text(path: NodePath) -> String:
	return String((_level.briefing.get_node_or_null(path) as Label).text)


func _touch_event(pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = Vector2(90.0, 48.0)
	return event


## M11 (T1): touch в ЦЕНТР кнопки — так событие приходит на Android в button.gui_input.
func _button_touch(button: Button, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = button.get_global_rect().get_center()
	return event


func _label_text_width(label: Label) -> float:
	var font := label.get_theme_font(&"font")
	if font == null:
		return 0.0
	return font.get_string_size(String(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1,
		label.get_theme_font_size(&"font_size")).x


func _font_covers(font: Font, text: String) -> bool:
	for index in text.length():
		var code := text.unicode_at(index)
		if code == 32 or code == 10:
			continue
		if not font.has_char(code):
			return false
	return true


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
