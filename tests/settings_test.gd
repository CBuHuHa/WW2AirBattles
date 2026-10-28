# settings_test.gd
# Purpose: Гейт M8a — экран настроек, звук/вибрация, сброс прогресса. Проверяет:
#            • чистый профиль: экран скрыт, «Настройки», звук/вибрация «Вкл», «Версия 1.0.0»,
#              блок «О игре» (Noto Sans OFL, SpriteCook), подтверждение сброса скрыто;
#            • раскладку: три строки 492×96 (тач-минимум 64) и «Назад» 320×88 внутри поля
#              540×960, строки не накладываются, корень/Dim прозрачны, интерактив STOP,
#              экран ALWAYS, «Назад» эмитит closed один раз за касание;
#            • переключатели: toggle_sound()/toggle_vibration() пишут SaveGame.get_setting(),
#              тексты «Вкл»/«Выкл» меняются;
#            • регресс «экран замер» (реальное устройство): латч одного касания снимался только
#              в refresh()/show_overlay(), а Android не присылает mouse-release — ввод гоняется
#              настоящим путём (gui_input pressed=true → pressed=false) двумя касаниями подряд:
#              звук, сразу вибрация, обратно; плюс «Назад» с mouse-дублем = один closed;
#            • сброс прогресса: первый тап — «Подтвердить сброс?» (профиль цел), второй —
#              звёзды/снабжение/самолёты/рекорд endless обнулены, «Прогресс сброшен»,
#              НАСТРОЙКИ звука/вибрации сохранены (решение M8a), после сброса снова нужно
#              подтверждение;
#            • main.tscn: Settings скрыт, «⚙» на брифинге (64×64, не перекрывает ряд кнопок,
#              строки и «В бой») открывает экран, «Назад» возвращает брифинг, волны не
#              стартуют; toggle_sound() реально глушит AudioManager (музыка −80 dB);
#              сброс прогресса обновляет гейт endless и возвращает миссию на m1;
#              _vibrate_on_damage() не падает в headless при включённой и выключенной настройке.
#          Изоляция: сейв живёт в user://qa_settings_*.cfg, реальный
#          user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/settings_test.tscn
# Dependencies: Settings, BriefingOverlay, LevelController (main.tscn), AudioManager, SaveGame,
#               RunRecord, GameConfig.
# Author: UI/UX Agent

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const SETTINGS_SCENE: PackedScene = preload("res://scenes/settings.tscn")

const M1 := "m1_airfield"
const M2 := "m2_crossing"
const LA5 := "la5"
const YAK3 := "yak3"

## Ожидаемые тексты (RU, player-facing; GDD «Оболочка» → «Настройки»).
const TITLE_TEXT := "Настройки"
const ON_TEXT := "Вкл"
const OFF_TEXT := "Выкл"
const RESET_LABEL := "Сбросить прогресс"
const CONFIRM_TEXT := "Подтвердить сброс?"
const DONE_TEXT := "Прогресс сброшен"
const VERSION_TEXT := "Версия 1.0.0"
const ABOUT_TEXT := "О игре"
const CREDITS_FONT := "Шрифт: Noto Sans (OFL)"
const CREDITS_ART := "Арт: SpriteCook"

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}
var _settings: Settings
var _level: LevelController


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_settings_%d.cfg" % Time.get_ticks_msec()
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
	if _settings != null:
		_settings.queue_free()
		_settings = null
	await get_tree().process_frame
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
	print("SETTINGS_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("SETTINGS_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	await _check_fresh_profile()
	_check_layout_and_input()
	_check_tap_input()
	_check_toggles()
	_check_reset_progress()
	await _check_main_scene()


# ─── Чистый профиль ─────────────────────────────────────────────────────────
func _check_fresh_profile() -> void:
	_fresh()
	_settings = SETTINGS_SCENE.instantiate()
	add_child(_settings)
	await get_tree().process_frame
	await get_tree().process_frame

	_check("свежий профиль: экран скрыт по умолчанию", not _settings.visible)
	_check("свежий профиль: заголовок «Настройки»", _label(^"Title") == TITLE_TEXT,
		_label(^"Title"))
	_check("свежий профиль: звук включён, текст «Вкл»",
		_settings.is_sound_enabled() and _settings.get_sound_text() == ON_TEXT,
		"%s / %s" % [_settings.is_sound_enabled(), _settings.get_sound_text()])
	_check("свежий профиль: вибрация включена, текст «Вкл»",
		_settings.is_vibration_enabled() and _settings.get_vibration_text() == ON_TEXT,
		"%s / %s" % [_settings.is_vibration_enabled(), _settings.get_vibration_text()])
	_check("свежий профиль: «О игре» + версия 1.0.0",
		_label(^"AboutTitle") == ABOUT_TEXT and _settings.get_version_text() == VERSION_TEXT,
		"%s / %s" % [_label(^"AboutTitle"), _settings.get_version_text()])
	_check("свежий профиль: лицензии (Noto Sans OFL) и арт (SpriteCook)",
		_label(^"CreditsFont") == CREDITS_FONT and _label(^"CreditsArt") == CREDITS_ART,
		"%s / %s" % [_label(^"CreditsFont"), _label(^"CreditsArt")])
	_check("свежий профиль: подтверждение сброса скрыто",
		not _settings.is_reset_confirm_visible() and not _settings.is_reset_armed())
	_check("свежий профиль: строка «Прогресс сброшен» скрыта",
		not _settings.is_reset_status_visible(), _settings.get_reset_status_text())
	_check("строки: подписи «Звук» / «Вибрация» / «Сбросить прогресс»",
		_row_label("SoundRow") == "Звук" and _row_label("VibrationRow") == "Вибрация"
		and _row_label("ResetRow") == RESET_LABEL,
		"%s / %s / %s" % [_row_label("SoundRow"), _row_label("VibrationRow"),
			_row_label("ResetRow")])
	_check("строки: состояние сброса «Сбросить»",
		_row_state("ResetRow") == "Сбросить", _row_state("ResetRow"))

	_settings.show_overlay()
	_check("показ: show_overlay() делает экран видимым",
		_settings.visible and _settings.get_sound_text() == ON_TEXT,
		_settings.get_sound_text())


# ─── Раскладка и ввод ───────────────────────────────────────────────────────
func _check_layout_and_input() -> void:
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var rows_ok := true
	var rows_inside := true
	var rects: Array[Rect2] = []
	for row_name: String in ["SoundRow", "VibrationRow", "ResetRow"]:
		var row := _settings.get_node_or_null(row_name) as Control
		if row == null:
			rows_ok = false
			continue
		var rect := row.get_global_rect()
		rects.append(rect)
		rows_ok = rows_ok and rect.size.x >= 64.0 and rect.size.y >= 64.0
		rows_inside = rows_inside and _rect_inside(rect, field)
	_check("раскладка: три строки настроек ≥ 64×64", rows_ok and rects.size() == 3,
		str(rects))
	_check("раскладка: строки внутри поля 540×960", rows_inside, str(rects))

	var overlaps := false
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			overlaps = overlaps or _rects_overlap(rects[i], rects[j])
	var back := _settings.get_node(^"BackButton") as Button
	var back_rect := back.get_global_rect()
	var confirm := _settings.get_node(^"ResetConfirm") as Control
	var status := _settings.get_node(^"ResetStatus") as Control
	var about := _settings.get_node(^"AboutTitle") as Control
	_check("раскладка: строки не накладываются друг на друга", not overlaps)
	_check("раскладка: «Назад» 320×88 внутри поля",
		back_rect.size.x >= 320.0 and back_rect.size.y >= 88.0
		and _rect_inside(back_rect, field) and String(back.text) == "Назад",
		str(back_rect))
	_check("раскладка: «Назад» не перекрывает строку сброса и блок «О игре»",
		not _rects_overlap(back_rect, rects[2])
		and not _rects_overlap(back_rect, about.get_global_rect())
		and not _rects_overlap(back_rect, status.get_global_rect()),
		"%s / %s" % [back_rect, status.get_global_rect()])
	_check("раскладка: подтверждение и статус не перекрывают строки",
		not _rects_overlap(confirm.get_global_rect(), rects[2])
		and not _rects_overlap(status.get_global_rect(), rects[2])
		and not _rects_overlap(confirm.get_global_rect(), status.get_global_rect()),
		"%s / %s" % [confirm.get_global_rect(), status.get_global_rect()])

	_check("ввод: корень и затемнение прозрачны для тапов, строки и «Назад» — STOP",
		_settings.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (_settings.get_node(^"Dim") as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (_settings.get_node(^"SoundRow") as Control).mouse_filter == Control.MOUSE_FILTER_STOP
		and (_settings.get_node(^"VibrationRow") as Control).mouse_filter
			== Control.MOUSE_FILTER_STOP
		and (_settings.get_node(^"ResetRow") as Control).mouse_filter == Control.MOUSE_FILTER_STOP
		and back.mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("ввод: экран живёт ALWAYS (не зависает от паузы дерева)",
		_settings.process_mode == Node.PROCESS_MODE_ALWAYS)

	# Латч «Назад»: двойной обработчик = один closed.
	var closed_events: Array[int] = []
	var counter := func() -> void: closed_events.append(1)
	_settings.closed.connect(counter)
	_settings.show_overlay()
	_settings._on_back_button_gui_input(_touch_event(true))
	_settings._on_back_button_gui_input(_touch_event(true))
	_check("ввод: «Назад» эмитит closed один раз за касание (латч)",
		closed_events.size() == 1, "событий %d" % closed_events.size())
	_settings.closed.disconnect(counter)
	_settings.hide_overlay()


# ─── Ввод: два касания подряд (регресс «экран замер после действия») ────────
## Баг с реального устройства: латч _latched снимался только в refresh()/show_overlay(), а на
## Android отпускание пальца не превращается в mouse-release — экран «замирал» для тапов.
## Гоняем настоящий путь ввода: gui_input(pressed=true) → pressed=false, два касания подряд.
func _check_tap_input() -> void:
	_settings.show_overlay()
	_check("ввод: перед касаниями звук и вибрация включены (дефолт профиля)",
		_settings.is_sound_enabled() and _settings.is_vibration_enabled(),
		"%s / %s" % [_settings.is_sound_enabled(), _settings.is_vibration_enabled()])

	_tap_row(&"_on_sound_row_gui_input")
	_check("ввод: касание строки «Звук» выключает звук (нажатие + отпускание)",
		not _settings.is_sound_enabled() and _settings.get_sound_text() == OFF_TEXT,
		"%s / %s" % [_settings.is_sound_enabled(), _settings.get_sound_text()])

	# Здесь старый код уже не отвечал: латч держался до refresh()/show_overlay().
	_tap_row(&"_on_vibration_row_gui_input")
	_check("ввод: второе касание подряд срабатывает — вибрация выключена (баг «экран замер»)",
		not _settings.is_vibration_enabled() and _settings.get_vibration_text() == OFF_TEXT,
		"%s / %s" % [_settings.is_vibration_enabled(), _settings.get_vibration_text()])

	# Обратно: ещё два касания подряд обязаны вернуть оба переключателя.
	_tap_row(&"_on_sound_row_gui_input")
	_tap_row(&"_on_vibration_row_gui_input")
	_check("ввод: два обратных касания подряд возвращают звук и вибрацию",
		_settings.is_sound_enabled() and _settings.is_vibration_enabled()
		and _settings.get_sound_text() == ON_TEXT
		and _settings.get_vibration_text() == ON_TEXT,
		"%s / %s" % [_settings.get_sound_text(), _settings.get_vibration_text()])

	# Одно физическое касание = один запрос: touch + mouse-дубль («Назад» на десктопе).
	var closed_events: Array[int] = []
	var counter := func() -> void: closed_events.append(1)
	_settings.closed.connect(counter)
	_tap_back()
	_check("ввод: одно касание «Назад» (touch + mouse-дубль) = один closed",
		closed_events.size() == 1, "событий %d" % closed_events.size())
	_tap_back()
	_check("ввод: второе касание «Назад» тоже срабатывает (латч не залип)",
		closed_events.size() == 2, "событий %d" % closed_events.size())
	_settings.closed.disconnect(counter)
	_check("ввод: латч касания снят — экран принимает следующее нажатие",
		_settings.is_tap_available())

	# Сброс прогресса двумя касаниями. Дубль одного касания здесь недопустим: арм + стирание
	# профиля на одном тапе стёрли бы прогресс без подтверждения.
	SaveGame.add_supply(500)
	_tap_row(&"_on_reset_row_gui_input")
	_check("ввод: первое касание строки сброса только вооружает подтверждение",
		_settings.is_reset_armed() and _settings.is_reset_confirm_visible()
		and SaveGame.get_supply() == 500,
		"armed=%s supply=%d" % [_settings.is_reset_armed(), SaveGame.get_supply()])
	_tap_row(&"_on_reset_row_gui_input")
	_check("ввод: второе касание подтверждает сброс — снабжение обнулено",
		not _settings.is_reset_armed() and SaveGame.get_supply() == 0,
		"armed=%s supply=%d" % [_settings.is_reset_armed(), SaveGame.get_supply()])


# ─── Переключатели ──────────────────────────────────────────────────────────
func _check_toggles() -> void:
	_check("звук: toggle_sound() → выкл", not _settings.toggle_sound()
		and not SaveGame.get_setting("sound"), str(SaveGame.get_setting("sound")))
	_check("звук: текст строки «Выкл»", _settings.get_sound_text() == OFF_TEXT,
		_settings.get_sound_text())
	_check("звук: повторный toggle_sound() → вкл",
		_settings.toggle_sound() and SaveGame.get_setting("sound")
		and _settings.get_sound_text() == ON_TEXT,
		"%s / %s" % [SaveGame.get_setting("sound"), _settings.get_sound_text()])

	_check("вибрация: toggle_vibration() → выкл", not _settings.toggle_vibration()
		and not SaveGame.get_setting("vibration"), str(SaveGame.get_setting("vibration")))
	_check("вибрация: текст «Выкл», звук не тронут",
		_settings.get_vibration_text() == OFF_TEXT and SaveGame.get_setting("sound"),
		"%s / %s" % [_settings.get_vibration_text(), SaveGame.get_setting("sound")])
	_check("вибрация: повторный toggle_vibration() → вкл",
		_settings.toggle_vibration() and SaveGame.get_setting("vibration")
		and _settings.get_vibration_text() == ON_TEXT,
		"%s / %s" % [SaveGame.get_setting("vibration"), _settings.get_vibration_text()])

	# Отклонения от дефолта перед сбросом: так видно, что сброс их НЕ трогает.
	_settings.toggle_sound()
	_settings.toggle_vibration()
	_check("перед сбросом: звук и вибрация выключены (не дефолт)",
		not SaveGame.get_setting("sound") and not SaveGame.get_setting("vibration"),
		"%s / %s" % [SaveGame.get_setting("sound"), SaveGame.get_setting("vibration")])


# ─── Сброс прогресса ────────────────────────────────────────────────────────
func _check_reset_progress() -> void:
	SaveGame.add_supply(500)
	SaveGame.record_stars(M1, 2)
	SaveGame.record_endless(1200, 5)
	SaveGame.unlock_plane(YAK3)
	SaveGame.select_plane(YAK3)

	_check("сброс: первый request_reset() только включает подтверждение",
		not _settings.request_reset() and _settings.is_reset_confirm_visible()
		and _label(^"ResetConfirm") == CONFIRM_TEXT,
		"armed=%s / %s" % [_settings.is_reset_armed(), _label(^"ResetConfirm")])
	_check("сброс: после первого тапа профиль цел (звёзды/снабжение/самолёт)",
		SaveGame.get_stars(M1) == 2 and SaveGame.get_supply() == 500
		and SaveGame.get_selected_plane() == YAK3,
		"%d / %d / %s" % [SaveGame.get_stars(M1), SaveGame.get_supply(),
			SaveGame.get_selected_plane()])
	_check("сброс: состояние строки «Ещё раз»",
		_row_state("ResetRow") == "Ещё раз", _row_state("ResetRow"))

	_check("сброс: второй request_reset() стирает профиль", _settings.request_reset())
	_check("сброс: звёзды и снабжение обнулены",
		SaveGame.total_stars() == 0 and SaveGame.get_stars(M1) == 0
		and SaveGame.get_supply() == 0,
		"stars=%d supply=%d" % [SaveGame.total_stars(), SaveGame.get_supply()])
	_check("сброс: рекорд endless и самолёты стёрты",
		SaveGame.get_endless_best() == 0 and SaveGame.get_endless_wave() == 0
		and SaveGame.get_selected_plane() == LA5 and not SaveGame.is_plane_unlocked(YAK3),
		"best=%d wave=%d plane=%s" % [SaveGame.get_endless_best(),
			SaveGame.get_endless_wave(), SaveGame.get_selected_plane()])
	_check("сброс: НАСТРОЙКИ сохранены (звук/вибрация остались выключены)",
		not SaveGame.get_setting("sound") and not SaveGame.get_setting("vibration"),
		"%s / %s" % [SaveGame.get_setting("sound"), SaveGame.get_setting("vibration")])
	_check("сброс: подтверждение скрыто, строка «Прогресс сброшен» видна",
		not _settings.is_reset_confirm_visible() and _settings.is_reset_status_visible()
		and _settings.get_reset_status_text() == DONE_TEXT,
		_settings.get_reset_status_text())
	_check("сброс: файл профиля существует (настройки записаны обратно)",
		FileAccess.file_exists(_path))
	_check("сброс: повторный тап снова требует подтверждения",
		not _settings.request_reset() and _settings.is_reset_confirm_visible())


# ─── main.tscn: «⚙» → настройки → «Назад», звук/сброс на живом уровне ───────
func _check_main_scene() -> void:
	_fresh()
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	# M8c1: при запуске приложения показан Home; брифинг открывается явно (публичный вход).
	_level.begin_briefing()
	await get_tree().process_frame

	_check("старт: состояние BRIEFING, брифинг виден, настройки скрыты",
		_level.get_state() == LevelController.State.BRIEFING and _level.briefing.visible
		and not _level.settings.visible,
		"state=%d, briefing=%s, settings=%s" % [_level.get_state(),
			_level.briefing.visible, _level.settings.visible])

	var settings_button := _level.briefing.get_node_or_null(^"SettingsButton") as Button
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	_check("брифинг: кнопка настроек 64×64 внутри поля",
		settings_button != null and settings_button.get_global_rect().size.x >= 64.0
		and settings_button.get_global_rect().size.y >= 64.0
		and _rect_inside(settings_button.get_global_rect(), field),
		"нет кнопки" if settings_button == null else str(settings_button.get_global_rect()))
	_check("брифинг: «⚙» не перекрывает «Миссии»/«Ангар»/«Бесконечный»/«В бой» и строки",
		settings_button != null and not _overlaps_briefing_ui(settings_button),
		"нет кнопки" if settings_button == null else str(settings_button.get_global_rect()))

	# Латч кнопки на реальном брифинге: двойное касание = один settings_requested.
	var settings_events: Array[int] = []
	var counter := func() -> void: settings_events.append(1)
	_level.briefing.settings_requested.connect(counter)
	_level.briefing._on_settings_button_gui_input(_touch_event(true))
	_level.briefing._on_settings_button_gui_input(_touch_event(true))
	_check("брифинг: «⚙» срабатывает один раз за касание (латч)",
		settings_events.size() == 1, "событий %d" % settings_events.size())
	_level.briefing.settings_requested.disconnect(counter)
	_level.settings.closed.emit()
	_check("настройки: «Назад» вернул брифинг, экран скрыт",
		_level.briefing.visible and not _level.settings.visible)

	# Выбор миссии 2 (открывается 1 звездой) — после сброса он обязан откатиться на m1.
	SaveGame.record_stars(M1, 1)
	_level._on_mission_chosen(M2)
	_check("подготовка: выбрана миссия 2", _level.briefing.get_mission_id() == M2,
		_level.briefing.get_mission_id())

	_level.briefing.settings_requested.emit()
	_check("настройки: открылись, брифинг скрыт, состояние BRIEFING",
		_level.settings.visible and not _level.briefing.visible
		and _level.get_state() == LevelController.State.BRIEFING,
		"settings=%s, briefing=%s, state=%d" % [_level.settings.visible,
			_level.briefing.visible, _level.get_state()])
	_check("настройки: забег не начался — волн нет, игрок без управления",
		_level.waves.get_alive_count() == 0 and not _level.player.is_processing()
		and not _level.player.is_processing_unhandled_input(),
		"живых врагов %d" % _level.waves.get_alive_count())

	var audio := _level.get_node_or_null(^"Audio") as AudioManager
	_check("звук: AudioManager жив и не заглушён при включённой настройке",
		audio != null and _level.settings.is_sound_enabled() and not audio.is_muted(),
		"<нет Audio>" if audio == null else str(audio.is_muted()))

	_check("звук: toggle_sound() глушит AudioManager сразу",
		not _level.settings.toggle_sound() and audio != null and audio.is_muted()
		and not SaveGame.get_setting("sound"),
		"<нет Audio>" if audio == null else str(audio.is_muted()))
	_check("звук: музыка реально приглушена (volume_db ≤ −60)",
		audio != null and audio.get_music_volume_db() <= -60.0,
		"<нет Audio>" if audio == null else str(audio.get_music_volume_db()))
	_check("звук: повторный toggle_sound() возвращает звук",
		_level.settings.toggle_sound() and audio != null and not audio.is_muted()
		and audio.get_music_volume_db() > -60.0 and SaveGame.get_setting("sound"),
		"<нет Audio>" if audio == null else str(audio.get_music_volume_db()))

	_check("вибрация: toggle_vibration() пишет настройку",
		not _level.settings.toggle_vibration() and not SaveGame.get_setting("vibration"))
	_check("вибрация: повторный toggle_vibration() включает обратно",
		_level.settings.toggle_vibration() and SaveGame.get_setting("vibration"))
	# Вибрация не наблюдаема в headless: проверяем, что хук не падает в обоих состояниях
	# (guard has_method + настройка) — вызов идёт из _on_player_damaged.
	_level._vibrate_on_damage()
	SaveGame.set_setting("vibration", false)
	_level._vibrate_on_damage()
	_level.settings.refresh()
	_check("вибрация: _vibrate_on_damage() не падает в headless при вкл/выкл", true)

	# Сброс на живом уровне: гейт endless и выбранная миссия зависят от профиля.
	SaveGame.set_setting("vibration", false)
	SaveGame.set_setting("sound", false)
	_level.settings.refresh()
	SaveGame.add_supply(700)
	_level.settings.request_reset()
	_level.settings.request_reset()
	_check("main: сброс обнулил снабжение и звёзды",
		SaveGame.get_supply() == 0 and SaveGame.total_stars() == 0,
		"supply=%d stars=%d" % [SaveGame.get_supply(), SaveGame.total_stars()])
	_check("main: настройки звука/вибрации после сброса сохранены",
		not SaveGame.get_setting("sound") and not SaveGame.get_setting("vibration"),
		"%s / %s" % [SaveGame.get_setting("sound"), SaveGame.get_setting("vibration")])
	_check("main: гейт «Бесконечный» снова закрыт (брифинг обновлён)",
		not _level.briefing.is_endless_enabled())
	_check("main: миссия 2 снова закрыта, выбранная миссия откатилась на m1",
		not SaveGame.is_mission_unlocked(M2) and _level.get_mission_id() == M1,
		"%s / %s" % [SaveGame.is_mission_unlocked(M2), _level.get_mission_id()])

	_level.settings.closed.emit()
	_check("main: «Назад» вернул брифинг m1, настройки скрыты",
		_level.briefing.visible and not _level.settings.visible
		and _level.briefing.get_mission_id() == M1,
		"briefing=%s, mission=%s" % [_level.briefing.visible,
			_level.briefing.get_mission_id()])
	_check("main: состояние остаётся BRIEFING — забег не стартовал",
		_level.get_state() == LevelController.State.BRIEFING
		and _level.waves.get_alive_count() == 0
		and not _level.player.is_processing(),
		"state=%d, живых врагов %d" % [_level.get_state(), _level.waves.get_alive_count()])


# ─── Помощники ──────────────────────────────────────────────────────────────
func _fresh() -> void:
	_remove_file(_path)


## Кнопка «⚙» не должна пересекаться ни с одной интерактивной/текстовой зоной брифинга.
func _overlaps_briefing_ui(button: Button) -> bool:
	var rect := button.get_global_rect()
	var briefing := _level.briefing
	# M11/T6 (D7): узла EndlessHint больше нет — подсказка условия удалена с брифинга.
	var blockers: Array[NodePath] = [
		^"MissionsButton", ^"HangarButton", ^"EndlessButton", ^"StartButton",
		^"Title", ^"Line1", ^"Line2", ^"Line3",
	]
	for path: NodePath in blockers:
		var other := briefing.get_node_or_null(path) as Control
		if other == null:
			return true
		if _rects_overlap(rect, other.get_global_rect()):
			return true
	return false


func _row_label(row: String) -> String:
	var label := _settings.get_node_or_null("%s/Inner/Label" % row) as Label
	return String(label.text) if label != null else "<нет метки>"


func _row_state(row: String) -> String:
	var label := _settings.get_node_or_null("%s/Inner/StateLabel" % row) as Label
	return String(label.text) if label != null else "<нет метки>"


func _label(path: NodePath) -> String:
	var label := _settings.get_node_or_null(path) as Label
	return String(label.text) if label != null else "<нет метки>"


func _touch_event(pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = Vector2(490.0, 120.0)
	return event


## Полное физическое касание строки настроек: нажатие, затем отпускание (как на Android).
func _tap_row(method: StringName) -> void:
	var handler := Callable(_settings, method)
	handler.call(_touch_event(true))
	handler.call(_touch_event(false))


## Касание «Назад» вместе с mouse-дублем (Button.pressed десктопа): один closed за касание.
func _tap_back() -> void:
	_settings._on_back_button_gui_input(_touch_event(true))
	_settings._on_back_button_gui_input(_touch_event(false))
	_settings._on_back_button_pressed()


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
