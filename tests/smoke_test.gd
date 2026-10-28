# smoke_test.gd
# Purpose: Автоматический дымовой тест M2 без устройства: настройки проекта, относительный драг,
#          автострельба, таблица врагов, урон/хитбоксы, бомба, группа босса, подборы, пауза,
#          смерть/рестарт, полный прогон уровня (6 волн миссии 1 → босс с 2 фазами → победа → рестарт).
#          Гейт M3-A: тема/шрифт Noto Sans (OFL, кириллица, TitleLabel Bold), HUD-полировка
#          (иконки ui_hp, полоса босса, бейдж ×N), раскладка HUD на поле 540×960.
#          Гейт M3-B: брифинг при запуске (BRIEFING до «В бой», забега ещё нет), подсказки
#          первого забега (тексты, IGNORE-ввод, замирание на паузе, гашение при исходе,
#          отсутствие повтора на рестарте, повторный показ в новом инстансе main).
#          Гейт M3-C: локальный рекорд (RunRecord: файл, валидация, границы; WinOverlay
#          RecordLine; запись только на победе и только при новом рекорде) + minor-фиксы
#          M3-B (reset() возвращает ввод, ghost-плашка после fade-out, body брифинга 22 px).
#          Рекорд изолирован: прогон подменяет путь на уникальный user://qa_m3c_*.cfg,
#          реальный user://ww2_air_battles.cfg игрока не читается и не пишется.
#          Гейт M3-D: аудио-слой (музыка + 8 SFX): формат/размер/README/импорт WAV, луп
#          LOOP_FORWARD на копии потока, узел Level/Audio (PAUSABLE, 8 голосов, громкости),
#          контракт сигналов LevelController → SFX (+1 к счётчику), троттлинг UI-клика,
#          автострельба → player_shot, замирание музыки на паузе без «догоняющего» скачка.
#          Гейт M3-E: фон-земля вида сверху (3 слоя параллакса, темы bg_airfield /
#          bg_crossing / bg_city по миссии, 9 облаков): декор ПОД World, без физики
#          и ввода, пауза замораживает параллакс, wrap плитки, alpha облаков ≤ 0.18,
#          земля светлее врагов и контрастна игроку; стресс-серия пула SFX идёт на
#          длинном клипе (bomb) — без флейка «0 из 8».
#          Касания подаются как InputEventScreenTouch/Drag — тот же путь, что и на Android.
# Запуск: godot --headless --path . res://tests/smoke_test.tscn
# Author: Mechanics Developer Agent (гейт M3-A — QA Agent)
#
# ВАЖНО (особенность теста, не игры): Input.parse_input_event ожидает координаты окна,
# а не канвы. В headless окно крошечное и get_final_transform() масштабирует ~15×,
# поэтому координаты канвы переводятся в оконные через _to_window().
# Input.emulate_mouse_from_touch в проекте выключен: игра обрабатывает только touch-события.

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")

# ─── M3-A (UI-фундамент): тема, шрифт, HUD ───────────────────────────────────
const THEME_PATH := "res://assets/ui_theme.tres"
const FONT_REGULAR_PATH := "res://assets/fonts/NotoSans-Regular.ttf"
const FONT_BOLD_PATH := "res://assets/fonts/NotoSans-Bold.ttf"
const OFL_PATH := "res://assets/fonts/OFL.txt"
const UI_FONT_SIZE := 24
const UI_TITLE_FONT_SIZE := 48
## M3-C: путь рекорда по умолчанию и уникальный путь прогона (изоляция user://).
const RECORD_DEFAULT_PATH := "user://ww2_air_battles.cfg"
## Рекорд хранится РОВНО одним ключом (GDD: никакой мета-прогрессии/статистики).
const RECORD_SECTION := "record"
const RECORD_KEY := "best_score"
## M5.3a: рекорды миссий сейва v2 лежат в [records] best_m1..m3 (см. _read_record_best).
const SAVE_RECORDS_SECTION := "records"
## M3-C minor: body-строки брифинга — 22 px, боковые поля экрана 24 px.
const BRIEFING_BODY_FONT_SIZE := 22
const BRIEFING_SIDE_MARGIN := 24.0
## Вся русская копия игры + знаки, которые рисуются тем же шрифтом («—», «×», «:»).
const UI_COPY_SAMPLE := "Аэродром потерян спасён Счёт Время Пауза Тап чтобы продолжить рестарт — ×:/0123456789 Ёё"
## Заголовки оверлеев: TitleLabel (Bold) рисует кириллицу без фолбэка на системный шрифт.
const UI_TITLE_SAMPLE := "Аэродром потерян спасён Пауза"

# ─── Гейт M3-D (аудио): музыка + 8 SFX, GDD «Audio» ─────────────────────────
const AUDIO_DIR := "res://assets/audio/"
const AUDIO_README := AUDIO_DIR + "README.md"
const AUDIO_GENERATOR := "res://tools/generate_audio.py"
## Полный набор файлов: 1 музыка + 8 SFX (ключи AudioManager.SFX_KEYS).
## Музыка 60–90 с — иначе это не луп уровня; SFX короткие (клип < 1.5 с).
const AUDIO_FILES: Array[String] = [
	"music_loop.wav",
	"player_shot.wav",
	"enemy_hit.wav",
	"player_hit.wav",
	"enemy_explosion.wav",
	"bomb.wav",
	"pickup.wav",
	"boss_alarm.wav",
	"ui_click.wav",
]
const AUDIO_BUDGET_BYTES := 4 * 1024 * 1024
## Плейсхолдеры нормализованы в mono / 16-bit PCM / 22050 Hz (assets/audio/README.md).
const AUDIO_SAMPLE_RATE := 22050
const AUDIO_MUSIC_MIN_LENGTH := 60.0
const AUDIO_MUSIC_MAX_LENGTH := 90.0
const AUDIO_SFX_MAX_LENGTH := 1.5
## 64.000 с × 22050 Гц = 1 411 200 сэмплов: loop_end обязан покрыть файл целиком.
const AUDIO_MUSIC_LOOP_SAMPLES := 1411200
## Пауза звука: аудиопоток микширует буфер порциями, поэтому после NOTIFICATION_PAUSED
## даём паузе «осесть» и меряем позицию внутри окна HOLD. «Догоняющий» баг перемотал бы
## поток минимум на HOLD, квант микса — десятки мс: допуски их разделяют.
const PAUSE_AUDIO_SETTLE := 0.06
const PAUSE_AUDIO_HOLD := 0.3
const PAUSE_AUDIO_DRIFT := 0.02
const PAUSE_AUDIO_GROWTH_WINDOW := 0.15
const PAUSE_AUDIO_CATCHUP_JUMP := 0.25

# ─── Гейт M3-E (фон): читаемость земли вида сверху ──────────────────────────
## Земля занимает всю боевую зону, поэтому её яркость проверяется числами, а не
## глазами: она должна быть светлее серых врагов (ArtStyle.ENEMY) и контрастна
## оливковому Ла-5 (ArtStyle.PLAYER), иначе силуэты и трассеры теряются.
const TERRAIN_MIN_LUMINANCE := 0.35
const TERRAIN_MAX_LUMINANCE := 0.80
const TERRAIN_ENEMY_CONTRAST := 0.10
const TERRAIN_PLAYER_CONTRAST := 0.12
## Минимальное RGB-расстояние между землёй разных тем (аэродром ≠ город).
const TERRAIN_THEME_DISTANCE := 0.02


var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
var _player_shots_spawned: int = 0
var _level: LevelController
var _boss_phase_events: Array[int] = []
## M3-C: уникальный файл рекорда прогона + слепок реального файла игрока до старта.
var _record_path: String = ""
var _real_record_snapshot: Dictionary = {}


func _ready() -> void:
	Input.emulate_mouse_from_touch = false
	# Тест живёт и при get_tree().paused (проверка паузы/победы).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	# M3-C: изоляция ДО первого инстанса main. Иначе победа в брифинге/полном прогоне
	# пишет рекорд в реальный user://ww2_air_battles.cfg игрока (QA-загрязнение M3-C).
	_real_record_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_record_path = "user://qa_m3c_%d.cfg" % Time.get_ticks_msec()
	RunRecord.set_save_path(_record_path)
	_remove_user_file(_record_path)
	# M8b: локальная аналитика не должна писать реальный user://analytics.log. Здесь — до
	# первого инстанса main (брифинг-проба ниже идёт РАНЬШЕ _boot_level и тоже логирует
	# app_start); вторая строка в _boot_level страхует прямой запуск проверки уровня.
	Analytics.set_enabled(false)
	await get_tree().process_frame
	await _run()
	# M3-C: уборка изоляции + доказательство, что реальный рекорд игрока не тронут.
	var temp_file_created := FileAccess.file_exists(_record_path)
	_remove_user_file(_record_path)
	RunRecord.reset_save_path()
	_check("рекорд: прогон писал только во временный файл",
		temp_file_created and RunRecord.get_save_path() == RECORD_DEFAULT_PATH,
		"создан=%s, путь=%s" % [temp_file_created, RunRecord.get_save_path()])
	_check("рекорд: временный qa-файл удалён после прогона",
		not FileAccess.file_exists(_record_path), _record_path)
	var real_after := _file_snapshot(RunRecord.DEFAULT_PATH)
	_check("рекорд: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_record_snapshot, real_after),
		"%s → %s" % [_snapshot_brief(_real_record_snapshot), _snapshot_brief(real_after)])
	# SMOKE_TIME нужен дев-циклу: раньше длительность прогона в логе не была видна.
	print("SMOKE_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("SMOKE_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


# ─── Сценарий ────────────────────────────────────────────────────────────────
func _run() -> void:
	# Гейт M3-C: рекорд проверяется ПЕРВЫМ — до instantiate main, на пустом временном файле.
	_check_run_record_api()
	_check_project_settings()
	# Гейт M3-A (UI-фундамент): тема/шрифт и ассеты проверяются до сцены — им нужен только проект.
	_check_ui_theme()
	_check_ui_assets()
	# Гейт M3-D: аудио-ассеты до сцены — нужен только проект (плюс автономный AudioManager).
	await _check_audio_assets()
	await _check_briefing_screen()
	await _boot_level()
	# Гейт M3-D: AudioManager живёт в сцене — узлы, пул, громкости, луп, музыка на брифинге.
	await _check_audio_manager()
	# Гейт M3-C: строка рекорда на экране победы (текст/раскладка) — до полного прогона.
	_check_win_overlay_record()
	# Гейт M3-A: HUD-полировка и раскладка — сразу после старта, до тач-тестов.
	_check_hud_polish()
	_check_hud_layout()
	_check_ui_fonts_applied()
	# M11/T2–T5: шорткатов нет, кнопки трёх экранов живы, звёзды без дубля, модельки +25 %.
	_check_overlay_shortcuts()
	# Гейт M3-B: подсказки первого забега — пока таймлайн жив (после старта).
	await _check_hints_overlay()
	await _check_relative_drag()
	await _check_autofire()
	# Гейт M3-D: контракт сигналов → SFX и замирание звука на паузе.
	await _check_audio_triggers()
	await _check_audio_pause()
	# Гейт M3-E: фон (небо/облака/аэродром/дым) — слой, пауза, параллакс, читаемость.
	await _check_background()
	await _check_bullet_tunneling_budget()
	await _check_enemy_table()
	await _check_enemy_and_bullet_damage()
	await _check_body_collision_no_damage()
	await _check_bomb()
	await _check_boss_group_and_bomb()
	await _check_pickups()
	await _check_repair_identity()
	await _check_patrol_corridor()
	await _check_boss_bomb_band()
	await _check_pause()
	await _check_damage_death_restart()
	await _check_finish_window_tap_ignored()
	await _check_enemies_stop_firing_after_death()
	await _check_autofire_kills_bf109()
	await _check_wave_table()
	await _check_boss_phases()
	await _check_full_run()


# ─── Гейт M3-C: локальный рекорд (RunRecord, файл user://) ───────────────────
## API проверяется на УНИКАЛЬНОМ временном файле (см. _ready): реальный рекорд игрока
## не читается и не пишется. Каждый шаг фиксирует и возврат submit(), и состояние диска.
func _check_run_record_api() -> void:
	_check("рекорд: путь сохранения изолирован на уникальный user://",
		RunRecord.get_save_path() == _record_path and _record_path.begins_with("user://qa_m3c_"),
		RunRecord.get_save_path())
	_check("рекорд: формат [record] best_score в user://ww2_air_battles.cfg",
		RunRecord.DEFAULT_PATH == RECORD_DEFAULT_PATH
		and RunRecord.SECTION == RECORD_SECTION and RunRecord.KEY_BEST == RECORD_KEY,
		"%s / %s / %s" % [RunRecord.DEFAULT_PATH, RunRecord.SECTION, RunRecord.KEY_BEST])

	# ── Нет файла → рекорда нет ─────────────────────────────────────────────
	_remove_user_file(_record_path)
	_check("рекорд: нет файла → 0", RunRecord.get_best_score() == 0,
		str(RunRecord.get_best_score()))

	# ── Новый рекорд пишется, меньший/равный — нет ──────────────────────────
	var first: Dictionary = RunRecord.submit(100)
	_check("рекорд: submit(100) → best 100, новый",
		int(first.get("best", -1)) == 100 and bool(first.get("is_new", false)), str(first))
	_check("рекорд: submit(100) создал файл", FileAccess.file_exists(_record_path),
		_record_path)
	var snapshot_100 := _file_snapshot(_record_path)
	var lower: Dictionary = RunRecord.submit(50)
	_check("рекорд: submit(50) → 100, не новый",
		int(lower.get("best", -1)) == 100 and not bool(lower.get("is_new", true)), str(lower))
	_check("рекорд: не-новый submit не перезаписывает файл",
		_snapshots_equal(snapshot_100, _file_snapshot(_record_path)),
		_snapshot_brief(snapshot_100))
	var equal: Dictionary = RunRecord.submit(100)
	_check("рекорд: равный счёт новым рекордом не считается",
		int(equal.get("best", -1)) == 100 and not bool(equal.get("is_new", true)), str(equal))
	var higher: Dictionary = RunRecord.submit(150)
	_check("рекорд: submit(150) → 150, новый",
		int(higher.get("best", -1)) == 150 and bool(higher.get("is_new", false)), str(higher))

	# ── Что реально лежит на диске: ровно один ключ, читается новым ConfigFile ──
	var config := ConfigFile.new()
	var load_result := config.load(_record_path)
	_check("рекорд: новый ConfigFile видит best_score = 150",
		load_result == OK
		and int(config.get_value(RECORD_SECTION, RECORD_KEY, -1)) == 150,
		"load=%d, значение %s" % [
			load_result, str(config.get_value(RECORD_SECTION, RECORD_KEY, -1))])
	_check("рекорд: в файле ровно один раздел и один ключ",
		config.get_sections() == PackedStringArray([RECORD_SECTION])
		and config.get_section_keys(RECORD_SECTION) == PackedStringArray([RECORD_KEY]),
		"разделы %s, ключи %s" % [
			str(config.get_sections()), str(config.get_section_keys(RECORD_SECTION))])
	_check("рекорд: get_best_score == 150", RunRecord.get_best_score() == 150,
		str(RunRecord.get_best_score()))

	# ── Отрицательный счёт: клампится 0 и не портит рекорд ──────────────────
	var negative: Dictionary = RunRecord.submit(-5)
	_check("рекорд: submit(-5) → 150, не новый, файл цел",
		int(negative.get("best", -1)) == 150 and not bool(negative.get("is_new", true))
		and RunRecord.get_best_score() == 150, str(negative))

	# ── Битый файл: 0 без ERROR-спама (структура отсекается до ConfigFile.load) ──
	_write_user_text(_record_path, "not an ini at all\n<<<мусор>>>\n")
	_check("рекорд: битый файл → 0 (без падения и ERROR в логе)",
		RunRecord.get_best_score() == 0, str(RunRecord.get_best_score()))
	var recovered: Dictionary = RunRecord.submit(10)
	_check("рекорд: submit(10) поверх битого файла → 10, новый",
		int(recovered.get("best", -1)) == 10 and bool(recovered.get("is_new", false))
		and RunRecord.get_best_score() == 10, str(recovered))

	# ── Путь: пустая строка = DEFAULT, reset_save_path = DEFAULT ────────────
	RunRecord.set_save_path("")
	_check("рекорд: пустой путь трактуется как DEFAULT_PATH",
		RunRecord.get_save_path() == RECORD_DEFAULT_PATH, RunRecord.get_save_path())
	# Возвращаем временный путь ДО любых чтений: реальный файл игрока не читаем вовсе.
	RunRecord.set_save_path(_record_path)
	RunRecord.reset_save_path()
	_check("рекорд: reset_save_path возвращает DEFAULT_PATH",
		RunRecord.get_save_path() == RECORD_DEFAULT_PATH, RunRecord.get_save_path())
	RunRecord.set_save_path(_record_path)
	# Следующий блок (брифинг) проверяет, что в BRIEFING/PAUSED/DEAD файл НЕ создаётся.
	_remove_user_file(_record_path)


# ─── Гейт M3-C: строка рекорда на экране победы ──────────────────────────────
## Текст, сохранение текста при hide и геометрия RecordLine (между TimeLine и StarsLine).
## M11/T3 (решение D4): узла Hint на экране победы больше нет — нижнюю границу строки
## задаёт StarsLine, ниже идут SupplyLine и три кнопки исхода.
func _check_win_overlay_record() -> void:
	var overlay := _level.win_overlay
	var record_line := overlay.get_node(^"RecordLine") as Label
	var time_line := overlay.get_node(^"TimeLine") as Label
	var stars_line := overlay.get_node(^"StarsLine") as Label
	var supply_line := overlay.get_node(^"SupplyLine") as Label
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)

	# ── Тексты «Новый рекорд» / «Рекорд» ────────────────────────────────────
	overlay.show_result(1234, 65.0, 1234, true)
	_check("оверлей победы: RecordLine «Новый рекорд: 1234»",
		String(record_line.text) == "Новый рекорд: 1234", String(record_line.text))
	_check("оверлей победы: best/is_new сохранены для QA",
		overlay.best_score == 1234 and overlay.is_new_record,
		"best=%d, new=%s" % [overlay.best_score, overlay.is_new_record])
	overlay.show_result(900, 60.0, 1234, false)
	_check("оверлей победы: RecordLine «Рекорд: 1234» при счёте 900",
		String(record_line.text) == "Рекорд: 1234", String(record_line.text))
	_check("оверлей победы: меньший счёт не затирает показанный рекорд",
		overlay.best_score == 1234 and not overlay.is_new_record,
		"best=%d, new=%s" % [overlay.best_score, overlay.is_new_record])

	# ── Раскладка: RecordLine — четвёртая строка, внутри поля, без наложений ──
	overlay.show_result(1234, 65.0, 1234, true)
	var rec_rect := record_line.get_global_rect()
	var time_rect := time_line.get_global_rect()
	var stars_rect := stars_line.get_global_rect()
	var supply_rect := supply_line.get_global_rect()
	_check("оверлей победы: RecordLine между TimeLine и StarsLine",
		rec_rect.position.y >= time_rect.end.y - 0.5
		and stars_rect.position.y >= rec_rect.end.y - 0.5,
		"time=%s, record=%s, stars=%s" % [time_rect, rec_rect, stars_rect])
	_check("оверлей победы: RecordLine внутри поля 540×960",
		_rect_inside(rec_rect, field), str(rec_rect))
	_check("оверлей победы: RecordLine не перекрывает соседние строки",
		not _rects_overlap(rec_rect, time_rect) and not _rects_overlap(rec_rect, stars_rect)
		and not _rects_overlap(rec_rect, supply_rect)
		and not _rects_overlap(rec_rect, (overlay.get_node(^"ScoreLine") as Label).get_global_rect()),
		"record=%s" % str(rec_rect))
	_check("оверлей победы: RecordLine прозрачен для тапов (IGNORE)",
		record_line.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		str(record_line.mouse_filter))
	_check("оверлей победы: RecordLine — Regular 26 px",
		record_line.get_theme_font_size(&"font_size") == 26
		and _label_font_covers(record_line, "NotoSans-Regular.ttf"),
		_label_font_details(record_line))
	var record_width := _label_text_width(record_line)
	_check("оверлей победы: «Новый рекорд: 1234» при 26 px влезает в 540",
		record_width <= field.size.x, "%.1f px" % record_width)
	# M11/T4 (решение D2): звёзды рисует ТОЛЬКО ряд пиксельных иконок — в тексте строки
	# остаётся подпись «Звёзды:», глифов ★/☆ нет (дубль звёзд — баг владельца).
	overlay.show_result(1234, 65.0, 1234, true, 2, 150)
	var icons := overlay.star_icons
	var icons_rect := icons.get_global_rect() if icons != null and icons.visible else Rect2()
	var group_left := minf(stars_line.get_global_rect().position.x, icons_rect.position.x)
	var group_right := maxf(stars_line.get_global_rect().end.x, icons_rect.end.x)
	_check("оверлей победы: 3 пиксельные звезды, 2 заполнены при stars=2",
		overlay.get_star_icon_count() == 3 and overlay.get_star_filled_count() == 2,
		"%d / %d" % [overlay.get_star_icon_count(), overlay.get_star_filled_count()])
	_check("оверлей победы: в StarsLine нет глифов ★/☆ — только подпись «Звёзды:»",
		String(stars_line.text) == "Звёзды:"
		and not String(stars_line.text).contains("★")
		and not String(stars_line.text).contains("☆"), String(stars_line.text))
	_check("оверлей победы: группа «подпись + 3 иконки» целиком внутри 540 px",
		icons != null and icons.visible and group_left >= -0.5
		and group_right <= field.size.x + 0.5,
		"лево %.1f, право %.1f" % [group_left, group_right])
	# M11/T2/T3: тап-шорткатов больше нет — рестарт/выход только кнопками. Поэтому центр
	# поля (270,480) обязан быть СВОБОДЕН от кнопок исхода: касание там ничего не нажимает.
	var center := Vector2(270.0, 480.0)
	var covers_center := false
	for path: NodePath in [^"ReplayButton", ^"CampaignButton", ^"HomeButton"]:
		var button := overlay.get_node_or_null(path) as Button
		if button != null and button.visible and button.get_global_rect().has_point(center):
			covers_center = true
	_check("оверлей победы: кнопки исхода не накрывают центр поля (тап там ничего не делает)",
		overlay.visible and not covers_center, str(center))

	# ── hide_overlay не теряет текст; старый вызов show_result(score, elapsed) жив ──
	overlay.hide_overlay()
	_check("оверлей победы: hide_overlay не теряет текст рекорда",
		not overlay.visible and String(record_line.text) == "Новый рекорд: 1234",
		"%s / «%s»" % [overlay.visible, record_line.text])
	overlay.show_result(10, 5.0)
	_check("оверлей победы: старый show_result(score, elapsed) не падает",
		overlay.visible and String(overlay.score_line.text) == "Счёт: 10"
		and String(record_line.text) == "Рекорд: 0",
		"%s / %s" % [overlay.score_line.text, record_line.text])
	overlay.hide_overlay()


func _check_project_settings() -> void:
	_check(
		"настройки: база 540×960",
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)) == 540
		and int(ProjectSettings.get_setting("display/window/size/viewport_height", 0)) == 960
	)
	_check(
		"настройки: stretch canvas_items / keep",
		String(ProjectSettings.get_setting("display/window/stretch/mode", "")) == "canvas_items"
		and String(ProjectSettings.get_setting("display/window/stretch/aspect", "")) == "keep"
	)
	var orientation: int = int(ProjectSettings.get_setting("display/window/handheld/orientation", -1))
	_check("настройки: портретная ориентация (1)", orientation == 1, "получено %d" % orientation)
	_check(
		"настройки: gl_compatibility",
		String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")) == "gl_compatibility"
	)
	_check(
		"настройки: emulate_touch_from_mouse",
		bool(ProjectSettings.get_setting("input_devices/pointing/emulate_touch_from_mouse", false))
	)
	# Игра обрабатывает только touch-события; эмуляция мыши из тача должна быть выключена,
	# иначе на Android появляются двойные события.
	_check(
		"настройки: emulate_mouse_from_touch выключен",
		not bool(ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true))
	)
	# Бюджет туннелирования пуль (800 px/s → 13.3 px/тик) держится на 60 Гц физике.
	_check(
		"настройки: physics_ticks_per_second = 60",
		int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 0)) == 60,
		str(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 0))
	)
	_check(
		"настройки: русское имя приложения",
		String(ProjectSettings.get_setting("application/config/name", "")).begins_with(
			"WW2 Air Battles: Оборона аэродрома"
		),
		String(ProjectSettings.get_setting("application/config/name", ""))
	)
	var font: Font = ThemeDB.fallback_font
	var cyrillic_ok := true
	if font != null and font.has_method("has_char"):
		cyrillic_ok = bool(font.call("has_char", "С".unicode_at(0)))
	_check("шрифт по умолчанию содержит кириллицу", cyrillic_ok)


# ─── M3-A: глобальная тема и шрифт Noto Sans (OFL) ───────────────────────────
## Проверяем не «файл лежит на диске», а рабочую цепочку:
## project setting gui/theme/custom → Theme → default_font → кириллические глифы → Label.get_theme_font().
func _check_ui_theme() -> void:
	var theme_path := String(ProjectSettings.get_setting("gui/theme/custom", ""))
	_check("тема: gui/theme/custom указывает на ui_theme.tres", theme_path == THEME_PATH,
		"получено «%s»" % theme_path)
	var theme_resource: Theme = null
	if ResourceLoader.exists(theme_path):
		theme_resource = load(theme_path) as Theme
	_check("тема: gui/theme/custom загружается как Theme", theme_resource != null, theme_path)
	if theme_resource == null:
		return

	var regular: Font = theme_resource.default_font
	_check("тема: default_font — FontFile (не фолбэк движка)", regular is FontFile,
		"null" if regular == null else String(regular.resource_path))
	_check("тема: default_font — NotoSans-Regular.ttf",
		regular != null and regular.resource_path.ends_with("NotoSans-Regular.ttf"),
		"null" if regular == null else String(regular.resource_path))
	# «А» и «Ё» — базовая кириллица и йотированная гласная: без них русский текст уходит
	# на системный шрифт Android и «плывёт» по метрикам.
	_check("тема: у шрифта есть глиф «А»",
		regular != null and regular.has_char("А".unicode_at(0)))
	_check("тема: у шрифта есть глиф «Ё»",
		regular != null and regular.has_char("Ё".unicode_at(0)))
	_check("тема: шрифт покрывает всю русскую копию UI и знаки «—», «×»",
		_font_covers(regular, UI_COPY_SAMPLE), _missing_glyphs(regular, UI_COPY_SAMPLE))
	_check("тема: default_font_size = 24", theme_resource.default_font_size == UI_FONT_SIZE,
		str(theme_resource.default_font_size))

	# Type variation TitleLabel: base_type Label + Bold (Regular остаётся для HUD/подсказок).
	var base_type := theme_resource.get_type_variation_base(&"TitleLabel")
	_check("тема: type variation TitleLabel существует, base_type Label",
		base_type == &"Label", "получено «%s»" % String(base_type))
	var title_font: Font = theme_resource.get_font(&"font", &"TitleLabel")
	_check("тема: TitleLabel шрифт — FontFile (Bold)",
		title_font is FontFile and title_font.resource_path.ends_with("NotoSans-Bold.ttf"),
		"null" if title_font == null else String(title_font.resource_path))
	_check("тема: TitleLabel шрифт отличается от Regular",
		title_font != null and regular != null
		and String(title_font.resource_path) != String(regular.resource_path),
		"Bold=%s Regular=%s" % [
			"null" if title_font == null else String(title_font.resource_path),
			"null" if regular == null else String(regular.resource_path),
		])
	_check("тема: Bold покрывает заголовки оверлеев",
		_font_covers(title_font, UI_TITLE_SAMPLE), _missing_glyphs(title_font, UI_TITLE_SAMPLE))


# ─── M3-A: ассеты UI (лицензия + импорт шрифтов) ─────────────────────────────
func _check_ui_assets() -> void:
	var licence_file := FileAccess.open(OFL_PATH, FileAccess.READ)
	_check("ассеты: assets/fonts/OFL.txt читается", licence_file != null, OFL_PATH)
	if licence_file != null:
		var licence := licence_file.get_as_text()
		licence_file.close()
		_check("ассеты: OFL.txt содержит «SIL OPEN FONT LICENSE»",
			licence.contains("SIL OPEN FONT LICENSE"))
	_check("ассеты: NotoSans-Regular.ttf импортирован (ResourceLoader.exists)",
		ResourceLoader.exists(FONT_REGULAR_PATH), FONT_REGULAR_PATH)
	_check("ассеты: NotoSans-Regular.ttf загружается как FontFile",
		load(FONT_REGULAR_PATH) is FontFile, FONT_REGULAR_PATH)
	_check("ассеты: NotoSans-Bold.ttf импортирован (ResourceLoader.exists)",
		ResourceLoader.exists(FONT_BOLD_PATH), FONT_BOLD_PATH)
	_check("ассеты: NotoSans-Bold.ttf загружается как FontFile",
		load(FONT_BOLD_PATH) is FontFile, FONT_BOLD_PATH)


# ─── Гейт M3-D: аудио-ассеты (WAV, луп, README, импорт) ─────────────────────
## Ассеты проверяются ДО первого инстанса main: нужен только проект. Луп проверяется
## на живой копии потока (AudioManager.new()): `.wav` в ресурсе не зациклен, луп ставит
## код в _build_music, поэтому «после AudioManager» — единственный корректный момент.
func _check_audio_assets() -> void:
	var missing: Array[String] = []
	var not_wav: Array[String] = []
	var wrong_format: Array[String] = []
	var total_bytes := 0
	var durations: Dictionary = {}
	for file_name in AUDIO_FILES:
		var path := AUDIO_DIR + file_name
		if not ResourceLoader.exists(path):
			missing.append(file_name)
			continue
		var stream := load(path) as AudioStreamWAV
		if stream == null:
			not_wav.append(file_name)
			continue
		total_bytes += _file_size(path)
		durations[file_name] = stream.get_length()
		# mono/16-bit/22050: тогда loop_end = data.size()/2 однозначно в сэмплах.
		if stream.stereo or stream.format != AudioStreamWAV.FORMAT_16_BITS \
				or stream.mix_rate != AUDIO_SAMPLE_RATE:
			wrong_format.append("%s: %s, %d Гц, format=%d" % [
				file_name, "stereo" if stream.stereo else "mono",
				stream.mix_rate, stream.format])
	_check("аудио: все 9 WAV на месте (музыка + 8 SFX)", missing.is_empty(), str(missing))
	_check("аудио: все 9 файлов загружаются как AudioStreamWAV", not_wav.is_empty(),
		str(not_wav))
	_check("аудио: формат mono / 16-bit / 22050 Гц у всех 9 файлов",
		wrong_format.is_empty(), str(wrong_format))

	var music_length := float(durations.get("music_loop.wav", 0.0))
	_check("аудио: музыка 60–90 с (факт 64)",
		music_length >= AUDIO_MUSIC_MIN_LENGTH and music_length <= AUDIO_MUSIC_MAX_LENGTH,
		"%.3f с" % music_length)
	var long_sfx: Array[String] = []
	for key: StringName in AudioManager.SFX_KEYS:
		var file_name := String(key) + ".wav"
		var length := float(durations.get(file_name, 0.0))
		if length <= 0.0 or length >= AUDIO_SFX_MAX_LENGTH:
			long_sfx.append("%s=%.3f с" % [file_name, length])
	_check("аудио: каждый SFX короче 1.5 с", long_sfx.is_empty(), str(long_sfx))
	_check("аудио: суммарный размер ≤ 4 MiB", total_bytes > 0
		and total_bytes <= AUDIO_BUDGET_BYTES,
		"%.2f MiB" % (float(total_bytes) / 1048576.0))

	# Ключ = имя файла: SFX_KEYS обязан полностью закрываться файлами в assets/audio.
	var keys_without_file: Array[String] = []
	for key: StringName in AudioManager.SFX_KEYS:
		if not ResourceLoader.exists(AUDIO_DIR + String(key) + ".wav"):
			keys_without_file.append(String(key))
	_check("аудио: все 8 ключей SFX_KEYS имеют одноимённый WAV",
		keys_without_file.is_empty(), str(keys_without_file))

	# Происхождение ассетов: сгенерированные плейсхолдеры, без внешних сэмплов.
	var readme := FileAccess.get_file_as_string(AUDIO_README).to_lower()
	_check("аудио: README фиксирует «generated placeholder» и «no external samples»",
		readme.contains("generated placeholder") and readme.contains("no external samples"),
		"%d символов" % readme.length())
	_check("аудио: tools/generate_audio.py существует",
		FileAccess.file_exists(AUDIO_GENERATOR), AUDIO_GENERATOR)

	# compress/mode=0 (несжатый PCM): иначе data.size() не равен числу сэмплов и луп
	# считается по длительности — плейсхолдеры должны оставаться предсказуемыми.
	var bad_import: Array[String] = []
	for file_name in AUDIO_FILES:
		var import_text := FileAccess.get_file_as_string(AUDIO_DIR + file_name + ".import")
		if not import_text.contains("compress/mode=0"):
			bad_import.append(file_name)
	_check("аудио: во всех .import compress/mode=0 (несжатый PCM)",
		bad_import.is_empty(), str(bad_import))

	# Луп ставится в рантайме на КОПИЮ потока — проверяем живой AudioManager.
	var manager := AudioManager.new()
	add_child(manager)
	await get_tree().process_frame
	_check("аудио: музыка стартует сразу после boot AudioManager",
		manager.is_music_playing())
	_check("аудио: после AudioManager loop_mode = LOOP_FORWARD",
		manager.get_music_loop_mode() == AudioStreamWAV.LOOP_FORWARD,
		str(manager.get_music_loop_mode()))
	var looped := manager.get_music_stream() as AudioStreamWAV
	var loop_samples := 0
	if looped != null:
		loop_samples = int(float(looped.data.size()) / 2.0)  # mono 16-bit = 2 байта/сэмпл
	var loop_end_ok := looped != null and looped.loop_begin == 0 \
		and looped.data.size() > 0 \
		and looped.loop_end == loop_samples \
		and looped.loop_end == AUDIO_MUSIC_LOOP_SAMPLES
	_check("аудио: луп покрывает весь файл (loop_begin 0, loop_end 1 411 200 сэмплов)",
		loop_end_ok,
		"begin=%s, end=%s, data=%s" % [
			str(looped.loop_begin) if looped != null else "—",
			str(looped.loop_end) if looped != null else "—",
			str(looped.data.size()) if looped != null else "—"])
	manager.queue_free()
	await get_tree().process_frame


# ─── Гейт M3-D: AudioManager в сцене (узлы, пул, громкости, луп) ─────────────
## Свежий инстанс main даёт чистое состояние «только что запустили приложение»:
## брифинг, музыка уже играет, SFX ещё не звучали.
func _check_audio_manager() -> void:
	var probe := MAIN_SCENE.instantiate() as LevelController
	add_child(probe)
	await get_tree().process_frame
	await get_tree().physics_frame

	var audio := probe.get_node_or_null(^"Audio") as AudioManager
	var has_audio := audio != null
	_check("аудио: узел Level/Audio существует и это AudioManager", has_audio,
		"Audio" if has_audio else "узла нет")
	_check("аудио: Audio — прямой ребёнок LevelController",
		has_audio and audio.get_parent() == probe)
	_check("аудио: process_mode Audio = PAUSABLE",
		has_audio and audio.process_mode == Node.PROCESS_MODE_PAUSABLE,
		str(audio.process_mode) if has_audio else "узла нет")
	_check("аудио: пул из 8 SFX-голосов (API и дерево)",
		has_audio and audio.get_voice_count() == 8
		and _count_sfx_players(audio) == 8,
		"%d голосов, %d узлов Sfx*" % [
			audio.get_voice_count() if has_audio else -1,
			_count_sfx_players(audio) if has_audio else -1])
	_check("аудио: музыка играет на брифинге (GDD «Audio»)",
		has_audio and probe.get_state() == LevelController.State.BRIEFING
		and audio.is_music_playing(),
		"state=%d, playing=%s" % [
			probe.get_state(), audio.is_music_playing() if has_audio else false])

	var music: AudioStreamPlayer = audio.get_node_or_null(^"Music") as AudioStreamPlayer \
		if has_audio else null
	_check("аудио: Music — AudioStreamPlayer со stream",
		music != null and music.stream != null)
	var music_db := music.volume_db if music != null else 0.0
	_check("аудио: громкость музыки ≤ −12 dB", music != null and music_db <= -12.0,
		"%.1f dB" % music_db if music != null else "Music нет")
	# Музыка не должна перекрывать боевые звуки: база пула заметно громче трека.
	var first_voice: AudioStreamPlayer = audio.get_node_or_null(^"Sfx0") as AudioStreamPlayer \
		if has_audio else null
	var voice_db := first_voice.volume_db if first_voice != null else 0.0
	_check("аудио: база SFX громче музыки",
		AudioManager.SFX_VOLUME_DB > AudioManager.MUSIC_VOLUME_DB
		and first_voice != null
		and is_equal_approx(voice_db, AudioManager.SFX_VOLUME_DB),
		"SFX %.1f dB, музыка %.1f dB, голос %s" % [
			AudioManager.SFX_VOLUME_DB, AudioManager.MUSIC_VOLUME_DB,
			("%.1f dB" % voice_db) if first_voice != null else "—"])

	var stream: AudioStreamWAV = audio.get_music_stream() as AudioStreamWAV if has_audio else null
	var stream_samples := 0
	if stream != null:
		stream_samples = int(float(stream.data.size()) / 2.0)  # mono 16-bit
	_check("аудио: музыка уровня — несжатый AudioStreamWAV", stream != null)
	_check("аудио: loop_end музыки = число сэмплов (data.size()/2)",
		stream != null and stream.data.size() > 0 and stream.loop_end == stream_samples,
		"end=%s, data=%s" % [
			str(stream.loop_end) if stream != null else "—",
			str(stream.data.size()) if stream != null else "—"])
	var loop_mode := audio.get_music_loop_mode() if has_audio else -1
	_check("аудио: loop_begin = 0 и loop_mode = LOOP_FORWARD у уровня",
		stream != null and stream.loop_begin == 0
		and loop_mode == AudioStreamWAV.LOOP_FORWARD,
		"begin=%s, mode=%d" % [str(stream.loop_begin) if stream != null else "—", loop_mode])
	_check("аудио: SFX_KEYS.size() == 8", AudioManager.SFX_KEYS.size() == 8,
		str(AudioManager.SFX_KEYS.size()))
	_check("аудио: до первого SFX get_last_sfx пуст",
		has_audio and audio.get_last_sfx() == &"", String(audio.get_last_sfx()) if has_audio else "—")

	probe.queue_free()
	await get_tree().process_frame
	# Боевой инстанс: тот же узел, музыка не останавливалась между брифингом и забегом.
	var level_audio := _level.get_node_or_null(^"Audio") as AudioManager
	var level_music: AudioStreamPlayer = null
	if level_audio != null:
		level_music = level_audio.get_node_or_null(^"Music") as AudioStreamPlayer
	var level_position := level_music.get_playback_position() if level_music != null else -1.0
	_check("аудио: у боевого уровня музыка играет и позиция растёт",
		level_audio != null and level_audio.is_music_playing() and level_position > 0.0,
		"playing=%s, позиция %.3f с" % [
			level_audio.is_music_playing() if level_audio != null else "—", level_position])


# ─── Гейт M3-D: контракт сигналов → SFX (по одному, +1 к счётчику) ──────────
## Автострельба меряется ПЕРВОЙ, на чистом уровне (без hit-stop от juice): реальный путь
## player.shot_fired → LevelController.player_shot_fired → AudioManager. Дальше process
## игрока выключен, чтобы каждый ручной сигнал давал ровно +1 и не смазывался выстрелами.
func _check_audio_triggers() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.grant_invulnerability(999.0)
	await get_tree().process_frame

	var audio := _level.get_node(^"Audio") as AudioManager
	var at := Vector2(270.0, 400.0)
	var shot_velocity := Vector2.UP * Player.BULLET_SPEED

	# ── Автострельба 8 выстр./с: за 0.5 с ожидаем 3–5 выстрелов ─────────────
	var shots_before := audio.get_sfx_count(&"player_shot")
	await get_tree().create_timer(0.5).timeout
	var shots_grown := audio.get_sfx_count(&"player_shot") - shots_before
	_check("аудио-триггер: автострельба даёт 3–5 player_shot за 0.5 с",
		shots_grown >= 3 and shots_grown <= 5, "player_shot: %d" % shots_grown)
	_check("аудио-триггер: последний SFX после автострельбы — player_shot",
		audio.get_last_sfx() == &"player_shot", String(audio.get_last_sfx()))

	# Дальше — только ручные сигналы: фоновые выстрелы выключены.
	_level.player.set_process(false)
	_level.player.set_process_unhandled_input(false)

	# ── Контракт LevelController → SFX ──────────────────────────────────────
	var before := audio.get_sfx_count(&"player_shot")
	_level.player_shot_fired.emit(at, shot_velocity, Player.BULLET_DAMAGE)
	_check("аудио-триггер: player_shot_fired → player_shot (+1)",
		audio.get_sfx_count(&"player_shot") == before + 1
		and audio.get_last_sfx() == &"player_shot",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"player_shot"), String(audio.get_last_sfx())])

	var enemy_stub := _make_stub(false, 4)
	before = audio.get_sfx_count(&"enemy_hit")
	_level.enemy_damaged.emit(enemy_stub, 1, at)
	_check("аудио-триггер: enemy_damaged → enemy_hit (+1)",
		audio.get_sfx_count(&"enemy_hit") == before + 1
		and audio.get_last_sfx() == &"enemy_hit",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"enemy_hit"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"enemy_explosion")
	_level.enemy_destroyed.emit(&"enemy_bf109", at)
	_check("аудио-триггер: enemy_destroyed → enemy_explosion (+1)",
		audio.get_sfx_count(&"enemy_explosion") == before + 1
		and audio.get_last_sfx() == &"enemy_explosion",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"enemy_explosion"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"player_hit")
	_level.player_damaged.emit(2, at)
	_check("аудио-триггер: player_damaged → player_hit (+1)",
		audio.get_sfx_count(&"player_hit") == before + 1
		and audio.get_last_sfx() == &"player_hit",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"player_hit"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"pickup")
	_level.pickup_collected.emit(Pickup.Kind.REPAIR, at)
	_check("аудио-триггер: pickup_collected → pickup (+1)",
		audio.get_sfx_count(&"pickup") == before + 1
		and audio.get_last_sfx() == &"pickup",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"pickup"), String(audio.get_last_sfx())])

	# ── UI-клик и троттлинг 0.1 с (двойное событие тапа не должно дублировать звук) ──
	var ui_before := audio.get_sfx_count(&"ui_click")
	_level.briefing.start_requested.emit()
	var ui_first := audio.get_sfx_count(&"ui_click")
	_level.briefing.start_requested.emit()
	var ui_second := audio.get_sfx_count(&"ui_click")
	_check("аудио-триггер: start_requested → ui_click (+1)",
		ui_first == ui_before + 1 and audio.get_last_sfx() == &"ui_click",
		"%d → %d, last=%s" % [ui_before, ui_first, String(audio.get_last_sfx())])
	_check("аудио-триггер: второй клик <100 мс не играет (троттлинг)",
		ui_second == ui_first, "%d → %d" % [ui_first, ui_second])
	await get_tree().create_timer(0.12).timeout
	_level.briefing.start_requested.emit()
	_check("аудио-триггер: через 0.12 с клик снова играет",
		audio.get_sfx_count(&"ui_click") == ui_second + 1,
		"%d → %d" % [ui_second, audio.get_sfx_count(&"ui_click")])

	# ── Пул: серия сигналов не создаёт больше 8 одновременных голосов ───────
	# Стресс-серия идёт на ДЛИННОМ клипе (bomb 1.0 с), а не на player_shot (0.06 с):
	# на медленном кадре короткие клипы успевали дозвучать до замера и тест падал
	# «играют 0 из 8» (флейк теста, не игры). bomb переживает любой кадр, смысл тот же:
	# пул не растёт сверх 8 голосов, а каждый сигнал всё равно считается.
	var stress_clip := load(AUDIO_DIR + "bomb.wav") as AudioStream
	var stress_length := stress_clip.get_length() if stress_clip != null else 0.0
	_check("аудио-пул: стресс-серия на длинном клипе bomb (≥ 0.9 с) — без флейка кадра",
		stress_length >= 0.9, "%.2f с" % stress_length)

	var bomb_before_stress := audio.get_sfx_count(&"bomb")
	for _index in 12:
		_level.bomb_detonated.emit(at, LevelController.BOMB_FLASH_RADIUS)
	await get_tree().process_frame
	var playing_voices := _count_playing_sfx(audio)
	_check("аудио-пул: серия из 12 сигналов — 1..8 одновременных голосов",
		playing_voices >= 1 and playing_voices <= 8,
		"играют %d из %d" % [playing_voices, audio.get_voice_count()])
	_check("аудио-пул: голосов ровно 8 (узлы Sfx*) и счётчик сигналов вырос на 12",
		audio.get_voice_count() == 8 and _count_sfx_players(audio) == 8
		and audio.get_sfx_count(&"bomb") == bomb_before_stress + 12,
		"бомба: %d → %d, голосов %d/%d" % [
			bomb_before_stress, audio.get_sfx_count(&"bomb"),
			audio.get_voice_count(), _count_sfx_players(audio)])

	# ── Бомба/гибель/бомба босса: у каждого свой клип и питч ────────────────
	before = audio.get_sfx_count(&"bomb")
	_level.bomb_detonated.emit(at, LevelController.BOMB_FLASH_RADIUS)
	_check("аудио-триггер: bomb_detonated → bomb (+1)",
		audio.get_sfx_count(&"bomb") == before + 1
		and audio.get_last_sfx() == &"bomb",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"bomb"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"enemy_explosion")
	_level.boss_bomb_detonated.emit(at, 100.0)
	_check("аудио-триггер: boss_bomb_detonated → enemy_explosion (+1)",
		audio.get_sfx_count(&"enemy_explosion") == before + 1
		and audio.get_last_sfx() == &"enemy_explosion",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"enemy_explosion"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"enemy_explosion")
	_level.player_died.emit(_level.player.global_position)
	_check("аудио-триггер: player_died → enemy_explosion (+1)",
		audio.get_sfx_count(&"enemy_explosion") == before + 1
		and audio.get_last_sfx() == &"enemy_explosion",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"enemy_explosion"), String(audio.get_last_sfx())])

	# ── Босс: тревога, попадания по HP, смена фазы ─────────────────────────
	var boss_stub := _make_stub(true, 120)
	before = audio.get_sfx_count(&"boss_alarm")
	_level.boss_spawned.emit(boss_stub)
	_check("аудио-триггер: boss_spawned → boss_alarm (+1)",
		audio.get_sfx_count(&"boss_alarm") == before + 1
		and audio.get_last_sfx() == &"boss_alarm",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"boss_alarm"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"enemy_hit")
	boss_stub.health_changed.emit(50)
	_check("аудио-триггер: попадание по боссу (hp 50) → enemy_hit (+1)",
		audio.get_sfx_count(&"enemy_hit") == before + 1
		and audio.get_last_sfx() == &"enemy_hit",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"enemy_hit"), String(audio.get_last_sfx())])

	before = audio.get_sfx_count(&"enemy_hit")
	boss_stub.health_changed.emit(0)
	_check("аудио-триггер: смертельный hp 0 не тикает enemy_hit",
		audio.get_sfx_count(&"enemy_hit") == before,
		"%d → %d" % [before, audio.get_sfx_count(&"enemy_hit")])

	before = audio.get_sfx_count(&"boss_alarm")
	_level.boss_phase_changed.emit(2)
	_check("аудио-триггер: boss_phase_changed → boss_alarm (+1)",
		audio.get_sfx_count(&"boss_alarm") == before + 1
		and audio.get_last_sfx() == &"boss_alarm",
		"%d → %d, last=%s" % [
			before, audio.get_sfx_count(&"boss_alarm"), String(audio.get_last_sfx())])

	# Уборка: заглушки вне дерева, ввод игрока возвращаем следующим тестам.
	boss_stub.free()
	enemy_stub.free()
	_level.player.set_process(true)
	_level.player.set_process_unhandled_input(true)


# ─── Гейт M3-D: пауза замораживает звук (без «догоняющего» скачка) ──────────
## AudioManager PAUSABLE + stream_paused на плеерах-ALWAYS: позиция музыки стоит,
## после resume продолжается с того же места, без перемотки вперёд.
func _check_audio_pause() -> void:
	_level.start_level()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	var audio := _level.get_node(^"Audio") as AudioManager
	var music := audio.get_node(^"Music") as AudioStreamPlayer

	# SFX тоже обязан замирать: клип бомбы (2.0 с) переживает паузу целиком.
	# Голос берём по ключу и самый «свежий»: _first_playing_sfx вернул бы ЛЮБОЙ играющий
	# голос (на этой машине — player_shot 0.12 с, который успевает закончиться до паузы,
	# и проверка смотрела бы на уже остановленный поток — ложный FAIL).
	_level.bomb_detonated.emit(Vector2(270.0, 520.0), LevelController.BOMB_FLASH_RADIUS)
	var sfx_voice := _playing_sfx_voice(audio, &"bomb")
	_check("аудио-пауза: SFX-голос запущен перед паузой",
		sfx_voice != null and sfx_voice.playing,
		"голос %s" % (String(sfx_voice.name) if sfx_voice != null else "не найден"))

	var running_from := music.get_playback_position()
	await get_tree().create_timer(0.15).timeout
	var running_to := music.get_playback_position()
	_check("аудио-пауза: до паузы музыка играет и позиция растёт",
		audio.is_music_playing() and running_to > running_from + 0.05,
		"%.3f → %.3f с" % [running_from, running_to])

	_level.pause_game()
	# NOTIFICATION_PAUSED доставляется отложенно (SceneTree → message queue), а аудиопоток
	# домикширует уже начатый буфер (Dummy-драйвер — крупными блоками ~23–93 мс), поэтому
	# перед замерами даём паузе «осесть»: иначе разница позиций — это буфер, а не утечка звука.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(PAUSE_AUDIO_SETTLE).timeout
	var paused_from := music.get_playback_position()
	var sfx_paused_from := sfx_voice.get_playback_position() if sfx_voice != null else -1.0
	await get_tree().create_timer(PAUSE_AUDIO_HOLD).timeout
	var paused_to := music.get_playback_position()
	var sfx_paused_to := sfx_voice.get_playback_position() if sfx_voice != null else -1.0
	_check("аудио-пауза: на паузе позиция музыки не растёт",
		absf(paused_to - paused_from) <= PAUSE_AUDIO_DRIFT,
		"%.3f → %.3f с" % [paused_from, paused_to])
	_check("аудио-пауза: на паузе поток музыки помечен stream_paused", music.stream_paused)
	_check("аудио-пауза: is_music_playing false на паузе",
		not audio.is_music_playing())
	_check("аудио-пауза: SFX-голос тоже stream_paused на паузе",
		sfx_voice != null and sfx_voice.stream_paused)
	_check("аудио-пауза: позиция SFX на паузе не растёт",
		sfx_voice != null and absf(sfx_paused_to - sfx_paused_from) <= PAUSE_AUDIO_DRIFT,
		"%.3f → %.3f с" % [sfx_paused_from, sfx_paused_to])

	_level.resume_game()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(PAUSE_AUDIO_SETTLE).timeout
	var resumed_from := music.get_playback_position()
	var sfx_resumed_from := sfx_voice.get_playback_position() if sfx_voice != null else -1.0
	await get_tree().create_timer(PAUSE_AUDIO_GROWTH_WINDOW).timeout
	var resumed_to := music.get_playback_position()
	var sfx_resumed_to := sfx_voice.get_playback_position() if sfx_voice != null else -1.0
	_check("аудио-пауза: после resume музыка играет",
		audio.is_music_playing() and not music.stream_paused)
	_check("аудио-пауза: после resume позиция снова растёт",
		resumed_to > resumed_from + 0.05,
		"%.3f → %.3f с" % [resumed_from, resumed_to])
	_check("аудио-пауза: после resume SFX продолжается с того же места",
		sfx_voice != null and not sfx_voice.stream_paused
		and sfx_resumed_to > sfx_resumed_from + 0.05,
		"%.3f → %.3f с" % [sfx_resumed_from, sfx_resumed_to])
	# «Догоняющий» баг перемотал бы поток на всю длительность паузы (>PAUSE_AUDIO_HOLD);
	# допуск PAUSE_AUDIO_CATCHUP_JUMP покрывает только квант микса, но не паузу.
	_check("аудио-пауза: на resume нет скачка (продолжение с того же места)",
		resumed_from - paused_to <= PAUSE_AUDIO_CATCHUP_JUMP
		and resumed_to - resumed_from <= 0.5,
		"пауза %.3f → resume %.3f → %.3f с (допуск скачка %.2f)" % [
			paused_to, resumed_from, resumed_to, PAUSE_AUDIO_CATCHUP_JUMP])


# ─── Гейт M3-E: фон-земля сверху (3 слоя параллакса, темы локаций, облака) ───
## Фон — чистый декор: земля строго сверху (полёт НАД объектом — ни неба, ни
## горизонта, ни перспективы), без физики и ввода, стоит ПОД World и подчиняется
## общим правилам паузы (замирает на паузе/исходе, живёт в PLAYING и на брифинге).
## Тема выбирается по миссии (GDD «Assets»: bg_airfield / bg_crossing / bg_city).
## Палитра проверяется по контракту ArtStyle и образцам get_theme_palette(), а не
## попиксельным сравнением: рендер держим свободным, инварианты — жёсткими.
func _check_background() -> void:
	_level.start_mission("m1_airfield")
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)

	var background: BattlefieldBackground = _level.background
	var has_bg := background != null and is_instance_valid(background)
	_check("фон: Level/Background существует и это BattlefieldBackground", has_bg,
		"BattlefieldBackground" if has_bg else "узла нет")
	if not has_bg:
		return

	_check("фон: process_mode PAUSABLE (замирает вместе с миром)",
		background.process_mode == Node.PROCESS_MODE_PAUSABLE,
		str(background.process_mode))

	# ── Слой в дереве: декор рисуется ДО игрового мира ──────────────────────
	# World в рантайме репарентится в обёртку ScreenShake (тряска), поэтому сравниваем
	# не get_index() соседей, а реальный порядок отрисовки — обход дерева в глубину.
	var world := _level.world
	var background_rank := _draw_rank(_level, background)
	var world_rank := _draw_rank(_level, world)
	var player_rank := _draw_rank(_level, _level.player)
	_check("фон: Background — прямой ребёнок Level и раньше World в порядке отрисовки",
		background.get_parent() == _level and background_rank >= 0
		and world_rank > background_rank and player_rank > background_rank,
		"rank: Background=%d, World=%d, Player=%d" % [
			background_rank, world_rank, player_rank])
	_check("фон: z-порядок не поднимает декор над самолётами/пулями",
		background.z_index <= world.z_index and background.z_index <= 0,
		"bg.z=%d, world.z=%d" % [background.z_index, world.z_index])
	var bg_node: Node = background
	_check("фон: фон вне CanvasLayer, HUD в CanvasLayer — HUD всегда поверх фона",
		not _has_canvas_layer_parent(bg_node)
		and _level.hud.get_parent() is CanvasLayer,
		"%s / %s" % [
			"CanvasLayer-родитель у фона" if _has_canvas_layer_parent(bg_node) else "фон в мире",
			_level.hud.get_parent().get_class()])

	# ── Декор не участвует в геймплее: ни узлов, ни физики, ни ввода ────────
	_check("фон: у Background нет дочерних узлов (только код отрисовки)",
		background.get_child_count() == 0,
		"детей: %d" % background.get_child_count())
	var physics_nodes := _count_physics_nodes(background)
	_check("фон: в фоне нет CollisionObject2D/Area2D/CollisionShape2D",
		physics_nodes == 0, "физических узлов: %d" % physics_nodes)

	var methods := _script_method_names(background.get_script())
	var input_methods: Array[String] = []
	for method_name in ["_input", "_unhandled_input", "_gui_input", "_input_event"]:
		if methods.has(method_name):
			input_methods.append(method_name)
	_check("фон: не перехватывает тап (нет _input/_unhandled_input/_gui_input)",
		input_methods.is_empty(), str(input_methods))
	_check("фон: скрипт рисует (_draw) и анимируется (_process)",
		methods.has("_draw") and methods.has("_process"), str(methods))

	# ── Производительность: геометрия предвычислена, в _draw нет сборки ─────
	var source := _script_source(background.get_script())
	_check("фон: земля/дороги/крыши берут цвета из ArtStyle (PLAYER/ENEMY/CREAM/SKY)",
		source.contains("ArtStyle.PLAYER") and source.contains("ArtStyle.ENEMY")
		and source.contains("ArtStyle.CREAM") and source.contains("ArtStyle.SKY")
		and source.contains("ArtStyle.CLOUD"),
		"исходник %d символов" % source.length())
	var draw_body := _function_body(source, "_draw")
	_check("фон: _draw не создаёт узлов и не собирает PackedVector2Array (геометрия предвычислена)",
		not draw_body.is_empty() and not draw_body.contains("PackedVector2Array(")
		and not draw_body.contains("add_child") and not draw_body.contains("instantiate("),
		"тело _draw %d символов" % draw_body.length())

	# ── Темы локаций (GDD «Assets»: bg_airfield / bg_crossing / bg_city) ────
	var constants: Dictionary = background.get_script().get_script_constant_map()
	var has_theme_keys := constants.has("THEME_AIRFIELD") and constants.has("THEME_CROSSING") \
		and constants.has("THEME_CITY") and constants.has("MISSION_THEMES") \
		and constants.has("TILE_HEIGHT") and constants.has("LAYER_SPEEDS") \
		and constants.has("CLOUD_BACK") and constants.has("CLOUD_FRONT") \
		and constants.has("CLOUD_WRAP_PADDING")
	_check("фон: темы/плитка/скорости/облака — именованные константы скрипта",
		has_theme_keys, str(constants.keys()))

	var object_alpha := 0.0
	var ground_alpha := 0.0
	var theme_m1 := background.get_theme_id()
	var palette_m1 := background.get_theme_palette()
	object_alpha = maxf(object_alpha,
		background.get_layer_max_alpha(BattlefieldBackground.LAYER_OBJECTS))
	ground_alpha = maxf(ground_alpha,
		background.get_layer_max_alpha(BattlefieldBackground.LAYER_GROUND))
	_check("фон: миссия 1 (m1_airfield) → тема bg_airfield",
		theme_m1 == BattlefieldBackground.THEME_AIRFIELD, String(theme_m1))

	_level.start_mission("m2_crossing")
	await get_tree().process_frame
	var theme_m2 := background.get_theme_id()
	var palette_m2 := background.get_theme_palette()
	object_alpha = maxf(object_alpha,
		background.get_layer_max_alpha(BattlefieldBackground.LAYER_OBJECTS))
	ground_alpha = maxf(ground_alpha,
		background.get_layer_max_alpha(BattlefieldBackground.LAYER_GROUND))
	_check("фон: миссия 2 (m2_crossing) → тема bg_crossing",
		theme_m2 == BattlefieldBackground.THEME_CROSSING, String(theme_m2))

	_level.start_mission("m3_city")
	await get_tree().process_frame
	var theme_m3 := background.get_theme_id()
	var palette_m3 := background.get_theme_palette()
	object_alpha = maxf(object_alpha,
		background.get_layer_max_alpha(BattlefieldBackground.LAYER_OBJECTS))
	ground_alpha = maxf(ground_alpha,
		background.get_layer_max_alpha(BattlefieldBackground.LAYER_GROUND))
	_check("фон: миссия 3 (m3_city) → тема bg_city",
		theme_m3 == BattlefieldBackground.THEME_CITY, String(theme_m3))
	_check("фон: у трёх миссий три разные темы (фон не одинаковый)",
		theme_m1 != theme_m2 and theme_m2 != theme_m3 and theme_m1 != theme_m3,
		"%s / %s / %s" % [String(theme_m1), String(theme_m2), String(theme_m3)])
	_check("фон: смена темы не создаёт узлов и не двигает Background в дереве",
		background.get_child_count() == 0 and _count_physics_nodes(background) == 0
		and background.get_parent() == _level
		and _draw_rank(_level, background) < _draw_rank(_level, world),
		"детей %d, rank %d" % [background.get_child_count(),
			_draw_rank(_level, background)])

	background.set_theme_for_mission("")
	var theme_fallback := background.get_theme_id()
	_check("фон: неизвестный/пустой id миссии → bg_airfield (дефолт)",
		theme_fallback == BattlefieldBackground.THEME_AIRFIELD, String(theme_fallback))
	# Дальше идёт кампанийный прогон smoke — возвращаем миссию 1.
	_level.start_mission("m1_airfield")
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)

	# Облака: 5 задних + 4 передних, все полупрозрачные (не «замазывают» цели).
	var cloud_max_alpha := 0.0
	var cloud_total := 0
	for layer: Array in [BattlefieldBackground.CLOUD_BACK, BattlefieldBackground.CLOUD_FRONT]:
		for cloud: Dictionary in layer:
			cloud_total += 1
			cloud_max_alpha = maxf(cloud_max_alpha, float(cloud["alpha"]))
	_check("фон: 9 облаков в двух слоях параллакса (5 задних + 4 передних)",
		background.get_cloud_count() == 9
		and BattlefieldBackground.CLOUD_BACK.size() == 5
		and BattlefieldBackground.CLOUD_FRONT.size() == 4
		and cloud_total == 9,
		"get_cloud_count()=%d, в слоях %d" % [background.get_cloud_count(), cloud_total])
	_check("фон: облака полупрозрачны (alpha ≤ 0.18) — цели читаются сквозь них",
		cloud_max_alpha > 0.0 and cloud_max_alpha <= 0.18,
		"max alpha %.2f" % cloud_max_alpha)

	# ── Читаемость: земля светлая и спокойная под силуэтами и пулями ────────
	var terrain_1: Color = palette_m1["terrain"]
	var terrain_2: Color = palette_m2["terrain"]
	var terrain_3: Color = palette_m3["terrain"]
	var lum_1 := _luminance(terrain_1)
	var lum_2 := _luminance(terrain_2)
	var lum_3 := _luminance(terrain_3)
	var lum_min := minf(minf(lum_1, lum_2), lum_3)
	var lum_max := maxf(maxf(lum_1, lum_2), lum_3)
	var enemy_lum := _luminance(ArtStyle.ENEMY)
	var player_lum := _luminance(ArtStyle.PLAYER)
	_check("фон: земля всех тем заметно светлее серых врагов (силуэты читаются)",
		lum_min - enemy_lum >= TERRAIN_ENEMY_CONTRAST,
		"земля ≥ %.3f против врага %.3f" % [lum_min, enemy_lum])
	_check("фон: земля контрастна оливковому Ла-5 (|Δ| ≥ 0.12 в каждой теме)",
		absf(lum_1 - player_lum) >= TERRAIN_PLAYER_CONTRAST
		and absf(lum_2 - player_lum) >= TERRAIN_PLAYER_CONTRAST
		and absf(lum_3 - player_lum) >= TERRAIN_PLAYER_CONTRAST,
		"%.3f / %.3f / %.3f против игрока %.3f" % [lum_1, lum_2, lum_3, player_lum])
	_check("фон: земля в пределах 0.35…0.80 — не «чёрная дыра» и не пересвет",
		lum_min >= TERRAIN_MIN_LUMINANCE and lum_max <= TERRAIN_MAX_LUMINANCE,
		"яркость %.3f…%.3f" % [lum_min, lum_max])
	# База/дорога/детали в каждой теме — разные цвета, а не плоская заливка.
	var flat_themes: Array[String] = []
	for palette: Dictionary in [palette_m1, palette_m2, palette_m3]:
		var base_color: Color = palette["terrain"]
		var route_color: Color = palette["route"]
		var detail_color: Color = palette["detail"]
		if base_color.is_equal_approx(route_color) \
				or route_color.is_equal_approx(detail_color) \
				or base_color.is_equal_approx(detail_color):
			flat_themes.append("плоская заливка")
	_check("фон: в каждой теме земля, дорога и детали — разные цвета (не плоская заливка)",
		flat_themes.is_empty(), str(flat_themes))
	_check("фон: темы различаются землёй (аэродром ≠ переправа ≠ город)",
		_color_distance(terrain_1, terrain_2) > TERRAIN_THEME_DISTANCE
		and _color_distance(terrain_2, terrain_3) > TERRAIN_THEME_DISTANCE
		and _color_distance(terrain_1, terrain_3) > TERRAIN_THEME_DISTANCE,
		"Δ %.3f / %.3f / %.3f" % [_color_distance(terrain_1, terrain_2),
			_color_distance(terrain_2, terrain_3), _color_distance(terrain_1, terrain_3)])
	# Объекты и пятна земли полупрозрачны: под самолётом нет пёстрого пятна.
	_check("фон: объекты и пятна земли полупрозрачны (объекты ≤ 0.65, земля ≤ 0.30)",
		object_alpha > 0.0 and object_alpha <= 0.65 and ground_alpha <= 0.30,
		"объекты %.2f, земля %.2f" % [object_alpha, ground_alpha])

	# ── Параллакс в PLAYING: слои ползут вниз с разной скоростью ────────────
	var tile := BattlefieldBackground.TILE_HEIGHT
	var back_from := background.get_back_offset()
	var front_from := background.get_front_offset()
	var time_from := background.get_animation_time()
	var offsets_in_range := back_from >= 0.0 and back_from < tile \
		and front_from >= 0.0 and front_from < tile
	await get_tree().create_timer(0.25).timeout
	var back_to := background.get_back_offset()
	var front_to := background.get_front_offset()
	var time_to := background.get_animation_time()
	_check("фон: в PLAYING земля ползёт вниз (offset базового слоя растёт)",
		back_to > back_from + 0.5, "%.2f → %.2f px" % [back_from, back_to])
	_check("фон: объекты быстрее земли (параллакс 46 px/с против 16)",
		front_to - front_from > back_to - back_from,
		"объекты %.2f px, земля %.2f px за 0.25 с" % [
			front_to - front_from, back_to - back_from])
	_check("фон: animation_time растёт (анимация живая)",
		time_to > time_from + 0.1, "%.2f → %.2f с" % [time_from, time_to])
	_check("фон: offset слоёв всегда в [0, TILE_HEIGHT)",
		offsets_in_range and back_to < tile and front_to < tile,
		"back=%.1f, front=%.1f, плитка=%.0f" % [back_to, front_to, tile])
	_check("фон: три слоя параллакса со строго возрастающими скоростями",
		background.get_layer_count() == 3
		and BattlefieldBackground.LAYER_SPEEDS.size() == 3
		and background.get_layer_speed(0) < background.get_layer_speed(1)
		and background.get_layer_speed(1) < background.get_layer_speed(2),
		"скорости %s px/с" % str(BattlefieldBackground.LAYER_SPEEDS))

	# Wrap проверяем напрямую: подводим смещение к кромке цикла и ждём кадр —
	# значение обязано вернуться к началу диапазона, а не улететь за плитку.
	background.set_layer_offset(BattlefieldBackground.LAYER_GROUND, tile - 0.01)
	background.set_layer_offset(BattlefieldBackground.LAYER_OBJECTS, tile - 0.01)
	await get_tree().process_frame
	await get_tree().process_frame
	var back_wrapped := background.get_back_offset()
	var front_wrapped := background.get_front_offset()
	_check("фон: wrap земли — у кромки плитки offset возвращается к началу",
		back_wrapped >= 0.0 and back_wrapped < 100.0
		and front_wrapped >= 0.0 and front_wrapped < 100.0,
		"back %.2f, front %.2f (было %.2f)" % [back_wrapped, front_wrapped, tile - 0.01])

	# ── Пауза: фон замирает, после resume снова живёт ───────────────────────
	_level.pause_game()
	await get_tree().process_frame
	await get_tree().process_frame
	var paused_back := background.get_back_offset()
	var paused_front := background.get_front_offset()
	var paused_time := background.get_animation_time()
	await get_tree().create_timer(0.2).timeout
	_check("фон: на паузе земля и облака замирают (offset и время стоят)",
		is_equal_approx(paused_back, background.get_back_offset())
		and is_equal_approx(paused_front, background.get_front_offset())
		and is_equal_approx(paused_time, background.get_animation_time()),
		"back %.3f → %.3f, front %.3f → %.3f, время %.3f → %.3f" % [
			paused_back, background.get_back_offset(),
			paused_front, background.get_front_offset(),
			paused_time, background.get_animation_time()])

	_level.resume_game()
	await get_tree().process_frame
	var resumed_time_from := background.get_animation_time()
	var resumed_front_from := background.get_front_offset()
	await get_tree().create_timer(0.2).timeout
	_check("фон: после resume фон снова живёт (время и передний слой растут)",
		background.get_animation_time() > resumed_time_from + 0.05
		and background.get_front_offset() > resumed_front_from + 0.3,
		"время %.2f → %.2f, front %.2f → %.2f" % [
			resumed_time_from, background.get_animation_time(),
			resumed_front_from, background.get_front_offset()])


# ─── M3-A: HUD-полировка (иконки HP, полоса босса, ввод) ─────────────────────
func _check_hud_polish() -> void:
	var hud := _level.hud
	var hp_icon := ArtStyle.size_of(ArtStyle.KEY_UI_HP)

	_check("HUD: hp = 3 на старте", hud.hp == Player.MAX_HP, str(hud.hp))
	_check("HUD: иконка ui_hp 24×24", hp_icon.is_equal_approx(Vector2(24.0, 24.0)), str(hp_icon))
	_check("HUD: ArtStyle.draw_hp_icon существует (иконки рисуются кодом)",
		_art_style_has_method("draw_hp_icon"))
	# Ряд иконок 3×24 с шагом 30 при x=16 → 100 px; текст «HP n/3» начинается с 112.
	var icons_right := Hud.HP_ICON_ORIGIN.x + Hud.HP_ICON_STEP * float(Player.MAX_HP - 1) + hp_icon.x
	_check("HUD: 3 иконки ui_hp не заходят под текст HP",
		icons_right <= hud.hp_label.get_global_rect().position.x,
		"иконки кончаются на %.0f px, текст с %.0f px" % [
			icons_right, hud.hp_label.get_global_rect().position.x])

	# set_hp — единственная точка записи: текст «HP n/3» обязан следовать за иконками.
	hud.set_hp(1)
	_check("HUD: set_hp(1) → hp = 1", hud.hp == 1, str(hud.hp))
	_check("HUD: set_hp(1) → «HP 1/3»", String(hud.hp_label.text) == "HP 1/3",
		String(hud.hp_label.text))
	hud.set_hp(Player.MAX_HP)
	_check("HUD: set_hp(3) восстанавливает hp и «HP 3/3»",
		hud.hp == Player.MAX_HP and String(hud.hp_label.text) == "HP 3/3",
		"%d / %s" % [hud.hp, hud.hp_label.text])
	hud.set_hp(99)
	_check("HUD: set_hp клампится по MAX_HP (99 → «HP 3/3»)",
		hud.hp == Player.MAX_HP and String(hud.hp_label.text) == "HP 3/3",
		"%d / %s" % [hud.hp, hud.hp_label.text])

	# HUD лежит поверх всего мира: любой перехват тапа ломает драг самолёта.
	_check("HUD: корневой Control не перехватывает ввод (IGNORE)",
		hud.mouse_filter == Control.MOUSE_FILTER_IGNORE, str(hud.mouse_filter))
	_check("HUD: HPLabel/ScoreLabel/BossBar прозрачны для тапов (IGNORE)",
		hud.hp_label.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and hud.score_label.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and hud.boss_bar.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	# Бейдж зарядов «×N» рисуется шрифтом темы: без глифа «×» счётчик станет пустым квадратом.
	var badge_font := _level.bomb_button.get_theme_font(&"font")
	_check("бомба: бейдж ×N рисуется шрифтом темы (глифы «×1»/«×0»)",
		badge_font != null and _font_covers(badge_font, "×1") and _font_covers(badge_font, "×0"),
		"шрифт null или без глифа «×»" if badge_font == null else String(badge_font.resource_path))
	_check("бомба: бейдж целиком внутри круга кнопки",
		BombButton.COUNTER_OFFSET.length() + BombButton.COUNTER_RADIUS <= BombButton.BUTTON_RADIUS,
		"%.1f + %.1f > %.1f" % [
			BombButton.COUNTER_OFFSET.length(), BombButton.COUNTER_RADIUS, BombButton.BUTTON_RADIUS])
	_check("бомба: текст бейджа 16 px", BombButton.COUNTER_FONT_SIZE == 16,
		str(BombButton.COUNTER_FONT_SIZE))

	# Кнопка паузы вторит кнопке бомбы: круг 23 при зоне тапа 48 (контур 2 px не срезается).
	_check("пауза: радиус 23 и контур 2 px",
		is_equal_approx(PauseButton.CIRCLE_RADIUS, 23.0)
		and is_equal_approx(PauseButton.OUTLINE_WIDTH, 2.0),
		"r=%.1f / контур %.1f" % [PauseButton.CIRCLE_RADIUS, PauseButton.OUTLINE_WIDTH])
	_check("пауза: круг с контуром влезает в зону тапа 48×48",
		PauseButton.CIRCLE_RADIUS + PauseButton.OUTLINE_WIDTH * 0.5
		<= PauseButton.TOUCH_SIZE.x * 0.5,
		"%.1f при половине зоны %.1f" % [
			PauseButton.CIRCLE_RADIUS + PauseButton.OUTLINE_WIDTH * 0.5,
			PauseButton.TOUCH_SIZE.x * 0.5])

	# Полоса HP босса: Frame (кремовый контур) > Back (тёмная подложка) > Fill (DANGER).
	hud.show_boss(120, 120)
	_check("полоса босса: show_boss(120,120) показывает бар", hud.boss_bar.visible)
	_check("полоса босса: 360×16",
		hud.boss_bar.size.is_equal_approx(Vector2(Hud.BOSS_BAR_WIDTH, Hud.BOSS_BAR_HEIGHT)),
		str(hud.boss_bar.size))
	var frame := hud.boss_bar.get_node_or_null(^"Frame") as ColorRect
	var back := hud.boss_bar.get_node_or_null(^"Back") as ColorRect
	var fill := hud.boss_bar.get_node_or_null(^"Fill") as ColorRect
	_check("полоса босса: Frame/Back/Fill существуют",
		frame != null and back != null and fill != null)
	_check("полоса босса: публичные boss_bar/boss_fill — те же узлы",
		hud.boss_bar == hud.get_node(^"BossBar") and fill != null and hud.boss_fill == fill)
	if frame != null and back != null and fill != null:
		_check("полоса босса: Frame больше Back по обеим осям",
			frame.size.x > back.size.x and frame.size.y > back.size.y,
			"frame %s / back %s" % [frame.size, back.size])
		_check("полоса босса: Fill внутри Back (не залезает на контур)",
			_rect_inside(Rect2(fill.position, fill.size), Rect2(back.position, back.size)),
			"fill %s / back %s" % [Rect2(fill.position, fill.size), Rect2(back.position, back.size)])
	var full_width := hud.boss_fill.size.x
	_check("полоса босса: заливка на 100% = 354 px (внутри контура 2 px)",
		is_equal_approx(full_width, Hud.BOSS_FILL_MAX_WIDTH), str(full_width))
	hud.set_boss_hp(60)
	var half_width := hud.boss_fill.size.x
	_check("полоса босса: 60/120 HP ≈ половина заливки (±2 px)",
		full_width > 0.0 and absf(half_width - full_width * 0.5) <= 2.0,
		"%.1f px при максимуме %.1f px" % [half_width, full_width])
	hud.hide_boss()
	_check("полоса босса: hide_boss скрывает бар", not hud.boss_bar.visible)

	# Состояние HUD после проверок — как после старта (иначе следующие тесты увидят чужой HP).
	hud.set_hp(_level.player.hp)
	hud.set_score(_level.get_score())


# ─── M3-A: раскладка HUD на поле 540×960 ─────────────────────────────────────
func _check_hud_layout() -> void:
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var hp_rect := _level.hud.hp_label.get_global_rect()
	var score_rect := _level.hud.score_label.get_global_rect()
	var pause_rect := _level.pause_button.get_global_rect()
	var boss_rect := _level.hud.boss_bar.get_global_rect()
	var bomb_rect := _level.bomb_button.get_global_rect()

	_check("раскладка: HPLabel в поле 540×960", _rect_inside(hp_rect, field), str(hp_rect))
	_check("раскладка: ScoreLabel в поле 540×960", _rect_inside(score_rect, field), str(score_rect))
	_check("раскладка: PauseButton в поле 540×960", _rect_inside(pause_rect, field), str(pause_rect))
	_check("раскладка: BossBar в поле 540×960", _rect_inside(boss_rect, field), str(boss_rect))
	_check("раскладка: BombButton в поле 540×960", _rect_inside(bomb_rect, field), str(bomb_rect))

	_check("раскладка: HPLabel не пересекается со ScoreLabel",
		not _rects_overlap(hp_rect, score_rect), "%s × %s" % [hp_rect, score_rect])
	_check("раскладка: HPLabel не пересекается с PauseButton",
		not _rects_overlap(hp_rect, pause_rect), "%s × %s" % [hp_rect, pause_rect])
	_check("раскладка: ScoreLabel не пересекается с PauseButton",
		not _rects_overlap(score_rect, pause_rect),
		"зазор %.0f px" % (pause_rect.position.x - score_rect.end.x))
	# Полоса босса — второй ряд HUD: обязана идти ниже строки HP, а не поверх неё.
	_check("раскладка: BossBar ниже HPLabel",
		boss_rect.position.y >= hp_rect.end.y,
		"bar.y=%.0f / hp.bottom=%.0f" % [boss_rect.position.y, hp_rect.end.y])
	_check("раскладка: BossBar по центру поля",
		absf(boss_rect.get_center().x - field.get_center().x) <= 1.0,
		"центр %.1f" % boss_rect.get_center().x)
	_check("раскладка: BombButton в правом нижнем углу",
		bomb_rect.get_center().x > field.end.x * 0.75
		and bomb_rect.get_center().y > field.end.y * 0.75,
		str(bomb_rect))
	_check("раскладка: BombButton не перекрывает верхний ряд HUD",
		not _rects_overlap(bomb_rect, hp_rect) and not _rects_overlap(bomb_rect, score_rect))


# ─── M3-A: шрифт темы реально доходит до Label оверлеев и HUD ────────────────
func _check_ui_fonts_applied() -> void:
	var hud := _level.hud
	var death_title := _level.death_overlay.get_node(^"Title") as Label
	var win_title := _level.win_overlay.get_node(^"Title") as Label
	var pause_title := _level.pause_overlay.get_node(^"Title") as Label

	_check("шрифт: HPLabel получает шрифт темы и покрывает «HP 3/3»",
		_label_font_covers(hud.hp_label, "NotoSans-Regular.ttf"), _label_font_details(hud.hp_label))
	_check("шрифт: ScoreLabel получает шрифт темы и покрывает «Счёт: 0»",
		_label_font_covers(hud.score_label, "NotoSans-Regular.ttf"),
		_label_font_details(hud.score_label))
	_check("шрифт: HUD рисует размером 24 px",
		hud.hp_label.get_theme_font_size(&"font_size") == UI_FONT_SIZE
		and hud.score_label.get_theme_font_size(&"font_size") == UI_FONT_SIZE,
		"%d / %d px" % [
			hud.hp_label.get_theme_font_size(&"font_size"),
			hud.score_label.get_theme_font_size(&"font_size")])

	_check("шрифт: заголовок поражения — Bold 48 и покрывает текст",
		_label_font_covers(death_title, "NotoSans-Bold.ttf")
		and death_title.get_theme_font_size(&"font_size") == UI_TITLE_FONT_SIZE,
		_label_font_details(death_title))
	_check("шрифт: заголовок победы — Bold 48 и покрывает текст",
		_label_font_covers(win_title, "NotoSans-Bold.ttf")
		and win_title.get_theme_font_size(&"font_size") == UI_TITLE_FONT_SIZE,
		_label_font_details(win_title))
	_check("шрифт: заголовок паузы — Bold 48 и покрывает текст",
		_label_font_covers(pause_title, "NotoSans-Bold.ttf")
		and pause_title.get_theme_font_size(&"font_size") == UI_TITLE_FONT_SIZE,
		_label_font_details(pause_title))

	var stars_line := _level.win_overlay.get_node(^"StarsLine") as Label
	var stars_font := stars_line.get_theme_font(&"font") if stars_line != null else null
	_check("шрифт: строка звёзд читается Regular (пиксельные иконки не зависят от шрифта)",
		stars_font != null
		and String(stars_font.resource_path).ends_with("NotoSans-Regular.ttf"),
		"шрифт null" if stars_font == null else String(stars_font.resource_path))
	_check("шрифт: строки победы (счёт/время/рекорд/снабжение) читаются Regular",
		_label_font_covers(_level.win_overlay.get_node(^"ScoreLine") as Label, "NotoSans-Regular.ttf")
		and _label_font_covers(_level.win_overlay.get_node(^"TimeLine") as Label, "NotoSans-Regular.ttf")
		and _label_font_covers(_level.win_overlay.get_node(^"RecordLine") as Label, "NotoSans-Regular.ttf")
		and _label_font_covers(_level.win_overlay.get_node(^"SupplyLine") as Label, "NotoSans-Regular.ttf"))


# ─── M11/T2–T5: регресс-гейт «шорткатов нет, кнопки экранов живы» ───────────
## Один блок на все экраны исхода/паузы (M11/T7). Проверяет то, что владелец нашёл на
## устройстве: в WON/DEAD/PAUSED касание свободного места больше ничего не делает (у
## LevelController нет _unhandled_input), ни на одном экране нет узла Hint и текста «Тап…»,
## у экрана поражения есть ТРИ реальные кнопки 320×88, звёзды на победе рисует только
## пиксельный ряд, а модельки выросли на 25 % без изменения хитбоксов.
func _check_overlay_shortcuts() -> void:
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	# 1) Шорткаты удалены из контроллера целиком: рестарт/выход — только кнопки.
	_check("шорткаты: у LevelController больше нет _unhandled_input",
		not _level.has_method("_unhandled_input"))

	# 2) Ни одного узла Hint и ни одной строки «Тап…» на трёх экранах (решение D4).
	var overlays: Array[Control] = [_level.win_overlay, _level.death_overlay, _level.pause_overlay]
	var hint_nodes: Array[String] = []
	var tap_texts: Array[String] = []
	for overlay: Control in overlays:
		for node: Node in _all_descendants(overlay):
			if String(node.name) == "Hint":
				hint_nodes.append("%s/%s" % [overlay.name, node.name])
			var label := node as Label
			if label != null and String(label.text).contains("Тап"):
				tap_texts.append("%s: «%s»" % [overlay.name, label.text])
	_check("шорткаты: ни в одном оверлее (победа/поражение/пауза) нет узла Hint",
		hint_nodes.is_empty(), str(hint_nodes))
	_check("шорткаты: нет текстов «Тап — рестарт»/«Тап — повторить»/«Тап, чтобы продолжить»",
		tap_texts.is_empty(), str(tap_texts))

	# 3) Экран поражения (решение D3): три реальных действия вместо удалённого тап-рестарта.
	_level.death_overlay.show_overlay()
	_check("экран поражения: три действия «Повторить»/«Кампания»/«В ангар»",
		_level.death_overlay.get_visible_action_button_count() == 3
		and String(_level.death_overlay.replay_button.text) == "Повторить"
		and String(_level.death_overlay.campaign_button.text) == "Кампания"
		and String(_level.death_overlay.home_button.text) == "В ангар",
		"кнопок %d" % _level.death_overlay.get_visible_action_button_count())
	_check_screen_buttons("экран поражения", [
		_level.death_overlay.replay_button,
		_level.death_overlay.campaign_button,
		_level.death_overlay.home_button,
	])
	# Скрытый слот rewarded-revive (M8b) остаётся и не перекрывает новые кнопки.
	_check("экран поражения: скрытый слот revive не перекрывает кнопки исхода",
		not _level.death_overlay.is_revive_visible()
		and not _rects_overlap(_level.death_overlay.revive_button.get_global_rect(),
			_level.death_overlay.replay_button.get_global_rect()),
		str(_level.death_overlay.revive_button.get_global_rect()))
	_level.death_overlay.hide_overlay()
	_check("экран поражения: после скрытия кнопок нет (следующий показ включит снова)",
		_level.death_overlay.get_visible_action_button_count() == 0)

	# 4) Экран победы: те же три кнопки; раньше они были «мёртвыми» (баг M11/T1).
	_level.win_overlay.show_result(0, 0.0, 0, false, 0, 0)
	_check("экран победы: три действия, «Повторить» на месте",
		_level.win_overlay.get_visible_action_button_count() == 3
		and String(_level.win_overlay.replay_button.text) == "Повторить",
		"кнопок %d" % _level.win_overlay.get_visible_action_button_count())
	_check_screen_buttons("экран победы", [
		_level.win_overlay.replay_button,
		_level.win_overlay.campaign_button,
		_level.win_overlay.home_button,
	])
	_level.win_overlay.hide_overlay()

	# 5) Экран паузы: три кнопки; «Продолжить» — единственный путь снятия паузы.
	_level.pause_overlay.show_overlay()
	_check("экран паузы: три действия «Продолжить»/«Заново»/«В ангар»",
		_level.pause_overlay.get_parent() != null
		and String(_level.pause_overlay.resume_button.text) == "Продолжить"
		and String(_level.pause_overlay.restart_button.text) == "Заново"
		and String(_level.pause_overlay.home_button.text) == "В ангар")
	_check_screen_buttons("экран паузы", [
		_level.pause_overlay.resume_button,
		_level.pause_overlay.restart_button,
		_level.pause_overlay.home_button,
	])
	_level.pause_overlay.hide_overlay()

	# 6) Брифинг: текст условия endless удалён (D7), гейт по звёздам жив.
	var briefing := _level.briefing
	_check("брифинг: узла EndlessHint (текст условия) больше нет, гейт закрыт на 0 звёзд",
		briefing.get_node_or_null(^"EndlessHint") == null
		and not briefing.is_endless_enabled() and briefing.endless_button.disabled,
		"enabled=%s, disabled=%s" % [
			briefing.is_endless_enabled(), briefing.endless_button.disabled])

	# 7) Данные: в блоке result остались только два заголовка (D4).
	var missions_raw := FileAccess.get_file_as_string("res://data/missions.json")
	var parsed: Variant = JSON.parse_string(missions_raw)
	var result_keys: Array[String] = []
	if parsed is Dictionary:
		for mission: Variant in (parsed as Dictionary).get("missions", []):
			var block: Dictionary = (mission as Dictionary).get("result", {})
			var keys := block.keys()
			keys.sort()
			result_keys.append(",".join(PackedStringArray(keys)))
	_check("данные: в result всех трёх миссий только lose_title/win_title",
		MissionData.RESULT_KEYS == ["win_title", "lose_title"]
		and result_keys.size() == 3 and result_keys.count("lose_title,win_title") == 3,
		str(result_keys))
	_check("данные: MissionData.validate() пуст",
		MissionData.validate().is_empty(), str(MissionData.validate()))

	# 8) M11/T5 (решение D1): рисуем на 25 % крупнее, хитбоксы (SIZES) не тронуты.
	var plane_keys: Array[StringName] = [
		ArtStyle.KEY_PLAYER_LA5, ArtStyle.KEY_PLAYER_YAK3, ArtStyle.KEY_PLAYER_P39,
		ArtStyle.KEY_ENEMY_BF109, ArtStyle.KEY_ENEMY_JU87, ArtStyle.KEY_ENEMY_FW190,
		ArtStyle.KEY_ENEMY_BF110, ArtStyle.KEY_BOSS_HE111, ArtStyle.KEY_BOSS_JU88,
		ArtStyle.KEY_BOSS_FW200,
	]
	var scale_ok := is_equal_approx(ArtStyle.DRAW_SCALE, 1.25)
	for key: StringName in plane_keys:
		scale_ok = scale_ok \
			and ArtStyle.draw_size_of(key).is_equal_approx(ArtStyle.size_of(key) * 1.25)
	_check("модельки: draw_size_of = size_of × 1.25 для всех 10 ключей самолётов",
		scale_ok, "DRAW_SCALE=%.2f" % ArtStyle.DRAW_SCALE)
	_check("модельки: хитбоксы не изменились (игрок 48, Bf 109 40, Ju 87 48)",
		ArtStyle.size_of(ArtStyle.KEY_PLAYER_LA5).is_equal_approx(Vector2(48.0, 48.0))
		and ArtStyle.size_of(ArtStyle.KEY_ENEMY_BF109).is_equal_approx(Vector2(40.0, 40.0))
		and ArtStyle.size_of(ArtStyle.KEY_ENEMY_JU87).is_equal_approx(Vector2(48.0, 48.0)),
		"%s / %s / %s" % [
			ArtStyle.size_of(ArtStyle.KEY_PLAYER_LA5),
			ArtStyle.size_of(ArtStyle.KEY_ENEMY_BF109),
			ArtStyle.size_of(ArtStyle.KEY_ENEMY_JU87)])


## Геометрия кнопок экрана исхода/паузы: три кнопки 320×88 (тач-минимум 64) внутри поля,
## без наложений, центр поля (270,480) свободен — тап там ничего не нажимает (M11/T2/T3).
func _check_screen_buttons(screen_name: String, buttons: Array) -> void:
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var center := Vector2(270.0, 480.0)
	var rects: Array[Rect2] = []
	var sizes_ok := true
	var inside_ok := true
	var centre_free := true
	for button: Button in buttons:
		var rect := button.get_global_rect()
		rects.append(rect)
		sizes_ok = sizes_ok and button.visible \
			and is_equal_approx(rect.size.x, 320.0) and is_equal_approx(rect.size.y, 88.0) \
			and rect.size.y >= DeathOverlay.BUTTON_MIN_HEIGHT
		inside_ok = inside_ok and _rect_inside(rect, field)
		centre_free = centre_free and not rect.has_point(center)
	var overlap := false
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if _rects_overlap(rects[i], rects[j]):
				overlap = true
	_check("%s: три кнопки 320×88 (тач-минимум 64) внутри поля 540×960" % screen_name,
		rects.size() == 3 and sizes_ok and inside_ok, str(rects))
	_check("%s: кнопки не перекрывают друг друга" % screen_name, not overlap, str(rects))
	_check("%s: центр поля (270,480) свободен — тап там ничего не нажимает" % screen_name,
		centre_free, str(center))


## Все потомки узла в глубину — проверка «нет узла Hint / нет текста Тап».
func _all_descendants(root: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in root.get_children():
		result.append(child)
		result.append_array(_all_descendants(child))
	return result


# ─── Гейт M3-B: брифинг при запуске приложения ───────────────────────────────
## Брифинг проверяется на ОТДЕЛЬНОМ инстансе main до _boot_level: основной _level ещё не
## создан, поэтому тапы в брифинге не задевают чужого игрока/кнопки. _boot_level затем
## проходит тот же путь на новом инстансе — это же и проверка «новый запуск = новый брифинг».
func _check_briefing_screen() -> void:
	var brief: LevelController = MAIN_SCENE.instantiate()
	add_child(brief)
	await get_tree().process_frame
	await get_tree().physics_frame

	# ── M8c1: запуск приложения показывает домашний экран-хаб, не брифинг ────
	# Брифинг открывается публичным begin_briefing() (тот же путь, что «Кампания →
	# миссия»); все проверки брифинга ниже не изменились.
	_check("старт: при запуске показан Home (брифинг скрыт), состояние BRIEFING",
		brief.get_state() == LevelController.State.BRIEFING
		and brief.home.visible and not brief.briefing.visible,
		"state=%d, home=%s, briefing=%s" % [brief.get_state(),
			brief.home.visible, brief.briefing.visible])
	brief.begin_briefing()
	await get_tree().process_frame
	# ── Экран до старта: забега ещё нет ─────────────────────────────────────
	_check("брифинг: оверлей видим, HUD/бомба/пауза скрыты",
		brief.briefing.visible
		and not brief.hud.visible
		and not brief.bomb_button.visible
		and not brief.pause_button.visible,
		"briefing=%s, hud=%s, bomb=%s, pause=%s" % [
			brief.briefing.visible, brief.hud.visible,
			brief.bomb_button.visible, brief.pause_button.visible])
	_check("брифинг: оверлеи исхода/паузы и подсказки скрыты",
		not brief.death_overlay.visible and not brief.win_overlay.visible
		and not brief.pause_overlay.visible
		and not brief.hints.visible and not brief.hints.is_showing())
	_check("брифинг: волны не запущены",
		not brief.waves.is_active() and brief.waves.get_wave_index() == -1,
		"active=%s, wave=%d" % [brief.waves.is_active(), brief.waves.get_wave_index()])
	_check("брифинг: таймер 0, бомба 1, счёт 0",
		brief.get_elapsed() == 0.0 and brief.get_bombs() == 1 and brief.get_score() == 0,
		"%.2f с, бомб %d, счёт %d" % [
			brief.get_elapsed(), brief.get_bombs(), brief.get_score()])
	_check("брифинг: в мире нет врагов и подборов",
		brief.enemies_root.get_child_count() == 0 and brief.get_pickup_count() == 0,
		"врагов %d, подборов %d" % [
			brief.enemies_root.get_child_count(), brief.get_pickup_count()])
	_check("брифинг: игрок на START_POSITION, но без process/ввода",
		brief.player.position == Player.START_POSITION
		and not brief.player.is_processing()
		and not brief.player.is_processing_unhandled_input(),
		"%s, process=%s, input=%s" % [
			brief.player.position, brief.player.is_processing(),
			brief.player.is_processing_unhandled_input()])
	# M3-C: брифинг — ещё не забег, рекорд не читается и не пишется.
	_check("рекорд: в BRIEFING файл рекорда не создаётся",
		not FileAccess.file_exists(_record_path), _record_path)
	# BRIEFING добавлен ПЕРВЫМ. В коде состояний нет числовых сравнений (grep: только
	# символьные ==/!=/match), но тест фиксирует порядок — сдвиг значений заметят сразу.
	_check("брифинг: BRIEFING = 0, PLAYING = 1 (числовых сравнений State в коде нет)",
		LevelController.State.BRIEFING == 0 and LevelController.State.PLAYING == 1
		and LevelController.State.PAUSED == 2 and LevelController.State.DEAD == 3
		and LevelController.State.WON == 4,
		"BRIEFING=%d, PLAYING=%d" % [
			LevelController.State.BRIEFING, LevelController.State.PLAYING])

	# ── Тексты брифинга (GDD «First 30 seconds») ────────────────────────────
	var title := brief.briefing.get_node(^"Title") as Label
	var line1 := brief.briefing.get_node(^"Line1") as Label
	var line2 := brief.briefing.get_node(^"Line2") as Label
	var line3 := brief.briefing.get_node(^"Line3") as Label
	var start_button := brief.briefing.start_button
	_check("брифинг: текст «Оборона аэродрома»",
		title != null and String(title.text) == "Оборона аэродрома",
		String(title.text) if title != null else "Title отсутствует")
	_check("брифинг: текст «1943 год. Восточный фронт.»",
		line1 != null and String(line1.text) == "1943 год. Восточный фронт.",
		String(line1.text) if line1 != null else "Line1 отсутствует")
	_check("брифинг: текст «Немецкая авиация идёт бомбить аэродром.»",
		line2 != null and String(line2.text) == "Немецкая авиация идёт бомбить аэродром.",
		String(line2.text) if line2 != null else "Line2 отсутствует")
	_check("брифинг: текст «Перехвати He 111 до бомбардировки.»",
		line3 != null and String(line3.text) == "Перехвати He 111 до бомбардировки.",
		String(line3.text) if line3 != null else "Line3 отсутствует")
	_check("брифинг: кнопка «В бой»",
		start_button != null and String(start_button.text) == "В бой",
		String(start_button.text) if start_button != null else "StartButton отсутствует")
	_check("брифинг: заголовок Bold, строки Regular, все покрывают кириллицу",
		_label_font_covers(title, "NotoSans-Bold.ttf")
		and _label_font_covers(line1, "NotoSans-Regular.ttf")
		and _label_font_covers(line2, "NotoSans-Regular.ttf")
		and _label_font_covers(line3, "NotoSans-Regular.ttf"),
		"%s / %s / %s / %s" % [
			_label_font_details(title), _label_font_details(line1),
			_label_font_details(line2), _label_font_details(line3)])
	var button_font := start_button.get_theme_font(&"font")
	_check("брифинг: шрифт кнопки покрывает «В бой»",
		_font_covers(button_font, String(start_button.text)),
		"шрифт без глифов" if button_font != null else "шрифт кнопки null")

	# ── Раскладка кнопки и текста на поле 540×960 ───────────────────────────
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var button_rect := start_button.get_global_rect()
	_check("брифинг: кнопка «В бой» внутри поля 540×960",
		_rect_inside(button_rect, field), str(button_rect))
	_check("брифинг: кнопка не ниже тач-минимума 88 px",
		button_rect.size.y >= 88.0 and button_rect.size.x >= 88.0,
		"%.0f×%.0f px" % [button_rect.size.x, button_rect.size.y])
	_check("брифинг: кнопка по центру поля",
		absf(button_rect.get_center().x - field.get_center().x) <= 1.0,
		"центр %.1f px" % button_rect.get_center().x)
	var text_rects: Array[Rect2] = [
		title.get_global_rect(), line1.get_global_rect(),
		line2.get_global_rect(), line3.get_global_rect(),
	]
	var text_hit := false
	var line_width_max := 0.0
	for rect: Rect2 in text_rects:
		if _rects_overlap(button_rect, rect):
			text_hit = true
	_check("брифинг: кнопка не перекрывает ни одну строку брифинга", not text_hit,
		str(button_rect))
	var lines_overlap := false
	for i in text_rects.size():
		for j in range(i + 1, text_rects.size()):
			if _rects_overlap(text_rects[i], text_rects[j]):
				lines_overlap = true
	_check("брифинг: строки не накладываются друг на друга", not lines_overlap)
	for label: Label in [title, line1, line2, line3]:
		line_width_max = maxf(line_width_max, _label_text_width(label))
	_check("брифинг: каждая строка влезает в ширину поля 540",
		line_width_max <= field.size.x, "%.1f px" % line_width_max)
	# M3-C minor: body брифинга — 22 px, и реальная ширина строки влезает в поле
	# с боковыми полями 24 px (запас по краям, иначе буквы липнут к рамке экрана).
	var body_font_ok := true
	var body_width_max := 0.0
	for body: Label in [line1, line2, line3]:
		body_font_ok = body_font_ok and body.get_theme_font_size(&"font_size") == BRIEFING_BODY_FONT_SIZE
		body_width_max = maxf(body_width_max, _label_text_width(body))
	_check("брифинг: body-строки 22 px", body_font_ok,
		"%d / %d / %d" % [
			line1.get_theme_font_size(&"font_size"),
			line2.get_theme_font_size(&"font_size"),
			line3.get_theme_font_size(&"font_size")])
	var body_content_width := GameConfig.REFERENCE_SIZE.x - 2.0 * BRIEFING_SIDE_MARGIN
	_check("брифинг: body-строки влезают в 540 − 2×24 = 492 px",
		body_width_max <= body_content_width,
		"%.1f px при лимите %.1f" % [body_width_max, body_content_width])

	var dim := brief.briefing.get_node(^"Dim") as ColorRect
	_check("брифинг: затемнение на всё поле и прозрачно для тапов",
		dim != null and _rect_inside(dim.get_global_rect(), field) and dim.color.a >= 0.4
		and dim.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"dim=%s, alpha=%.2f" % [dim.get_global_rect(), dim.color.a] if dim != null else "Dim нет")
	_check("брифинг: корень не перехватывает тапы мимо кнопки (IGNORE)",
		brief.briefing.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("брифинг: оверлей живёт ALWAYS (кнопка работает и при случайной паузе)",
		brief.briefing.process_mode == Node.PROCESS_MODE_ALWAYS)

	# ── Тап/драг мимо кнопки ничего не делают ───────────────────────────────
	var start_events: Array[int] = []
	var start_handler := func() -> void: start_events.append(1)
	brief.briefing.start_requested.connect(start_handler)
	var player_at := brief.player.position
	await _touch_down(0, Vector2(270.0, 520.0))
	await _touch_up(0, Vector2(270.0, 520.0))
	_check("брифинг: тап по затемнению мимо кнопки не стартует забег",
		brief.get_state() == LevelController.State.BRIEFING and start_events.is_empty(),
		"state=%d, стартов %d" % [brief.get_state(), start_events.size()])
	await _touch_down(0, Vector2(60.0, 720.0))
	await _touch_drag(0, Vector2(140.0, 700.0))
	await _touch_drag(0, Vector2(180.0, 760.0))
	await _touch_up(0, Vector2(180.0, 760.0))
	_check("брифинг: драг мимо кнопки не двигает Ла-5 и не стартует",
		brief.player.position == player_at
		and brief.get_state() == LevelController.State.BRIEFING
		and start_events.is_empty(),
		"игрок %s, state=%d, стартов %d" % [
			brief.player.position, brief.get_state(), start_events.size()])
	brief.pause_game()
	_check("брифинг: pause_game в BRIEFING не включается (гвард PLAYING)",
		brief.get_state() == LevelController.State.BRIEFING
		and not get_tree().paused and not brief.pause_overlay.visible,
		"state=%d, paused=%s" % [brief.get_state(), get_tree().paused])

	# ── Реальное касание «В бой»: ровно один старт ──────────────────────────
	await _touch_down(0, button_rect.get_center())
	await _touch_up(0, button_rect.get_center())
	await get_tree().process_frame
	_check("брифинг: касание «В бой» → PLAYING",
		brief.get_state() == LevelController.State.PLAYING, str(brief.get_state()))
	_check("брифинг: старт сработал ровно один раз (латч touch+pressed)",
		start_events.size() == 1, "стартов %d" % start_events.size())
	_check("брифинг: после старта брифинг скрыт, HUD/кнопки видимы",
		not brief.briefing.visible
		and brief.hud.visible and brief.bomb_button.visible and brief.pause_button.visible)
	_check("брифинг: после старта волна 1 заспавнена сразу (4 борта)",
		brief.waves.is_active() and brief.waves.get_wave_index() == 0
		and brief.enemies_root.get_child_count() == 4,
		"wave=%d, врагов %d" % [
			brief.waves.get_wave_index(), brief.enemies_root.get_child_count()])
	_check("брифинг: после старта игрок снова обрабатывает process/ввод",
		brief.player.is_processing() and brief.player.is_processing_unhandled_input())
	_check("брифинг: после старта таймер/бомба в стартовых значениях",
		brief.get_elapsed() < 0.25 and brief.get_bombs() == 1,
		"%.2f с, бомб %d" % [brief.get_elapsed(), brief.get_bombs()])
	_check("подсказки: первый забег показывает подсказки",
		brief.hints.visible and brief.hints.is_showing())
	# Повторный тап по месту скрытой кнопки не перезапускает уже идущий забег.
	await _touch_down(0, button_rect.get_center())
	await _touch_up(0, button_rect.get_center())
	_check("брифинг: тап по месту скрытой кнопки не перезапускает забег",
		brief.get_state() == LevelController.State.PLAYING
		and brief.waves.get_wave_index() == 0 and start_events.size() == 1,
		"state=%d, стартов %d" % [brief.get_state(), start_events.size()])

	# ── Подсказки: каскад 0 / 1.2 / 2.4 с, замирание на паузе ───────────────
	var hint1 := brief.hints.get_node(^"Hint1") as Control
	var hint2 := brief.hints.get_node(^"Hint2") as Control
	var hint3 := brief.hints.get_node(^"Hint3") as Control
	var hint1_shown: bool = await _wait_until(
		func() -> bool: return hint1.modulate.a > 0.9, 1.0)
	_check("подсказки: первая плашка проявляется сразу после старта",
		hint1_shown and hint1.visible, "alpha %.2f" % hint1.modulate.a)

	var hints_elapsed := brief.hints._elapsed
	var hint1_alpha := hint1.modulate.a
	var hint1_visible := hint1.visible
	brief.pause_game()
	_check("подсказки: пауза забега → PAUSED и дерево заморожено",
		brief.get_state() == LevelController.State.PAUSED and get_tree().paused)
	await get_tree().create_timer(0.5).timeout
	_check("подсказки: на паузе таймлайн замер (elapsed не растёт)",
		is_equal_approx(brief.hints._elapsed, hints_elapsed),
		"%.3f → %.3f" % [hints_elapsed, brief.hints._elapsed])
	_check("подсказки: на паузе alpha плашки не меняется",
		is_equal_approx(hint1.modulate.a, hint1_alpha) and hint1.visible == hint1_visible,
		"%.3f → %.3f" % [hint1_alpha, hint1.modulate.a])
	_check("подсказки: пауза их не прячет (гасит только исход)",
		brief.hints.visible and brief.hints.is_showing())
	_check("рекорд: пауза не создаёт файл рекорда",
		not FileAccess.file_exists(_record_path), _record_path)
	brief.resume_game()
	await get_tree().create_timer(0.25).timeout
	_check("подсказки: после resume таймлайн продолжается",
		brief.hints._elapsed > hints_elapsed + 0.15,
		"%.3f → %.3f" % [hints_elapsed, brief.hints._elapsed])
	var hint2_shown: bool = await _wait_until(func() -> bool: return hint2.visible, 2.0)
	var hint2_at := brief.hints._elapsed if hint2_shown else -1.0
	_check("подсказки: вторая плашка появляется на ~1.2 с",
		hint2_shown and hint2_at >= 1.15 and hint2_at <= 1.7, "%.2f с" % hint2_at)
	var hint3_shown: bool = await _wait_until(func() -> bool: return hint3.visible, 2.5)
	var hint3_at := brief.hints._elapsed if hint3_shown else -1.0
	_check("подсказки: третья плашка появляется на ~2.4 с",
		hint3_shown and hint3_at >= 2.35 and hint3_at <= 2.9, "%.2f с" % hint3_at)
	var all_three: bool = await _wait_until(
		func() -> bool: return hint3.modulate.a > 0.5, 0.5)
	_check("подсказки: к третьей плашке видны все три сразу",
		all_three and hint1.visible and hint2.visible and hint3.visible
		and hint2.modulate.a > 0.5,
		"%.2f с, alpha %.2f / %.2f / %.2f" % [
			brief.hints._elapsed, hint1.modulate.a, hint2.modulate.a, hint3.modulate.a])

	# ── M3-C minor: fade-out гасит плашку целиком (без полупрозрачного «призрака») ──
	# Таймлайн первой плашки: 0.18 fade-in + 2.5 hold + 0.35 fade-out ≈ 3.03 с.
	var ghost_gone: bool = await _wait_until(func() -> bool: return not hint1.visible, 2.0)
	_check("подсказки: после fade-out плашка скрыта целиком (visible=false)",
		ghost_gone and not hint1.visible
		and hint1.modulate.a < HintsOverlay.GHOST_ALPHA_THRESHOLD,
		"visible=%s, alpha %.3f" % [hint1.visible, hint1.modulate.a])
	_check("подсказки: гаснет только первая, вторая ещё читается",
		hint2.visible and hint2.modulate.a > 0.5,
		"visible=%s, alpha %.2f" % [hint2.visible, hint2.modulate.a])

	# ── Исход гасит подсказки; рестарт их не повторяет ──────────────────────
	brief.player._invulnerability_left = 0.0
	brief.player.take_hit(Player.MAX_HP)
	await get_tree().process_frame
	_check("подсказки: при исходе (DEAD) сразу скрыты",
		brief.get_state() == LevelController.State.DEAD
		and not brief.hints.visible and not brief.hints.is_showing(),
		"state=%d, visible=%s" % [brief.get_state(), brief.hints.visible])
	var death_shown: bool = await _wait_until(
		func() -> bool: return brief.death_overlay.visible and get_tree().paused, 2.0)
	_check("брифинг/подсказки: экран «Аэродром потерян» показан", death_shown)
	_check("рекорд: поражение не создаёт файл рекорда",
		not FileAccess.file_exists(_record_path), _record_path)
	# M11/T2: экран поражения рестартит только кнопка «Повторить» — тап по свободному
	# месту не меняет состояние и не прячет экран.
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	await get_tree().process_frame
	_check("рестарт после DEAD: тап по свободному месту ничего не делает",
		brief.get_state() == LevelController.State.DEAD and brief.death_overlay.visible,
		"state=%d, overlay=%s" % [brief.get_state(), brief.death_overlay.visible])
	_check("рестарт после DEAD: кнопка «Повторить» доступна",
		brief.death_overlay.request_replay())
	await get_tree().process_frame
	_check("рестарт после DEAD: PLAYING, брифинг скрыт",
		brief.get_state() == LevelController.State.PLAYING and not brief.briefing.visible,
		"state=%d, briefing=%s" % [brief.get_state(), brief.briefing.visible])
	_check("рестарт после DEAD: подсказки не повторяются",
		not brief.hints.is_showing() and not brief.hints.visible)
	await get_tree().create_timer(0.4).timeout
	_check("рестарт после DEAD: через 0.4 с подсказок всё ещё нет",
		not brief.hints.is_showing() and not brief.hints.visible)

	brief.stop_waves()
	await get_tree().process_frame
	for child in brief.enemies_root.get_children():
		child.queue_free()
	brief.bullets.clear_all()
	await get_tree().process_frame
	brief.player.grant_invulnerability(999.0)
	var boss := brief.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 200.0))
	boss.set_physics_process(false)
	await get_tree().process_frame
	boss.take_damage(9999)
	await get_tree().process_frame
	_check("брифинг/подсказки: гибель босса → WON",
		brief.get_state() == LevelController.State.WON, str(brief.get_state()))
	var win_shown: bool = await _wait_until(
		func() -> bool: return brief.win_overlay.visible and get_tree().paused, 2.0)
	_check("брифинг/подсказки: экран «Аэродром спасён» показан", win_shown)
	# M3-C: победа засчитывает рекорд ПОСЛЕ бонуса за HP, оверлей получает best/is_new.
	_check("рекорд: победа записала ровно итоговый счёт (после HP-бонуса)",
		win_shown and _read_record_best() == brief.get_score(),
		"файл %d, счёт %d" % [_read_record_best(), brief.get_score()])
	_check("рекорд: на экране победы «Новый рекорд: N»",
		String((brief.win_overlay.get_node(^"RecordLine") as Label).text)
		== "Новый рекорд: %d" % brief.get_score(),
		String((brief.win_overlay.get_node(^"RecordLine") as Label).text))
	# Победа: тоже только кнопкой «Повторить» (M11/T2).
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	await get_tree().process_frame
	_check("рестарт после WON: тап по свободному месту ничего не делает",
		brief.get_state() == LevelController.State.WON and brief.win_overlay.visible,
		"state=%d, overlay=%s" % [brief.get_state(), brief.win_overlay.visible])
	_check("рестарт после WON: кнопка «Повторить» доступна",
		brief.win_overlay.request_replay())
	await get_tree().process_frame
	_check("рестарт после WON: PLAYING, брифинг скрыт",
		brief.get_state() == LevelController.State.PLAYING and not brief.briefing.visible,
		"state=%d, briefing=%s" % [brief.get_state(), brief.briefing.visible])
	_check("рестарт после WON: подсказки не повторяются",
		not brief.hints.is_showing() and not brief.hints.visible)

	brief.queue_free()
	await get_tree().process_frame


# ─── Гейт M3-B: подсказки первого забега (тексты, ввод, раскладка) ──────────
## Геометрия и ввод подсказок проверяются на основном _level сразу после старта: таймлайн
## ещё жив (гашение на паузе/исходе и повторный запуск — в _check_briefing_screen).
func _check_hints_overlay() -> void:
	var hints := _level.hints
	var hint1 := hints.get_node(^"Hint1") as Panel
	var hint2 := hints.get_node(^"Hint2") as Panel
	var hint3 := hints.get_node(^"Hint3") as Panel
	var label1 := hint1.get_node(^"Text") as Label
	var label2 := hint2.get_node(^"Text") as Label
	var label3 := hint3.get_node(^"Text") as Label

	_check("подсказки: текст «Веди пальцем»", String(label1.text) == "Веди пальцем",
		String(label1.text))
	_check("подсказки: текст «Стрельба автоматическая»",
		String(label2.text) == "Стрельба автоматическая", String(label2.text))
	_check("подсказки: текст «Бомба — справа снизу»",
		String(label3.text) == "Бомба — справа снизу", String(label3.text))
	_check("подсказки: показаны в первом забеге", hints.visible and hints.is_showing())
	_check("подсказки: шрифт плашек покрывает кириллицу",
		_label_font_covers(label1, "NotoSans-Regular.ttf")
		and _label_font_covers(label2, "NotoSans-Regular.ttf")
		and _label_font_covers(label3, "NotoSans-Regular.ttf"),
		"%s / %s / %s" % [
			_label_font_details(label1), _label_font_details(label2),
			_label_font_details(label3)])
	_check("подсказки: корень, плашки и текст прозрачны для ввода (IGNORE)",
		hints.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and hint1.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and hint2.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and hint3.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and label1.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and label2.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and label3.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("подсказки: PAUSABLE — таймлайн замирает вместе с миром",
		hints.process_mode == Node.PROCESS_MODE_PAUSABLE, str(hints.process_mode))

	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var player_zone := Rect2(Player.START_POSITION - Vector2(24.0, 24.0), Vector2(48.0, 48.0))
	var bomb_rect := _level.bomb_button.get_global_rect()
	var plates: Array[Panel] = [hint1, hint2, hint3]
	var inside := true
	var over_player := false
	var over_bomb := false
	for plate: Panel in plates:
		var rect := plate.get_global_rect()
		inside = inside and _rect_inside(rect, field)
		over_player = over_player or _rects_overlap(rect, player_zone)
		over_bomb = over_bomb or _rects_overlap(rect, bomb_rect)
	_check("подсказки: все плашки внутри поля 540×960", inside)
	_check("подсказки: плашки не перекрывают Ла-5 на старте (зона y≈840)", not over_player,
		"зона %s" % str(player_zone))
	_check("подсказки: плашки не перекрывают кнопку бомбы", not over_bomb,
		"bomb %s" % str(bomb_rect))
	_check("подсказки: плашки стоят друг под другом без наложений",
		not _rects_overlap(hint1.get_global_rect(), hint2.get_global_rect())
		and not _rects_overlap(hint2.get_global_rect(), hint3.get_global_rect()))

	# Ввод не перехватывается: драг, начатый НА плашке, ведёт самолёт.
	var before := _level.player.position
	var plate_center := hint1.get_global_rect().get_center()
	await _touch_down(0, plate_center)
	await _touch_drag(0, plate_center + Vector2(12.0, 0.0))
	await _touch_up(0, plate_center + Vector2(12.0, 0.0))
	_check("подсказки: драг по плашке ведёт Ла-5 (ввод не перехвачен)",
		_level.player.position.is_equal_approx(before + Vector2(12.0, 0.0)),
		"было %s, стало %s" % [before, _level.player.position])
	_level.player.position = Player.START_POSITION


func _boot_level() -> void:
	# M8b: smoke не пишет реальный user://analytics.log (число проверок не меняется).
	Analytics.set_enabled(false)
	# Единственный источник стартовой позиции — Player.START_POSITION: сцена не задаёт position.
	var probe_root := MAIN_SCENE.instantiate() as Node2D
	var probe_player := probe_root.get_node(^"World/Player") as Node2D
	_check("старт: позиция игрока не дублируется в main.tscn",
		probe_player.position == Vector2.ZERO, str(probe_player.position))
	probe_root.free()

	# Новый инстанс main = «новый запуск приложения»: здесь снова Home (M8c1), а не забег.
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	await get_tree().physics_frame

	# ── M3-B: при запуске приложения сначала Home (M8c1); брифинг открывается
	# публичным begin_briefing() — забега ещё нет ─────────────────────────────
	_check("старт: Home показан, брифинг скрыт, состояние BRIEFING",
		_level.get_state() == LevelController.State.BRIEFING
		and _level.home.visible and not _level.briefing.visible,
		"state=%d, home=%s, briefing=%s" % [_level.get_state(),
			_level.home.visible, _level.briefing.visible])
	_level.begin_briefing()
	await get_tree().process_frame
	_check("старт: брифинг показан, HUD/бомба/пауза скрыты",
		_level.briefing.visible
		and not _level.hud.visible
		and not _level.bomb_button.visible
		and not _level.pause_button.visible,
		"briefing=%s, hud=%s, bomb=%s, pause=%s" % [
			_level.briefing.visible, _level.hud.visible,
			_level.bomb_button.visible, _level.pause_button.visible])
	_check("старт: оверлеи исхода/паузы и подсказки скрыты",
		not _level.death_overlay.visible and not _level.win_overlay.visible
		and not _level.pause_overlay.visible
		and not _level.hints.visible and not _level.hints.is_showing())
	_check("старт: волны не запущены, врагов и подборов нет",
		not _level.waves.is_active() and _level.waves.get_wave_index() == -1
		and _enemy_count() == 0 and _level.get_pickup_count() == 0,
		"active=%s, wave=%d, врагов %d" % [
			_level.waves.is_active(), _level.waves.get_wave_index(), _enemy_count()])
	_check("старт: таймер 0, бомба 1, счёт 0",
		_level.get_elapsed() == 0.0 and _level.get_bombs() == 1 and _level.get_score() == 0,
		"%.2f с, бомб %d, счёт %d" % [
			_level.get_elapsed(), _level.get_bombs(), _level.get_score()])
	_check("старт: игрок на START_POSITION без process/ввода",
		_level.player.position == Player.START_POSITION
		and not _level.player.is_processing()
		and not _level.player.is_processing_unhandled_input(),
		"%s, process=%s, input=%s" % [
			_level.player.position, _level.player.is_processing(),
			_level.player.is_processing_unhandled_input()])

	# ── «В бой» → забег (тот же публичный путь, что у кнопки/start_requested) ─
	_level.start_level()
	await get_tree().process_frame
	await get_tree().physics_frame
	# M6.1b: выбор перка здесь не проверяется — оверлей не должен вставать на паузу
	# посреди E2E-прогона (UI выбора/пауза — в tests/perk_choice_test.tscn).
	_level.set_perks_enabled(false)
	_check("старт: после «В бой» состояние PLAYING",
		_level.get_state() == LevelController.State.PLAYING, str(_level.get_state()))
	_check("старт: брифинг скрыт, HUD/кнопки видимы",
		not _level.briefing.visible
		and _level.hud.visible and _level.bomb_button.visible and _level.pause_button.visible)
	_check("старт: подсказки первого забега показываются",
		_level.hints.visible and _level.hints.is_showing())

	_check("старт: игрок внизу по центру", _level.player.position == Player.START_POSITION,
		str(_level.player.position))
	_check("старт: 3 HP", _level.player.hp == 3, str(_level.player.hp))
	var player_shape := (_level.player.get_node(^"CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	_check("игрок: хитбокс r=8", is_equal_approx(player_shape.radius, Player.HIT_RADIUS),
		str(player_shape.radius))
	_check("старт: 1 бомба", _level.get_bombs() == 1, str(_level.get_bombs()))
	_check("старт: кнопка бомбы видима и активна",
		_level.bomb_button.visible and _level.bomb_button.get_charges() == 1)
	_check("старт: кнопка бомбы потребляет тач (STOP)",
		_level.bomb_button.mouse_filter == Control.MOUSE_FILTER_STOP)
	# GDD «Волны и враги»: волна 1 — 4 Bf 109.
	_check("старт: волна 1 = 4 Bf 109", _enemy_count() == 4 and _count_bf109() == 4,
		"врагов %d, Bf109 %d" % [_enemy_count(), _count_bf109()])
	_check("старт: менеджер волн активен, волна 1",
		_level.waves.is_active() and _level.waves.get_wave_index() == 0,
		str(_level.waves.get_wave_index()))
	_check("старт: экран поражения скрыт", not _level.death_overlay.visible)
	_check("старт: экран победы скрыт", not _level.win_overlay.visible)
	_check("старт: оверлей паузы скрыт", not _level.pause_overlay.visible)
	_check("экран поражения: текст «Аэродром потерян»",
		String((_level.death_overlay.get_node("Title") as Label).text) == "Аэродром потерян")
	# Заголовок длинный (17 символов вместо 4): он обязан влезать в поле 540 px, иначе края
	# экрана срезают буквы (замер — реальным шрифтом и реальным размером Label).
	var death_title := _level.death_overlay.get_node("Title") as Label
	var death_title_width := _label_text_width(death_title)
	_check("экран поражения: заголовок влезает в ширину поля 540",
		death_title_width <= GameConfig.REFERENCE_SIZE.x,
		"%.1f px при поле %.0f" % [death_title_width, GameConfig.REFERENCE_SIZE.x])
	# M11/T3 (решение D4): строки-подсказки «Тап — рестарт» больше нет — узел Hint удалён,
	# рестарт/выход дают три кнопки (проверяются в _check_overlay_shortcuts).
	_check("экран поражения: узла Hint (подсказка тапа) больше нет",
		_level.death_overlay.get_node_or_null(^"Hint") == null
		and _level.win_overlay.get_node_or_null(^"Hint") == null
		and _level.pause_overlay.get_node_or_null(^"Hint") == null)
	_check("экран победы: текст «Аэродром спасён»",
		String((_level.win_overlay.get_node("Title") as Label).text) == "Аэродром спасён")
	_check("HUD: HP и счёт на старте",
		String(_level.hud.hp_label.text) == "HP 3/3" and String(_level.hud.score_label.text) == "Счёт: 0",
		"%s / %s" % [_level.hud.hp_label.text, _level.hud.score_label.text])

	# Снаряд игрока: параметры из GDD «Игрок» (1 урон, 800 px/s вверх).
	var bullet_seen: Bullet = await _wait_player_bullet(1.0)
	_check("снаряд игрока: vel=(0,−800)",
		bullet_seen != null and bullet_seen.velocity.is_equal_approx(Vector2(0.0, -Player.BULLET_SPEED)),
		str(bullet_seen.velocity) if bullet_seen != null else "пуля не появилась")
	_check("снаряд игрока: dmg=1",
		bullet_seen != null and bullet_seen.damage == Player.BULLET_DAMAGE,
		str(bullet_seen.damage) if bullet_seen != null else "пуля не появилась")

	# M3-C minor: reset() обязан вернуть оба канала (process + unhandled_input) — иначе
	# рестарт/QA-сброс оставляют Ла-5 без управления (begin_briefing гасит их отдельно).
	_level.player.set_process(false)
	_level.player.set_process_unhandled_input(false)
	_level.player.reset(Player.START_POSITION)
	_check("игрок: reset() включает process и unhandled_input",
		_level.player.is_processing() and _level.player.is_processing_unhandled_input(),
		"process=%s, input=%s" % [
			_level.player.is_processing(), _level.player.is_processing_unhandled_input()])

	# На время проверок драга/стрельбы игрок не должен умирать от случайных пуль.
	_level.player.grant_invulnerability(999.0)


func _check_relative_drag() -> void:
	var start := _level.player.position

	# Касание в стороне от самолёта: палец не обязан быть на Ла-5.
	await _touch_down(0, Vector2(80.0, 600.0))
	await _touch_drag(0, Vector2(140.0, 570.0))
	await _touch_drag(0, Vector2(160.0, 565.0))
	await _touch_up(0, Vector2(160.0, 565.0))
	var expected := start + Vector2(80.0, -35.0)
	_check("драг: смещение пальца переносится 1:1", _level.player.position.is_equal_approx(expected),
		"ожидание %s, факт %s" % [expected, _level.player.position])

	# Отпустили — самолёт остался на месте.
	var after_release := _level.player.position
	await get_tree().process_frame
	_check("драг: после отпускания самолёт стоит", _level.player.position == after_release)

	# Новое касание в другом месте не тянет самолёт к пальцу.
	await _touch_down(0, Vector2(450.0, 200.0))
	await get_tree().process_frame
	_check("драг: новое касание не телепортирует самолёт",
		_level.player.position == after_release, str(_level.player.position))
	await _touch_drag(0, Vector2(410.0, 170.0))
	await _touch_up(0, Vector2(410.0, 170.0))
	var expected_second := after_release + Vector2(-40.0, -30.0)
	_check("драг: второй драг тоже относительный", _level.player.position.is_equal_approx(expected_second),
		"ожидание %s, факт %s" % [expected_second, _level.player.position])

	# Кламп границ: уводим палец за правый край.
	await _touch_down(0, Vector2(300.0, 500.0))
	await _touch_drag(0, Vector2(1200.0, 500.0))
	await _touch_up(0, Vector2(1200.0, 500.0))
	_check("драг: кламп по правому краю",
		is_equal_approx(_level.player.position.x, GameConfig.REFERENCE_SIZE.x - GameConfig.PLAYFIELD_MARGIN),
		str(_level.player.position))
	_check("драг: маржа клампа не обрезает крылья (26 px)",
		is_equal_approx(GameConfig.PLAYFIELD_MARGIN, 26.0), str(GameConfig.PLAYFIELD_MARGIN))

	# Возвращаем игрока под центр для дальнейших проверок.
	_level.player.position = Player.START_POSITION


func _check_autofire() -> void:
	_player_shots_spawned = 0
	_level.bullets.child_entered_tree.connect(_on_bullet_spawned)
	await get_tree().create_timer(1.0).timeout
	_level.bullets.child_entered_tree.disconnect(_on_bullet_spawned)
	# 8 выстрелов/с: за 1 с ожидаем 7–9 (первый выстрел идёт сразу на старте).
	_check("автострельба: ~8 выстрелов/с", _player_shots_spawned >= 7 and _player_shots_spawned <= 9,
		"выстрелов за 1 с: %d" % _player_shots_spawned)
	_check("автострельба: пули игрока создаются", _level.bullets.count_bullets() > 0)


## QA-замечание: без 60 Гц физики пуля 800 px/s проскакивала бы хитбокс за один тик.
func _check_bullet_tunneling_budget() -> void:
	var step := 1.0 / float(int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))
	var per_tick := Player.BULLET_SPEED * step
	var budget := Player.HIT_RADIUS + Player.HIT_RADIUS  # консервативная оценка зазора
	_check("туннелирование: шаг пули за тик меньше хитбокса", per_tick < budget,
		"%.1f px/тик при бюджете %.1f" % [per_tick, budget])


# ─── Таблица врагов (GDD «Волны и враги») ───────────────────────────────────
func _check_enemy_table() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()

	var bf := LevelController.ENEMY_BF109_SCENE.instantiate() as EnemyBase
	var ju := WaveManager.JU87_SCENE.instantiate() as EnemyBase
	var fw := WaveManager.FW190_SCENE.instantiate() as EnemyBase
	var boss := WaveManager.BOSS_SCENE.instantiate() as EnemyBase

	_check("таблица: Bf 109 — 4 HP / 100 очков / 1.2 с",
		bf.max_hp == 4 and bf.score_value == 100 and is_equal_approx(bf.fire_interval, 1.2),
		"%d HP, %d очк., %.2f с" % [bf.max_hp, bf.score_value, bf.fire_interval])
	_check("таблица: Ju 87 — 8 HP / 150 очков / 2.0 с",
		ju.max_hp == 8 and ju.score_value == 150 and is_equal_approx(ju.fire_interval, 2.0),
		"%d HP, %d очк., %.2f с" % [ju.max_hp, ju.score_value, ju.fire_interval])
	_check("таблица: Fw 190 — 12 HP / 300 очков / 1.5 с",
		fw.max_hp == 12 and fw.score_value == 300 and is_equal_approx(fw.fire_interval, 1.5),
		"%d HP, %d очк., %.2f с" % [fw.max_hp, fw.score_value, fw.fire_interval])
	_check("таблица: He 111 — 120 HP / 2000 очков / босс",
		boss.max_hp == 120 and boss.score_value == 2000 and boss.is_boss,
		"%d HP, %d очк., boss=%s" % [boss.max_hp, boss.score_value, boss.is_boss])
	# GDD «Волны и враги»: скорости движения 180 / 120 / 240 px/s (ревью #16).
	_check("таблица: скорости движения Bf 109 / Ju 87 / Fw 190 = 180 / 120 / 240",
		is_equal_approx(EnemyBf109.BF109_SPEED, 180.0)
		and is_equal_approx(EnemyJu87.JU87_SPEED, 120.0)
		and is_equal_approx(EnemyFw190.FW190_SPEED, 240.0),
		"%.0f / %.0f / %.0f" % [EnemyBf109.BF109_SPEED, EnemyJu87.JU87_SPEED, EnemyFw190.FW190_SPEED])
	# Гейт #8: GDD «Босс» — «прицельные ОЧЕРЕДИ», а не одиночный снаряд.
	_check("босс: прицельные очереди 2–3 снаряда с интервалом 0.10–0.15 с",
		BossHe111.AIMED_BURST_SHOTS >= 2 and BossHe111.AIMED_BURST_SHOTS <= 3
		and BossHe111.AIMED_BURST_INTERVAL >= 0.10 and BossHe111.AIMED_BURST_INTERVAL <= 0.15,
		"%d × %.2f с" % [BossHe111.AIMED_BURST_SHOTS, BossHe111.AIMED_BURST_INTERVAL])
	for type_data: Array in [[bf, "Bf 109"], [ju, "Ju 87"], [fw, "Fw 190"], [boss, "He 111"]]:
		var unit := type_data[0] as EnemyBase
		_check("таблица: %s — скорость пуль в 260–420" % type_data[1],
			unit.bullet_speed >= 260.0 and unit.bullet_speed <= 420.0, str(unit.bullet_speed))
	bf.free()
	ju.free()
	fw.free()
	boss.free()

	# Хитбоксы: 0.4×ширины силуэта и собственный (duplicate) shape на каждый инстанс.
	var a := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(150.0, 120.0))
	var b := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(240.0, 160.0))
	var c := _level.spawn_enemy(WaveManager.JU87_SCENE, Vector2(360.0, 120.0))
	a.set_physics_process(false)
	b.set_physics_process(false)
	c.set_physics_process(false)
	var shape_a := (a.get_node(^"CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	var shape_b := (b.get_node(^"CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	var shape_c := (c.get_node(^"CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	_check("хитбокс: Bf 109 = 0.4 × 40 = 16", is_equal_approx(shape_a.radius, 16.0), str(shape_a.radius))
	_check("хитбокс: Ju 87 = 0.4 × 48 = 19.2", is_equal_approx(shape_c.radius, 19.2), str(shape_c.radius))
	_check("хитбокс: shape не общий между инстансами", shape_a != shape_b,
		"один и тот же ресурс CircleShape2D")
	_clear_enemies()
	await get_tree().process_frame


# ─── Урон, смерть врага, очки ───────────────────────────────────────────────
func _check_enemy_and_bullet_damage() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.player.position = Vector2(60.0, Player.START_POSITION.y)
	_level.player.grant_invulnerability(999.0)
	# Пули, выпущенные автострельбой до переноса игрока, остались бы на старой колонне
	# и дали бы «лишний» урон — очищаем.
	await get_tree().process_frame
	_level.bullets.clear_all()

	var enemy := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(270.0, -40.0))
	enemy.patrol_amplitude = 0.0  # детерминизм: колонна врага не пересекает колонну игрока
	_check("враг: 4 HP", enemy.max_hp == 4 and enemy.hp == 4, "%d/%d" % [enemy.hp, enemy.max_hp])

	var patrol_reached: bool = await _wait_enemy_patrol(enemy, 4.0)
	_check("враг: дошёл до высоты патруля y≈220", patrol_reached)
	var enemy_fired: bool = await _wait_enemy_bullets(3.0)
	_check("враг: стреляет по игроку", enemy_fired)

	var score_before := _level.get_score()
	# Гейт #6: у обычного врага должен быть HP-сигнал для hit-flash.
	var damage_events: Array = []
	var damage_handler := func(_enemy: EnemyBase, hp: int, _at: Vector2) -> void:
		damage_events.append(hp)
	_level.enemy_damaged.connect(damage_handler)
	# Bf 109 — 4 HP и 1 урон за пулю. hp_before снимается ДО выстрела: иначе проверка
	# «hp == ожидание» проходит ещё до прилёта пули и съедает следующий выстрел.
	# Три несмертельных попадания: 4→3, 3→2, 2→1.
	for expected_hp in range(3, 0, -1):
		var hp_before := enemy.hp
		_fire_player_bullet_at(enemy)
		var hit: bool = await _wait_enemy_hp(enemy, expected_hp, 1.5)
		_check("враг: попадание снимает 1 HP (%d → %d)" % [hp_before, expected_hp],
			hit and hp_before == expected_hp + 1,
			"hp=%s" % (str(enemy.hp) if is_instance_valid(enemy) else "освобождён"))
	_check("враг: перед смертельным выстрелом 1 HP",
		is_instance_valid(enemy) and enemy.hp == 1,
		str(enemy.hp) if is_instance_valid(enemy) else "освобождён")
	_fire_player_bullet_at(enemy)
	var destroyed: bool = await _wait_enemy_gone(1.0)
	_level.enemy_damaged.disconnect(damage_handler)
	_check("враг: 4-е попадание сбивает Bf 109", destroyed, str(_enemy_count()))
	# health_changed отдаёт HP ПОСЛЕ урона, смертельный удар (hp = 0) отфильтрован LevelController.
	_check("враг: enemy_damaged форвардится с hp (4 попадания, смертельный не флешится)",
		damage_events == [3, 2, 1], str(damage_events))
	_check("враг: за сбитие начислено 100 очков", _level.get_score() - score_before == 100,
		"прирост %d" % (_level.get_score() - score_before))
	_level.bullets.clear_all()
	await get_tree().process_frame


## Урон игроку наносит ТОЛЬКО вражеская пуля. Столкновение корпусов HP не снимает.
func _check_body_collision_no_damage() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.position = Vector2(270.0, 700.0)
	# Автострельба выключена, чтобы враг не погиб раньше времени и корпус оставался на игроке.
	_level.player.set_process(false)
	var body_enemy := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(270.0, 700.0))
	body_enemy.set_physics_process(false)
	await get_tree().create_timer(0.6).timeout
	_check("корпус врага: столкновение не наносит урон", _level.player.hp == Player.MAX_HP,
		"hp=%d" % _level.player.hp)
	_check("корпус врага: игрок жив после наложения", _level.player.is_alive)
	_level.player.set_process(true)
	if is_instance_valid(body_enemy):
		body_enemy.despawn()
	_level.bullets.clear_all()
	await get_tree().process_frame


# ─── Бомба игрока ───────────────────────────────────────────────────────────
func _check_bomb() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_check("бомба: заряд выдан на старте", _level.get_bombs() == 1)

	var victim := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(270.0, 200.0))
	victim.set_physics_process(false)
	var score_before := _level.get_score()

	for i in 3:
		_level.bullets.fire_enemy(Vector2(120.0 + 60.0 * i, 300.0), Vector2.DOWN * 320.0, 1)
	await get_tree().physics_frame
	var enemy_bullets_before := _level.bullets.count_bullets(true)
	_check("бомба: на экране есть вражеские пули", enemy_bullets_before >= 3, str(enemy_bullets_before))

	var player_before := _level.player.position
	var button_center := _level.bomb_button.get_global_rect().get_center()
	await _touch_down(0, button_center)
	await _touch_up(0, button_center)
	await get_tree().process_frame

	_check("бомба: заряд израсходован", _level.get_bombs() == 0, str(_level.get_bombs()))
	_check("бомба: кнопка без заряда пропускает тапы (IGNORE)",
		_level.bomb_button.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		str(_level.bomb_button.mouse_filter))
	_check("бомба: вражеские пули очищены", _level.bullets.count_bullets(true) == 0,
		str(_level.bullets.count_bullets(true)))
	_check("бомба: тап по кнопке не двигает самолёт", _level.player.position == player_before)
	var bomb_invuln: float = _level.player._invulnerability_left
	_check("бомба: неуязвимость 0.4–0.6 с", bomb_invuln >= 0.4 and bomb_invuln <= 0.6,
		"%.3f с" % bomb_invuln)
	_check("бомба: флеш создан", _level.effects_root.get_child_count() > 0)
	_check("бомба: обычный враг уничтожен", _enemy_count() == 0, str(_enemy_count()))
	_check("бомба: очки за уничтоженного врага начислены", _level.get_score() - score_before == 100,
		"прирост %d" % (_level.get_score() - score_before))

	# Повторный тап без заряда ничего не делает.
	await _touch_down(0, button_center)
	await _touch_up(0, button_center)
	_check("бомба: без заряда повторный тап игнорируется", _level.get_bombs() == 0)
	_check("бомба: интерфейс босса без босса безопасен", _level.get_boss() == null)
	_level.bomb_hit_boss(LevelController.BOMB_DAMAGE_TO_BOSS)
	_check("бомба: bomb_hit_boss без босса не падает", true)


## QA-ловушка M2: босс не должен попадать в GROUP_ENEMIES, иначе бомба убивала бы его
## до начисления 30 урона. Проверяем на заглушках EnemyBase.
func _check_boss_group_and_bomb() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()

	var stub_boss := _make_stub(true, 120)
	var stub_enemy := _make_stub(false, 12)
	_level.enemies_root.add_child(stub_boss)
	_level.enemies_root.add_child(stub_enemy)
	await get_tree().process_frame

	_check("босс: только в группе boss", stub_boss.is_in_group(GameConfig.GROUP_BOSS)
		and not stub_boss.is_in_group(GameConfig.GROUP_ENEMIES))
	_check("обычный враг: только в группе enemies", stub_enemy.is_in_group(GameConfig.GROUP_ENEMIES)
		and not stub_enemy.is_in_group(GameConfig.GROUP_BOSS))
	_check("босс: get_boss() находит заглушку", _level.get_boss() == stub_boss)

	_level.use_bomb()
	await get_tree().process_frame
	_check("босс: бомба нанесла 30 урона (120 → 90)", stub_boss.hp == 90, str(stub_boss.hp))
	_check("босс: жив после бомбы", stub_boss.is_active)
	_check("бомба: обычный враг-заглушка уничтожен",
		not is_instance_valid(stub_enemy) or not stub_enemy.is_active)

	if is_instance_valid(stub_boss):
		stub_boss.despawn()
	await get_tree().process_frame
	_check("бомба: после удаления босса get_boss() == null", _level.get_boss() == null)


## Заглушка EnemyBase: ровно то, что нужно для проверки групп/урона.
func _make_stub(as_boss: bool, hp_value: int) -> EnemyBase:
	var stub := EnemyBase.new()
	stub.is_boss = as_boss
	stub.max_hp = hp_value
	stub.hp = hp_value
	stub.score_value = 2000 if as_boss else 100
	stub.asset_key = ArtStyle.KEY_BOSS_HE111 if as_boss else ArtStyle.KEY_ENEMY_BF109
	var shape := CollisionShape2D.new()
	shape.name = "CollisionShape2D"
	var circle := CircleShape2D.new()
	circle.radius = 64.0 if as_boss else 16.0
	shape.shape = circle
	stub.add_child(shape)
	return stub


# ─── Подборы (GDD «Бомба» / «Волны и враги») ────────────────────────────────
## GDD «Бомба» (Changelog 2026-10-26): ровно 1 заряд на забег БЕЗ пополнений — элита Fw 190
## бомбу не роняет, подборов бомбы нет вовсе. Проверяем структуру и оба профиля запаса.
## WP0.5: подбор создаётся публичным LevelController.spawn_pickup — флага дропа на враге
## больше нет (правило «последний живой Ju 87 волны 4» проверяется в _check_repair_identity).
func _check_pickups() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.player.grant_invulnerability(999.0)

	# 0. Структура: единственный вид подбора — ремкомплект; ключа ассета pickup_bomb нет.
	_check("подбор: единственный вид подбора — ремкомплект",
		Pickup.Kind.keys() == ["REPAIR"], str(Pickup.Kind.keys()))
	_check("подбор: ключ ассета pickup_bomb удалён из ArtStyle",
		not ArtStyle.SIZES.has(&"pickup_bomb"))
	# WP0.5: дропы — правила внешних узлов, на враге не осталось ни флага бомбы, ни флага
	# ремкомплекта (иначе флаг «переезжал» на следующего живого и ронял лишние подборы).
	var fw_probe := WaveManager.FW190_SCENE.instantiate() as EnemyBase
	_check("подбор: у врага нет флагов дропа (бомба и ремкомплект)",
		not ("drops_bomb_on_death" in fw_probe) and not ("drops_repair_on_death" in fw_probe))
	fw_probe.free()

	# 1. Инвариант «элита никогда не роняет бомбу»: волна 3 целиком (3×Fw 190) в обоих профилях
	# запаса. Порядок добивания разный (прямой / обратный) — результат обязан быть одинаковым.
	for profile: Array in [[1, "запас 1", false], [0, "запас 0", true]]:
		var expected_bombs: int = profile[0]
		var profile_name: String = profile[1]
		var reverse_order: bool = profile[2]
		_level.start_level()
		_level.waves.stop()
		await get_tree().process_frame
		_clear_enemies()
		await get_tree().process_frame
		_level.player.grant_invulnerability(999.0)
		if expected_bombs == 0:
			# Единственный заряд тратится кнопкой — второго не будет ниоткуда.
			var button_center := _level.bomb_button.get_global_rect().get_center()
			await _touch_down(0, button_center)
			await _touch_up(0, button_center)
			await get_tree().process_frame
		_check("подбор: запас перед волной 3 (%s) равен %d" % [profile_name, expected_bombs],
			_level.get_bombs() == expected_bombs, str(_level.get_bombs()))
		_level.waves.start_at_wave(2)
		await get_tree().process_frame
		var elites: Array[EnemyBase] = []
		for child in _level.enemies_root.get_children():
			if child is EnemyFw190 and not child.is_queued_for_deletion():
				elites.append(child as EnemyBase)
		_check("подбор: в волне 3 три элиты Fw 190 (%s)" % profile_name, elites.size() == 3,
			str(elites.size()))
		if reverse_order:
			elites.reverse()
		for elite in elites:
			elite.set_physics_process(false)
			elite.take_damage(9999)
			await get_tree().process_frame
		_check("подбор: гибель всех элит (%s) не роняет подбор" % profile_name,
			_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())
		_check("подбор: запас после элит (%s) не изменился" % profile_name,
			_level.get_bombs() == expected_bombs, str(_level.get_bombs()))

	# 2. Ремкомплект при HP < 3: +1 HP; запас бомбы подбор не меняет (пополнений нет).
	_level.start_level()
	_level.waves.stop()
	await get_tree().process_frame
	_clear_enemies()
	_level.player.grant_invulnerability(999.0)
	var bombs_before := _level.get_bombs()
	var collected_kinds: Array = []
	var collected_handler := func(kind: int, _at: Vector2) -> void: collected_kinds.append(kind)
	_level.pickup_collected.connect(collected_handler)

	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(1)
	await get_tree().process_frame
	_check("подбор: HP снижены для проверки ремонта", _level.player.hp == 2, str(_level.player.hp))

	# Подбор ставится напрямую публичным API: флага дропа на Ju 87 больше нет, а правило
	# «последний живой Ju 87 волны 4» проверяется отдельно и не смешивается с поведением подбора.
	_level.spawn_pickup(Pickup.Kind.REPAIR, Vector2(320.0, 300.0))
	await get_tree().process_frame
	var repair_pickup := _first_pickup()
	_check("подбор: spawn_pickup создаёт узел Pickup", repair_pickup != null,
		"подборов %d" % _level.get_pickup_count())
	if repair_pickup == null:
		_level.pickup_collected.disconnect(collected_handler)
		return
	_check("подбор: созданный подбор — REPAIR", repair_pickup.kind == Pickup.Kind.REPAIR,
		str(repair_pickup.kind))
	var fall_start := repair_pickup.global_position.y
	await get_tree().create_timer(0.3).timeout
	_check("подбор: падает вниз", repair_pickup.global_position.y > fall_start,
		"%.1f → %.1f" % [fall_start, repair_pickup.global_position.y])
	_level.player.position = repair_pickup.global_position
	var repaired: bool = await _wait_until(func() -> bool: return _level.player.hp == 3, 1.5)
	await get_tree().process_frame
	_check("подбор: ремкомплект даёт +1 HP", repaired, str(_level.player.hp))
	_check("подбор: pickup_collected отдаёт kind = REPAIR", collected_kinds == [Pickup.Kind.REPAIR],
		str(collected_kinds))
	_check("подбор: ремкомплект не меняет запас бомбы", _level.get_bombs() == bombs_before,
		"%d → %d" % [bombs_before, _level.get_bombs()])

	# 3. Ремкомплект при полном HP: ровно +500 очков (LevelController.REPAIR_FULL_HP_SCORE), HP не растёт.
	var score_before := _level.get_score()
	_level.spawn_pickup(Pickup.Kind.REPAIR, Vector2(360.0, 300.0))
	await get_tree().process_frame
	var repair_full := _first_pickup()
	_check("подбор: второй подбор создан", repair_full != null,
		"подборов %d" % _level.get_pickup_count())
	if repair_full == null:
		_level.pickup_collected.disconnect(collected_handler)
		return
	_level.player.position = repair_full.global_position
	var scored: bool = await _wait_until(
		func() -> bool: return _level.get_score() - score_before == LevelController.REPAIR_FULL_HP_SCORE,
		1.5
	)
	await get_tree().process_frame
	_check("подбор: при полном HP ремкомплект даёт 500 очков", scored and _level.player.hp == 3,
		"прирост %d, HP %d" % [_level.get_score() - score_before, _level.player.hp])
	_check("подбор: второй ремкомплект тоже kind = REPAIR",
		collected_kinds == [Pickup.Kind.REPAIR, Pickup.Kind.REPAIR], str(collected_kinds))
	_level.pickup_collected.disconnect(collected_handler)

	# 4. Деспавн за нижним краем.
	_level.spawn_pickup(Pickup.Kind.REPAIR, Vector2(120.0, 940.0))
	await get_tree().create_timer(1.0).timeout
	_check("подбор: исчезает за нижним краем", _level.get_pickup_count() == 0,
		str(_level.get_pickup_count()))

	# 5. Инвариант заряда: больше 1 он не появляется ни по одному пути (старт, трата, подборы).
	_check("бомба: стартовый запас — он же максимум (1)", LevelController.BOMBS_AT_START == 1,
		str(LevelController.BOMBS_AT_START))
	_check("бомба: зарядов ≤ 1 после всех путей (старт/трата/подборы)",
		_level.get_bombs() <= LevelController.BOMBS_AT_START, str(_level.get_bombs()))
	_level.start_level()
	await get_tree().process_frame


# ─── Ремкомплект волны 4: последний ЖИВОЙ Ju 87 (гейт M2, #1) ────────────────
## GDD «Волны и враги»: «Ремкомплект выпадает из последнего Ju 87 в волне 4».
## WP0.5: правило целиком в WaveManager (_try_drop_repair), флага на враге нет. Решение
## принимается при удалении борта из волны, поэтому проверяем:
##  * сбит НЕпоследний (в т.ч. последний по порядку спавна) → дропа нет;
##  * сбит последний ЖИВОЙ → ровно один подбор в точке гибели;
##  * последний ЖИВОЙ ушёл за нижний край → подбор в последней ВИДИМОЙ (достижимой) точке;
##  * второго подбора нет, до волны 4 подбора нет, в новом забеге правило взводится заново.
func _check_repair_identity() -> void:
	_level.start_level()
	_level.waves.stop()
	await get_tree().process_frame
	_clear_enemies()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	# Игрок вне колонн спавна: подборы падают мимо и не собираются сами — счётчики подборов
	# остаются стабильными, а проверки детерминированными.
	_level.player.position = Vector2(60.0, Player.START_POSITION.y)

	# ── A. «Последний ЖИВОЙ», а не «последний по порядку спавна» ─────────────
	var ju87s: Array[EnemyBase] = _spawn_wave4_ju87s()
	_check("ремкомплект: в волне 4 три Ju 87", ju87s.size() == 3, str(ju87s.size()))
	if ju87s.size() != 3:
		_check("ремкомплект: волна 4 пригодна для проверки порядка", false)
		return
	for ju: EnemyBase in ju87s:
		ju.set_physics_process(false)  # борт не спускается и не стреляет: точки гибели точные
	# Ставим борта в поле, чтобы точка дропа была измеримой (спавн начинается за краем).
	ju87s[0].position = Vector2(150.0, 300.0)
	ju87s[1].position = Vector2(270.0, 300.0)
	ju87s[2].position = Vector2(390.0, 300.0)
	await get_tree().process_frame

	# Дефект WP0.5: прежний флаг стоял на ПОСЛЕДНЕМ ПО ПОРЯДКУ СПАВНА борта, и его смерть
	# роняла ремкомплект при двух живых Ju 87 — лечение появлялось не там, где нужно.
	var spawn_last: EnemyBase = ju87s[2]
	spawn_last.take_damage(9999)
	await get_tree().process_frame
	_check("ремкомплект: сбит последний по порядку спавна при двух живых — дропа нет",
		_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())

	var middle: EnemyBase = ju87s[1]
	middle.take_damage(9999)
	await get_tree().process_frame
	_check("ремкомплект: сбит второй из трёх (живой ещё один) — дропа нет",
		_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())

	var last_living: EnemyBase = ju87s[0]
	_check("ремкомплект: перед смертью последнего живого подбора всё ещё нет",
		_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())
	var last_at := last_living.global_position
	last_living.take_damage(9999)
	await get_tree().process_frame
	var killed_drop := _first_pickup()
	_check("ремкомплект: сбит последний ЖИВОЙ Ju 87 — ровно один подбор",
		_level.get_pickup_count() == 1 and killed_drop != null
		and killed_drop.kind == Pickup.Kind.REPAIR,
		"подборов %d" % _level.get_pickup_count())
	if killed_drop != null:
		# Подбор падает (90 px/s), поэтому сверяем с точкой гибели с допуском в пару кадров.
		_check("ремкомплект: подбор появился в точке гибели последнего живого Ju 87",
			killed_drop.global_position.distance_to(last_at) <= 8.0,
			"%s vs %s" % [killed_drop.global_position, last_at])
	# Повторного дропа нет: зачистка остатка волны (4 Bf 109) второй подбор не создаёт.
	_kill_all_enemies()
	await get_tree().process_frame
	_check("ремкомплект: зачистка волны 4 не создаёт второго подбора",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())

	# ── B. Сброс между забегами ──────────────────────────────────────────────
	_level.start_level()
	_level.waves.stop()
	await get_tree().process_frame
	await get_tree().process_frame  # queue_free из _clear_level успевает отработать
	_check("ремкомплект: рестарт забега не оставляет подбор прошлого забега",
		_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())
	_clear_enemies()
	ju87s = _spawn_wave4_ju87s()
	if ju87s.size() != 3:
		_check("ремкомплект: новый забег снова даёт три Ju 87", false)
		return
	for ju: EnemyBase in ju87s:
		ju.take_damage(9999)
		await get_tree().process_frame
	_check("ремкомплект: в новом забеге подбор снова выпадает (сброс работает)",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())

	# ── C. Последний ЖИВОЙ Ju 87 ушёл за нижний край (despawn) ───────────────
	_level.start_level()
	_level.waves.stop()
	await get_tree().process_frame
	_clear_enemies()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_level.player.position = Vector2(60.0, Player.START_POSITION.y)
	ju87s = _spawn_wave4_ju87s()
	if ju87s.size() != 3:
		_check("ремкомплект: волна 4 пересоздана для деспавна", false)
		return
	ju87s[0].set_physics_process(false)
	ju87s[1].set_physics_process(false)
	ju87s[0].take_damage(9999)
	ju87s[1].take_damage(9999)
	await get_tree().process_frame
	_check("ремкомплект: перед деспавном последнего живого подбора нет",
		_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())
	var despawner: EnemyBase = ju87s[2]
	despawner.position = Vector2(390.0, 900.0)
	# Лямбды в GDScript захватывают локальные переменные по значению — пишем в Array-держатель.
	var holder: Array = []
	var probe := func() -> bool:
		var pickup := _first_pickup()
		if pickup != null:
			holder.append(pickup)
			return true
		return false
	var dropped: bool = await _wait_until(probe, 3.0)
	var despawn_drop: Pickup = holder[0] as Pickup if not holder.is_empty() else null
	_check("ремкомплект: уход последнего Ju 87 за край не теряет лечение",
		dropped and despawn_drop != null and despawn_drop.kind == Pickup.Kind.REPAIR,
		"подборов %d" % _level.get_pickup_count())
	if despawn_drop != null:
		# Сырая точка деспавна уже за экраном (y > 960 + 96): подбор обязан оказаться в поле.
		# Допуск +12 px — подбор падает 90 px/s, пока опрос ловит его в следующем кадре.
		var floor_y := GameConfig.REFERENCE_SIZE.y - GameConfig.PLAYFIELD_MARGIN
		var drop_at := despawn_drop.global_position
		_check("ремкомплект: подбор поднят в достижимую точку (y ≈ %d)" % int(floor_y),
			drop_at.y <= floor_y + 12.0 and drop_at.y >= floor_y - 0.5
			and is_equal_approx(drop_at.x, 390.0),
			str(drop_at))
	# Повторного дропа нет и на пути деспавна: зачистка остатка волны второй подбор не создаёт.
	_kill_all_enemies()
	await get_tree().process_frame
	_check("ремкомплект: после деспавна зачистка волны не создаёт второго подбора",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())

	# ── D. До волны 4 подбора нет ────────────────────────────────────────────
	_level.start_level()
	_level.waves.stop()
	await get_tree().process_frame
	await get_tree().process_frame
	_clear_enemies()
	var pre_wave_pickups: Array = []
	for index in WaveManager.REPAIR_WAVE_INDEX:  # волны 1–3 (индексы 0..2)
		_level.waves.start_at_wave(index)
		await get_tree().process_frame
		_kill_all_enemies()
		await get_tree().process_frame
		pre_wave_pickups.append(_level.get_pickup_count())
	_check("ремкомплект: до волны 4 подбора нет (волны 1–3)",
		pre_wave_pickups == [0, 0, 0], str(pre_wave_pickups))

	_level.start_level()
	await get_tree().process_frame


## Запускает волну 4 в обход предыдущих и возвращает её Ju 87 в порядке спавна.
func _spawn_wave4_ju87s() -> Array[EnemyBase]:
	_level.waves.start_at_wave(WaveManager.REPAIR_WAVE_INDEX)
	var result: Array[EnemyBase] = []
	for child in _level.enemies_root.get_children():
		if child is EnemyJu87:
			result.append(child as EnemyBase)
	return result


# ─── Патруль Bf 109 в коридоре поля (гейт M2, #10) ──────────────────────────
## Раньше синусоида с центром у края уезжала в x ≈ −30…600: врага нельзя было добить,
## а деспавн не срабатывал (padding 96 px спасал от смерти). В волне 2 крайние колонны
## теперь 80 / 460, поэтому кламп центра патруля (PATROL_X_MARGIN = 90) обязателен.
func _check_patrol_corridor() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.grant_invulnerability(999.0)

	var corridor_min := GameConfig.PLAYFIELD_MARGIN
	var corridor_max := GameConfig.REFERENCE_SIZE.x - GameConfig.PLAYFIELD_MARGIN
	# Борт у левого края поля (x = 120): центр патруля поджимается к PATROL_X_MARGIN, а
	# амплитуда — под коридор поля. Левее в таблице волн стоят колонны 80 (волна 2) и 120 —
	# для всех них действует один и тот же кламп, проверяемый здесь на граничном x = 120.
	var edge_enemy := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(120.0, 120.0))
	edge_enemy.patrol_altitude = 200.0
	_check("Bf 109: амплитуда патруля подрезана под коридор поля",
		edge_enemy.patrol_amplitude <= 120.0 - corridor_min + 0.01,
		"амплитуда %.1f" % edge_enemy.patrol_amplitude)

	var patrol_reached: bool = await _wait_until(
		func() -> bool: return is_instance_valid(edge_enemy) and is_equal_approx(edge_enemy.position.y, 200.0),
		2.0
	)
	var min_x := 9999.0
	var max_x := -9999.0
	var deadline := Time.get_ticks_msec() + 2600
	while Time.get_ticks_msec() < deadline and is_instance_valid(edge_enemy):
		min_x = minf(min_x, edge_enemy.position.x)
		max_x = maxf(max_x, edge_enemy.position.x)
		await get_tree().process_frame
	_check("Bf 109: патруль не выезжает за поля",
		patrol_reached and min_x >= corridor_min - 0.5 and max_x <= corridor_max + 0.5,
		"x %.1f…%.1f" % [min_x, max_x])
	_check("Bf 109: патруль реально движется (амплитуда не обнулена)",
		patrol_reached and max_x - min_x > 20.0, "x %.1f…%.1f" % [min_x, max_x])

	# Хард-кламп: даже грубая амплитуда, выставленная в рантайме, не выводит борт за поле.
	edge_enemy.patrol_amplitude = 400.0
	edge_enemy._patrol_time = (PI * 0.5) / edge_enemy.patrol_angular_speed
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("Bf 109: хард-кламп патруля держит борт в поле",
		is_instance_valid(edge_enemy) and is_equal_approx(edge_enemy.position.x, corridor_max),
		str(edge_enemy.position.x) if is_instance_valid(edge_enemy) else "враг удалён")

	# Фактическая скорость спуска Ju 87 (GDD: 120 px/s).
	var ju87 := _level.spawn_enemy(WaveManager.JU87_SCENE, Vector2(270.0, 120.0))
	var y_before := ju87.position.y
	await get_tree().create_timer(0.5).timeout
	var measured_speed := (ju87.position.y - y_before) / 0.5
	_check("Ju 87: фактическая скорость спуска ≈ 120 px/s",
		absf(measured_speed - EnemyJu87.JU87_SPEED) <= 6.0, "%.1f px/s" % measured_speed)

	_clear_enemies()
	_level.bullets.clear_all()
	_level.start_level()
	await get_tree().process_frame


# ─── Бомба босса: детонация в полосе игрока (гейт M2, #9) ────────────────────
## Раньше взрыв всегда был на y = 760, а игрок ходит до y = 934: нижние ~80 px были
## неуязвимы. Теперь высота детонации целится в Y игрока, урон — только внутри радиуса.
func _check_boss_bomb_band() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.reset(Vector2(270.0, 880.0))
	await get_tree().process_frame

	var drops: Array = []
	var drop_handler := func(at: Vector2, blast_at: Vector2, radius: float) -> void:
		drops.append([at, blast_at, radius])
	_level.boss_bomb_dropped.connect(drop_handler)
	_level._on_boss_bomb_dropped(Vector2(270.0, 800.0))
	await get_tree().process_frame
	_check("бомба босса: сигнал отдаёт точку сброса, будущую зону и радиус",
		drops.size() == 1
		and (drops[0][1] as Vector2).is_equal_approx(Vector2(270.0, 880.0))
		and is_equal_approx(float(drops[0][2]), BossBomb.BLAST_RADIUS),
		str(drops))
	_level.boss_bomb_dropped.disconnect(drop_handler)

	var hp_before := _level.player.hp
	var damaged: bool = await _wait_until(func() -> bool: return _level.player.hp < hp_before, 2.0)
	await get_tree().process_frame
	_check("бомба босса: детонация в полосе игрока наносит 1 урон",
		damaged and _level.player.hp == hp_before - 1, "hp %d" % _level.player.hp)

	# Вне радиуса: X бомбы фиксирован, уклонение горизонтальное.
	_level.player.reset(Vector2(270.0, 880.0))
	await get_tree().process_frame
	_level._on_boss_bomb_dropped(Vector2(270.0, 800.0))
	_level.player.position = Vector2(270.0 + 150.0, 880.0)
	var hp_safe := _level.player.hp
	await get_tree().create_timer(1.2).timeout
	_check("бомба босса: вне радиуса (150 px) урона нет",
		_level.player.hp == hp_safe and _level.player.is_alive,
		"hp %d, бомб %d" % [_level.player.hp, _count_boss_bombs()])
	_check("бомба босса: после детонации объект исчезает", _count_boss_bombs() == 0,
		str(_count_boss_bombs()))

	_level.bullets.clear_all()
	_level.start_level()
	await get_tree().process_frame


# ─── Пауза ──────────────────────────────────────────────────────────────────
func _check_pause() -> void:
	_level.start_level()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	await get_tree().create_timer(0.3).timeout

	var pause_center := _level.pause_button.get_global_rect().get_center()
	var elapsed_before := _level.get_elapsed()

	await _touch_down(0, pause_center)
	await _touch_up(0, pause_center)
	_check("пауза: состояние PAUSED", _level.get_state() == LevelController.State.PAUSED)
	_check("пауза: дерево заморожено", get_tree().paused)
	_check("пауза: оверлей «Пауза» показан", _level.pause_overlay.visible)
	_check("пауза: HUD остаётся живым", _level.hud.visible and not _level.death_overlay.visible)

	# Позиции фиксируем уже ПОСЛЕ паузы — до неё враги успевают сдвинуться.
	var enemy_before := _first_enemy()
	var enemy_pos_before := enemy_before.position if enemy_before != null else Vector2.ZERO
	await get_tree().create_timer(0.4).timeout
	var enemy_after := _first_enemy()
	var enemy_pos_after := enemy_after.position if enemy_after != null else Vector2.ZERO
	_check("пауза: враги не двигаются", enemy_pos_after.is_equal_approx(enemy_pos_before),
		"%s → %s" % [enemy_pos_before, enemy_pos_after])
	_check("пауза: таймер забега остановлен",
		is_equal_approx(_level.get_elapsed(), elapsed_before),
		"%.2f → %.2f" % [elapsed_before, _level.get_elapsed()])

	# Возобновление тапом по кнопке паузы (HUD-кнопка остаётся видимой — поведение прежнее).
	await _touch_down(0, pause_center)
	await _touch_up(0, pause_center)
	_check("пауза: повторный тап по кнопке паузы возвращает PLAYING",
		_level.get_state() == LevelController.State.PLAYING)
	_check("пауза: дерево разморожено", not get_tree().paused)
	_check("пауза: оверлей скрыт", not _level.pause_overlay.visible)

	# M11/T2: шорткат «тап по экрану продолжает игру» удалён. Касание свободного места
	# (270,480 — выше кнопок «Продолжить/Заново/В ангар») не меняет состояние.
	await _touch_down(0, pause_center)
	await _touch_up(0, pause_center)
	_check("пауза: снова PAUSED", _level.get_state() == LevelController.State.PAUSED
		and get_tree().paused and _level.pause_overlay.visible,
		"state=%d, paused=%s" % [_level.get_state(), get_tree().paused])
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	_check("пауза: тап по свободному месту НЕ возобновляет забег (шортката нет)",
		_level.get_state() == LevelController.State.PAUSED and get_tree().paused
		and _level.pause_overlay.visible,
		"state=%d, paused=%s, overlay=%s" % [
			_level.get_state(), get_tree().paused, _level.pause_overlay.visible])
	# Снятие паузы — кнопкой «Продолжить» реальным путём ввода (gui_input, как на Android):
	# нажатие даёт ровно один сигнал, забег возвращается в PLAYING.
	var resume_events: Array = []
	var resume_handler := func() -> void: resume_events.append(1)
	_level.pause_overlay.resume_requested.connect(resume_handler)
	var resume_center := _level.pause_overlay.resume_button.get_global_rect().get_center()
	await _touch_down(0, resume_center)
	await _touch_up(0, resume_center)
	_level.pause_overlay.resume_requested.disconnect(resume_handler)
	_check("пауза: кнопка «Продолжить» возвращает PLAYING (ровно один сигнал)",
		_level.get_state() == LevelController.State.PLAYING and not get_tree().paused
		and not _level.pause_overlay.visible and resume_events.size() == 1,
		"state=%d, paused=%s, сигналов %d" % [
			_level.get_state(), get_tree().paused, resume_events.size()])


# ─── Смерть и рестарт ────────────────────────────────────────────────────────
func _check_damage_death_restart() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	await get_tree().process_frame

	_check("рестарт фазы: HP 3, вражеских пуль нет",
		_level.player.hp == 3 and _level.player.is_alive and _level.bullets.count_bullets(true) == 0,
		"hp=%d, вражеских пуль=%d" % [_level.player.hp, _level.bullets.count_bullets(true)])

	await _fire_enemy_bullet_at_player(0.8)
	_check("урон: попадание снимает 1 HP", _level.player.hp == 2, str(_level.player.hp))
	_check("урон: выдана неуязвимость", _level.player._invulnerability_left > 0.0)

	# Пока действует неуязвимость 1.5 с, повторное попадание не проходит.
	await _fire_enemy_bullet_at_player(0.6)
	_check("урон: неуязвимость блокирует второе попадание", _level.player.hp == 2,
		str(_level.player.hp))

	await get_tree().create_timer(Player.INVULNERABILITY_TIME + 0.2).timeout
	await _fire_enemy_bullet_at_player(0.8)
	_check("урон: после 1.5 с попадание снова проходит", _level.player.hp == 1,
		str(_level.player.hp))

	await get_tree().create_timer(Player.INVULNERABILITY_TIME + 0.2).timeout
	# player_died обязан форвардиться LevelController'ом (гейт M2, #4): juice не ищет Player сам.
	var death_events: Array = []
	var death_handler := func(at: Vector2) -> void: death_events.append(at)
	_level.player_died.connect(death_handler)
	var player_at := _level.player.global_position
	await _fire_enemy_bullet_at_player(0.8)
	await get_tree().process_frame
	_check("смерть: HP = 0", _level.player.hp == 0, str(_level.player.hp))
	_check("смерть: игрок неактивен", not _level.player.is_alive)
	_check("смерть: состояние DEAD", _level.get_state() == LevelController.State.DEAD)
	_check("смерть: player_died форвардится с точкой гибели",
		death_events.size() == 1 and (death_events[0] as Vector2).is_equal_approx(player_at),
		str(death_events))
	_level.player_died.disconnect(death_handler)
	# Окно исхода FINISH_DELAY_LOSS: оверлей и пауза приходят ПОСЛЕ него (juice успевает
	# отыграть взрыв), поэтому ждём, а не проверяем немедленно (гейт M2, #2).
	var death_shown: bool = await _wait_until(
		func() -> bool: return _level.death_overlay.visible and get_tree().paused, 2.0
	)
	_check("смерть: показан экран «Аэродром потерян»", death_shown and _level.death_overlay.visible)
	_check("смерть: кнопка бомбы скрыта", not _level.bomb_button.visible)
	_check("смерть: кнопка паузы скрыта (#13)", not _level.pause_button.visible)
	_check("смерть: мир заморожен после окна исхода (#13)", get_tree().paused)

	# Оставляем вражеские пули на экране: рестарт обязан их убрать.
	for i in 3:
		_level.bullets.fire_enemy(Vector2(140.0 + 60.0 * i, 260.0), Vector2.DOWN * 320.0, 1)
	await get_tree().physics_frame
	var enemy_bullets_before := _level.bullets.count_bullets(true)
	_check("рестарт: до тапа на экране есть вражеские пули", enemy_bullets_before >= 3,
		str(enemy_bullets_before))

	# M11/T2: тап в свободном месте экрана поражения больше ничего не делает — рестарт только
	# кнопкой. Сначала фиксируем, что касание (270,480) не меняет состояние и не прячет экран.
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	await get_tree().process_frame
	_check("смерть: тап по свободному месту НЕ рестартит (экран остаётся на месте)",
		_level.get_state() == LevelController.State.DEAD and _level.death_overlay.visible
		and get_tree().paused
		and _level.bullets.count_bullets(true) == enemy_bullets_before,
		"state=%d, overlay=%s, пуль %d из %d" % [
			_level.get_state(), _level.death_overlay.visible,
			_level.bullets.count_bullets(true), enemy_bullets_before])

	# Рестарт — кнопкой «Повторить» РЕАЛЬНЫМ путём ввода (gui_input, как на Android):
	# ровно один replay_requested на нажатие, отпускание не добавляет второго.
	var replay_events: Array = []
	var replay_handler := func() -> void: replay_events.append(1)
	_level.death_overlay.replay_requested.connect(replay_handler)
	var replay_center := _level.death_overlay.replay_button.get_global_rect().get_center()
	await _touch_down(0, replay_center)
	var replay_after_press := replay_events.size()
	await _touch_up(0, replay_center)
	_level.death_overlay.replay_requested.disconnect(replay_handler)
	await get_tree().process_frame
	_check("смерть: кнопка «Повторить» — ровно один сигнал на нажатие, отпускание молчит",
		replay_after_press == 1 and replay_events.size() == 1,
		"после press %d, после release %d" % [replay_after_press, replay_events.size()])
	_check("рестарт: состояние PLAYING", _level.get_state() == LevelController.State.PLAYING)
	_check("рестарт: HP восстановлены", _level.player.hp == 3 and _level.player.is_alive)
	_check("рестарт: бомба восстановлена", _level.get_bombs() == 1)
	_check("рестарт: счёт сброшен", _level.get_score() == 0, str(_level.get_score()))
	_check("рестарт: экран поражения скрыт", not _level.death_overlay.visible)
	_check("рестарт: вражеские пули очищены", _level.bullets.count_bullets(true) == 0,
		"было %d, стало %d" % [enemy_bullets_before, _level.bullets.count_bullets(true)])
	_check("рестарт: волна 1 заспавнена заново", _enemy_count() == 4 and _count_bf109() == 4,
		"врагов %d" % _enemy_count())
	_check("рестарт: волны снова идут", _level.waves.is_active())
	_check("рестарт: игрок внизу по центру", _level.player.position == Player.START_POSITION,
		str(_level.player.position))
	# M3-B: рестарт мгновенный — брифинг и подсказки не возвращаются.
	_check("рестарт: брифинг не показывается", not _level.briefing.visible)
	_check("рестарт: подсказки не повторяются",
		not _level.hints.visible and not _level.hints.is_showing())


# ─── Окно исхода: тап не должен рестартить (ревью, MAJOR) ───────────────────
## Гейт: в окне FINISH_DELAY_* исход уже решён, но оверлей ещё не показан. Палец, постоянно
## лежащий на экране, — обычная поза на телефоне, поэтому тап в окне обязан НИЧЕГО не делать:
## иначе экран «Аэродром потерян»/«Аэродром спасён» со счётом проглатывается и игрок не видит результат.
func _check_finish_window_tap_ignored() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.position = Vector2(270.0, Player.START_POSITION.y)
	_level.player.grant_invulnerability(999.0)
	# Жертва окна: враг, который умрёт уже ПОСЛЕ решения об исходе.
	var victim := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(270.0, 140.0))
	victim.set_physics_process(false)
	await get_tree().process_frame

	# ── Поражение: окно FINISH_DELAY_LOSS ───────────────────────────────────
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(Player.MAX_HP)
	await get_tree().process_frame
	var score_in_window := _level.get_score()
	_check("окно исхода: DEAD, оверлея и паузы ещё нет (исход решён, экран позже)",
		_level.get_state() == LevelController.State.DEAD
		and not _level.death_overlay.visible and not get_tree().paused,
		"state=%d, overlay=%s, paused=%s" % [
			_level.get_state(), _level.death_overlay.visible, get_tree().paused
		])

	# Тап в окне (палец «всегда на экране») — игнор: ни рестарта, ни сброса счёта.
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	_check("тап в окне исхода НЕ рестартит (DEAD остаётся)",
		_level.get_state() == LevelController.State.DEAD, str(_level.get_state()))
	# Двойной тап (рестарт усилием) окно тоже не проглатывает.
	await _touch_down(0, Vector2(200.0, 300.0))
	await _touch_up(0, Vector2(200.0, 300.0))
	_check("двойной тап в окне: DEAD остаётся, счёт не сброшен, оверлея нет",
		_level.get_state() == LevelController.State.DEAD
		and _level.get_score() == score_in_window and not _level.death_overlay.visible,
		"state=%d, счёт %d (было %d)" % [
			_level.get_state(), _level.get_score(), score_in_window
		])

	# Враг, добитый в окне: очков не даёт (исход решён), но взрыв отыгрывает (мир честный).
	var explosions_before := _count_explosions()
	victim.take_damage(9999)
	await get_tree().process_frame
	_check("окно DEAD: сбитый в окне враг не даёт очков",
		_level.get_score() == score_in_window, "счёт %d (было %d)" % [
			_level.get_score(), score_in_window
		])
	_check("окно DEAD: взрыв сбитого врага всё равно отыгран",
		_count_explosions() == explosions_before + 1,
		"было %d, стало %d" % [explosions_before, _count_explosions()])

	var death_shown: bool = await _wait_until(
		func() -> bool: return _level.death_overlay.visible and get_tree().paused, 2.0
	)
	_check("окно исхода: экран «Аэродром потерян» появляется ПОСЛЕ окна (тап его не съел)",
		death_shown and _level.death_overlay.visible)

	# На ВИДИМОМ оверлее тап-шортката больше нет: касание свободного места ничего не делает,
	# а переиграть можно только кнопкой «Повторить» (M11/T3, решение D3).
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	await get_tree().process_frame
	_check("тап на видимом экране «Аэродром потерян» ничего не делает",
		_level.get_state() == LevelController.State.DEAD and _level.death_overlay.visible
		and get_tree().paused and _level.get_score() == score_in_window,
		"state=%d, paused=%s, счёт %d (было %d)" % [
			_level.get_state(), get_tree().paused, _level.get_score(), score_in_window])
	_check("экран поражения: «Повторить» — единственный путь рестарта",
		_level.death_overlay.get_visible_action_button_count() == 3
		and _level.death_overlay.request_replay())
	await get_tree().process_frame
	_check("«Повторить» на экране поражения рестартит забег",
		_level.get_state() == LevelController.State.PLAYING
		and not _level.death_overlay.visible and not get_tree().paused and _level.get_score() == 0,
		"state=%d, paused=%s, счёт %d" % [
			_level.get_state(), get_tree().paused, _level.get_score()
		])

	# ── Победа: окно FINISH_DELAY_WIN ───────────────────────────────────────
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.grant_invulnerability(999.0)
	var boss := _level.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 200.0)) as BossHe111
	boss.set_physics_process(false)
	await get_tree().process_frame
	boss.take_damage(9999)
	await get_tree().process_frame
	var win_score_in_window := _level.get_score()
	_check("окно победы: WON, экран со счётом ещё не показан",
		_level.get_state() == LevelController.State.WON
		and not _level.win_overlay.visible and not get_tree().paused,
		"state=%d, overlay=%s, paused=%s" % [
			_level.get_state(), _level.win_overlay.visible, get_tree().paused
		])
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	_check("тап в окне победы НЕ рестартит (WON и счёт сохранены)",
		_level.get_state() == LevelController.State.WON
		and _level.get_score() == win_score_in_window,
		"state=%d, счёт %d (было %d)" % [
			_level.get_state(), _level.get_score(), win_score_in_window
		])
	var win_shown: bool = await _wait_until(
		func() -> bool: return _level.win_overlay.visible and get_tree().paused, 2.0
	)
	_check("окно победы: «Аэродром спасён» появляется ПОСЛЕ окна",
		win_shown and _level.win_overlay.visible)
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	await get_tree().process_frame
	_check("тап на видимом экране победы ничего не делает",
		_level.get_state() == LevelController.State.WON and _level.win_overlay.visible
		and get_tree().paused and _level.get_score() == win_score_in_window,
		"state=%d, paused=%s, счёт %d (было %d)" % [
			_level.get_state(), get_tree().paused, _level.get_score(), win_score_in_window])
	_check("экран победы: «Повторить» — единственный путь рестарта",
		_level.win_overlay.get_visible_action_button_count() == 3
		and _level.win_overlay.request_replay())
	await get_tree().process_frame
	_check("«Повторить» на экране победы рестартит забег",
		_level.get_state() == LevelController.State.PLAYING
		and not _level.win_overlay.visible and not get_tree().paused,
		"state=%d, paused=%s" % [_level.get_state(), get_tree().paused])


## После смерти игрока враги обязаны замолчать (цель мертва).
func _check_enemies_stop_firing_after_death() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.position = Vector2(270.0, Player.START_POSITION.y)
	_level.player.grant_invulnerability(999.0)
	var shooter := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(270.0, 120.0))
	shooter.patrol_altitude = 200.0
	var fired_before: bool = await _wait_enemy_bullets(4.0)
	_check("смерть игрока: враг стрелял, пока игрок был жив", fired_before)

	_level.bullets.clear_all()
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(Player.MAX_HP)
	await get_tree().process_frame
	_check("смерть игрока: игрок сбит", not _level.player.is_alive, "hp=%d" % _level.player.hp)

	await get_tree().create_timer(3.0).timeout
	_check("смерть игрока: враги перестали стрелять", _level.bullets.count_bullets(true) == 0,
		"вражеских пуль: %d" % _level.bullets.count_bullets(true))
	_level.start_level()
	await get_tree().process_frame


## End-to-end: игрок стоит в колонне патруля (x≈270), НИ ОДНОЙ ручной пули через fire_player() —
## Bf 109 сбивается только автострельбой, после чего волна возвращается.
func _check_autofire_kills_bf109() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	_level.player.position = Vector2(270.0, Player.START_POSITION.y)
	_level.player.grant_invulnerability(999.0)
	var score_before := _level.get_score()

	var target_enemy := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(270.0, -40.0))
	target_enemy.patrol_altitude = 300.0
	target_enemy.patrol_amplitude = 0.0  # колонна патруля совпадает с колонной автострельбы

	var killed: bool = await _wait_enemy_count(0, 5.0)
	_check("E2E: автострельба сбивает Bf 109 без ручных пуль", killed,
		"врагов осталось %d" % _enemy_count())
	_check("E2E: за сбитие начислено 100 очков", _level.get_score() - score_before == 100,
		"прирост %d" % (_level.get_score() - score_before))

	# «Респавн»: полный перезапуск уровня возвращает первую волну.
	_level.start_level()
	await get_tree().process_frame
	var respawned: bool = await _wait_enemy_count(4, 1.0)
	_check("E2E: после рестарта волна 1 вернулась", respawned, str(_enemy_count()))


# ─── Таблица волн (GDD «Волны и враги») ─────────────────────────────────────
func _check_wave_table() -> void:
	var table := WaveManager.wave_table()
	_check("волны: всего 6 волн + босс", WaveManager.WAVE_COUNT == 6 and table.size() == 6,
		"%d / %d" % [WaveManager.WAVE_COUNT, table.size()])

	var counts := []
	for wave: Array in table:
		counts.append(wave.size())
	_check("волны: состав 4 / 5 / 3 / 7 / 6 / 6", counts == [4, 5, 3, 7, 6, 6], str(counts))

	var all_types_ok := true
	for entry: Dictionary in table[0]:
		all_types_ok = all_types_ok and entry["scene"] == WaveManager.BF109_SCENE
	_check("волна 1: только Bf 109", all_types_ok)

	# Волна 2 — настоящая симметричная V «1-2-2» вокруг центра поля (x = 270): один apex на
	# ближней линии (y = −34), две пары расходятся назад (−46 и −64), пять различимых колонок.
	var wave2: Array = table[1]
	var bf_only := true
	var xs := []
	var ys := []
	var y_by_x := {}
	for entry: Dictionary in wave2:
		bf_only = bf_only and entry["scene"] == WaveManager.BF109_SCENE
		var point := entry["position"] as Vector2
		xs.append(point.x)
		ys.append(point.y)
		y_by_x[point.x] = point.y
	xs.sort()
	var distinct_columns := true
	for i in range(1, xs.size()):
		distinct_columns = distinct_columns and xs[i] > xs[i - 1]
	# Ближняя к игроку линия — максимальный Y (ось Y смотрит вниз): apex обязан быть один.
	var nearest_y := -INF
	for y: float in ys:
		nearest_y = maxf(nearest_y, y)
	var apex_count := 0
	for y: float in ys:
		if is_equal_approx(y, nearest_y):
			apex_count += 1
	var v_shape: bool = (
		wave2.size() == 5
		and bf_only
		and distinct_columns
		and apex_count == 1
		and is_equal_approx(nearest_y, WaveManager.SPAWN_DEPTH_MID)
		and is_equal_approx(float(y_by_x[xs[0]]), WaveManager.SPAWN_DEPTH_V)
		and is_equal_approx(float(y_by_x[xs[1]]), WaveManager.SPAWN_DEPTH_LEAD)
		and is_equal_approx(float(y_by_x[xs[3]]), WaveManager.SPAWN_DEPTH_LEAD)
		and is_equal_approx(float(y_by_x[xs[4]]), WaveManager.SPAWN_DEPTH_V)
	)
	_check("волна 2: 5 Bf 109, V 1-2-2 (apex ближе к игроку, пары −46/−64)", v_shape,
		"xs=%s, ys=%s" % [xs, ys])
	# Симметрия: центральный борт в центре поля, X-суммы пар = ширина поля (80+460, 175+365).
	var symmetry_ok: bool = (
		wave2.size() == 5
		and xs.size() == 5
		and is_equal_approx(float(xs[2]), GameConfig.REFERENCE_SIZE.x * 0.5)
		and is_equal_approx(float(xs[0]) + float(xs[4]), GameConfig.REFERENCE_SIZE.x)
		and is_equal_approx(float(xs[1]) + float(xs[3]), GameConfig.REFERENCE_SIZE.x)
	)
	_check("волна 2: симметрия — центр 270 и X-суммы пар = 540", symmetry_ok, "xs=%s" % [xs])

	# GDD «Бомба» (Changelog 2026-10-26): элита бомбу не роняет, поэтому в таблице нет ни
	# флага дропа, ни ключа drop_bomb. Состав волны 3: 3 элитных Fw 190.
	var wave3_ok := true
	for entry: Dictionary in table[2]:
		wave3_ok = (
			wave3_ok
			and entry["scene"] == WaveManager.FW190_SCENE
			and not entry.has("drop_bomb")
		)
	_check("волна 3: 3 элитных Fw 190 без дропа бомбы", table[2].size() == 3 and wave3_ok,
		str(table[2].size()))

	var ju_count := 0
	var bf_count := 0
	var table_repair_flags := 0
	for entry: Dictionary in table[3]:
		if entry["scene"] == WaveManager.JU87_SCENE:
			ju_count += 1
		elif entry["scene"] == WaveManager.BF109_SCENE:
			bf_count += 1
		if bool(entry.get("drop_repair", false)):
			table_repair_flags += 1
	# Гейт #1: «последний Ju 87» — рантайм-правило WaveManager, в таблице флага больше нет.
	_check("волна 4: 3 Ju 87 + 4 Bf 109, ремкомплект решается в рантайме",
		ju_count == 3 and bf_count == 4 and table_repair_flags == 0
		and WaveManager.REPAIR_WAVE_INDEX == 3,
		"Ju87 %d, Bf109 %d, флагов в таблице %d" % [ju_count, bf_count, table_repair_flags])

	var wave5_fw := 0
	var wave5_bf := 0
	for entry: Dictionary in table[4]:
		if entry["scene"] == WaveManager.FW190_SCENE:
			wave5_fw += 1
		elif entry["scene"] == WaveManager.BF109_SCENE:
			wave5_bf += 1
	_check("волна 5: 3 Fw 190 + 3 Bf 109", wave5_fw == 3 and wave5_bf == 3,
		"Fw190 %d, Bf109 %d" % [wave5_fw, wave5_bf])

	# M5.3c, GDD «Волны миссий»: волна 6 «Аэродрома» — 2 Fw 190 + 4 Bf 109 (Fw 190 спавнятся
	# первыми, Bf 109 идут задней линией). Симметрия вокруг центра поля x = 270, как у волн 2/5.
	var wave6_fw := 0
	var wave6_bf := 0
	var wave6_order_ok := true
	var wave6_depth_ok := true
	var wave6_fw_xs := []
	var wave6_bf_xs := []
	for entry: Dictionary in table[5]:
		var point := entry["position"] as Vector2
		if entry["scene"] == WaveManager.FW190_SCENE:
			# Порядок entry: Fw 190 не должны идти после Bf 109.
			wave6_order_ok = wave6_order_ok and wave6_bf == 0
			wave6_fw += 1
			wave6_fw_xs.append(point.x)
			wave6_depth_ok = wave6_depth_ok \
				and is_equal_approx(point.y, WaveManager.SPAWN_DEPTH)
		elif entry["scene"] == WaveManager.BF109_SCENE:
			wave6_bf += 1
			wave6_bf_xs.append(point.x)
			wave6_depth_ok = wave6_depth_ok \
				and is_equal_approx(point.y, WaveManager.SPAWN_DEPTH_BACK)
		else:
			wave6_order_ok = false
	var wave6_symmetry := true
	for xs_list: Array in [wave6_fw_xs, wave6_bf_xs]:
		if xs_list.size() < 2:
			wave6_symmetry = false
			continue
		for i in xs_list.size():
			wave6_symmetry = wave6_symmetry \
				and is_equal_approx(float(xs_list[i]) + float(xs_list[xs_list.size() - 1 - i]),
					GameConfig.REFERENCE_SIZE.x)
	_check("волна 6: 2 Fw 190 + 4 Bf 109 (Fw 190 первыми, Bf 109 −88), симметрия к 540",
		table.size() == 6 and wave6_fw == 2 and wave6_bf == 4
		and wave6_order_ok and wave6_depth_ok and wave6_symmetry,
		"Fw190 %d %s, Bf109 %d %s, порядок %s, глубины %s" % [
			wave6_fw, wave6_fw_xs, wave6_bf, wave6_bf_xs, wave6_order_ok, wave6_depth_ok])

	# WP0.5: каждый спавн обязан быть виден целиком.
	#  * X: силуэт (полуширина ассета) внутри поля с GameConfig.PLAYFIELD_MARGIN — иначе борт
	#    стреляет из-за края (найденный дефект «Ju 87 за экраном» на прежнем x = 600);
	#  * Y: выше порога авто-деспавна EnemyBase, иначе враг удалялся бы в первом кадре.
	var half_width := {}
	for scene: PackedScene in [WaveManager.BF109_SCENE, WaveManager.JU87_SCENE, WaveManager.FW190_SCENE]:
		var probe := scene.instantiate() as EnemyBase
		half_width[scene.resource_path] = ArtStyle.size_of(probe.asset_key).x * 0.5
		probe.free()
	var silhouette_ok := true
	var spawn_ok := true
	var tightest := 9999.0
	var deepest := 0.0
	var deepest_x := 0.0
	for wave: Array in table:
		for entry: Dictionary in wave:
			var point := entry["position"] as Vector2
			var scene_path := (entry["scene"] as PackedScene).resource_path
			# Неизвестная сцена в таблице — тоже провал: иначе новый враг без полуширины
			# прошёл бы проверку «по умолчанию» (half = 0).
			if not half_width.has(scene_path):
				silhouette_ok = false
			var half: float = float(half_width.get(scene_path, 0.0))
			var side_margin := minf(
				point.x - half - GameConfig.PLAYFIELD_MARGIN,
				GameConfig.REFERENCE_SIZE.x - point.x - half - GameConfig.PLAYFIELD_MARGIN
			)
			tightest = minf(tightest, side_margin)
			if side_margin < 0.0:
				silhouette_ok = false
			if point.y <= -EnemyBase.DEFAULT_DESPAWN_PADDING:
				spawn_ok = false
			if point.y < deepest:
				deepest = point.y
				deepest_x = point.x
	_check("волны: силуэт каждого борта на спавне в поле (полуширина + маржа 26)",
		silhouette_ok, "минимальный запас до края %.1f px" % tightest)
	_check("волны: спавн выше порога авто-деспавна (> −96)", spawn_ok,
		"глубочайший спавн y=%.1f (x=%.0f)" % [deepest, deepest_x])


# ─── Босс: фазы, скорость пуль, бомбы ───────────────────────────────────────
func _check_boss_phases() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	# Автострельба выключена на весь тест фаз: Ла-5 стоит на x=470, а босс прочёсывает
	# [110, 430] с полушириной ~80 — случайное попадание на 1 урона сдвигало HP порога
	# (флейк «hp 59 вместо 60»). Фазы проверяются явными take_damage/bomb_hit_boss.
	# Висящие пули прошлого теста убираем: они летят вверх и могут задеть босса на входе.
	_level.bullets.clear_all()
	_level.player.set_process(false)
	_level.player.position = Vector2(470.0, Player.START_POSITION.y)
	_level.player.grant_invulnerability(999.0)
	_boss_phase_events.clear()

	var boss := _level.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 120.0)) as BossHe111
	boss.phase_changed.connect(_on_boss_phase_changed)
	var entered: bool = await _wait_until(func() -> bool: return boss.position.y >= BossHe111.ALTITUDE - 1.0, 3.0)
	_check("босс: входит в поле и идёт на высоте прочёса", entered, str(boss.position))
	_check("босс: 120 HP, 2000 очков", boss.hp == 120 and boss.score_value == 2000)
	_check("босс: только в группе boss", boss.is_in_group(GameConfig.GROUP_BOSS)
		and not boss.is_in_group(GameConfig.GROUP_ENEMIES))

	# Бомба по боссу: 120 → 90, босс жив.
	var boss_damage_events: Array = []
	var boss_damage_probe := func(_enemy: EnemyBase, _hp: int, _at: Vector2) -> void:
		boss_damage_events.append(1)
	_level.enemy_damaged.connect(boss_damage_probe)
	_level.bomb_hit_boss(LevelController.BOMB_DAMAGE_TO_BOSS)
	await get_tree().process_frame
	_check("босс: бомба 120 → 90 и он жив", boss.hp == 90 and boss.is_active, str(boss.hp))
	_check("босс: после бомбы всё ещё фаза 1", boss.phase == 1, str(boss.phase))

	# Фаза 1: прицельные очереди + веер, скорость пуль 300 (в диапазоне 260–420).
	_level.bullets.clear_all()
	var phase1_fired: bool = await _wait_enemy_bullets(4.0)
	var phase1_speed := _max_enemy_bullet_speed()
	_check("босс: фаза 1 стреляет", phase1_fired)
	_check("босс: скорость пуль фазы 1 = 300", is_equal_approx(phase1_speed, BossHe111.PHASE1_BULLET_SPEED),
		str(phase1_speed))
	_check("босс: в фазе 1 бомбы не сбрасываются", _count_boss_bombs() == 0,
		str(_count_boss_bombs()))

	# Гейт #8: очередь = 3 залпа × 2 турели = 6 снарядов за ~0.25 с (веер отключён для чистоты).
	_level.bullets.clear_all()
	boss._fan_timer = 999.0
	boss._aimed_timer = 0.0
	boss._burst_shots_left = 0
	await get_tree().create_timer(0.5).timeout
	_check("босс: прицельная очередь = 6 снарядов (3 залпа × 2 турели)",
		_level.bullets.count_bullets(true) == 6, str(_level.bullets.count_bullets(true)))
	_level.bullets.clear_all()

	# Порог фазы 2: 90 → 60 HP.
	boss.take_damage(30)
	await get_tree().process_frame
	_check("босс: на 60 HP включилась фаза 2", boss.hp == 60 and boss.phase == 2,
		"hp %d, фаза %d" % [boss.hp, boss.phase])
	_check("босс: сигнал смены фазы отправлен один раз",
		_boss_phase_events.size() == 1 and _boss_phase_events[0] == 2, str(_boss_phase_events))
	_check("босс: скорость пуль фазы 2 +30% (390)",
		is_equal_approx(boss.bullet_speed, BossHe111.PHASE1_BULLET_SPEED * BossHe111.PHASE2_SPEED_MULT),
		str(boss.bullet_speed))
	_check("босс: HP не дублируется в enemy_damaged (у босса свой health_changed)",
		boss_damage_events.is_empty(), str(boss_damage_events.size()))
	_level.enemy_damaged.disconnect(boss_damage_probe)

	_level.bullets.clear_all()
	var phase2_fired: bool = await _wait_enemy_bullets(3.5)
	var phase2_speed := _max_enemy_bullet_speed()
	_check("босс: фаза 2 стреляет быстрее", phase2_fired and phase2_speed > phase1_speed * 1.25,
		"%.1f → %.1f" % [phase1_speed, phase2_speed])

	# Односторонний переход: ниже 60 HP вторая фаза не сбрасывается.
	boss.take_damage(20)
	await get_tree().process_frame
	_check("босс: фаза 2 не откатывается при 40 HP", boss.phase == 2 and _boss_phase_events.size() == 1,
		"hp %d, фаза %d, событий %d" % [boss.hp, boss.phase, _boss_phase_events.size()])

	# Фаза 2: бомбы с задержкой (видимый объект → детонация).
	var bomb_appeared: bool = await _wait_until(func() -> bool: return _count_boss_bombs() > 0, 4.0)
	_check("босс: фаза 2 сбрасывает бомбу с задержкой", bomb_appeared, str(_count_boss_bombs()))
	var bomb_gone: bool = await _wait_until(func() -> bool: return _count_boss_bombs() == 0, 5.0)
	_check("босс: бомба детонирует и исчезает", bomb_gone)

	# Новых врагов босс не призывает.
	await get_tree().create_timer(1.0).timeout
	_check("босс: не призывает новых врагов", _enemy_count() == 1, str(_enemy_count()))

	if is_instance_valid(boss):
		boss.despawn()
	await get_tree().process_frame
	_level.bullets.clear_all()
	_level.player.set_process(true)
	_level.start_level()
	await get_tree().process_frame


func _on_boss_phase_changed(phase: int) -> void:
	_boss_phase_events.append(phase)


# ─── Полный прогон уровня: 6 волн → босс → победа → рестарт ─────────────────
func _check_full_run() -> void:
	_level.start_level()
	await get_tree().process_frame
	# Игрок не в колонне врагов: подборы падают мимо и не меняют счёт.
	_level.player.position = Vector2(60.0, Player.START_POSITION.y)
	_level.player.grant_invulnerability(999.0)

	# Волна 1: 4×100; волна 2: 5×100; волна 3: 3×300; волна 4: 3×150+4×100;
	# волна 5: 3×300+3×100; волна 6 (M5.3c): 2×300+4×100.
	var expected_kills := [400, 500, 900, 850, 1200, 1000]
	var expected_score := 0
	var wave_reached := true

	for wave_index in WaveManager.WAVE_COUNT:
		wave_reached = await _wait_until(
			func() -> bool: return _level.waves.get_wave_index() == wave_index, 6.0
		) and wave_reached
		if not wave_reached:
			break
		var spawned: bool = await _wait_until(
			func() -> bool: return _enemy_count() == int(WaveManager.wave_table()[wave_index].size()), 3.0
		)
		_check("прогон: волна %d заспавнена целиком" % (wave_index + 1), spawned,
			"врагов %d" % _enemy_count())
		if not spawned:
			break
		_kill_all_enemies()
		expected_score += int(expected_kills[wave_index]) + LevelController.WAVE_CLEAR_BONUS
		var cleared: bool = await _wait_until(
			func() -> bool: return _level.get_score() == expected_score, 4.0
		)
		_check("прогон: счёт после волны %d = %d" % [wave_index + 1, expected_score],
			cleared, "факт %d" % _level.get_score())
		if wave_index == 2:
			# Все элиты волны 3 сбиты — подборов бомбы нет вовсе (GDD «Бомба»).
			_check("прогон: после элит волны 3 подборов нет", _level.get_pickup_count() == 0,
				str(_level.get_pickup_count()))
		if wave_index == 3:
			# GDD: ремкомплект выпадает из последнего Ju 87 четвёртой волны.
			var repair_dropped: bool = await _wait_until(
				func() -> bool: return _level.get_pickup_count() >= 1, 1.0
			)
			_check("прогон: ремкомплект волны 4 выпал", repair_dropped,
				str(_level.get_pickup_count()))

	var boss_appeared: bool = await _wait_until(
		func() -> bool: return _level.get_boss() != null, 6.0
	)
	_check("прогон: после волн появился босс", boss_appeared)
	_check("прогон: все 6 волн пройдены", wave_reached and _level.waves.get_wave_index() == 6,
		str(_level.waves.get_wave_index()))
	var boss := _level.get_boss() as BossHe111
	if boss == null:
		_check("прогон: босс доступен для боя", false)
		return
	_check("прогон: в бою с боссом один враг (без подмоги)", _enemy_count() == 1, str(_enemy_count()))
	_check("прогон: HUD показывает полосу HP босса", _level.hud.boss_bar.visible)
	_check("прогон: босс на полном HP", boss.hp == 120, str(boss.hp))

	await get_tree().create_timer(1.0).timeout
	_check("прогон: босс не спавнит волны", _enemy_count() == 1, str(_enemy_count()))

	var score_before_boss := _level.get_score()
	# #3: гибель босса приходит отдельным сигналом (juice не угадывает тип по узлу).
	var boss_deaths: Array = []
	var boss_death_handler := func(at: Vector2) -> void: boss_deaths.append(at)
	_level.boss_destroyed.connect(boss_death_handler)
	var boss_at := boss.global_position
	boss.take_damage(9999)
	await get_tree().process_frame

	var expected_win := score_before_boss + 2000 + LevelController.REMAINING_HP_BONUS * 3
	_check("победа: состояние WON", _level.get_state() == LevelController.State.WON,
		str(_level.get_state()))
	_check("победа: boss_destroyed с точкой гибели",
		boss_deaths.size() == 1 and (boss_deaths[0] as Vector2).is_equal_approx(boss_at),
		str(boss_deaths))
	_level.boss_destroyed.disconnect(boss_death_handler)
	# #2: окно FINISH_DELAY_WIN — сигнал уже ушёл, а пауза и оверлей ещё нет.
	_check("победа: run_finished приходит ДО паузы (окно для juice)",
		not get_tree().paused and not _level.win_overlay.visible,
		"paused=%s, overlay=%s" % [get_tree().paused, _level.win_overlay.visible])
	var win_shown: bool = await _wait_until(
		func() -> bool: return _level.win_overlay.visible and get_tree().paused, 2.0
	)
	_check("победа: экран «Аэродром спасён»",
		win_shown and _level.win_overlay.visible and not _level.death_overlay.visible)
	_check("победа: счёт = убийства + волны + 250×HP", _level.get_score() == expected_win,
		"ожидание %d, факт %d" % [expected_win, _level.get_score()])
	_check("победа: счёт на экране", String(_level.win_overlay.score_line.text) == "Счёт: %d" % expected_win,
		String(_level.win_overlay.score_line.text))
	_check("победа: время показано и не влияет на счёт",
		String(_level.win_overlay.time_line.text).begins_with("Время: ")
		and _level.get_elapsed() > 0.0, "%s / %.2f с" % [_level.win_overlay.time_line.text, _level.get_elapsed()])
	_check("победа: полоса HP босса скрыта", not _level.hud.boss_bar.visible)
	_check("победа: кнопка паузы скрыта (#13)", not _level.pause_button.visible)
	_check("победа: мир заморожен", get_tree().paused)

	# ── M3-C: рекорд записан ровно один раз и показывает новый best ──────────
	_check("рекорд: на диске ровно итоговый счёт победы",
		_read_record_best() == expected_win,
		"файл %d, ожидание %d" % [_read_record_best(), expected_win])
	_check("рекорд: RecordLine показывает «Новый рекорд: N»",
		String(_level.win_overlay.record_line.text) == "Новый рекорд: %d" % expected_win,
		String(_level.win_overlay.record_line.text))
	_check("рекорд: оверлей получил best/is_new",
		_level.win_overlay.best_score == expected_win and _level.win_overlay.is_new_record,
		"best=%d, new=%s" % [
			_level.win_overlay.best_score, _level.win_overlay.is_new_record])
	# Повторный _finish_run(true) в WON — no-op: ни счёт, ни файл не меняются
	# (гвард состояния + submit не пишет при равном счёте).
	var win_snapshot := _file_snapshot(_record_path)
	var win_score := _level.get_score()
	_level._finish_run(true)
	await get_tree().process_frame
	_check("рекорд: повторный _finish_run(true) не меняет файл",
		_snapshots_equal(win_snapshot, _file_snapshot(_record_path)),
		_snapshot_brief(win_snapshot))
	_check("рекорд: повторный _finish_run(true) не меняет счёт",
		_level.get_score() == win_score, "%d → %d" % [win_score, _level.get_score()])

	# M11/T2/T3: тап по свободному месту экрана победы больше не рестартит — только кнопка
	# «Повторить» (это был баг владельца: «сработал только тап в свободную область»).
	await _touch_down(0, Vector2(270.0, 480.0))
	await _touch_up(0, Vector2(270.0, 480.0))
	await get_tree().process_frame
	_check("победа: тап по свободному месту НЕ рестартит (экран и рекорд целы)",
		_level.get_state() == LevelController.State.WON and _level.win_overlay.visible
		and get_tree().paused and _level.get_score() == win_score
		and _read_record_best() == expected_win,
		"state=%d, overlay=%s, счёт %d" % [
			_level.get_state(), _level.win_overlay.visible, _level.get_score()])
	var win_replay_events: Array = []
	var win_replay_handler := func() -> void: win_replay_events.append(1)
	_level.win_overlay.replay_requested.connect(win_replay_handler)
	var win_replay_center := _level.win_overlay.replay_button.get_global_rect().get_center()
	await _touch_down(0, win_replay_center)
	var win_replay_after_press := win_replay_events.size()
	await _touch_up(0, win_replay_center)
	_level.win_overlay.replay_requested.disconnect(win_replay_handler)
	await get_tree().process_frame
	_check("победа: кнопка «Повторить» живая — ровно один сигнал, отпускание молчит",
		win_replay_after_press == 1 and win_replay_events.size() == 1,
		"после press %d, после release %d" % [
			win_replay_after_press, win_replay_events.size()])
	_check("рестарт из победы: состояние PLAYING", _level.get_state() == LevelController.State.PLAYING)
	_check("рестарт из победы: счёт обнулён", _level.get_score() == 0, str(_level.get_score()))
	_check("рестарт из победы: время обнулено", _level.get_elapsed() < 0.25,
		str(_level.get_elapsed()))
	_check("рестарт из победы: экран победы скрыт", not _level.win_overlay.visible)
	_check("рестарт из победы: волна 1 снова в игре", _enemy_count() == 4 and _count_bf109() == 4,
		str(_enemy_count()))
	_check("рестарт из победы: дерево разморожено", not get_tree().paused)
	_check("рестарт из победы: кнопка паузы снова видна (#13)", _level.pause_button.visible)
	# M3-B: победа → тап → мгновенный забег, без брифинга и подсказок.
	_check("рестарт из победы: брифинг не показывается", not _level.briefing.visible)
	_check("рестарт из победы: подсказки не повторяются", not _level.hints.is_showing())

	# ── M3-C: поражение рекорд не трогает (DEAD — не результат забега) ───────
	var before_loss := _file_snapshot(_record_path)
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(Player.MAX_HP)
	await get_tree().process_frame
	var death_after_record: bool = await _wait_until(
		func() -> bool: return _level.death_overlay.visible and get_tree().paused, 2.0
	)
	_check("рекорд: поражение не меняет файл рекорда",
		death_after_record and _snapshots_equal(before_loss, _file_snapshot(_record_path)),
		_snapshot_brief(before_loss))

	# ── M3-C: новая (меньшая) победа показывает ПРЕЖНИЙ рекорд и не пишет файл ──
	# Рестарт после поражения — тоже кнопкой (тап-шорткатов нет, M11/T2).
	_check("экран поражения: «Повторить» после смерти → PLAYING",
		_level.death_overlay.request_replay())
	await get_tree().process_frame
	_check("рекорд: рестарт после поражения → PLAYING",
		_level.get_state() == LevelController.State.PLAYING, str(_level.get_state()))
	_level.player.grant_invulnerability(999.0)
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	await get_tree().process_frame
	var cheap_boss := _level.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 200.0))
	cheap_boss.set_physics_process(false)
	await get_tree().process_frame
	cheap_boss.take_damage(9999)
	await get_tree().process_frame
	var second_win: bool = await _wait_until(
		func() -> bool: return _level.win_overlay.visible and get_tree().paused, 2.0)
	var smaller_score := _level.get_score()
	_check("рекорд: меньшая победа показывает прежний рекорд",
		second_win and smaller_score < expected_win
		and String(_level.win_overlay.record_line.text) == "Рекорд: %d" % expected_win
		and not _level.win_overlay.is_new_record,
		"счёт %d, строка «%s»" % [smaller_score, _level.win_overlay.record_line.text])
	_check("рекорд: меньшая победа не перезаписывает файл",
		_read_record_best() == expected_win,
		"файл %d, ожидание %d" % [_read_record_best(), expected_win])


# ─── Ввод (как на Android: только touch-события) ─────────────────────────────
## Координаты канвы → координаты окна (нужно только для Input.parse_input_event в headless).
func _to_window(canvas_position: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * canvas_position


func _touch_down(index: int, position: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = _to_window(position)
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().physics_frame


func _touch_up(index: int, position: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = _to_window(position)
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().physics_frame


func _touch_drag(index: int, position: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = _to_window(position)
	Input.parse_input_event(event)
	await get_tree().process_frame


# ─── Вспомогательные проверки ────────────────────────────────────────────────
func _fire_player_bullet_at(enemy: EnemyBase) -> void:
	if not is_instance_valid(enemy):
		return
	_level.bullets.fire_player(
		enemy.global_position + Vector2(0.0, 60.0),
		Vector2.UP * Player.BULLET_SPEED,
		Player.BULLET_DAMAGE
	)


## Стреляет вражеской пулей прямо в игрока и ждёт физического попадания.
func _fire_enemy_bullet_at_player(timeout: float) -> void:
	var hp_before := _level.player.hp
	_level.bullets.fire_enemy(
		_level.player.position + Vector2(0.0, -60.0),
		Vector2.DOWN * 320.0,
		1
	)
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _level.player.hp != hp_before or not _level.player.is_alive:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _wait_until(condition: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _wait_enemy_hp(enemy: EnemyBase, expected_hp: int, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if is_instance_valid(enemy) and enemy.hp == expected_hp:
			return true
		await get_tree().process_frame
	return is_instance_valid(enemy) and enemy.hp == expected_hp


func _wait_enemy_gone(timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _enemy_count() == 0:
			return true
		await get_tree().process_frame
	return _enemy_count() == 0


## Ждёт, пока в контейнере врагов останется ровно expected живых врагов.
func _wait_enemy_count(expected: int, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _enemy_count() == expected:
			return true
		await get_tree().process_frame
	return _enemy_count() == expected


## Ждёт первый снаряд игрока (для проверки скорости/урона автострельбы).
func _wait_player_bullet(timeout: float) -> Bullet:
	var holder: Array = []
	var handler := func(node: Node) -> void:
		var bullet := node as Bullet
		if bullet != null and bullet.kind == Bullet.Kind.PLAYER and holder.is_empty():
			holder.append(bullet)
	_level.bullets.child_entered_tree.connect(handler)
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while holder.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_level.bullets.child_entered_tree.disconnect(handler)
	return holder[0] as Bullet if not holder.is_empty() else null


func _wait_enemy_patrol(enemy: EnemyBase, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if is_instance_valid(enemy) and is_equal_approx(enemy.position.y, EnemyBf109.PATROL_ALTITUDE):
			return true
		await get_tree().process_frame
	return false


func _wait_enemy_bullets(timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _level.bullets.count_bullets(true) > 0:
			return true
		await get_tree().process_frame
	return _level.bullets.count_bullets(true) > 0


func _max_enemy_bullet_speed() -> float:
	var fastest := 0.0
	for child in _level.bullets.get_children():
		var bullet := child as Bullet
		if bullet == null or bullet.is_queued_for_deletion():
			continue
		if bullet.kind == Bullet.Kind.ENEMY:
			fastest = maxf(fastest, bullet.velocity.length())
	return fastest


## Взрывы (juice) в Effects. Опознание по ГРУППЕ: повторные взрывы движок переименовывает.
func _count_explosions() -> int:
	var total := 0
	for child in _level.effects_root.get_children():
		if child.is_in_group(Explosions.GROUP_EXPLOSION) and not child.is_queued_for_deletion():
			total += 1
	return total


func _count_boss_bombs() -> int:
	var total := 0
	for child in _level.effects_root.get_children():
		if child is BossBomb and not child.is_queued_for_deletion():
			total += 1
	return total


func _kill_all_enemies() -> void:
	for child in _level.enemies_root.get_children():
		var enemy := child as EnemyBase
		if enemy != null and enemy.is_active:
			enemy.take_damage(9999)


func _clear_enemies() -> void:
	for child in _level.enemies_root.get_children():
		var enemy := child as EnemyBase
		if enemy != null:
			enemy.despawn()
		else:
			child.queue_free()


# ─── M3-C/M5.3a: файловые помощники рекорда (user://) ───────────────────────
## Лучший результат миссии из файла ПРОГОНА (не через SaveGame: тест читает диск сам).
## M5.3a: сейв v2 пишет рекорд в [records] best_m1..m3 (RunRecord в забеге больше не
## участвует) — берём максимум по трём миссиям, чтобы проверка не зависела от id забега.
func _read_record_best() -> int:
	var config := ConfigFile.new()
	if config.load(_record_path) != OK:
		return -1
	var best := -1
	for index in 3:
		best = maxi(best, int(config.get_value(SAVE_RECORDS_SECTION, "best_m%d" % (index + 1), -1)))
	return best


func _remove_user_file(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write_user_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


## Слепок user:// файла: существование, размер, mtime, текст. mtime+содержимое —
## доказательство, что прогон не перезаписал реальный рекорд игрока.
func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": -1, "mtime": -1, "text": ""}
	var snapshot := {
		"exists": true, "size": -1, "mtime": FileAccess.get_modified_time(path), "text": ""
	}
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		snapshot["size"] = file.get_length()
		snapshot["text"] = file.get_as_text()
		file.close()
	return snapshot


## Dictionary == в GDScript сравнивает по ссылке — поля сравниваем явно.
func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	return bool(a.get("exists", false)) == bool(b.get("exists", false)) \
		and int(a.get("size", -1)) == int(b.get("size", -1)) \
		and int(a.get("mtime", -1)) == int(b.get("mtime", -1)) \
		and String(a.get("text", "")) == String(b.get("text", ""))


func _snapshot_brief(snapshot: Dictionary) -> String:
	if not bool(snapshot.get("exists", false)):
		return "файла нет"
	return "%d байт, mtime %d, «%s»" % [
		int(snapshot.get("size", -1)), int(snapshot.get("mtime", -1)),
		String(snapshot.get("text", "")).strip_edges()]


## Ширина строки Label её реальным шрифтом и размером: длинный русский заголовок
## («Аэродром потерян») обязан влезать в поле 540, иначе края экрана срезают буквы.
func _label_text_width(label: Label) -> float:
	if label == null:
		return 0.0
	var font := label.get_theme_font(&"font")
	if font == null:
		font = ThemeDB.fallback_font
	if font == null:
		return 0.0
	var font_size := label.get_theme_font_size(&"font_size")
	return font.get_string_size(String(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


# ─── M3-A: помощники проверок темы/HUD ───────────────────────────────────────
## Все непустые символы строки есть в шрифте. Пробелы/переводы строк не проверяем.
func _font_covers(font: Font, text: String) -> bool:
	if font == null:
		return false
	for i in text.length():
		var code := text.unicode_at(i)
		if code > 32 and not font.has_char(code):
			return false
	return true


## Какие символы шрифт не покрывает — для details упавшей проверки.
func _missing_glyphs(font: Font, text: String) -> String:
	if font == null:
		return "шрифт null"
	var missing := ""
	for i in text.length():
		var code := text.unicode_at(i)
		if code > 32 and not font.has_char(code):
			missing += String.chr(code)
	return ("нет глифов: " + missing) if missing != "" else "все глифы на месте"


## Метод у class_name ArtStyle (static func): проверяем по списку методов скрипта,
## чтобы не создавать инстанс и не зависеть от рантайм-вызова отрисовки.
func _art_style_has_method(method_name: String) -> bool:
	var script: Variant = ArtStyle
	if script == null:
		return false
	for method: Dictionary in script.get_script_method_list():
		if String(method.get("name", "")) == method_name:
			return true
	return false


## Шрифт темы реально применён к Label: не null, нужное начертание и покрывает весь текст.
func _label_font_covers(label: Label, expected_file: String) -> bool:
	if label == null:
		return false
	var font := label.get_theme_font(&"font")
	if font == null or not _font_covers(font, String(label.text)):
		return false
	return expected_file == "" or String(font.resource_path).ends_with(expected_file)


func _label_font_details(label: Label) -> String:
	if label == null:
		return "Label отсутствует"
	var font := label.get_theme_font(&"font")
	if font == null:
		return "шрифт темы null («%s»)" % String(label.text)
	return "%s %d px «%s»" % [
		String(font.resource_path).get_file(),
		label.get_theme_font_size(&"font_size"),
		String(label.text)]


func _rect_inside(inner: Rect2, outer: Rect2, eps: float = 0.5) -> bool:
	return inner.position.x >= outer.position.x - eps \
		and inner.position.y >= outer.position.y - eps \
		and inner.end.x <= outer.end.x + eps \
		and inner.end.y <= outer.end.y + eps


## Пересечение с допуском 0.5 px: касание краями (HPLabel.end.x == ScoreLabel.x) — не перекрытие.
func _rects_overlap(a: Rect2, b: Rect2) -> bool:
	return a.position.x < b.end.x - 0.5 and b.position.x < a.end.x - 0.5 \
		and a.position.y < b.end.y - 0.5 and b.position.y < a.end.y - 0.5


func _first_pickup() -> Pickup:
	for child in _level.pickups_root.get_children():
		var pickup := child as Pickup
		if pickup != null and not pickup.is_queued_for_deletion():
			return pickup
	return null


func _first_enemy() -> EnemyBase:
	for child in _level.enemies_root.get_children():
		var enemy := child as EnemyBase
		if enemy != null and not enemy.is_queued_for_deletion():
			return enemy
	return null


func _enemy_count() -> int:
	var total := 0
	for child in _level.enemies_root.get_children():
		if child is EnemyBase and not child.is_queued_for_deletion():
			total += 1
	return total


func _count_bf109() -> int:
	var total := 0
	for child in _level.enemies_root.get_children():
		if child is EnemyBf109 and not child.is_queued_for_deletion():
			total += 1
	return total


func _on_bullet_spawned(node: Node) -> void:
	var bullet := node as Bullet
	if bullet != null and bullet.kind == Bullet.Kind.PLAYER:
		_player_shots_spawned += 1


func _count_playing_sfx(audio: AudioManager) -> int:
	var playing := 0
	for child in audio.get_children():
		var player := child as AudioStreamPlayer
		if player != null and player.playing and String(player.name).begins_with("Sfx"):
			playing += 1
	return playing


## Самый «свежий» играющий голос КОНКРЕТНОГО SFX (bomb.wav и т.п.). Пул переиспользуется
## по кругу, поэтому один и тот же ключ может звучать сразу на нескольких голосах; для
## проверок паузы нужен тот, что начался последним (у него впереди весь клип), а не чужой
## короткий клип из первого свободного голоса.
func _playing_sfx_voice(audio: AudioManager, key: StringName) -> AudioStreamPlayer:
	var expected_file := "%s.wav" % String(key)
	var best: AudioStreamPlayer = null
	var best_pos := INF
	for child in audio.get_children():
		var player := child as AudioStreamPlayer
		if player == null or not player.playing or not String(player.name).begins_with("Sfx"):
			continue
		if player.stream == null or player.stream.resource_path.get_file() != expected_file:
			continue
		var pos := player.get_playback_position()
		if pos < best_pos:
			best = player
			best_pos = pos
	return best


func _count_sfx_players(audio: AudioManager) -> int:
	var total := 0
	for child in audio.get_children():
		if child is AudioStreamPlayer and String(child.name).begins_with("Sfx"):
			total += 1
	return total


## M3-E: порядок отрисовки Node2D = обход дерева в глубину. World в рантайме живёт
## внутри обёртки ScreenShake (тряска), поэтому get_index() соседей ничего не доказывает.
func _draw_rank(root: Node, target: Node) -> int:
	var order: Array[Node] = []
	_collect_draw_order(root, order)
	return order.find(target)


func _collect_draw_order(node: Node, out: Array[Node]) -> void:
	out.append(node)
	for child in node.get_children():
		_collect_draw_order(child, out)


## M3-E: есть ли над узлом CanvasLayer (тогда порядок отрисовки задаёт слой, а не дерево).
func _has_canvas_layer_parent(node: Node) -> bool:
	var current := node.get_parent()
	while current != null:
		if current is CanvasLayer:
			return true
		current = current.get_parent()
	return false


## M3-E: физические узлы в поддереве фона — фон обязан быть чистым декором.
func _count_physics_nodes(root: Node) -> int:
	var total := 0
	for child in root.get_children():
		if child is CollisionObject2D or child is CollisionShape2D:
			total += 1
		total += _count_physics_nodes(child)
	return total


## M3-E: имена методов, объявленных в скрипте (виртуальные — в том числе).
func _script_method_names(script: Script) -> Array[String]:
	var names: Array[String] = []
	if script == null:
		return names
	for method: Dictionary in script.get_script_method_list():
		names.append(String(method.get("name", "")))
	return names


## M3-E: исходник скрипта — проверяем ссылки на палитру ArtStyle без попиксельного
## сравнения картинки (рендер остаётся свободным, контракт палитры — жёстким).
func _script_source(script: Script) -> String:
	if script == null:
		return ""
	var code: String = script.source_code
	if code.is_empty() and not script.resource_path.is_empty():
		code = FileAccess.get_file_as_string(script.resource_path)
	return code


## M3-E: тело одной функции из исходника. По нему видно, что в _draw фон не
## собирает геометрию и не создаёт узлы (рендер идёт по готовым массивам).
func _function_body(source: String, function_name: String) -> String:
	var marker := "func " + function_name + "("
	var start := source.find(marker)
	if start < 0:
		return ""
	var next_function := source.find("\nfunc ", start + marker.length())
	if next_function < 0:
		return source.substr(start)
	return source.substr(start, next_function - start)


## M3-E: относительная яркость цвета (без alpha) — пороги читаемости фона.
func _luminance(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


## M3-E: RGB-расстояние между цветами — «темы не одинаковые» без сравнения кадра.
func _color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
