# tools/capture_store_screenshots.gd
# Purpose: M8c2 — снять 4 реальных скриншота игры для Google Play (1080×1920, 9:16)
#          без отладочных оверлеев. DEV-ИНСТРУМЕНТ: лежит в tools/, поэтому не попадает
#          в APK/AAB (exclude_filter обоих пресетов содержит tools/*).
#          Сцена инстансит res://scenes/main.tscn и проходит реальные экраны:
#              Home → «Кампания» → выбор миссии → «В бой» (реальный забег m1) → победа → Home → «Ангар».
#          Ни один экран не рисуется вручную: игра работает как есть, а забег играется
#          настоящими событиями тача (InputEventScreenTouch/Drag через Input.parse_input_event),
#          поэтому самолёт уклоняется от пуль и доживает до середины миссии.
#          Профиль игрока изолирован (user://store_capture.cfg, удаляется на старте), аналитика
#          выключена — реальные user://ww2_air_battles.cfg и user://analytics.log не трогаются.
#          Окно принудительно 1080×1920, поэтому 540-канвас рендерится в 2× масштабе
#          (stretch canvas_items) — текст и пиксель-арт остаются чёткими, апскейл не нужен.
#          M11: экран победы снимается QA-хуком LevelController.qa_force_win() (только
#          debug-сборка, в релизе no-op): m1 скриптовым вводом не проходится. Debug-кнопка
#          «QA» (_create_qa_force_win_button) в кадр не попадает — тул её прячет.
# Run (окном, НЕ headless — headless не рисует):
#   godot --path D:\WW2AirBattles --resolution 1080x1920 res://tools/capture_store_screenshots.tscn
# Output: store/screenshots/01_home.png, 02_mission_select.png, 04_hangar.png,
#         серия кадров забега 03_gameplay_1..N (снимаются каждые 1.5 с волн 1–3:
#         из них выбирается лучший кадр — враги в поле, HP не на нуле — и копируется
#         в 03_gameplay.png, остальные удаляются) и 05_win.png (экран победы M11:
#         подпись «Звёзды:» + ряд пиксельных иконок, три кнопки исхода, без подсказки).
#         Кадры нужно пересохранить в RGB: viewport отдаёт RGBA, а стор-листингу нужен PNG без альфы.
# Author: QA Agent (M8c2)

extends Node

## Куда пишем PNG (путь проекта, не user://: файлы сразу нужны в repo для стор-листинга).
const SHOT_DIR_REL := "store/screenshots"
## 9:16 1080×1920: рекомендуемый формат скриншотов Play для телефонов.
const TARGET_SIZE := Vector2i(1080, 1920)
## Изолированный профиль: реальный сейв игрока не читается и не перезаписывается.
const CAPTURE_SAVE_PATH := "user://store_capture.cfg"

## «Палец» для настоящих touch-событий: игрок двигается драгом 1:1, как в руках.
## Стартовая точка совпадает с позицией игрока (270, 840), поэтому драг идёт без смещения
## захвата; границы держат самолёт левее кнопки бомбы (круг r46 с центром ~(459,900)),
## иначе в стор-кадре нос закрыт кнопкой.
const FINGER_Y := 700.0
const DODGE_CENTER_X := 270.0
const DODGE_AMPLITUDE := 120.0
const DODGE_PERIOD := 1.6
const DODGE_MIN_X := 80.0
const DODGE_MAX_X := 380.0
## Моменты съёмки забега (с от старта): частые кадры волн 1–3 — из них выбирается
## лучший (враги в кадре, HP не на нуле), лишние кадры удаляются.
const GAMEPLAY_SHOT_TIMES: Array[float] = [
	3.0, 4.5, 6.0, 7.5, 9.0, 10.5, 12.0, 13.5, 15.0, 16.5, 18.0,
]
## Максимум попыток забега (самолёт без «игрока» может погибнуть до кадра).
const MAX_RUN_ATTEMPTS := 3

## M11: имена кадра экрана победы и значения LevelController.State, которые нужны тулу.
## Порядок enum: BRIEFING, PLAYING, PAUSED, DEAD, WON (scripts/level_controller.gd).
const WIN_SHOT := "05_win"
const STATE_PLAYING := 1
const STATE_WON := 4
## FINISH_DELAY_WIN (0.5 с) + время на показ оверлея и раскладку ряда иконок звёзд.
const WIN_SHOT_DELAY := 1.4

## LevelController (нетипизированный: вызовы публичного QA/игрового API — динамические).
var _level
var _shot_dir := ""
## Игрок и слой пуль уровня (ищутся рекурсивно: World переезжает под ScreenShake).
var _player
var _bullets
## Драг-«палец»: позиция последнего отправленного touch-события (в координатах канвы).
var _finger := Vector2(DODGE_CENTER_X, FINGER_Y)
## Идёт ли игровой забег (тогда _process двигает палец и шлёт drag-события).
var _playing := false
var _dodge_time := 0.0
## Масштаб канва → окно: события тача приходят в координатах окна, а палец считается
## по канве 540×960 (иначе драг «делится» на 2 и самолёт почти не двигается).
var _input_scale := 1.0


func _ready() -> void:
	# Скриншоты снимаются и на паузе (выбор перка/итоги), поэтому узел — ALWAYS.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_shot_dir = ProjectSettings.globalize_path("res://" + SHOT_DIR_REL)
	DirAccess.make_dir_recursive_absolute(_shot_dir)

	SaveGame.set_save_path(CAPTURE_SAVE_PATH)
	SaveGame.reset()
	Analytics.set_enabled(false)

	# Окно 1080×1920: canvas_items stretch растягивает базу 540×960 ровно в 2×.
	get_window().size = TARGET_SIZE
	DisplayServer.window_set_size(TARGET_SIZE)
	await get_tree().process_frame
	await get_tree().process_frame
	_input_scale = float(get_window().size.x) / maxf(1.0, get_viewport().get_visible_rect().size.x)
	print("CAPTURE window=", get_window().size, " viewport=", get_viewport().get_visible_rect().size,
		" input_scale=", _input_scale)

	_level = load("res://scenes/main.tscn").instantiate()
	add_child(_level)
	await get_tree().process_frame
	_player = _level.find_child("Player", true, false)
	_bullets = _level.find_child("Bullets", true, false)
	# M11 (T8): debug-кнопка «QA» (принудительная победа) — тул-хук, а не игровой UI,
	# в стор-кадр она попадать не должна. Прячем, победу зовём напрямую qa_force_win().
	var qa_button := _level.get_node_or_null("UI/QAForceWinButton") as Control
	if qa_button != null:
		qa_button.visible = false
		print("CAPTURE QA-кнопка скрыта")

	# 1. Домашний экран (он же экран запуска приложения, M8c1).
	await _wait(0.8)
	await _shoot("01_home")

	# 2. Выбор миссии — через настоящий сигнал «Кампания» (Home сам скрывается).
	_level.get_node("UI/Home").request_campaign()
	await _wait(0.6)
	await _shoot("02_mission_select")

	# 3. Геймплей миссии 1: реальный забег с настоящим драг-управлением.
	await _capture_gameplay()

	# 3b. Экран победы M11: подпись «Звёзды:» + ряд пиксельных иконок, три кнопки исхода.
	await _capture_win()

	# 4. Ангар — через Home («В ангар» ведёт туда же из паузы).
	_playing = false
	_level.show_home()
	await _wait(0.4)
	_level.get_node("UI/Home").request_hangar()
	await _wait(0.6)
	await _shoot("04_hangar")

	SaveGame.reset()
	print("CAPTURE done -> ", _shot_dir)
	get_tree().quit()


# ─── Забег: реальное управление тачем ───────────────────────────────────────
## Забег миссии 1: несколько кадров в разные моменты миссии (волны 1–3). Первый
## предложенный перк берётся через реальный UI-API, чтобы на поздних кадрах были
## заполненные слоты перков. Если самолёт погиб раньше — повтор забега.
func _capture_gameplay() -> void:
	for attempt in MAX_RUN_ATTEMPTS:
		_level.start_level()
		_level.get_node("UI/HintsOverlay").hide_hints()
		_start_touch()
		var shot_index := 0
		var elapsed := 0.0
		while shot_index < GAMEPLAY_SHOT_TIMES.size():
			_level.get_node("UI/HintsOverlay").hide_hints()
			if (_level.get_node("UI/DeathOverlay") as Control).visible:
				break
			var choice = _level.get_node("UI/PerkChoice")
			if (choice as Control).visible:
				# Пауза выбора перка: берём первую карту реальным путём и продолжаем забег.
				var offers: Array = choice.get_offered_ids()
				if offers.size() > 0:
					choice.request_perk(String(offers[0]))
					print("CAPTURE perk=", offers[0])
				continue
			if elapsed >= GAMEPLAY_SHOT_TIMES[shot_index]:
				await _shoot("03_gameplay_%d" % (shot_index + 1))
				shot_index += 1
				elapsed += 0.1
				continue
			await _wait(0.1)
			elapsed += 0.1
		_stop_touch()
		print("CAPTURE attempt %d: кадров боя %d" % [attempt + 1, shot_index])
		if shot_index > 0:
			return
	# Худший случай: кадров боя нет — снимаем старт волны 1 (реальный кадр, без поражения).
	_level.start_level()
	_level.get_node("UI/HintsOverlay").hide_hints()
	await _wait(1.2)
	await _shoot("03_gameplay_1")


# ─── Экран победы (M11) ─────────────────────────────────────────────────────
## Кадр экрана победы: подпись «Звёзды:» + ряд из 3 пиксельных иконок, строки счёта/времени/
## рекорда/снабжения и три кнопки исхода 320×88 («Повторить»/«Кампания»/«В ангар»).
## Победу даёт QA-хук LevelController.qa_force_win() — m1 скриптовым вводом не проходится;
## хук в релизной сборке no-op (guard OS.is_debug_build()), а в кадр он не попадает (кнопка
## «QA» спрятана в _ready). Звёзды считает настоящий CampaignProgress: победа засчитывается
## как пройденная миссия, а HP-звезда зависит от того, дожил ли самолёт в забеге.
func _capture_win() -> void:
	_stop_touch()
	if int(_level.get_state()) != STATE_PLAYING:
		# Забег закончился поражением — начинаем новый и сразу завершаем его победой.
		_level.start_level()
		_level.get_node("UI/HintsOverlay").hide_hints()
		await _wait(1.5)
	_level.qa_force_win()
	await _wait(WIN_SHOT_DELAY)
	var state := int(_level.get_state())
	var overlay = _level.get_node("UI/WinOverlay")
	if overlay.visible and state == STATE_WON:
		var stars_line = overlay.get_node("StarsLine") as Label
		var star_row = overlay.get_node("StarIcons")
		print("CAPTURE win stars_line=%s star_row=%s filled=%d" % [stars_line.text,
			str(star_row.size), overlay.get_star_filled_count()])
		await _shoot(WIN_SHOT)
		return
	# Победа не показалась (не debug-сборка / хук не сработал) — кадр не подменяем.
	print("CAPTURE WARNING: экран победы не открылся (state=%d, visible=%s)" % [state, overlay.visible])


func _start_touch() -> void:
	_finger = Vector2(DODGE_CENTER_X, FINGER_Y)
	_dodge_time = 0.0
	_playing = true
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = _finger * _input_scale
	Input.parse_input_event(press)


func _stop_touch() -> void:
	if not _playing:
		return
	_playing = false
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.pressed = false
	release.position = _finger * _input_scale
	Input.parse_input_event(release)


## Уклонение: синусоида по X плюс отход от ближайшей вражеской пули, летящей в лоб.
## Каждый кадр отправляется настоящий ScreenDrag — игрок двигается ровно тем же путём,
## что и от пальца (драг 1:1), а не телепортируется в обход игры.
func _process(delta: float) -> void:
	if not _playing:
		return
	_dodge_time += delta
	var target := DODGE_CENTER_X + DODGE_AMPLITUDE * sin(TAU * _dodge_time / DODGE_PERIOD)
	target += _threat_offset()
	var next := Vector2(clampf(target, DODGE_MIN_X, DODGE_MAX_X), FINGER_Y)
	if next.is_equal_approx(_finger):
		return
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = next * _input_scale
	drag.relative = (next - _finger) * _input_scale
	_finger = next
	Input.parse_input_event(drag)


## Смещение в сторону от самой опасной вражеской пули в передней полусфере:
## чем ближе пуля по X и чем ближе к самолёту по Y, тем сильнее отход.
func _threat_offset() -> float:
	if _bullets == null or _player == null:
		return 0.0
	var pos: Vector2 = _player.global_position
	var best_weight := 0.0
	var best_x := 0.0
	for node in _bullets.get_children():
		var bullet := node as Bullet
		if bullet == null or bullet.kind != Bullet.Kind.ENEMY:
			continue
		var delta_pos: Vector2 = bullet.global_position - pos
		if delta_pos.y > 70.0 or delta_pos.y < -560.0:
			continue
		if absf(delta_pos.x) > 80.0:
			continue
		var weight := 1.0 - absf(delta_pos.x) / 80.0
		if weight > best_weight:
			best_weight = weight
			best_x = delta_pos.x
	if best_weight <= 0.0:
		return 0.0
	return -signf(best_x if not is_zero_approx(best_x) else 1.0) * 130.0 * best_weight


# ─── Утилиты ────────────────────────────────────────────────────────────────
func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _shoot(shot_name: String) -> void:
	# Диагностика кадра: где самолёт и где «палец» (иначе непонятно, почему кадр пустой).
	if _player != null:
		print("CAPTURE %s player=%s finger=%s hp=%s" % [shot_name, _player.position, _finger,
			_player.hp if "hp" in _player else "?"])
	# Кадр должен быть дорисован: иначе в текстуре окажется предыдущий экран.
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_shot_dir, shot_name]
	var err := image.save_png(path)
	print("CAPTURE %s %dx%d err=%d" % [path, image.get_width(), image.get_height(), err])
	await get_tree().process_frame
