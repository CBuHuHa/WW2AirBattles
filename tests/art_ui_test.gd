# art_ui_test.gd
# Purpose: Гейт M7c «три импортированных PNG подключены к UI» (GDD «Assets», «UI / HUD»,
#          «Game feel»):
#            * файлы/импорт: pickup_repair, ui_bomb, ui_star существуют, lossless без мипмапов,
#              ArtAssets не подменяет эти ключи чужими спрайтами (никакого temp reuse);
#            * Pickup: иконка из PNG, DRAW_SIZE = половина PNG (1/2, nearest), зона подбора
#              PICKUP_RADIUS и CollisionShape2D не изменились, подбор по-прежнему срабатывает;
#            * BombButton: иконка из PNG в прямоугольник 48×48, заряды/mouse_filter/зона тапа
#              те же, неактивная кнопка остаётся с иконкой (alpha);
#            * WinOverlay (M11/T4): звёзды показаны ОДИН раз — StarsLine пишет только подпись
#              «Звёзды:» (без глифов ★/☆), а ряд из 3 иконок ui_star 24×24 стоит сразу справа
#              (зазор 8), группа «подпись + иконки» центрирована по полосе (±2); 2 звезды → 2
#              заполнены, 0 → 0; 4-аргументный show_result жив;
#            * строки-подсказки (узел Hint) на экране победы больше нет (M11/T3, решение D4);
#            * main.tscn: инстанс поднимается, строки итогов и кнопка бомбы не сдвинуты.
#          Изоляция: сейв уводится в user://qa_art_ui_*.cfg, реальный
#          user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/art_ui_test.tscn
# Dependencies: ArtAssets, ArtStyle, Pickup, BombButton, WinOverlay, LevelController (main.tscn),
#               SaveGame/RunRecord, GameConfig.
# Author: Technical Artist Agent (M7c)

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")

## Три ключа, которые M7c подключает к UI (до этого файлы были импортированы, но не рисовались).
const UI_KEYS := [&"pickup_repair", &"ui_bomb", &"ui_star"]
## Размер исходных PNG smoke-листа M7a: арт 64×64, отрисовка — целым коэффициентом.
const SOURCE_PIXELS := Vector2(64.0, 64.0)
## Геометрия из GDD «Assets», которая артом не двигается.
const EXPECTED_BOMB_ICON := Vector2(48.0, 48.0)
const EXPECTED_STAR_ICON := Vector2(24.0, 24.0)
const EXPECTED_PICKUP_RADIUS := 16.0
const EXPECTED_TOUCH_SIZE := Vector2(96.0, 96.0)

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}
var _level: LevelController


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_art_ui_%d.cfg" % Time.get_ticks_msec()
	SaveGame.set_save_path(_path)
	await get_tree().process_frame
	await _run()
	if _level != null:
		_level.queue_free()
		_level = null
	await get_tree().process_frame
	_remove_file(_path)
	RunRecord.reset_save_path()
	_check("изоляция: путь вернулся к DEFAULT_PATH и qa-файл удалён",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH and not FileAccess.file_exists(_path),
		SaveGame.get_save_path())
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_snapshot, _file_snapshot(RunRecord.DEFAULT_PATH)),
		"%s → %s" % [_snapshot_brief(_real_snapshot),
			_snapshot_brief(_file_snapshot(RunRecord.DEFAULT_PATH))])
	print("ART_UI_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("ART_UI_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_check_files_and_registry()
	await _check_pickup()
	await _check_bomb_button_fallback()
	await _check_main_scene()


# ─── Файлы, импорт и реестр ─────────────────────────────────────────────────
func _check_files_and_registry() -> void:
	var missing: Array[String] = []
	for key: StringName in UI_KEYS:
		if not FileAccess.file_exists(ArtAssets.path_for(key)):
			missing.append(String(key))
	_check("файлы: pickup_repair / ui_bomb / ui_star существуют в assets/art", missing.is_empty(),
		str(missing))

	var import_details := ""
	var import_ok := true
	for key: StringName in UI_KEYS:
		var path := ArtAssets.path_for(key) + ".import"
		var text := ""
		if FileAccess.file_exists(path):
			text = FileAccess.get_file_as_string(path)
		if not text.contains("compress/mode=0") or not text.contains("mipmaps/generate=false"):
			import_ok = false
			import_details += "%s без lossless/без mipmaps-off; " % String(key)
	_check("импорт: у всех трёх .import с compress/mode=0 и mipmaps/generate=false", import_ok,
		import_details)

	var remapped: Array[String] = []
	for key: StringName in UI_KEYS:
		if ArtAssets.render_key(key) != key:
			remapped.append("%s → %s" % [String(key), String(ArtAssets.render_key(key))])
	_check("ключи: три UI-ключа не подменяются чужими спрайтами (нет temp reuse)",
		remapped.is_empty(), str(remapped))

	var wrong_size: Array[String] = []
	for key: StringName in UI_KEYS:
		var tex := ArtAssets.texture(key)
		if tex == null or tex.get_size() != SOURCE_PIXELS:
			wrong_size.append("%s: %s" % [String(key),
				str(tex.get_size()) if tex != null else "null"])
	_check("текстуры: все три PNG 64×64 и грузятся без ошибок", wrong_size.is_empty(),
		str(wrong_size))


# ─── Pickup: иконка из PNG, зона подбора прежняя ────────────────────────────
func _check_pickup() -> void:
	var host := Node2D.new()
	host.name = "PickupHost"
	add_child(host)
	await get_tree().process_frame

	var pickup := Pickup.new()
	host.add_child(pickup)
	pickup.setup(Pickup.Kind.REPAIR, Vector2(120.0, 300.0))
	await get_tree().process_frame

	_check("Pickup: иконка рисуется из PNG (ключ pickup_repair)",
		pickup.is_using_texture() and pickup.get_texture_key() == &"pickup_repair",
		"%s / %s" % [pickup.is_using_texture(), String(pickup.get_texture_key())])
	_check("Pickup: DRAW_SIZE 32 = ровно 1/2 PNG (nearest без «дыр» в контуре)",
		is_equal_approx(Pickup.DRAW_SIZE, SOURCE_PIXELS.x * 0.5)
		and is_equal_approx(Pickup.DRAW_SIZE, 32.0),
		str(Pickup.DRAW_SIZE))
	_check("Pickup: фильтр узла — nearest (иконка не размывается)",
		pickup.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		str(pickup.texture_filter))
	_check("Pickup: зона подбора не изменилась (PICKUP_RADIUS 16, CollisionShape2D r=16)",
		is_equal_approx(Pickup.PICKUP_RADIUS, EXPECTED_PICKUP_RADIUS)
		and is_equal_approx(_area_radius(pickup), EXPECTED_PICKUP_RADIUS),
		"%.1f / %.1f" % [Pickup.PICKUP_RADIUS, _area_radius(pickup)])
	_check("Pickup: единственный вид подбора остался REPAIR",
		Pickup.Kind.keys() == ["REPAIR"], str(Pickup.Kind.keys()))

	# Подбор работает и с артом: перекрытие с игроком отдаёт сигнал collected(kind).
	var player := PLAYER_SCENE.instantiate() as Player
	player.set_process(false)
	player.set_physics_process(false)
	host.add_child(player)
	player.global_position = pickup.global_position
	var collected: Array[int] = []
	pickup.collected.connect(func(kind: int, _at: Vector2) -> void: collected.append(kind))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check("Pickup: подбор по-прежнему срабатывает (collected → REPAIR)",
		collected.size() == 1 and collected[0] == Pickup.Kind.REPAIR, str(collected))

	# Фолбэк: флаг выключает арт (как ShipVisual.use_sprite_art) — узел живёт на ArtStyle.
	var silent := Pickup.new()
	silent.use_sprite_art = false
	host.add_child(silent)
	silent.setup(Pickup.Kind.REPAIR, Vector2(320.0, 300.0))
	await get_tree().process_frame
	_check("Pickup: use_sprite_art=false → код-силуэт ArtStyle (нет текстуры)",
		not silent.is_using_texture() and silent.get_texture_key() == &""
		and silent.is_visible_in_tree(),
		"%s / %s" % [silent.is_using_texture(), String(silent.get_texture_key())])
	_check("Pickup: контракт фолбэка — неизвестный ключ даёт null без ERROR",
		ArtAssets.texture(&"no_such_asset") == null and not ArtAssets.has_texture(&"no_such_asset"))

	host.queue_free()
	await get_tree().process_frame


# ─── BombButton вне сцены: фолбэк на код-силуэт ─────────────────────────────
func _check_bomb_button_fallback() -> void:
	var button := BombButton.new()
	button.use_sprite_art = false
	button.set_charges(1)
	add_child(button)
	await get_tree().process_frame
	_check("BombButton: use_sprite_art=false → код-силуэт ArtStyle (нет текстуры)",
		not button.is_using_texture() and button.get_texture_key() == &""
		and button.get_charges() == 1,
		"%s / %s" % [button.is_using_texture(), String(button.get_texture_key())])
	button.queue_free()
	await get_tree().process_frame


# ─── main.tscn: BombButton, WinOverlay и иконки звёзд ───────────────────────
func _check_main_scene() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	await get_tree().process_frame

	var overlay := _level.win_overlay
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var score_line := overlay.get_node(^"ScoreLine") as Label
	var time_line := overlay.get_node(^"TimeLine") as Label
	var record_line := overlay.get_node(^"RecordLine") as Label
	var stars_line := overlay.get_node(^"StarsLine") as Label
	var supply_line := overlay.get_node(^"SupplyLine") as Label
	var replay_button := overlay.get_node(^"ReplayButton") as Button
	var campaign_button := overlay.get_node(^"CampaignButton") as Button
	var home_button := overlay.get_node(^"HomeButton") as Button
	_check("main.tscn: инстанс поднимается, экран победы скрыт, строки и кнопка «Повторить» на месте",
		_level != null and not overlay.visible
		and score_line != null and time_line != null and record_line != null
		and stars_line != null and supply_line != null and replay_button != null)
	_check("main.tscn: узла Hint в WinOverlay больше нет (M11/T3, решение D4)",
		overlay.get_node_or_null(^"Hint") == null)

	# ── Геометрия, которую фиксирует smoke: иконки ничего не сдвинули ───────
	var record_rect := record_line.get_global_rect()
	var stars_rect := stars_line.get_global_rect()
	var supply_rect := supply_line.get_global_rect()
	var replay_rect := replay_button.get_global_rect()
	var time_rect := time_line.get_global_rect()
	var score_rect := score_line.get_global_rect()
	_check("раскладка: RecordLine между TimeLine и StarsLine (контракт smoke)",
		record_rect.position.y >= time_rect.end.y - 0.5
		and stars_rect.position.y >= record_rect.end.y - 0.5,
		"time=%s, record=%s, stars=%s" % [time_rect, record_rect, stars_rect])
	_check("раскладка: SupplyLine под StarsLine, кнопки исхода ниже строк (зазор вместо Hint)",
		supply_rect.position.y >= stars_rect.end.y - 0.5
		and replay_rect.position.y >= supply_rect.end.y - 0.5,
		"stars=%s, supply=%s, replay=%s" % [stars_rect, supply_rect, replay_rect])
	_check("раскладка: строки не перекрываются, кнопки 320×88 и всё внутри поля 540×960",
		not _rects_overlap(record_rect, score_rect)
		and not _rects_overlap(record_rect, time_rect)
		and not _rects_overlap(stars_rect, supply_rect)
		and not _rects_overlap(replay_rect, supply_rect)
		and is_equal_approx(replay_rect.size.x, 320.0)
		and is_equal_approx(replay_rect.size.y, 88.0)
		and _rect_inside(record_rect, field)
		# M11/T4: полоса StarsLine сжимается/сдвигается под группу «подпись + иконки», поэтому
		# её собственный rect может выйти за поле влево — по вертикали она обязана остаться в поле,
		# а попадание группы в поле проверяется ниже (после show_result).
		and stars_rect.position.y >= field.position.y and stars_rect.end.y <= field.end.y
		and _rect_inside(supply_rect, field) and _rect_inside(replay_rect, field)
		and _rect_inside(campaign_button.get_global_rect(), field)
		and _rect_inside(home_button.get_global_rect(), field),
		"record=%s, stars=%s, supply=%s, replay=%s" % [
			record_rect, stars_rect, supply_rect, replay_rect])

	# ── show_result с 2 звёздами: ряд иконок ────────────────────────────────
	overlay.show_result(1234, 65.0, 1234, true, 2, 150)
	await get_tree().process_frame
	_check("звёзды: ряд из 3 иконок, 2 заполнены при stars=2",
		overlay.get_star_icon_count() == 3 and overlay.get_star_filled_count() == 2,
		"%d / %d" % [overlay.get_star_icon_count(), overlay.get_star_filled_count()])
	_check("звёзды: текстура ряда — ui_star, ряд виден", overlay.get_star_texture_key() == &"ui_star"
		and overlay.is_star_row_visible(), String(overlay.get_star_texture_key()))

	var icons: Array[TextureRect] = []
	var icons_ok := true
	var icons_details := ""
	var row := overlay.star_icons
	if row != null:
		for child in row.get_children():
			var icon := child as TextureRect
			if icon == null:
				continue
			icons.append(icon)
			if icon.texture == null or not icon.visible:
				icons_ok = false
				icons_details += "иконка без текстуры/скрыта; "
			if icon.texture_filter != CanvasItem.TEXTURE_FILTER_NEAREST:
				icons_ok = false
				icons_details += "фильтр %d; " % icon.texture_filter
			if not is_equal_approx(icon.size.x, EXPECTED_STAR_ICON.x) \
					or not is_equal_approx(icon.size.y, EXPECTED_STAR_ICON.y):
				icons_ok = false
				icons_details += "размер %s; " % icon.size
	_check("звёзды: 3 TextureRect 24×24 с nearest и текстурой", icons_ok and icons.size() == 3,
		icons_details)
	_check("звёзды: альфы 1.0 / 1.0 / 0.25 (заполненные / пустая)",
		icons.size() == 3 and is_equal_approx(icons[0].modulate.a, 1.0)
		and is_equal_approx(icons[1].modulate.a, 1.0)
		and is_equal_approx(icons[2].modulate.a, WinOverlay.STAR_EMPTY_ALPHA),
		str([
			icons[0].modulate.a, icons[1].modulate.a, icons[2].modulate.a
		]) if icons.size() == 3 else "нет иконок")
	_check("звёзды: текст StarsLine — только подпись «Звёзды:» (без дубля глифов ★/☆)",
		String(stars_line.text) == WinOverlay.STARS_LABEL_TEXT
		and not String(stars_line.text).contains("★")
		and not String(stars_line.text).contains("☆"),
		String(stars_line.text))

	var row_rect := row.get_global_rect()
	var stars_now := stars_line.get_global_rect()
	var text_width := _label_text_width(stars_line)
	# Горизонтальная раскладка M11/T4: подпись внутри 540-полосы сдвинута так, чтобы её текст
	# начинался в группе, ряд иконок стоит сразу за текстом с зазором 8, вся группа — по центру.
	var text_left := stars_now.position.x + (stars_now.size.x - text_width) * 0.5
	# M11/T4: полоса StarsLine в сцене занимает всё поле (0…540), поэтому её центр совпадает
	# с центром поля 270 — группа «подпись + 3 иконки» центрируется именно по нему.
	var band_center_x := field.position.x + field.size.x * 0.5
	var band_center_y := stars_rect.position.y + stars_rect.size.y * 0.5
	var row_center_y := row_rect.position.y + row_rect.size.y * 0.5
	var expected_row_width := EXPECTED_STAR_ICON.x * 3.0 \
		+ float(WinOverlay.STAR_ICON_SEPARATION) * 2.0
	_check("звёзды: ряд 3×24 + 2×4, по центру полосы по вертикали и внутри поля",
		is_equal_approx(row_rect.size.x, expected_row_width)
		and is_equal_approx(row_rect.size.y, EXPECTED_STAR_ICON.y)
		and absf(row_center_y - band_center_y) <= 1.0
		and _rect_inside(row_rect, field),
		"row=%s, band_center_y=%.1f" % [row_rect, band_center_y])
	_check("звёзды: ряд встаёт сразу справа от подписи с зазором 8 px",
		is_equal_approx(row_rect.position.x - (text_left + text_width),
			WinOverlay.STAR_ICON_TEXT_GAP),
		"row.x=%.1f, конец текста=%.1f" % [row_rect.position.x, text_left + text_width])
	_check("звёзды: группа «подпись + 3 иконки» центрирована по полосе (±2 px) и внутри поля",
		absf((text_left + row_rect.end.x) * 0.5 - band_center_x) <= 2.0
		and text_left >= field.position.x and row_rect.end.x <= field.end.x,
		"группа=%.1f…%.1f, центр полосы=%.1f" % [text_left, row_rect.end.x, band_center_x])
	_check("звёзды: ряд не наезжает на RecordLine и SupplyLine",
		not _rects_overlap(row_rect, record_rect) and not _rects_overlap(row_rect, supply_rect),
		"row=%s, record=%s, supply=%s" % [row_rect, record_rect, supply_rect])

	# ── stars=0 и старый 4-аргументный вызов ───────────────────────────────
	overlay.show_result(1234, 65.0, 1234, true, 0, 0)
	_check("звёзды: stars=0 → 0 заполнено, текст остаётся подписью «Звёзды:»",
		overlay.get_star_filled_count() == 0
		and String(stars_line.text) == WinOverlay.STARS_LABEL_TEXT, String(stars_line.text))
	overlay.show_result(900, 60.0, 1234, false)
	_check("звёзды: 4-аргументный show_result не падает, 0 заполнено, рекорд прежний",
		overlay.get_star_filled_count() == 0
		and String(stars_line.text) == WinOverlay.STARS_LABEL_TEXT
		and String(record_line.text) == "Рекорд: 1234"
		and String(supply_line.text) == "Снабжение: +0"
		and overlay.best_score == 1234 and not overlay.is_new_record,
		"%s / %s" % [record_line.text, supply_line.text])
	overlay.hide_overlay()

	# ── BombButton в сцене: иконка, заряды, touch-зона ─────────────────────
	var bomb := _level.bomb_button
	bomb.set_charges(1)
	await get_tree().process_frame
	_check("BombButton: иконка из PNG (ключ ui_bomb)",
		bomb.is_using_texture() and bomb.get_texture_key() == &"ui_bomb",
		"%s / %s" % [bomb.is_using_texture(), String(bomb.get_texture_key())])
	_check("BombButton: прямоугольник иконки 48×48 из GDD влезает в круг r46",
		ArtStyle.size_of(BombButton.ICON_KEY) == EXPECTED_BOMB_ICON
		and EXPECTED_BOMB_ICON.x <= BombButton.BUTTON_RADIUS * 2.0,
		str(ArtStyle.size_of(BombButton.ICON_KEY)))
	_check("BombButton: зона тапа 96×96 и заряды как раньше (STOP при 1, IGNORE при 0)",
		bomb.custom_minimum_size == EXPECTED_TOUCH_SIZE
		and BombButton.TOUCH_SIZE == EXPECTED_TOUCH_SIZE
		and bomb.get_charges() == 1 and bomb.mouse_filter == Control.MOUSE_FILTER_STOP,
		"%s / фильтр %d" % [bomb.custom_minimum_size, bomb.mouse_filter])
	bomb.set_charges(0)
	_check("BombButton: при 0 зарядов кнопка пропускает тапы, но иконка остаётся",
		bomb.get_charges() == 0 and bomb.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and bomb.is_using_texture())
	_level.queue_free()
	_level = null
	await get_tree().process_frame


# ─── Хелперы ────────────────────────────────────────────────────────────────
func _area_radius(area: Area2D) -> float:
	for child in area.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node == null:
			continue
		var circle := shape_node.shape as CircleShape2D
		if circle != null:
			return circle.radius
	return -1.0


func _label_text_width(label: Label) -> float:
	var font := label.get_theme_font(&"font")
	if font == null:
		return 0.0
	return font.get_string_size(String(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1,
		label.get_theme_font_size(&"font_size")).x


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
