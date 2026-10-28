# campaign_data_test.gd
# Purpose: Гейт M5.1 «данные миссий» (GDD «Реализация v1» → «Данные миссии»): проверяет, что
#          `data/missions.json` валиден, содержит ровно 3 миссии (m1_airfield / m2_crossing /
#          m3_city), что миссия 1 — волны 1–5 ТОЧНАЯ копия прежнего хардкода `WaveManager.wave_table()`
#          (те же сцены, те же x/y, те же составы 4/5/3/7/6), а волна 6 (M5.3c) набрана по GDD
#          «Волны миссий»: 2 Fw 190 + 4 Bf 109. Всего 6 волн, He 111, ремкомплект волны 4 из
#          Ju 87; миссии 2/3 тоже 6 волн (Ju 88 / Fw 200, ремкомплект волны 5
#          из Ju 87 / Bf 110, пули 300–380 и 340–420). Отдельно проверяется загрузчик: все штатные
#          типы резолвятся в сцены (M5.2: bf110/ju88/fw200 подключены), а неизвестный тип даёт
#          null, а не ошибку.
#          M10 (bug 5): блок `result` каждой миссии — точные тексты m1/m2/m3, контракт
#          get_result() (неизвестный id → пустые строки) и геттеры get_result_*.
#          M11/T3 (решение D4): подсказки удалены — в блоке только win_title/lose_title
#          (два ключа, лимит длины 18 символов, полей win_hint/lose_hint нет и в JSON).
#          Сетевых/пользовательских файлов тест не трогает; сцена не нужна — только data и
#          статические функции MissionData.
# Запуск: godot --headless --path . res://tests/campaign_data_test.tscn
# Author: Mechanics Developer Agent

extends Node

## Реальная сцена игры для рантайм-проверки: WaveManager обязан брать волны миссии из данных,
## а несуществующие сцены (bf110 в M3) — пропускать без падения.
const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")

## Ожидаемая таблица миссии 1: волны 1–5 — прежний хардкод `WaveManager.wave_table()` 1:1
## (эталон регрессии: если данные поедут, тест покажет волну и точку), волна 6 — GDD
## «Волны миссий» (M5.3c: 2 Fw 190 default + 4 Bf 109 back, симметрия вокруг x = 270).
## Ключи сцен — Path к tscn, чтобы тест не зависел от констант-клонов.
const M1_EXPECTED := [
	[
		["res://scenes/enemy_bf109.tscn", Vector2(120.0, -70.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(220.0, -46.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(320.0, -46.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(420.0, -70.0)],
	],
	[
		["res://scenes/enemy_bf109.tscn", Vector2(80.0, -64.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(175.0, -46.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(270.0, -34.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(365.0, -46.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(460.0, -64.0)],
	],
	[
		["res://scenes/enemy_fw190.tscn", Vector2(140.0, -70.0)],
		["res://scenes/enemy_fw190.tscn", Vector2(270.0, -88.0)],
		["res://scenes/enemy_fw190.tscn", Vector2(400.0, -70.0)],
	],
	[
		["res://scenes/enemy_ju87.tscn", Vector2(140.0, -70.0)],
		["res://scenes/enemy_ju87.tscn", Vector2(270.0, -70.0)],
		["res://scenes/enemy_ju87.tscn", Vector2(400.0, -70.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(120.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(220.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(320.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(420.0, -88.0)],
	],
	[
		["res://scenes/enemy_fw190.tscn", Vector2(145.0, -70.0)],
		["res://scenes/enemy_fw190.tscn", Vector2(270.0, -70.0)],
		["res://scenes/enemy_fw190.tscn", Vector2(395.0, -70.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(120.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(270.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(420.0, -88.0)],
	],
	# M5.3c, волна 6 по GDD: 2 Fw 190 + 4 Bf 109 (сначала Fw 190, затем Bf 109).
	[
		["res://scenes/enemy_fw190.tscn", Vector2(140.0, -70.0)],
		["res://scenes/enemy_fw190.tscn", Vector2(400.0, -70.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(120.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(220.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(320.0, -88.0)],
		["res://scenes/enemy_bf109.tscn", Vector2(420.0, -88.0)],
	],
]

## Составы миссий 2/3 по GDD «Волны миссий» — счётчики по типам, волна за волной.
const M2_EXPECTED := [
	{"bf109": 5},
	{"ju87": 3},
	{"bf109": 4, "ju87": 2},
	{"fw190": 3},
	{"ju87": 3, "bf109": 4},
	{"fw190": 2, "ju87": 2, "bf109": 3},
]
const M3_EXPECTED := [
	{"bf109": 5},
	{"fw190": 3},
	{"bf110": 2, "bf109": 3},
	{"fw190": 4, "ju87": 2},
	{"bf110": 3, "bf109": 4},
	{"fw190": 3, "bf110": 3},
]

## Допустимые глубины и их Y — те же числа, что в WaveManager/MissionData.
const DEPTH_TABLE := {
	"default": -70.0,
	"back": -88.0,
	"mid": -34.0,
	"lead": -46.0,
	"v": -64.0,
}

## M10 (bug 5): блок result — тексты экранов победы/поражения, по миссии.
## M11/T3 (решение D4): подсказки «Тап — рестарт» удалены вместе с тап-шорткатами —
## в данных остались ТОЛЬКО два заголовка: win_title / lose_title.
## m1 заморожена (контракт smoke: «Аэродром спасён» / «Аэродром потерян»).
## m2 win_title — согласованный фолбэк «Переправа цела»: «Переправа удержана» реальным
## шрифтом (Bold 48) занимает 533.0 px при лимите 520 (поле 540) — см. отчёт M10.
const EXPECTED_RESULT := {
	"m1_airfield": {
		"win_title": "Аэродром спасён",
		"lose_title": "Аэродром потерян",
	},
	"m2_crossing": {
		"win_title": "Переправа цела",
		"lose_title": "Переправа потеряна",
	},
	"m3_city": {
		"win_title": "Город спасён",
		"lose_title": "Город потерян",
	},
}

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Сейв изолирован: start_mission() читает SaveGame (выбранный самолёт), поэтому реальный
## user://ww2_air_battles.cfg не должен участвовать даже в чтении/миграции.
var _save_path: String = ""
## Экземпляр main.tscn для рантайм-проверки (освобождается в конце, ничего не сохраняет).
var _level: LevelController


func _ready() -> void:
	_started_msec = Time.get_ticks_msec()
	_save_path = "user://qa_campaign_data_%d.cfg" % _started_msec
	RunRecord.set_save_path(_save_path)
	await _run()
	RunRecord.reset_save_path()
	if FileAccess.file_exists(_save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_save_path))
	print("CAMPAIGN_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("CAMPAIGN_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_check_loader()
	_check_missions()
	_check_result_texts()
	_check_mission_1()
	_check_mission_2_and_3()
	_check_depths_and_scenes()
	_check_playfield()
	await _check_runtime()


# ─── Загрузчик ──────────────────────────────────────────────────────────────
func _check_loader() -> void:
	var errors := MissionData.validate()
	_check("данные: MissionData.validate() без ошибок", errors.is_empty(), str(errors))
	_check("данные: файл data/missions.json существует",
		FileAccess.file_exists(MissionData.DATA_PATH), MissionData.DATA_PATH)
	_check("данные: неизвестная миссия → пустой словарь",
		MissionData.get_mission("nope").is_empty())
	_check("данные: у неизвестной миссии нет волн (get_wave_table не падает)",
		MissionData.get_wave_count("nope") == 0
		and MissionData.get_wave_table("nope").is_empty())
	_check("данные: у неизвестной миссии нет босса и star_score = 0",
		MissionData.get_boss_type("nope").is_empty() and MissionData.get_star_score("nope") == 0,
		str(MissionData.get_star_score("nope")))


# ─── Три миссии ─────────────────────────────────────────────────────────────
func _check_missions() -> void:
	var ids := MissionData.get_mission_ids()
	_check("миссии: ровно 3 миссии", ids.size() == 3, str(ids))
	_check("миссии: id ровно m1_airfield / m2_crossing / m3_city",
		ids == ["m1_airfield", "m2_crossing", "m3_city"], str(ids))
	var titles_ok := true
	var briefings_ok := true
	for id: String in ids:
		titles_ok = titles_ok and not MissionData.get_title(id).is_empty()
		briefings_ok = briefings_ok and MissionData.get_briefing(id).length() >= 20
	_check("миссии: у всех есть title и briefing", titles_ok and briefings_ok)
	# M5.3a: порог третьей звезды — данные миссии (GDD «Счёт, звёзды, снабжение»).
	_check("миссии: star_score 4500 / 5500 / 7000",
		MissionData.get_star_score("m1_airfield") == 4500
		and MissionData.get_star_score("m2_crossing") == 5500
		and MissionData.get_star_score("m3_city") == 7000,
		"%d / %d / %d" % [MissionData.get_star_score("m1_airfield"),
			MissionData.get_star_score("m2_crossing"), MissionData.get_star_score("m3_city")])


# ─── M10 (bug 5): блок result — тексты экранов победы/поражения ─────────────
## M11/T3 (решение D4): контракт — ровно два ключа (win_title / lose_title). Подсказок
## «Тап — рестарт» в данных больше нет: тап-шорткаты удалены (T2), исход покидается кнопками.
func _check_result_texts() -> void:
	# Контракт get_result(): ровно два ключа, порядок — RESULT_KEYS, значения строки.
	var contract_ok := true
	var contract_details := ""
	for id: String in MissionData.MISSION_IDS:
		var result := MissionData.get_result(id)
		var keys: Array = result.keys()
		keys.sort()
		var expected_keys: Array = MissionData.RESULT_KEYS.duplicate()
		expected_keys.sort()
		if result.size() != MissionData.RESULT_KEYS.size() or keys != expected_keys:
			contract_ok = false
			contract_details += "%s: %s; " % [id, str(result.keys())]
		for key: String in result.keys():
			if typeof(result[key]) != TYPE_STRING:
				contract_ok = false
				contract_details += "%s.%s не строка; " % [id, key]
	_check("result: у каждой миссии ровно 2 ключа (win_title/lose_title), значения — строки",
		contract_ok, contract_details)

	var texts_ok := true
	var texts_details := ""
	for id: String in EXPECTED_RESULT:
		var result := MissionData.get_result(id)
		var expected: Dictionary = EXPECTED_RESULT[id]
		for key: String in expected.keys():
			if String(result.get(key, "")) != String(expected[key]):
				texts_ok = false
				texts_details += "%s.%s «%s» вместо «%s»; " % [id, key,
					String(result.get(key, "")), String(expected[key])]
	_check("result: тексты m1/m2/m3 ровно по согласованному списку",
		texts_ok, texts_details)

	# Геттеры — то же, что get_result (единственный источник строк для оверлеев).
	var getters_ok := true
	for id: String in MissionData.MISSION_IDS:
		var result := MissionData.get_result(id)
		getters_ok = getters_ok \
			and MissionData.get_result_win_title(id) == String(result["win_title"]) \
			and MissionData.get_result_lose_title(id) == String(result["lose_title"]) \
			and not result.has("win_hint") and not result.has("lose_hint")
	_check("result: get_result_win_title/lose_title совпадают с блоком, подсказок в блоке нет",
		getters_ok)

	# Неизвестная миссия и пустой id: пустые строки (UI берёт текст сцены).
	var unknown := MissionData.get_result("nope")
	var empty := MissionData.get_result("")
	var empty_ok := unknown.size() == MissionData.RESULT_KEYS.size() \
		and empty.size() == MissionData.RESULT_KEYS.size()
	for key: String in MissionData.RESULT_KEYS:
		empty_ok = empty_ok and String(unknown[key]).is_empty() and String(empty[key]).is_empty()
	_check("result: неизвестная миссия и пустой id → 2 пустые строки (фолбэк UI)",
		empty_ok, "%s / %s" % [str(unknown), str(empty)])
	_check("result: геттеры неизвестной миссии → пустые строки",
		MissionData.get_result_win_title("nope").is_empty()
		and MissionData.get_result_lose_title("nope").is_empty())

	# Лимит длины (символы) — только для заголовков: 48 px Bold в поле 540.
	var limits_ok := true
	var limits_details := ""
	for id: String in MissionData.MISSION_IDS:
		var result := MissionData.get_result(id)
		for key: String in MissionData.RESULT_KEYS:
			var text := String(result.get(key, ""))
			if text.length() > MissionData.RESULT_TITLE_MAX_CHARS:
				limits_ok = false
				limits_details += "%s.%s %d > %d; " % [id, key, text.length(),
					MissionData.RESULT_TITLE_MAX_CHARS]
	_check("result: заголовки ≤ %d символов" % MissionData.RESULT_TITLE_MAX_CHARS,
		limits_ok, limits_details)
	_check("result: лимит 18 символов и 2 ключа — часть контракта данных",
		MissionData.RESULT_TITLE_MAX_CHARS == 18
		and MissionData.RESULT_KEYS == ["win_title", "lose_title"],
		"%d / %s" % [MissionData.RESULT_TITLE_MAX_CHARS, str(MissionData.RESULT_KEYS)])
	# M11/T3 (D4): подсказок нет и в самом JSON — иначе данные и UI разъедутся молча.
	var raw := FileAccess.get_file_as_string(MissionData.DATA_PATH)
	_check("result: в data/missions.json нет полей win_hint/lose_hint (D4)",
		not raw.contains("win_hint") and not raw.contains("lose_hint"))
	# validate() обязан молчать на реальных данных (блок result тоже проверяется).
	var errors := MissionData.validate()
	_check("result: MissionData.validate() без ошибок (result валиден)",
		errors.is_empty(), str(errors))


# ─── Миссия 1 — 6 волн: 1–5 как прежний хардкод, 6-я по GDD ─────────────────
func _check_mission_1() -> void:
	var table := MissionData.get_wave_table("m1_airfield")
	_check("M1: 6 волн", table.size() == 6 and MissionData.get_wave_count("m1_airfield") == 6,
		str(table.size()))
	var counts: Array = []
	for wave: Array in table:
		counts.append(wave.size())
	_check("M1: состав 4 / 5 / 3 / 7 / 6 / 6", counts == [4, 5, 3, 7, 6, 6], str(counts))

	# Таблица: волны 1–5 — 1:1 с прежним хардкодом, волна 6 — по GDD (эталон M1_EXPECTED).
	# Разбираем по волнам, чтобы FAIL называл волну.
	var exact := table.size() == M1_EXPECTED.size()
	var first_bad := ""
	for wave_index in mini(table.size(), M1_EXPECTED.size()):
		var expected_wave: Array = M1_EXPECTED[wave_index]
		var actual_wave: Array = table[wave_index]
		if actual_wave.size() != expected_wave.size():
			exact = false
			first_bad = "волна %d: %d бортов вместо %d" % [
				wave_index + 1, actual_wave.size(), expected_wave.size()]
			continue
		for entry_index in expected_wave.size():
			var expected_entry: Array = expected_wave[entry_index]
			var actual_entry: Dictionary = actual_wave[entry_index]
			var scene: PackedScene = actual_entry.get("scene") as PackedScene
			var scene_path := scene.resource_path if scene != null else "<null>"
			var point: Vector2 = actual_entry.get("position", Vector2.ZERO) as Vector2
			var expected_point: Vector2 = expected_entry[1]
			if scene_path != String(expected_entry[0]):
				exact = false
				first_bad = "волна %d #%d: сцена %s вместо %s" % [
					wave_index + 1, entry_index + 1, scene_path, expected_entry[0]]
			elif not is_equal_approx(point.x, expected_point.x) \
					or not is_equal_approx(point.y, expected_point.y):
				exact = false
				first_bad = "волна %d #%d: %s вместо %s" % [
					wave_index + 1, entry_index + 1, point, expected_point]
	_check("M1: волны 1–5 1:1 с прежней таблицей, волна 6 — по GDD (сцены и точки)",
		exact, first_bad)

	# Совместимость со smoke-тестом: статический WaveManager.wave_table() — та же таблица.
	var legacy := WaveManager.wave_table()
	var legacy_ok := legacy.size() == table.size()
	var legacy_bad := ""
	for wave_index in mini(legacy.size(), table.size()):
		var a: Array = legacy[wave_index]
		var b: Array = table[wave_index]
		if a.size() != b.size():
			legacy_ok = false
			legacy_bad = "волна %d: %d / %d" % [wave_index + 1, a.size(), b.size()]
			continue
		for entry_index in a.size():
			var left: Dictionary = a[entry_index]
			var right: Dictionary = b[entry_index]
			var left_scene := String((left.get("scene") as PackedScene).resource_path) \
				if left.get("scene") != null else "<null>"
			var right_scene := String((right.get("scene") as PackedScene).resource_path) \
				if right.get("scene") != null else "<null>"
			var left_point: Vector2 = left.get("position", Vector2.ZERO) as Vector2
			var right_point: Vector2 = right.get("position", Vector2.ZERO) as Vector2
			if left_scene != right_scene or left_point != right_point:
				legacy_ok = false
				legacy_bad = "волна %d #%d" % [wave_index + 1, entry_index + 1]
	_check("M1: WaveManager.wave_table() совместим (сцены и точки)", legacy_ok, legacy_bad)
	_check("M1: WaveManager.WAVE_COUNT = 6 и ремкомплект в волне 4 (индекс 3)",
		WaveManager.WAVE_COUNT == 6 and WaveManager.REPAIR_WAVE_INDEX == 3,
		"%d / %d" % [WaveManager.WAVE_COUNT, WaveManager.REPAIR_WAVE_INDEX])

	_check("M1: босс he111", MissionData.get_boss_type("m1_airfield") == "he111",
		MissionData.get_boss_type("m1_airfield"))
	_check("M1: repair_wave = 3", MissionData.get_repair_wave("m1_airfield") == 3,
		str(MissionData.get_repair_wave("m1_airfield")))
	_check("M1: repair_types = [ju87]",
		_is_single_type(MissionData.get_repair_types("m1_airfield"), "ju87"),
		str(MissionData.get_repair_types("m1_airfield")))
	_check("M1: пули 260–320",
		MissionData.get_bullet_speed_range("m1_airfield") == Vector2(260.0, 320.0),
		str(MissionData.get_bullet_speed_range("m1_airfield")))


# ─── Миссии 2 и 3 ───────────────────────────────────────────────────────────
func _check_mission_2_and_3() -> void:
	var cases := [
		{"id": "m2_crossing", "boss": "ju88", "repair": "ju87", "bullets": Vector2(300.0, 380.0),
			"expected": M2_EXPECTED},
		{"id": "m3_city", "boss": "fw200", "repair": "bf110", "bullets": Vector2(340.0, 420.0),
			"expected": M3_EXPECTED},
	]
	for mission_case: Dictionary in cases:
		var id := String(mission_case["id"])
		var table := MissionData.get_wave_table(id)
		_check("%s: 6 волн" % id, table.size() == 6 and MissionData.get_wave_count(id) == 6,
			"%d / %d" % [table.size(), MissionData.get_wave_count(id)])
		_check("%s: босс %s" % [id, mission_case["boss"]],
			MissionData.get_boss_type(id) == String(mission_case["boss"]),
			MissionData.get_boss_type(id))
		_check("%s: repair_wave = 4" % id, MissionData.get_repair_wave(id) == 4,
			str(MissionData.get_repair_wave(id)))
		_check("%s: repair_types = [%s]" % [id, mission_case["repair"]],
			_is_single_type(MissionData.get_repair_types(id), String(mission_case["repair"])),
			str(MissionData.get_repair_types(id)))
		_check("%s: пули %d–%d" % [id, int(mission_case["bullets"][0]),
				int(mission_case["bullets"][1])],
			MissionData.get_bullet_speed_range(id) == mission_case["bullets"],
			str(MissionData.get_bullet_speed_range(id)))
		# Состав волн по GDD: сравниваем счётчики типов, лишние типы — провал.
		var expected_waves: Array = mission_case["expected"]
		var comp_ok := table.size() == expected_waves.size()
		var comp_bad := ""
		for wave_index in mini(table.size(), expected_waves.size()):
			var actual: Dictionary = _type_counts(id, wave_index)
			var expected: Dictionary = expected_waves[wave_index]
			if actual != expected:
				comp_ok = false
				comp_bad = "волна %d: %s вместо %s" % [wave_index + 1, actual, expected]
		_check("%s: волны набраны по GDD" % id, comp_ok, comp_bad)
		# Ремкомплект имеет смысл: в его волне есть хотя бы один борт нужного типа.
		var repair_counts: Dictionary = _type_counts(id, MissionData.get_repair_wave(id))
		_check("%s: в волне ремкомплекта есть %s" % [id, mission_case["repair"]],
			int(repair_counts.get(String(mission_case["repair"]), 0)) > 0, str(repair_counts))

	# M2 не содержит неизвестных типов: с M5.2 все сцены (включая bf110) существуют.
	var m2_table := MissionData.get_wave_table("m2_crossing")
	var null_scenes := 0
	var known_scenes_ok := true
	for wave: Array in m2_table:
		for entry: Dictionary in wave:
			if entry.get("scene") == null:
				null_scenes += 1
	# ju87/bf109/fw190 в M2 обязаны резолвиться в сцены (M5.2 добавит только bf110/ju88/fw200).
	var m2_waves := MissionData.get_waves("m2_crossing")
	for wave: Dictionary in m2_waves:
		for entry: Dictionary in (wave.get("enemies", []) as Array):
			var type := String(entry.get("type", ""))
			if type in ["bf109", "ju87", "fw190"]:
				known_scenes_ok = known_scenes_ok and MissionData.scene_for_type(type) != null
	_check("M2: неизвестных сцен нет (все борта существуют)", null_scenes == 0 and known_scenes_ok,
		"null-сцен %d" % null_scenes)
	# M3 ссылается на bf110 — с M5.2 сцена существует и должна резолвиться.
	var m3_has_bf110 := false
	var m3_null_scenes := 0
	for wave: Dictionary in MissionData.get_waves("m3_city"):
		for entry: Dictionary in (wave.get("enemies", []) as Array):
			if String(entry.get("type", "")) == "bf110":
				m3_has_bf110 = true
	for wave: Array in MissionData.get_wave_table("m3_city"):
		for entry: Dictionary in wave:
			if entry.get("scene") == null:
				m3_null_scenes += 1
	_check("M3: bf110 есть в данных и его сцена резолвится (M5.2)",
		m3_has_bf110 and m3_null_scenes == 0
		and MissionData.scene_for_type("bf110") != null,
		"bf110 %s, null-сцен %d" % [m3_has_bf110, m3_null_scenes])


## Один тип в repair_types: Array[String] из JSON сравниваем поэлементно (без кастов массивов).
func _is_single_type(types: Array[String], expected: String) -> bool:
	return types.size() == 1 and types[0] == expected


## Счётчики типов волны по данным (JSON), без сцен: {"bf109": 2, ...}.
func _type_counts(id: String, wave_index: int) -> Dictionary:
	var counts := {}
	var waves := MissionData.get_waves(id)
	if wave_index < 0 or wave_index >= waves.size():
		return counts
	var wave: Dictionary = waves[wave_index]
	for entry: Dictionary in (wave.get("enemies", []) as Array):
		var type := String(entry.get("type", ""))
		counts[type] = int(counts.get(type, 0)) + 1
	return counts


## Сколько Bf 110 реально в мире (M5.2): проверка, что волна миссии 3 спавнится целиком.
func _count_bf110() -> int:
	if _level == null:
		return 0
	var total := 0
	for child in _level.enemies_root.get_children():
		if child is EnemyBf110 and (child as EnemyBase).is_active:
			total += 1
	return total


# ─── Глубины и сцены ────────────────────────────────────────────────────────
func _check_depths_and_scenes() -> void:
	var depths_ok := true
	for depth: String in DEPTH_TABLE:
		depths_ok = depths_ok and is_equal_approx(
			MissionData.depth_y(depth), float(DEPTH_TABLE[depth]))
	_check("глубины: default −70 / back −88 / mid −34 / lead −46 / v −64", depths_ok)
	_check("глубины: совпадают с константами WaveManager",
		is_equal_approx(MissionData.depth_y("default"), WaveManager.SPAWN_DEPTH)
		and is_equal_approx(MissionData.depth_y("back"), WaveManager.SPAWN_DEPTH_BACK)
		and is_equal_approx(MissionData.depth_y("mid"), WaveManager.SPAWN_DEPTH_MID)
		and is_equal_approx(MissionData.depth_y("lead"), WaveManager.SPAWN_DEPTH_LEAD)
		and is_equal_approx(MissionData.depth_y("v"), WaveManager.SPAWN_DEPTH_V))
	_check("глубины: неизвестная строка → default",
		is_equal_approx(MissionData.depth_y("?"), MissionData.DEPTH_DEFAULT))
	_check("сцены: he111 → boss_he111.tscn",
		MissionData.scene_for_type("he111") == WaveManager.BOSS_SCENE)
	_check("сцены: ju87 → enemy_ju87.tscn",
		MissionData.scene_for_type("ju87") == WaveManager.JU87_SCENE)
	_check("сцены: bf110/ju88/fw200 → свои сцены (M5.2)",
		MissionData.scene_for_type("bf110") == MissionData.BF110_SCENE
		and MissionData.scene_for_type("ju88") == MissionData.BOSS_JU88_SCENE
		and MissionData.scene_for_type("fw200") == MissionData.BOSS_FW200_SCENE)
	_check("типы: asset_key → id (enemy_ju87 → ju87, boss_fw200 → fw200)",
		MissionData.type_for_asset_key(&"enemy_ju87") == "ju87"
		and MissionData.type_for_asset_key(&"boss_fw200") == "fw200")


# ─── Поле и безопасность спавна ─────────────────────────────────────────────
## Каждая точка всех миссий: x в полосе 80…460 (силуэт с маржой 26 в поле 540),
## y выше порога авто-деспавна EnemyBase (−96). Миссия 1 проверена эталоном выше,
## здесь — общий инвариант данных 2 и 3.
func _check_playfield() -> void:
	var bad_entry := ""
	var checked := 0
	for id: String in ["m2_crossing", "m3_city"]:
		var table := MissionData.get_wave_table(id)
		for wave_index in MissionData.get_wave_count(id):
			var wave: Array = table[wave_index]
			for entry: Dictionary in wave:
				checked += 1
				var point: Vector2 = entry.get("position", Vector2.ZERO) as Vector2
				if point.x < 80.0 or point.x > 460.0:
					bad_entry = "%s волна %d: x=%.1f" % [id, wave_index + 1, point.x]
				elif point.y <= -EnemyBase.DEFAULT_DESPAWN_PADDING:
					bad_entry = "%s волна %d: y=%.1f" % [id, wave_index + 1, point.y]
	_check("M2/M3: все спавны в полосе 80…460 и выше порога авто-деспавна",
		bad_entry == "", bad_entry if bad_entry != "" else "%d точек" % checked)


# ─── Рантайм: WaveManager читает волны из данных ────────────────────────────
## Реальная main.tscn: миссия 2 стартует по данным (6 волн, 5 Bf 109 в первой), миссия 3
## поднимает волну 3 (2 Bf 110 + 3 Bf 109) — с M5.2 спавнятся все пять бортов.
## Забег в конце возвращается на миссию 1 и освобождается.
func _check_runtime() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame

	_level.start_mission("m2_crossing")
	await get_tree().process_frame
	_check("рантайм: миссия 2 стартовала, 6 волн, 5 Bf 109 в волне 1",
		_level.get_mission_id() == "m2_crossing"
		and _level.waves.get_mission_id() == "m2_crossing"
		and _level.waves.get_wave_count() == 6
		and _level.waves.get_alive_count() == 5
		and _level.waves.get_wave_index() == 0,
		"миссия %s, волн %d, живых %d, индекс %d" % [
			_level.waves.get_mission_id(), _level.waves.get_wave_count(),
			_level.waves.get_alive_count(), _level.waves.get_wave_index()])

	_level.start_mission("m3_city")
	await get_tree().process_frame
	_level.waves.start_at_wave(2)
	await get_tree().process_frame
	# M5.2: сцены Bf 110 появились, поэтому волна 3 спавнится целиком (2 Bf 110 + 3 Bf 109).
	_check("рантайм: M3 волна 3 — 2 Bf 110 + 3 Bf 109 заспавнены (M5.2)",
		_level.waves.get_wave_count() == 6 and _level.waves.get_alive_count() == 5
		and _count_bf110() == 2,
		"живых %d, Bf110 %d" % [_level.waves.get_alive_count(), _count_bf110()])

	# Возврат на миссию 1: рестарт из UI и тап по экрану исхода идут этим же путём.
	_level.start_mission("m1_airfield")
	await get_tree().process_frame
	_check("рантайм: start_mission(m1_airfield) возвращает 6 волн и 4 борта волны 1",
		_level.get_mission_id() == "m1_airfield"
		and _level.waves.get_wave_count() == 6
		and _level.waves.get_alive_count() == 4,
		"волн %d, живых %d" % [_level.waves.get_wave_count(), _level.waves.get_alive_count()])

	_level.queue_free()
	_level = null
	await get_tree().process_frame


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
