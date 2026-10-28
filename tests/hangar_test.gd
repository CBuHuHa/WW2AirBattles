# hangar_test.gd
# Purpose: Гейт M6.2b — экран ангара. Проверяет:
#            • чистый профиль: 3 карточки, Ла-5 выбран, Як-3/Аэрокобра закрыты с текстами
#              «Закрыто: пройди кампанию» / «Закрыто: 9/9 звёзд», строки «Снабжение: 0» и
#              «Звёзды: 0/9», строка статов «8 выстр./с · урон 1.0 · HP 3», кнопка замка disabled;
#            • превью: ShipVisual с ключом выбранного самолёта, scale 2× (целочисленно),
#              без ливреи — белый modulate;
#            • свотчи ливрей: 0 — «Без ливреи» + 300/600/900, состояние «Купить N»/«Выбрать»/
#              «Выбрано», disabled при нехватке снабжения;
#            • refresh() после снабжения + unlock_plane: Як-3 открыт и выбирается,
#              request_plane(yak3) → true, сейв отдаёт yak3, карточка «Выбрано», превью yak3;
#            • закрытый P-39: request_plane → false, выбор не меняется; неизвестный id → false;
#            • ливреи: request_livery(1) при 1000 → куплена+выбрана, снабжение 700, повторного
#              списания нет; при 500 request_livery(2) → false (600 не хватает), профиль цел;
#              request_livery(0) снимает ливрею, свотчи обновляются, индекс 5 → false;
#            • раскладка: карточки/свотчи/«Назад» внутри 540×960, тач-таргеты ≥ 64 px,
#              корень и Dim прозрачны для тапов, интерактив STOP, экран ALWAYS;
#            • main.tscn: Hangar скрыт, брифинг виден, состояние BRIEFING; кнопка «Ангар» на
#              брифинге не перекрывает «В бой» и «Миссии», латч один сигнал за касание;
#              «Ангар» → ангар виден, брифинг скрыт, забег не стартует; «Назад» → брифинг;
#              start_level() применяет выбранный самолёт и ливрею (plane_id/livery_index/тинт),
#              HUD и профиль (снабжение/самолёт) не ломаются.
#            • регресс «экран замер» (реальное устройство): после выбора самолёта/покупки ливреи
#              экран переставал реагировать на тапы, потому что латч _latched снимался только
#              в refresh()/show_overlay(), а Android не присылает mouse-release. Здесь ввод
#              гоняется НАСТОЯЩИМ путём: gui_input(pressed=true) → gui_input(pressed=false),
#              несколько касаний подряд (свотч → карточка → закрытая карточка → карточка →
#              свотч → «Назад» ×2) — каждое обязано сработать, а mouse-дубль одного касания
#              дать ровно один запрос.
#          Изоляция: сейв живёт в user://qa_hangar_*.cfg, реальный
#          user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/hangar_test.tscn
# Dependencies: Hangar, BriefingOverlay, LevelController (main.tscn), Player, SaveGame,
#               PlaneData, ArtStyle, RunRecord, GameConfig.
# Author: UI/UX Agent

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const HANGAR_SCENE: PackedScene = preload("res://scenes/hangar.tscn")

const LA5 := "la5"
const YAK3 := "yak3"
const P39 := "p39"
const M1 := "m1_airfield"

## Ожидаемые тексты карточек (GDD «Самолёты (ангар)» + data/planes.json).
const LA5_STATS := "8 выстр./с · урон 1.0 · HP 3"
const YAK3_STATS := "10 выстр./с · урон 0.85 · HP 3"
const P39_STATS := "6.5 выстр./с · урон 1.5 · HP 3"
const YAK3_LOCK := "Закрыто: пройди кампанию"
const P39_LOCK := "Закрыто: 9/9 звёзд"

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}
var _hangar: Hangar
var _level: LevelController


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_hangar_%d.cfg" % Time.get_ticks_msec()
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
	if _hangar != null:
		_hangar.queue_free()
		_hangar = null
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
	print("HANGAR_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("HANGAR_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	await _check_fresh_profile()
	_check_layout()
	_check_unlock_and_select()
	_check_liveries()
	_check_tap_input()
	await _check_main_scene()


# ─── Чистый профиль: карточки, превью, свотчи ───────────────────────────────
func _check_fresh_profile() -> void:
	_fresh()
	_hangar = HANGAR_SCENE.instantiate()
	add_child(_hangar)
	await get_tree().process_frame
	await get_tree().process_frame

	_check("свежий профиль: экран скрыт по умолчанию", not _hangar.visible)
	_check("свежий профиль: карточек самолётов 3", _hangar.get_visible_plane_count() == 3,
		str(_hangar.get_visible_plane_count()))
	_check("свежий профиль: заголовок «Ангар»", _label(^"Title") == "Ангар", _label(^"Title"))
	_check("свежий профиль: «Снабжение: 0»",
		_hangar.get_supply_text() == "Снабжение: 0", _hangar.get_supply_text())
	_check("свежий профиль: «Звёзды: 0/9»",
		_hangar.get_stars_text() == "Звёзды: 0/9", _hangar.get_stars_text())

	var la5 := _hangar.get_plane_card_state(LA5)
	var yak3 := _hangar.get_plane_card_state(YAK3)
	var p39 := _hangar.get_plane_card_state(P39)
	_check("свежий профиль: Ла-5 открыт и выбран",
		bool(la5["unlocked"]) and bool(la5["selected"]), str(la5))
	_check("свежий профиль: Як-3 и Аэрокобра закрыты",
		not bool(yak3["unlocked"]) and not bool(p39["unlocked"]),
		"yak3=%s p39=%s" % [yak3["unlocked"], p39["unlocked"]])
	_check("замок: Як-3 — «Закрыто: пройди кампанию»", String(yak3["lock_text"]) == YAK3_LOCK,
		String(yak3["lock_text"]))
	_check("замок: Аэрокобра — «Закрыто: 9/9 звёзд»", String(p39["lock_text"]) == P39_LOCK,
		String(p39["lock_text"]))
	_check("замок: строка состояния видна в карточке Як-3",
		_card_label(YAK3, "StateLabel") == YAK3_LOCK, _card_label(YAK3, "StateLabel"))
	_check("замок: кнопки закрытых карточек disabled, у открытой Ла-5 — «Выбрано»",
		_card_button(LA5).disabled and _card_button(YAK3).disabled and _card_button(P39).disabled
		and _card_button(LA5).text == "Выбрано",
		"%s / %s" % [_card_button(LA5).text, _card_button(YAK3).text])

	_check("статы: Ла-5 «%s»" % LA5_STATS, _card_label(LA5, "StatsLabel") == LA5_STATS,
		_card_label(LA5, "StatsLabel"))
	_check("статы: Як-3 «%s»" % YAK3_STATS, _card_label(YAK3, "StatsLabel") == YAK3_STATS,
		_card_label(YAK3, "StatsLabel"))
	_check("статы: Аэрокобра «%s»" % P39_STATS, _card_label(P39, "StatsLabel") == P39_STATS,
		_card_label(P39, "StatsLabel"))

	var preview := _preview()
	_check("превью: силуэт выбранного самолёта (player_la5)",
		preview != null and preview.asset_key == &"player_la5",
		"<нет узла>" if preview == null else str(preview.asset_key))
	_check("превью: увеличение целочисленно 2× и влезает в панель",
		preview != null and preview.scale == Vector2(2.0, 2.0)
		and _preview_fits_panel(),
		"<нет узла>" if preview == null else str(preview.scale))
	_check("превью: без ливреи — белый тинт (родная палитра)",
		preview != null and preview.modulate.is_equal_approx(Color(1, 1, 1)),
		"<нет узла>" if preview == null else str(preview.modulate))

	_check("ливреи: 4 свотча (0 — без ливреи + 3 платные)",
		_swatch_count() == SaveGame.LIVERY_SLOTS, str(_swatch_count()))
	_check("ливреи: «Без ливреи» выбран",
		_swatch_label(0, "NameLabel") == "Без ливреи"
		and _swatch_label(0, "StateLabel") == "Выбрано",
		"%s / %s" % [_swatch_label(0, "NameLabel"), _swatch_label(0, "StateLabel")])
	_check("ливреи: цены 300/600/900 на свотчах",
		_swatch_label(1, "StateLabel") == "Купить 300"
		and _swatch_label(2, "StateLabel") == "Купить 600"
		and _swatch_label(3, "StateLabel") == "Купить 900",
		"%s / %s / %s" % [_swatch_label(1, "StateLabel"), _swatch_label(2, "StateLabel"),
			_swatch_label(3, "StateLabel")])
	_check("ливреи: при снабжении 0 платные свотчи disabled",
		bool(_hangar.get_livery_state(1)["disabled"])
		and bool(_hangar.get_livery_state(3)["disabled"])
		and not bool(_hangar.get_livery_state(0)["disabled"]),
		str(_hangar.get_livery_state(1)))
	_check("ливреи: свотч 1 показывает цену 300", int(_hangar.get_livery_state(1)["cost"]) == 300,
		str(_hangar.get_livery_state(1)["cost"]))

	_check("запрос: request_plane(закрытая p39) → false, выбор остаётся Ла-5",
		not _hangar.request_plane(P39) and SaveGame.get_selected_plane() == LA5,
		SaveGame.get_selected_plane())
	_check("запрос: неизвестный id самолёта → false",
		not _hangar.request_plane("biplane") and SaveGame.get_selected_plane() == LA5)

	_hangar.show_overlay()
	_check("показ: show_overlay() делает экран видимым",
		_hangar.visible and _hangar.get_supply_text() == "Снабжение: 0",
		_hangar.get_supply_text())


# ─── Раскладка и ввод ───────────────────────────────────────────────────────
func _check_layout() -> void:
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var cards_inside := true
	var buttons_ok := true
	var button_offsets: Array[float] = []
	for id: String in PlaneData.PLANE_IDS:
		var panel := _hangar.get_node_or_null("Cards/Card_" + id) as Control
		if panel == null or not _rect_inside(panel.get_global_rect(), field):
			cards_inside = false
			continue
		var button := _card_button(id)
		buttons_ok = buttons_ok and button.get_global_rect().size.y >= 64.0
		button_offsets.append(button.get_global_rect().position.y - panel.get_global_rect().position.y)
	var offsets_equal := button_offsets.size() == PlaneData.PLANE_IDS.size()
	for offset: float in button_offsets:
		offsets_equal = offsets_equal and absf(offset - button_offsets[0]) <= 0.5

	_check("раскладка: три карточки внутри поля 540×960", cards_inside,
		str((_hangar.get_node(^"Cards") as Control).get_global_rect()))
	_check("раскладка: кнопки карточек ≥ 64 px и на одной высоте", buttons_ok and offsets_equal,
		str(button_offsets))

	var swatch_ok := true
	for index in SaveGame.LIVERY_SLOTS:
		var panel := _hangar.get_node_or_null("LiveryRow/Swatch_%d" % index) as Control
		if panel == null:
			swatch_ok = false
			continue
		var rect := panel.get_global_rect()
		swatch_ok = swatch_ok and _rect_inside(rect, field) and rect.size.y >= 64.0 \
			and rect.size.x >= 64.0
	_check("раскладка: свотчи ливрей ≥ 64×64 и внутри поля", swatch_ok,
		str((_hangar.get_node(^"LiveryRow") as Control).get_global_rect()))

	var back := (_hangar.get_node(^"BackButton") as Button)
	var back_rect := back.get_global_rect()
	var livery_rect := (_hangar.get_node(^"LiveryRow") as Control).get_global_rect()
	var cards_rect := (_hangar.get_node(^"Cards") as Control).get_global_rect()
	_check("раскладка: «Назад» 320×88 внутри поля", back_rect.size.x >= 320.0
		and back_rect.size.y >= 88.0 and _rect_inside(back_rect, field)
		and String(back.text) == "Назад", str(back_rect))
	_check("раскладка: ряды не накладываются (карточки / ливреи / «Назад»)",
		not _rects_overlap(cards_rect, livery_rect)
		and not _rects_overlap(livery_rect, back_rect)
		and not _rects_overlap(cards_rect, back_rect),
		"%s / %s / %s" % [cards_rect, livery_rect, back_rect])
	_check("раскладка: превью-панель выше карточек и не перекрывает их",
		not _rects_overlap((_hangar.get_node(^"PreviewPanel") as Control).get_global_rect(),
			cards_rect))

	_check("ввод: корень и затемнение прозрачны для тапов, интерактив — STOP",
		_hangar.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (_hangar.get_node(^"Dim") as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE
		and _card_button(LA5).mouse_filter == Control.MOUSE_FILTER_STOP
		and (_hangar.get_node(^"LiveryRow/Swatch_1") as Control).mouse_filter
			== Control.MOUSE_FILTER_STOP
		and back.mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("ввод: экран живёт ALWAYS (не зависает от паузы дерева)",
		_hangar.process_mode == Node.PROCESS_MODE_ALWAYS)

	# Латч «Назад»: двойной обработчик = один closed.
	var closed_events: Array[int] = []
	var counter := func() -> void: closed_events.append(1)
	_hangar.closed.connect(counter)
	_hangar.show_overlay()
	_hangar._on_back_button_gui_input(_touch_event(true))
	_hangar._on_back_button_gui_input(_touch_event(true))
	_check("ввод: «Назад» эмитит closed один раз за касание (латч)",
		closed_events.size() == 1, "событий %d" % closed_events.size())
	_hangar.closed.disconnect(counter)
	_hangar.hide_overlay()


# ─── Открытие Як-3 и выбор самолёта ─────────────────────────────────────────
func _check_unlock_and_select() -> void:
	SaveGame.add_supply(1000)
	SaveGame.unlock_plane(YAK3)
	_hangar.refresh()
	var yak3 := _hangar.get_plane_card_state(YAK3)
	_check("открытие: 1000 снабжения + unlock_plane(yak3) → Як-3 открыт, не выбран",
		bool(yak3["unlocked"]) and not bool(yak3["selected"])
		and String(yak3["lock_text"]).is_empty(), str(yak3))
	_check("открытие: refresh() очистил замок и включил кнопку «Выбрать»",
		_card_label(YAK3, "StateLabel").is_empty() and _card_button(YAK3).text == "Выбрать"
		and not _card_button(YAK3).disabled,
		"%s / %s" % [_card_label(YAK3, "StateLabel"), _card_button(YAK3).text])
	_check("открытие: строка снабжения «Снабжение: 1000»",
		_hangar.get_supply_text() == "Снабжение: 1000", _hangar.get_supply_text())

	_check("выбор: request_plane(yak3) → true", _hangar.request_plane(YAK3))
	_check("выбор: сейв отдаёт yak3", SaveGame.get_selected_plane() == YAK3,
		SaveGame.get_selected_plane())
	_check("выбор: карточка Як-3 «Выбрано», Ла-5 снова «Выбрать»",
		_hangar.get_plane_card_state(YAK3)["selected"]
		and _card_button(YAK3).text == "Выбрано" and _card_button(YAK3).disabled
		and _card_button(LA5).text == "Выбрать" and not _card_button(LA5).disabled,
		"%s / %s" % [_card_button(YAK3).text, _card_button(LA5).text])
	_check("выбор: превью переключилось на player_yak3",
		_preview().asset_key == &"player_yak3", str(_preview().asset_key))

	_check("выбор: закрытая Аэрокобра не выбирается программно (выбор остаётся yak3)",
		not _hangar.request_plane(P39) and SaveGame.get_selected_plane() == YAK3,
		SaveGame.get_selected_plane())


# ─── Ливреи: покупка, выбор, нехватка снабжения ─────────────────────────────
func _check_liveries() -> void:
	_check("ливрея: request_livery(1) при 1000 → true", _hangar.request_livery(1))
	_check("ливрея: куплена и выбрана, снабжение 700 (списано 300)",
		SaveGame.is_livery_owned(1) and SaveGame.get_selected_livery() == 1
		and SaveGame.get_supply() == 700,
		"owned=%s selected=%d supply=%d" % [SaveGame.is_livery_owned(1),
			SaveGame.get_selected_livery(), SaveGame.get_supply()])
	_check("ливрея: превью получило тинт ливреи 1 (#6B7F5A)",
		_preview().modulate.is_equal_approx(ArtStyle.livery_tint(1)),
		str(_preview().modulate))
	_check("ливрея: свотч 1 «Выбрано», остальные — цена/выбор",
		_swatch_label(1, "StateLabel") == "Выбрано"
		and _swatch_label(2, "StateLabel") == "Купить 600",
		"%s / %s" % [_swatch_label(1, "StateLabel"), _swatch_label(2, "StateLabel")])

	_check("ливрея: повторный request_livery(1) не списывает снабжение",
		_hangar.request_livery(1) and SaveGame.get_supply() == 700,
		str(SaveGame.get_supply()))

	# 500 < 600: покупка ливреи 2 не проходит, баланс и профиль не меняются.
	SaveGame.spend_supply(200)
	_check("ливрея: при 500 снабжения request_livery(2) → false (нужно 600)",
		not _hangar.request_livery(2) and SaveGame.get_supply() == 500
		and not SaveGame.is_livery_owned(2),
		"supply=%d owned=%s" % [SaveGame.get_supply(), SaveGame.is_livery_owned(2)])
	_check("ливрея: свотч 2 остался «Купить 600» и disabled",
		_swatch_label(2, "StateLabel") == "Купить 600"
		and bool(_hangar.get_livery_state(2)["disabled"]),
		str(_hangar.get_livery_state(2)))

	_check("ливрея: request_livery(0) снимает ливрею",
		_hangar.request_livery(0) and SaveGame.get_selected_livery() == 0,
		str(SaveGame.get_selected_livery()))
	_check("ливрея: свотч 0 «Выбрано», свотч 1 «Выбрать» (куплена, не выбрана)",
		_swatch_label(0, "StateLabel") == "Выбрано"
		and _swatch_label(1, "StateLabel") == "Выбрать" and not _swatch_label(1,
			"StateLabel").begins_with("Купить"),
		"%s / %s" % [_swatch_label(0, "StateLabel"), _swatch_label(1, "StateLabel")])
	_check("ливрея: без ливреи превью снова белое",
		_preview().modulate.is_equal_approx(Color(1, 1, 1)), str(_preview().modulate))
	_check("ливрея: индекс 5 → false (вне 0…3)",
		not _hangar.request_livery(5) and SaveGame.get_selected_livery() == 0)
	_check("ливрея: get_selected_livery() отдаёт 0", _hangar.get_selected_livery() == 0)


# ─── Ввод: касания подряд (регресс «экран замер после действия») ────────────
## Баг с реального устройства: на Android отпускание пальца не превращается в mouse-release,
## а латч `_latched` снимался ТОЛЬКО в refresh()/show_overlay(). request_plane()/request_livery()
## зовут refresh() до установки латча, поэтому после первого же успешного действия латч
## оставался true навсегда и экран переставал реагировать на тапы (помогал лишь перезапуск).
## Здесь ввод идёт НАСТОЯЩИМ путём: gui_input(pressed=true) → gui_input(pressed=false).
func _check_tap_input() -> void:
	_hangar.show_overlay()

	# 1) Полное касание свотча ливреи 1: покупка уже была, значит выбор.
	_tap_swatch(1)
	_check("ввод: касание свотча «Ливрея 1» (нажатие + отпускание) выбирает ливрею",
		SaveGame.get_selected_livery() == 1, str(SaveGame.get_selected_livery()))

	# 2) СРАЗУ второе касание, уже по карточке Ла-5: старый код здесь уже не отвечал.
	_tap_plane(LA5)
	_check("ввод: второе касание подряд срабатывает — выбран Ла-5 (баг «экран замер»)",
		SaveGame.get_selected_plane() == LA5, SaveGame.get_selected_plane())
	_check("ввод: карточки и свотчи перерисованы после двух касаний подряд",
		_card_button(LA5).text == "Выбрано" and _card_button(YAK3).text == "Выбрать"
		and _swatch_label(1, "StateLabel") == "Выбрано",
		"%s / %s / %s" % [_card_button(LA5).text, _card_button(YAK3).text,
			_swatch_label(1, "StateLabel")])

	# 3) Провал (закрытая Аэрокобра) не блокирует следующее касание.
	_tap_plane(P39)
	_check("ввод: касание закрытой карточки ничего не выбирает (Ла-5 остаётся)",
		SaveGame.get_selected_plane() == LA5, SaveGame.get_selected_plane())
	_tap_plane(YAK3)
	_check("ввод: после провала следующее касание срабатывает — выбран Як-3",
		SaveGame.get_selected_plane() == YAK3, SaveGame.get_selected_plane())

	# 4) Ещё одно касание подряд: снятие ливреи.
	_tap_swatch(0)
	_check("ввод: третье касание подряд снимает ливрею (индекс 0)",
		SaveGame.get_selected_livery() == 0, str(SaveGame.get_selected_livery()))

	# 5) Одно физическое касание = один запрос: touch-нажатие, touch-отпускание и mouse-дубль
	#    (Button.pressed на десктопе) дают РОВНО один closed, а второе касание — второй.
	var closed_events: Array[int] = []
	var counter := func() -> void: closed_events.append(1)
	_hangar.closed.connect(counter)
	_tap_back()
	_check("ввод: одно касание «Назад» (touch + mouse-дубль) = один closed",
		closed_events.size() == 1, "событий %d" % closed_events.size())
	_tap_back()
	_check("ввод: второе касание «Назад» тоже срабатывает (латч не залип)",
		closed_events.size() == 2, "событий %d" % closed_events.size())
	_hangar.closed.disconnect(counter)
	_check("ввод: латч касания снят — экран принимает следующее нажатие",
		_hangar.is_tap_available())
	_hangar.hide_overlay()


# ─── main.tscn: «Ангар» на брифинге → экран → «В бой» с самолётом ───────────
func _check_main_scene() -> void:
	# Для проверки применения ливреи выбираем купленную ливрею 1 (снабжение не тратится).
	SaveGame.select_livery(1)
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	# M8c1: при запуске приложения показан Home; брифинг открывается явно (публичный вход).
	_level.begin_briefing()
	await get_tree().process_frame

	_check("старт: состояние BRIEFING, брифинг виден, ангар скрыт",
		_level.get_state() == LevelController.State.BRIEFING
		and _level.briefing.visible and not _level.hangar.visible,
		"state=%d, briefing=%s, hangar=%s" % [_level.get_state(),
			_level.briefing.visible, _level.hangar.visible])

	var hangar_button := _level.briefing.get_node_or_null(^"HangarButton") as Button
	var missions_button := _level.briefing.get_node_or_null(^"MissionsButton") as Button
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	_check("брифинг: кнопка «Ангар» есть, 160×64, внутри поля",
		hangar_button != null and String(hangar_button.text) == "Ангар"
		and hangar_button.get_global_rect().size.y >= 64.0
		and _rect_inside(hangar_button.get_global_rect(), field),
		"нет кнопки" if hangar_button == null else str(hangar_button.get_global_rect()))
	_check("брифинг: «Ангар» не перекрывает «В бой» и «Миссии»",
		hangar_button != null and missions_button != null
		and not _rects_overlap(hangar_button.get_global_rect(),
			_level.briefing.start_button.get_global_rect())
		and not _rects_overlap(hangar_button.get_global_rect(),
			missions_button.get_global_rect()))

	# Латч кнопки на реальном брифинге: двойное касание = один hangar_requested.
	var hangar_events: Array[int] = []
	var counter := func() -> void: hangar_events.append(1)
	_level.briefing.hangar_requested.connect(counter)
	_level.briefing.show_overlay()
	_level.briefing._on_hangar_button_gui_input(_touch_event(true))
	_level.briefing._on_hangar_button_gui_input(_touch_event(true))
	_check("брифинг: «Ангар» срабатывает один раз за касание (латч)",
		hangar_events.size() == 1, "событий %d" % hangar_events.size())
	_level.briefing.hangar_requested.disconnect(counter)
	_level.hangar.closed.emit()
	_check("ангар: «Назад» вернул брифинг",
		_level.briefing.visible and not _level.hangar.visible)

	# Основной путь: «Ангар» → экран, состояние остаётся BRIEFING, волны не стартуют.
	_level.briefing.hangar_requested.emit()
	_check("ангар: открылся, брифинг скрыт, состояние BRIEFING",
		_level.hangar.visible and not _level.briefing.visible
		and _level.get_state() == LevelController.State.BRIEFING,
		"hangar=%s, briefing=%s, state=%d" % [_level.hangar.visible,
			_level.briefing.visible, _level.get_state()])
	_check("ангар: забег не начался — волн нет, игрок без управления",
		_level.waves.get_alive_count() == 0
		and not _level.player.is_processing()
		and not _level.player.is_processing_unhandled_input(),
		"живых врагов %d" % _level.waves.get_alive_count())
	_check("ангар: строка снабжения и выбор самолёта читаются из профиля",
		_level.hangar.get_supply_text() == "Снабжение: 500"
		and SaveGame.get_selected_plane() == YAK3,
		"%s / %s" % [_level.hangar.get_supply_text(), SaveGame.get_selected_plane()])

	_level.hangar.closed.emit()
	_check("ангар: «Назад» снова показывает брифинг текущей миссии",
		_level.briefing.visible and not _level.hangar.visible
		and _level.briefing.get_mission_id() == M1,
		"briefing=%s, mission=%s" % [_level.briefing.visible,
			_level.briefing.get_mission_id()])

	# «В бой»: стартует забег уже с самолётом ангара и его ливреей.
	_level.briefing.start_requested.emit()
	await get_tree().process_frame
	var player_visual := _level.player.get_node_or_null(^"Visual") as CanvasItem
	_check("старт забега: выбранный в ангаре самолёт (plane_id = yak3)",
		_level.player.plane_id == YAK3, _level.player.plane_id)
	_check("старт забега: ливрея ангара применена (livery_index = 1)",
		_level.player.livery_index == 1, str(_level.player.livery_index))
	_check("старт забега: Visual.modulate = тинт ливреи 1",
		player_visual != null and player_visual.modulate.is_equal_approx(
			ArtStyle.livery_tint(1)),
		"<нет Visual>" if player_visual == null else str(player_visual.modulate))
	_check("старт забега: HUD цел (виден, «HP 3/3»), состояние PLAYING",
		_level.get_state() == LevelController.State.PLAYING and _level.hud.visible
		and String((_level.hud.get_node(^"HPLabel") as Label).text) == "HP 3/3",
		"state=%d, HUD %s" % [_level.get_state(),
			(_level.hud.get_node(^"HPLabel") as Label).text])
	_check("старт забега: профиль не сломан (самолёт yak3, снабжение 500, ливрея 1)",
		SaveGame.get_selected_plane() == YAK3 and SaveGame.get_supply() == 500
		and SaveGame.get_selected_livery() == 1,
		"%s / %d / %d" % [SaveGame.get_selected_plane(), SaveGame.get_supply(),
			SaveGame.get_selected_livery()])


# ─── Помощники ──────────────────────────────────────────────────────────────
func _fresh() -> void:
	_remove_file(_path)


func _preview() -> ShipVisual:
	return _hangar.get_node_or_null(^"PreviewPanel/Preview") as ShipVisual


func _preview_fits_panel() -> bool:
	var panel := _hangar.get_node(^"PreviewPanel") as Control
	# M11/T5: ShipVisual рисует в draw_size_of (SIZES × 1.25), а не в SIZES — считаем по картинке.
	var size := ArtStyle.draw_size_of(_preview().asset_key) * Hangar.PREVIEW_SCALE
	return size.x <= panel.size.x and size.y <= panel.size.y


func _swatch_count() -> int:
	return (_hangar.get_node(^"LiveryRow") as Control).get_child_count()


func _swatch_label(index: int, path: String) -> String:
	var label := _hangar.get_node_or_null("LiveryRow/Swatch_%d/Inner/%s" % [index, path]) as Label
	return String(label.text) if label != null else "<нет метки>"


func _card_label(id: String, path: String) -> String:
	var label := _hangar.get_node_or_null("Cards/Card_%s/Inner/Lines/%s" % [id, path]) as Label
	return String(label.text) if label != null else "<нет метки>"


func _card_button(id: String) -> Button:
	return _hangar.get_node("Cards/Card_%s/Inner/ChooseButton" % id) as Button


func _label(path: NodePath) -> String:
	return String((_hangar.get_node(path) as Label).text)


func _touch_event(pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = Vector2(90.0, 48.0)
	return event


## Полное физическое касание свотча ливреи: нажатие, затем отпускание (как на Android).
func _tap_swatch(index: int) -> void:
	var panel := _hangar.get_node_or_null("LiveryRow/Swatch_%d" % index) as Control
	_hangar._on_swatch_gui_input(_touch_event(true), index, panel)
	_hangar._on_swatch_gui_input(_touch_event(false), index, panel)


## Полное физическое касание кнопки карточки самолёта: нажатие + отпускание.
func _tap_plane(id: String) -> void:
	var button := _card_button(id)
	_hangar._on_plane_button_gui_input(_touch_event(true), id, button)
	_hangar._on_plane_button_gui_input(_touch_event(false), id, button)


## Касание «Назад» вместе с mouse-дублем (Button.pressed десктопа): один closed за касание.
func _tap_back() -> void:
	_hangar._on_back_button_gui_input(_touch_event(true))
	_hangar._on_back_button_gui_input(_touch_event(false))
	_hangar._on_back_button_pressed()


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
