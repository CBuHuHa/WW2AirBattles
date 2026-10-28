# art_integration_test.gd
# Purpose: Гейт M7b «пиксель-арт в сценах без смены хитбоксов» (GDD «Assets», «Art direction»,
#          «Временные перки»):
#            * файлы: 9 игровых PNG + 9 `ui_perk_*.png`, lossless-импорт без мипмапов;
#            * ArtAssets: render_key (временное переиспользование Bf 110 / боссов), texture/has_texture,
#              кэш (один ресурс на ключ), perk_icon_key, неизвестный ключ → null/&"";
#            * регресс-страж M9 «экспорт-безопасное существование»: render_key отдаёт все ключи с
#              собственным PNG, пути видны через ResourceLoader.exists, а в исходнике ArtAssets нет
#              проверки ресурса через FileAccess/DirAccess (в APK исходных PNG нет — только .ctex);
#            * ShipVisual: Bf 109 / Bf 110 / He 111 / Ju 88 / Fw 200 / игрок рисуют текстуру,
#              прямоугольник = ArtStyle.draw_size_of(key) = size_of(key) × 1.25 (M11/T5: модели
#              крупнее на 25 %, хитбоксы и SIZES прежние — сравнение «арт включён» / «арт выключен»);
#            * HUD: set_perks рисует иконки 24×24 в плашке 26×26, коды карт сохранены;
#            * PerkChoice: 2 карточки с иконкой 48×48, геометрия в поле 540×960, без PNG — фолбэк;
#            * реальный `user://ww2_air_battles.cfg` не трогается: тест не поднимает
#              LevelController и не зовёт RunRecord/SaveGame на запись.
# Запуск: godot --headless --path . res://tests/art_integration_test.tscn
# Author: Technical Artist Agent (M7b)

extends Node

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const BF109_SCENE: PackedScene = preload("res://scenes/enemy_bf109.tscn")
const BF110_SCENE: PackedScene = preload("res://scenes/enemy_bf110.tscn")
const BOSS_HE111_SCENE: PackedScene = preload("res://scenes/boss_he111.tscn")
const BOSS_JU88_SCENE: PackedScene = preload("res://scenes/boss_ju88.tscn")
const BOSS_FW200_SCENE: PackedScene = preload("res://scenes/boss_fw200.tscn")
const PERK_CHOICE_SCENE: PackedScene = preload("res://scenes/perk_choice.tscn")

## 9 спрайтов smoke-листа (M7a) — их ключи обязаны резолвиться в файл.
const GAME_KEYS := [
	&"player_la5", &"player_yak3", &"player_p39",
	&"enemy_bf109", &"enemy_ju87", &"enemy_fw190",
	&"ui_star", &"ui_bomb", &"pickup_repair",
]
## Ключи ArtStyle, у которых есть СОБСТВЕННЫЙ PNG (без временного маппинга). Регресс-страж M9:
## в экспортированной сборке этих файлов на диске нет, и render_key обязан всё равно их отдать.
const OWN_PNG_KEYS := [
	ArtStyle.KEY_PLAYER_LA5, ArtStyle.KEY_PLAYER_YAK3, ArtStyle.KEY_PLAYER_P39,
	ArtStyle.KEY_ENEMY_BF109, ArtStyle.KEY_ENEMY_JU87, ArtStyle.KEY_ENEMY_FW190,
]
## 9 иконок перков (лист 2026-10-28), файл = ui_perk_<id>.png.
const PERK_IDS := [
	"sparka", "ap", "rockets", "shatter", "accuracy", "heavy",
	"repair", "coolhead", "emergency",
]
## Прямоугольники из таблицы Assets GDD: SIZES не должен «подстроиться» под PNG 64×64.
## Значения продублированы здесь намеренно — правка ArtStyle.SIZES обязана провалить гейт.
const EXPECTED_SIZES := {
	&"player_la5": Vector2(48.0, 48.0),
	&"enemy_bf109": Vector2(40.0, 40.0),
	&"enemy_bf110": Vector2(64.0, 64.0),
	&"boss_he111": Vector2(160.0, 96.0),
	&"boss_ju88": Vector2(160.0, 112.0),
	&"boss_fw200": Vector2(192.0, 128.0),
}
## Радиусы хитбоксов, зафиксированные до M7b (= size_of(key).x × EnemyBase.HIT_RADIUS_RATIO):
## арт не имеет права их двигать. Дублируются в тесте, чтобы дрейф SIZES был виден.
const EXPECTED_HIT_RADII := {
	&"enemy_bf109": 16.0,
	&"enemy_bf110": 25.6,
	&"boss_he111": 64.0,
	&"boss_ju88": 64.0,
	&"boss_fw200": 76.8,
}
## M11/T5: размеры ОТРИСОВКИ после +25 % (решение владельца D1). Дублируются здесь намеренно:
## правка DRAW_SCALE или SIZES обязана провалить гейт. Хитбоксы при этом не меняются.
const EXPECTED_DRAW_SIZES := {
	&"player_la5": Vector2(60.0, 60.0),
	&"player_yak3": Vector2(60.0, 60.0),
	&"player_p39": Vector2(60.0, 60.0),
	&"enemy_bf109": Vector2(50.0, 50.0),
	&"enemy_ju87": Vector2(60.0, 60.0),
	&"enemy_fw190": Vector2(55.0, 55.0),
	&"enemy_bf110": Vector2(80.0, 80.0),
	&"boss_he111": Vector2(200.0, 120.0),
	&"boss_ju88": Vector2(200.0, 140.0),
	&"boss_fw200": Vector2(240.0, 160.0),
}
## Панель превью ангара/Home: 492×128 (hangar.tscn: offset 24…516 / 152…280; home.tscn: 104…232).
## ShipVisual там стоит со scale 2 → картинка = draw_size_of × 2 и обязана влезть в панель.
const PREVIEW_PANEL_SIZE := Vector2(492.0, 128.0)
## Размер файла-иконки перка (M7a): 24×24, 1:1 в HUD и 2× в карточке.
const PERK_ICON_PIXELS := Vector2(24.0, 24.0)

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Слепок реального профиля ДО прогона: тест не должен его даже трогать.
var _real_save_path: String = ""
var _real_save_snapshot: Dictionary = {}


func _ready() -> void:
	_started_msec = Time.get_ticks_msec()
	_real_save_path = RunRecord.get_save_path()
	_real_save_snapshot = _file_snapshot(_real_save_path)
	await get_tree().process_frame
	await _run()
	_check("сейв: реальный %s не тронут (существование/размер/mtime те же)" % _real_save_path,
		_file_snapshot(_real_save_path) == _real_save_snapshot,
		"%s → %s" % [_real_save_snapshot, _file_snapshot(_real_save_path)])
	print("ART_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("ART_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_check_files()
	_check_render_keys()
	_check_textures()
	_check_export_safe_existence()
	_check_app_icon()
	await _check_ship_visuals()
	await _check_hud_perk_icons()
	await _check_perk_choice_icons()


# ─── Иконка приложения (M10, bug 1) ─────────────────────────────────────────
## Иконка собрана из игрового арта Ла-5 (`tools/build_app_icon.py`), а не нарисована заново.
## Проверяем то, что молча ломалось: файлы на месте и нужных размеров, `config/icon` смотрит
## на PNG, а не на снятый с производства `icon.svg`, во ВСЕХ трёх пресетах заполнены
## `launcher_icons/*` (пустая строка = сборка с прежней плоской иконкой), adaptive-слой
## вписан в безопасную зону 66 % и с прозрачными углами.
const ICON_MAIN := "res://assets/art/app_icon.png"
const ICON_LEGACY := "res://assets/art/app_icon_192.png"
const ICON_ADAPTIVE_FG := "res://assets/art/app_icon_adaptive_fg_432.png"
const ICON_ADAPTIVE_BG := "res://assets/art/app_icon_adaptive_bg_432.png"
## Безопасная зона adaptive-иконки: центральные 66 % канвы 432 px.
const ADAPTIVE_SAFE := 285


func _check_app_icon() -> void:
	var sizes := {
		ICON_MAIN: Vector2i(512, 512),
		ICON_LEGACY: Vector2i(192, 192),
		ICON_ADAPTIVE_FG: Vector2i(432, 432),
		ICON_ADAPTIVE_BG: Vector2i(432, 432),
	}
	var wrong: Array[String] = []
	for path: String in sizes:
		if not ResourceLoader.exists(path):
			wrong.append("%s нет" % path)
			continue
		var image := (load(path) as Texture2D).get_image()
		if image.get_size() != sizes[path]:
			wrong.append("%s %s" % [path, str(image.get_size())])
	_check("иконка: 4 PNG на месте и нужных размеров (512/192/432/432)", wrong.is_empty(),
		str(wrong))

	# config/icon должен указывать на PNG из арта: icon.svg снят с производства в M7.
	var project_icon := String(ProjectSettings.get_setting("application/config/icon", ""))
	_check("иконка: project.godot config/icon = %s (не icon.svg)" % ICON_MAIN,
		project_icon == ICON_MAIN, project_icon)

	# Пресеты: у всех трёх должны быть заполнены три ключа launcher_icons.
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	var empty_icons := presets.count("launcher_icons/main_192x192=\"\"") \
		+ presets.count("launcher_icons/adaptive_foreground_432x432=\"\"") \
		+ presets.count("launcher_icons/adaptive_background_432x432=\"\"")
	_check("иконка: во всех 3 пресетах launcher_icons заполнены (пустых ключей %d)" % empty_icons,
		empty_icons == 0 and presets.count("launcher_icons/main_192x192=\"%s\"" % ICON_LEGACY) == 3
		and presets.count("launcher_icons/adaptive_foreground_432x432=\"%s\"" % ICON_ADAPTIVE_FG) == 3
		and presets.count("launcher_icons/adaptive_background_432x432=\"%s\"" % ICON_ADAPTIVE_BG) == 3,
		"пустых %d" % empty_icons)

	# Основная иконка: небо ArtStyle.SKY по углам + самолёт в центре (не пустая канва).
	var main_image := (load(ICON_MAIN) as Texture2D).get_image()
	var corner := main_image.get_pixel(0, 0)
	var plane_pixels := 0
	for y in range(0, main_image.get_height(), 4):
		for x in range(0, main_image.get_width(), 4):
			if not main_image.get_pixel(x, y).is_equal_approx(ArtStyle.SKY):
				plane_pixels += 1
	_check("иконка: фон = ArtStyle.SKY, самолёт нарисован (непустых точек %d)" % plane_pixels,
		corner.is_equal_approx(ArtStyle.SKY) and plane_pixels > 200,
		"угол %s, точек %d" % [corner, plane_pixels])

	# Adaptive foreground: углы прозрачные (иначе маска лаунчера покажет плашку) и весь
	# контент внутри безопасной зоны 285 px по центру — иначе самолёт подрежет маска.
	var fg_image := (load(ICON_ADAPTIVE_FG) as Texture2D).get_image()
	var used := fg_image.get_used_rect()
	var inset := (fg_image.get_width() - ADAPTIVE_SAFE) / 2
	var inside := used.position.x >= inset and used.position.y >= inset \
		and used.end.x <= fg_image.get_width() - inset \
		and used.end.y <= fg_image.get_height() - inset
	_check("иконка: adaptive foreground прозрачен по углам и вписан в зону %d px" % ADAPTIVE_SAFE,
		fg_image.get_pixel(0, 0).a == 0.0 and fg_image.get_pixel(431, 431).a == 0.0
		and inside and used.get_area() > 0,
		"bbox %s, inset %d" % [used, inset])

	# Adaptive background — сплошное небо: лаунчер кроит его любой маской.
	var bg_image := (load(ICON_ADAPTIVE_BG) as Texture2D).get_image()
	var solid := true
	for point: Vector2i in [Vector2i(0, 0), Vector2i(431, 0), Vector2i(0, 431), Vector2i(431, 431),
			Vector2i(216, 216)]:
		if not bg_image.get_pixelv(point).is_equal_approx(ArtStyle.SKY):
			solid = false
	_check("иконка: adaptive background — сплошной ArtStyle.SKY", solid)

	var icon_import := FileAccess.get_file_as_string(ICON_MAIN + ".import")
	_check("иконка: импорт lossless без мипмапов (пиксель-арт не мылится)",
		"compress/mode=0" in icon_import and "mipmaps/generate=false" in icon_import)


# ─── Файлы и импорт ─────────────────────────────────────────────────────────
func _check_files() -> void:
	var missing: Array[String] = []
	for key: StringName in GAME_KEYS:
		if not FileAccess.file_exists(ArtAssets.path_for(key)):
			missing.append(String(key))
	_check("файлы: 9 игровых PNG по ключам GDD", missing.is_empty(), str(missing))

	var missing_icons: Array[String] = []
	for id: String in PERK_IDS:
		var key := ArtAssets.perk_icon_key(id)
		if key == &"" or not FileAccess.file_exists(ArtAssets.path_for(key)):
			missing_icons.append(id)
	_check("файлы: 9 иконок ui_perk_*.png по id карт", missing_icons.is_empty(),
		str(missing_icons))

	# Импорт M7b: lossless + без мипмапов (иначе пиксель-арт мылится при масштабе).
	var import_path := ArtAssets.path_for(ArtAssets.perk_icon_key("sparka")) + ".import"
	var import_text := ""
	if FileAccess.file_exists(import_path):
		import_text = FileAccess.get_file_as_string(import_path)
	_check("импорт: ui_perk_sparka.png.import существует", not import_text.is_empty(),
		import_path)
	_check("импорт: compress/mode=0 (lossless)", import_text.contains("compress/mode=0"))
	_check("импорт: mipmaps/generate=false", import_text.contains("mipmaps/generate=false"))

	# Остальные иконки тоже импортированы: без .import текстура не загрузится в headless.
	var unimported: Array[String] = []
	for id: String in PERK_IDS:
		var path := ArtAssets.path_for(ArtAssets.perk_icon_key(id)) + ".import"
		if not FileAccess.file_exists(path):
			unimported.append(id)
	_check("импорт: .import есть у всех 9 иконок перков", unimported.is_empty(),
		str(unimported))


# ─── Маппинг переиспользования ──────────────────────────────────────────────
func _check_render_keys() -> void:
	_check("ключи: player_la5 → свой файл",
		ArtAssets.render_key(&"player_la5") == &"player_la5")
	_check("ключи: enemy_bf109 → свой файл",
		ArtAssets.render_key(&"enemy_bf109") == &"enemy_bf109")
	_check("ключи: enemy_bf110 → спрайт Bf 109 (temp reuse)",
		ArtAssets.render_key(&"enemy_bf110") == &"enemy_bf109",
		String(ArtAssets.render_key(&"enemy_bf110")))
	_check("ключи: boss_he111 → спрайт Fw 190 (temp reuse)",
		ArtAssets.render_key(&"boss_he111") == &"enemy_fw190",
		String(ArtAssets.render_key(&"boss_he111")))
	_check("ключи: boss_ju88 → спрайт Fw 190 (temp reuse)",
		ArtAssets.render_key(&"boss_ju88") == &"enemy_fw190",
		String(ArtAssets.render_key(&"boss_ju88")))
	_check("ключи: boss_fw200 → спрайт Fw 190 (temp reuse)",
		ArtAssets.render_key(&"boss_fw200") == &"enemy_fw190",
		String(ArtAssets.render_key(&"boss_fw200")))
	_check("ключи: неизвестный ключ → &\"\"",
		ArtAssets.render_key(&"no_such_asset") == &"",
		String(ArtAssets.render_key(&"no_such_asset")))
	_check("ключи: ui_perk_sparka → ui_perk_sparka, неизвестный id → &\"\"",
		ArtAssets.perk_icon_key("sparka") == &"ui_perk_sparka"
		and ArtAssets.perk_icon_key("nope") == &"",
		String(ArtAssets.perk_icon_key("sparka")))


# ─── Текстуры и кэш ─────────────────────────────────────────────────────────
func _check_textures() -> void:
	var no_texture: Array[String] = []
	for key: StringName in GAME_KEYS:
		if not ArtAssets.has_texture(key):
			no_texture.append(String(key))
	_check("текстуры: has_texture true у 9 ключей M7a", no_texture.is_empty(), str(no_texture))

	var no_icons: Array[String] = []
	for id: String in PERK_IDS:
		if not ArtAssets.has_texture(ArtAssets.perk_icon_key(id)):
			no_icons.append(id)
	_check("текстуры: has_texture true у 9 иконок перков", no_icons.is_empty(), str(no_icons))

	_check("текстуры: маппинг отдаёт тот же ресурс (bf110 == bf109)",
		ArtAssets.texture(&"enemy_bf110") == ArtAssets.texture(&"enemy_bf109"))
	_check("текстуры: кэш — повторный вызов возвращает тот же объект",
		ArtAssets.texture(&"player_la5") == ArtAssets.texture(&"player_la5"))
	_check("текстуры: неизвестный ключ → null (без ERROR)",
		ArtAssets.texture(&"no_such_asset") == null
		and not ArtAssets.has_texture(&"no_such_asset"))

	var la5 := ArtAssets.texture(&"player_la5")
	_check("текстуры: player_la5 — PNG 64×64",
		la5 != null and la5.get_size() == Vector2(64.0, 64.0),
		str(la5.get_size()) if la5 != null else "null")
	var icon := ArtAssets.texture(ArtAssets.perk_icon_key("repair"))
	_check("текстуры: ui_perk_repair — PNG 24×24",
		icon != null and icon.get_size() == PERK_ICON_PIXELS,
		str(icon.get_size()) if icon != null else "null")


# ─── Экспорт-безопасность существования ресурса (регресс M9) ─────────────────
## Guard бага с устройства: в release APK исходных `assets/art/*.png` нет — в PCK лежат только
## импортированные `.ctex` в `res://.godot/imported/` плюс remap. Поэтому гейт существования
## через FileAccess на устройстве ВСЕГДА false, и все корабли падали в код-силуэт ArtStyle, хотя
## headless-прогон (файлы лежат на диске) был зелёным. Headless это состояние не воспроизводит,
## поэтому страж косвенный: (1) все ключи с собственным PNG резолвятся через render_key,
## (2) пути видны через ResourceLoader.exists, (3) в исходнике ArtAssets нет FileAccess/DirAccess
## проверки ресурса и есть ResourceLoader.exists.
func _check_export_safe_existence() -> void:
	var unresolved: Array[String] = []
	for key: StringName in OWN_PNG_KEYS:
		if ArtAssets.render_key(key) != key:
			unresolved.append("%s→%s" % [String(key), String(ArtAssets.render_key(key))])
	_check("экспорт: render_key отдаёт все 6 ключей с собственным PNG (pl/bf/ju/fw)",
		unresolved.is_empty(), str(unresolved))

	var invisible: Array[String] = []
	for key: StringName in GAME_KEYS:
		if not ResourceLoader.exists(ArtAssets.path_for(key)):
			invisible.append(String(key))
	for id: String in PERK_IDS:
		var icon_key := ArtAssets.perk_icon_key(id)
		if icon_key == &"" or not ResourceLoader.exists(ArtAssets.path_for(icon_key)):
			invisible.append("ui_perk_" + id)
	_check("экспорт: 18 PNG видны через ResourceLoader.exists (так же, как в PCK после remap)",
		invisible.is_empty(), str(invisible))

	# Исходник читается как текст: FileAccess по .gd в репозитории работает и в headless.
	var source := FileAccess.get_file_as_string("res://scripts/art_assets.gd")
	_check("экспорт: в ArtAssets нет проверки ресурса через FileAccess/DirAccess",
		not source.is_empty() and not source.contains("FileAccess.file_exists")
		and not source.contains("DirAccess."), "пустой исходник" if source.is_empty() else "")
	_check("экспорт: ArtAssets резолвит текстуры через ResourceLoader.exists",
		source.contains("ResourceLoader.exists"))


# ─── ShipVisual: текстура в прямоугольнике SIZES, хитбокс не меняется ───────
func _check_ship_visuals() -> void:
	var sizes_ok := true
	var sizes_details := ""
	for key: StringName in EXPECTED_SIZES.keys():
		var expected: Vector2 = EXPECTED_SIZES[key]
		var actual := ArtStyle.size_of(key)
		if actual != expected:
			sizes_ok = false
			sizes_details += "%s: %s≠%s " % [key, actual, expected]
	_check("SIZES: прямоугольники из таблицы Assets не изменились", sizes_ok, sizes_details)

	# M11/T5: +25 % только к отрисовке. SIZES (источник хитбоксов) не тронут, draw_size_of = ×1.25.
	var draw_ok := true
	var draw_details := ""
	for key: StringName in EXPECTED_DRAW_SIZES.keys():
		var expected_draw: Vector2 = EXPECTED_DRAW_SIZES[key]
		var actual_draw := ArtStyle.draw_size_of(key)
		if actual_draw != expected_draw or actual_draw != ArtStyle.size_of(key) * ArtStyle.DRAW_SCALE:
			draw_ok = false
			draw_details += "%s: %s≠%s " % [key, actual_draw, expected_draw]
	_check("масштаб: draw_size_of == size_of × 1.25 для 8 ключей плана + yak3/p39",
		draw_ok and is_equal_approx(ArtStyle.DRAW_SCALE, 1.25), draw_details)

	# Хитбоксы выводятся из size_of, а не из draw_size_of: +25 % картинки баланс не меняет.
	var ratio_ok := is_equal_approx(EnemyBase.HIT_RADIUS_RATIO, 0.4)
	var radii_details := "" if ratio_ok else "HIT_RADIUS_RATIO=%s" % EnemyBase.HIT_RADIUS_RATIO
	for key: StringName in EXPECTED_HIT_RADII.keys():
		var from_sizes := ArtStyle.size_of(key).x * EnemyBase.HIT_RADIUS_RATIO
		if not is_equal_approx(from_sizes, EXPECTED_HIT_RADII[key]):
			ratio_ok = false
			radii_details += "%s: %.2f≠%.2f " % [key, from_sizes, EXPECTED_HIT_RADII[key]]
	_check("масштаб: хитбоксы по-прежнему из size_of (r16/25.6/64/64/76.8), не из draw_size_of",
		ratio_ok, radii_details)
	_check("масштаб: превью ангара/Home (draw_size_of игрока ×2) влезает в панель 492×128",
		ArtStyle.draw_size_of(&"player_la5") * Hangar.PREVIEW_SCALE
			== Vector2(120.0, 120.0)
		and ArtStyle.draw_size_of(&"player_la5").x * Hangar.PREVIEW_SCALE
			<= PREVIEW_PANEL_SIZE.x
		and ArtStyle.draw_size_of(&"player_la5").y * Hangar.PREVIEW_SCALE
			<= PREVIEW_PANEL_SIZE.y
		and is_equal_approx(Home.PREVIEW_SCALE, Hangar.PREVIEW_SCALE),
		"%s × %.1f в %s" % [str(ArtStyle.draw_size_of(&"player_la5")), Hangar.PREVIEW_SCALE,
			str(PREVIEW_PANEL_SIZE)])

	var player := PLAYER_SCENE.instantiate() as Player
	player.set_process(false)
	add_child(player)
	player.set_process(false)
	var player_visual := player.get_node_or_null(^"Visual") as ShipVisual
	_check("ShipVisual: игрок рисует текстуру player_la5",
		player_visual != null and player_visual.is_using_texture()
		and player_visual.get_texture_key() == &"player_la5",
		String(player_visual.get_texture_key()) if player_visual != null else "нет Visual")
	_check("ShipVisual: размер игрока — ArtStyle.draw_size_of(player_la5) = 60×60 (было 48)",
		ArtStyle.draw_size_of(&"player_la5") == Vector2(60.0, 60.0)
		and ArtStyle.size_of(&"player_la5") == Vector2(48.0, 48.0),
		"%s / SIZES %s" % [str(ArtStyle.draw_size_of(&"player_la5")),
			str(ArtStyle.size_of(&"player_la5"))])
	_check("хитбокс: игрок r=8 (текстура его не трогает)",
		is_equal_approx(player.hit_radius, 8.0)
		and is_equal_approx(_shape_radius(player), 8.0),
		"%.1f / %.1f" % [player.hit_radius, _shape_radius(player)])

	var cases: Array[Dictionary] = [
		{"scene": BF109_SCENE, "key": &"enemy_bf109", "texture": &"enemy_bf109",
			"label": "Bf 109"},
		{"scene": BF110_SCENE, "key": &"enemy_bf110", "texture": &"enemy_bf109",
			"label": "Bf 110"},
		{"scene": BOSS_HE111_SCENE, "key": &"boss_he111", "texture": &"enemy_fw190",
			"label": "He 111"},
		{"scene": BOSS_JU88_SCENE, "key": &"boss_ju88", "texture": &"enemy_fw190",
			"label": "Ju 88"},
		{"scene": BOSS_FW200_SCENE, "key": &"boss_fw200", "texture": &"enemy_fw190",
			"label": "Fw 200"},
	]
	var spawned: Array[EnemyBase] = []
	for item: Dictionary in cases:
		var scene: PackedScene = item["scene"]
		var key: StringName = item["key"]
		var expected_texture: StringName = item["texture"]
		var label: String = item["label"]
		var enemy := scene.instantiate() as EnemyBase
		enemy.set_physics_process(false)
		add_child(enemy)
		enemy.set_physics_process(false)
		spawned.append(enemy)
		var visual := enemy.get_node_or_null(^"Visual") as ShipVisual
		var expected_size: Vector2 = EXPECTED_SIZES[key]
		_check("ShipVisual: %s — текстура %s в прямоугольнике отрисовки %s" % [label,
			String(expected_texture), expected_size * ArtStyle.DRAW_SCALE],
			visual != null and visual.is_using_texture()
			and visual.get_texture_key() == expected_texture
			and ArtStyle.draw_size_of(visual.asset_key) == expected_size * ArtStyle.DRAW_SCALE,
			"%s / %s" % [String(visual.get_texture_key()) if visual != null else "нет Visual",
				str(ArtStyle.draw_size_of(key))])
		var expected_radius: float = EXPECTED_HIT_RADII[key]
		_check("хитбокс: %s не изменился артом (r=%.1f)" % [label, expected_radius],
			is_equal_approx(_shape_radius(enemy), expected_radius),
			"%.2f ≠ %.2f" % [_shape_radius(enemy), expected_radius])

	# Сравнение «до/после» на одном и том же враге: радиус не зависит от того, что на Visual.
	var with_art := BF109_SCENE.instantiate() as EnemyBase
	add_child(with_art)
	with_art.set_physics_process(false)
	var art_radius := _shape_radius(with_art)
	var without_art := BF109_SCENE.instantiate() as EnemyBase
	var silent_visual := without_art.get_node_or_null(^"Visual") as ShipVisual
	if silent_visual != null:
		silent_visual.use_sprite_art = false
	without_art.set_physics_process(false)
	add_child(without_art)
	without_art.set_physics_process(false)
	var code_radius := _shape_radius(without_art)
	_check("хитбокс: Bf 109 r=16 одинаков с артом и без (до/после)",
		is_equal_approx(art_radius, 16.0) and is_equal_approx(code_radius, art_radius),
		"%.2f / %.2f" % [art_radius, code_radius])
	_check("фолбэк: use_sprite_art=false → код-силуэт ArtStyle",
		silent_visual != null and not silent_visual.is_using_texture()
		and silent_visual.get_texture_key() == &"",
		String(silent_visual.get_texture_key()) if silent_visual != null else "нет Visual")

	# Код-силуэт обязан рисоваться в том же увеличенном прямоугольнике, что и PNG (иначе при
	# use_sprite_art=false модель «прыгает» на 20 %). Проверяем по исходнику: draw_ship берёт
	# размер из draw_size_of, а ShipVisual — тоже draw_size_of.
	var style_source := FileAccess.get_file_as_string("res://scripts/art_style.gd")
	var visual_source := FileAccess.get_file_as_string("res://scripts/ship_visual.gd")
	_check("фолбэк: draw_ship и ShipVisual._draw берут размер из draw_size_of (арт = силуэт)",
		style_source.contains("static func draw_ship")
		and style_source.contains("var size := draw_size_of(asset_key)")
		and visual_source.contains("var size := ArtStyle.draw_size_of(asset_key)"),
		"исходники не прочитаны/не совпали")

	# Ключ без файла: текстуры нет, отрисовка уходит в ArtStyle (не падает и не мигает).
	var orphan := ShipVisual.new()
	orphan.name = "OrphanVisual"
	orphan.asset_key = &"no_such_asset"
	add_child(orphan)
	await get_tree().process_frame
	_check("фолбэк: неизвестный ключ → нет текстуры, силуэт рисуется",
		not orphan.is_using_texture() and orphan.get_texture_key() == &""
		and ArtAssets.texture(&"no_such_asset") == null)

	orphan.queue_free()
	player.queue_free()
	with_art.queue_free()
	without_art.queue_free()
	for enemy: EnemyBase in spawned:
		enemy.queue_free()


# ─── HUD: иконки в слотах 26×26 ─────────────────────────────────────────────
func _check_hud_perk_icons() -> void:
	var hud := _build_hud()
	add_child(hud)
	await get_tree().process_frame

	hud.set_perks(_as_ids(["sparka", "ap", "repair"]))
	_check("HUD: 3 слота заняты после set_perks(sparka, ap, repair)",
		hud.get_perk_slot_count() == 3, str(hud.get_perk_slot_count()))
	_check("HUD: has_perk_icon true у всех занятых слотов",
		hud.has_perk_icon(0) and hud.has_perk_icon(1) and hud.has_perk_icon(2),
		"%s %s %s" % [hud.has_perk_icon(0), hud.has_perk_icon(1), hud.has_perk_icon(2)])
	_check("HUD: коды карт сохранены (СП / БР / РЕ)",
		hud.get_perk_slot_text(0) == "СП" and hud.get_perk_slot_text(1) == "БР"
		and hud.get_perk_slot_text(2) == "РЕ",
		"%s %s %s" % [hud.get_perk_slot_text(0), hud.get_perk_slot_text(1),
			hud.get_perk_slot_text(2)])
	_check("HUD: id карт по слотам (sparka / ap / repair)",
		hud.get_perk_id(0) == "sparka" and hud.get_perk_id(1) == "ap"
		and hud.get_perk_id(2) == "repair",
		"%s %s %s" % [hud.get_perk_id(0), hud.get_perk_id(1), hud.get_perk_id(2)])
	_check("HUD: иконка 24×24 влезает в плашку 26×26",
		Hud.PERK_ICON_SIZE == PERK_ICON_PIXELS
		and Hud.PERK_ICON_SIZE.x <= Hud.PERK_SLOT_SIZE.x
		and Hud.PERK_ICON_SIZE.y <= Hud.PERK_SLOT_SIZE.y,
		"%s в %s" % [Hud.PERK_ICON_SIZE, Hud.PERK_SLOT_SIZE])
	var sparka := ArtAssets.texture(ArtAssets.perk_icon_key("sparka"))
	_check("HUD: подложка под иконку — кремовый wash alpha 0.15",
		is_equal_approx(Hud.PERK_ICON_BACKDROP_ALPHA, 0.15) and sparka != null,
		str(Hud.PERK_ICON_BACKDROP_ALPHA))

	hud.set_perks([])
	_check("HUD: свободные слоты без иконок (0 занято, has_perk_icon false)",
		hud.get_perk_slot_count() == 0 and not hud.has_perk_icon(0)
		and hud.get_perk_slot_text(0).is_empty(),
		"%d / %s" % [hud.get_perk_slot_count(), hud.has_perk_icon(0)])
	_check("HUD: индекс вне 0…2 не падает",
		not hud.has_perk_icon(7) and hud.get_perk_slot_text(-1).is_empty()
		and hud.get_perk_id(9).is_empty())
	hud.queue_free()


# ─── PerkChoice: иконка 48×48 в карточке ────────────────────────────────────
func _check_perk_choice_icons() -> void:
	var choice := PERK_CHOICE_SCENE.instantiate() as PerkChoice
	add_child(choice)
	await get_tree().process_frame

	choice.show_offers(_as_ids(["sparka", "ap"]))
	await get_tree().process_frame
	await get_tree().process_frame
	_check("PerkChoice: 2 карточки для 2 карт",
		choice.get_card_count() == 2 and choice.visible, str(choice.get_card_count()))
	_check("PerkChoice: иконки есть у обеих карточек (файл + узел)",
		choice.has_card_icon(0) and choice.has_card_icon(1),
		"%s %s" % [choice.has_card_icon(0), choice.has_card_icon(1)])
	_check("PerkChoice: ключи иконок = ui_perk_sparka / ui_perk_ap",
		choice.get_card_icon_key(0) == &"ui_perk_sparka"
		and choice.get_card_icon_key(1) == &"ui_perk_ap",
		"%s / %s" % [String(choice.get_card_icon_key(0)),
			String(choice.get_card_icon_key(1))])

	var icon_ok := true
	var icon_details := ""
	for index in 2:
		var card := choice.get_card_control(index)
		var icon: TextureRect = null
		if card != null:
			icon = card.get_node_or_null(NodePath("Inner/Icon")) as TextureRect
		if icon == null:
			icon_ok = false
			icon_details += "нет узла Icon (карточка %d) " % index
			continue
		if not icon.visible or icon.texture == null:
			icon_ok = false
			icon_details += "иконка скрыта/без текстуры (карточка %d) " % index
		if not is_equal_approx(icon.custom_minimum_size.x, PerkChoice.CARD_ICON_SIZE) \
				or not is_equal_approx(icon.custom_minimum_size.y, PerkChoice.CARD_ICON_SIZE):
			icon_ok = false
			icon_details += "размер %s (карточка %d) " % [icon.custom_minimum_size, index]
		if icon.texture_filter != CanvasItem.TEXTURE_FILTER_NEAREST:
			icon_ok = false
			icon_details += "фильтр %d (карточка %d) " % [icon.texture_filter, index]
	_check("PerkChoice: узел Icon 48×48, nearest, с текстурой", icon_ok, icon_details)

	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var first := choice.get_card_control(0).get_global_rect()
	var second := choice.get_card_control(1).get_global_rect()
	_check("PerkChoice: карточки с иконкой в поле 540×960 и не уже 200 px",
		first.size.x >= 200.0 and field.encloses(first) and field.encloses(second),
		"%s / %s" % [first, second])
	_check("PerkChoice: карточки не перекрываются", not first.intersects(second),
		"%s × %s" % [first, second])

	# Фолбэк: карта с несуществующим id (файла иконки нет) — карточка и кнопка на месте.
	choice.show_offers(_as_ids(["sparka", "nope"]))
	await get_tree().process_frame
	await get_tree().process_frame
	var fallback_card := choice.get_card_control(1)
	var fallback_button: Button = null
	if fallback_card != null:
		fallback_button = fallback_card.get_node_or_null(NodePath("Inner/TakeButton")) as Button
	_check("PerkChoice: карта без PNG не ломает карточку (нет иконки, кнопка есть)",
		choice.get_card_count() == 2 and choice.has_card_icon(0)
		and not choice.has_card_icon(1) and fallback_button != null
		and fallback_button.custom_minimum_size.y >= PerkChoice.TAKE_MIN_HEIGHT,
		"%s / %s" % [choice.has_card_icon(1),
			str(fallback_button.custom_minimum_size) if fallback_button != null else "нет кнопки"])
	_check("PerkChoice: индекс вне предложения → нет иконки/узла",
		not choice.has_card_icon(5) and choice.get_card_icon_key(-1) == &""
		and choice.get_card_control(9) == null)

	choice.hide_choice()
	_check("PerkChoice: hide_choice снимает карточки и иконки",
		choice.get_card_count() == 0 and not choice.has_card_icon(0))
	choice.queue_free()


# ─── Хелперы ────────────────────────────────────────────────────────────────
## Минимальный HUD: те же узлы, что в main.tscn (Label/ColorRect), без LevelController и звука —
## профиль `user://` тест не открывает.
func _build_hud() -> Hud:
	var hud := Hud.new()
	hud.name = "HUD"
	var hp_label := Label.new()
	hp_label.name = "HPLabel"
	hud.add_child(hp_label)
	var score_label := Label.new()
	score_label.name = "ScoreLabel"
	hud.add_child(score_label)
	var wave_label := Label.new()
	wave_label.name = "WaveLabel"
	hud.add_child(wave_label)
	var boss_bar := Control.new()
	boss_bar.name = "BossBar"
	hud.add_child(boss_bar)
	var fill := ColorRect.new()
	fill.name = "Fill"
	boss_bar.add_child(fill)
	return hud


func _as_ids(source: Array) -> Array[String]:
	var ids: Array[String] = []
	for item: Variant in source:
		ids.append(String(item))
	return ids


func _shape_radius(area: Area2D) -> float:
	var shape_node := area.get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return -1.0
	var circle := shape_node.shape as CircleShape2D
	return circle.radius if circle != null else -1.0


## Слепок файла без чтения содержимого: существование, размер, время изменения.
func _file_snapshot(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"exists": false}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"exists": true, "size": -1, "mtime": -1}
	var size := file.get_length()
	file.close()
	return {
		"exists": true,
		"size": size,
		"mtime": FileAccess.get_modified_time(path),
	}


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
