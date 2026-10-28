# mission_data.gd
# Purpose: Данные миссий M5.1 (GDD «Реализация v1» → «Данные миссий»): волны, состав врагов,
#          босс, диапазон скорости пуль и правило ремкомплекта читаются из `data/missions.json`,
#          хардкода волн в `WaveManager` больше нет. Поведение миссии 1 (m1_airfield) — точная
#          копия прежнего `WaveManager.wave_table()`, остальные миссии наполняются данными.
#          JSON кэшируется на процесс: один `FileAccess.get_file_as_string` + `JSON.parse_string`,
#          повторные вызовы (в т.ч. из smoke-теста) файл не читают. Битый/отсутствующий файл не
#          роняет игру: `push_error` один раз и пустой словарь → миссия без волн (иначе сцена
#          запуска падала бы на старте забега).
#          M5.2: загрузчик отдаёт сцены всех типов из `data/missions.json` — bf110 / ju88 / fw200
#          подключены (enemy_bf110.tscn, boss_ju88.tscn, boss_fw200.tscn), поэтому
#          `scene_for_type()` больше не возвращает null для типов из VALID_TYPES/VALID_BOSSES.
#          M5.3a: `star_score` миссии (порог третьей звезды) — тоже данные: get_star_score(id)
#          с валидацией «положительное число».
#          M10 (bug 5): блок `result` миссии — тексты экранов победы и поражения («Аэродром
#          спасён» / «Переправа потеряна»…). M11/T3 (решение D4): два обязательных ключа
#          (`win_title`/`lose_title`) и один лимит длины (заголовок); строки-подсказки удалены.
#          Пустое/битое значение → UI берёт текст сцены (фолбэк).
# Dependencies: сцены врагов enemy_bf109/enemy_ju87/enemy_fw190/enemy_bf110 и боссов
#               boss_he111/boss_ju88/boss_fw200. Обратных зависимостей нет: MissionData —
#               RefCounted-утилита без узлов и сигналов.
# Author: Mechanics Developer Agent

class_name MissionData
extends RefCounted

const DATA_PATH := "res://data/missions.json"
const SCHEMA_VERSION := 1
## Сколько миссий в кампании v1 (GDD: 3 миссии × 3–4 мин).
const MISSION_COUNT := 3
## Порядок миссий кампании (он же порядок карточек в M5.3).
const MISSION_IDS := ["m1_airfield", "m2_crossing", "m3_city"]

## Глубины спавна: значения совпадают с константами WaveManager (SPAWN_DEPTH*).
## Y строго выше −EnemyBase.DEFAULT_DESPAWN_PADDING (−96 px), иначе авто-деспавн в первом кадре.
const DEPTH_DEFAULT := -70.0
const DEPTH_BACK := -88.0
const DEPTH_MID := -34.0
const DEPTH_LEAD := -46.0
const DEPTH_V := -64.0

## Допустимые строковые id врагов (GDD «Враги»). Сцены есть у всех четырёх типов (bf110 — M5.2),
## боссы — отдельным списком.
const VALID_TYPES := ["bf109", "ju87", "fw190", "bf110"]
const VALID_BOSSES := ["he111", "ju88", "fw200"]

## M10: ключи блока `result` миссии (порядок — порядок карточек/экранов, менять нельзя:
## GDD-ключи стабильны). M11/T3 (решение D4): строки-подсказки `win_hint`/`lose_hint` удалены
## вместе с тап-шорткатами — на экранах исхода подсказок нет, остались только заголовки.
const RESULT_KEYS := ["win_title", "lose_title"]
## Лимит длины строк result в СИМВОЛАХ. Заголовки — Bold 48 px в поле 540 (замер реальным
## шрифтом: «Переправа потеряна» = 520.0 px — верхняя граница 520).
const RESULT_TITLE_MAX_CHARS := 18

const BF109_SCENE: PackedScene = preload("res://scenes/enemy_bf109.tscn")
const JU87_SCENE: PackedScene = preload("res://scenes/enemy_ju87.tscn")
const FW190_SCENE: PackedScene = preload("res://scenes/enemy_fw190.tscn")
const BF110_SCENE: PackedScene = preload("res://scenes/enemy_bf110.tscn")
const BOSS_HE111_SCENE: PackedScene = preload("res://scenes/boss_he111.tscn")
const BOSS_JU88_SCENE: PackedScene = preload("res://scenes/boss_ju88.tscn")
const BOSS_FW200_SCENE: PackedScene = preload("res://scenes/boss_fw200.tscn")

## Кэш разобранного JSON на процесс. `_load_attempted` отделяет «ещё не читали» от
## «прочитали и получили пусто» — второй раз файл и `push_error` не повторяются.
static var _cache: Dictionary = {}
static var _load_attempted: bool = false


# ─── Загрузка / кэш ─────────────────────────────────────────────────────────
## Корень JSON ({"schema_version", "missions"}). Никогда не null: при ошибке {}.
static func _data() -> Dictionary:
	if not _load_attempted:
		_load_attempted = true
		_cache = _read_file()
	return _cache


## Единственное чтение файла. Любая проблема → push_error один раз (кэш уже помечен
## загруженным) и {} — вызывающий код обязан пережить пустые данные.
static func _read_file() -> Dictionary:
	if not FileAccess.file_exists(DATA_PATH):
		push_error("MissionData: файл %s не найден — миссии без волн" % DATA_PATH)
		return {}
	var text := FileAccess.get_file_as_string(DATA_PATH)
	if text.is_empty():
		push_error("MissionData: файл %s пуст или недоступен" % DATA_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("MissionData: %s — невалидный JSON (ожидался объект)" % DATA_PATH)
		return {}
	var data: Dictionary = parsed
	if typeof(data.get("missions")) != TYPE_ARRAY:
		push_error("MissionData: %s — нет массива missions" % DATA_PATH)
		return {}
	return data


## QA/тесты: сбросить кэш (например, после правки JSON на ходу). Игровой код не вызывает.
static func reload() -> void:
	_load_attempted = false
	_cache.clear()


# ─── Публичный доступ к миссиям ─────────────────────────────────────────────
## Миссия по id. Неизвестный id / битые данные → {} (никогда не null).
static func get_mission(id: String) -> Dictionary:
	for mission: Variant in _data().get("missions", []):
		if typeof(mission) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = mission
		if String(item.get("id", "")) == id:
			return item
	return {}


## id миссий в порядке файла. Пустой массив при битых данных.
static func get_mission_ids() -> Array[String]:
	var ids: Array[String] = []
	for mission: Variant in _data().get("missions", []):
		if typeof(mission) != TYPE_DICTIONARY:
			continue
		var id := String((mission as Dictionary).get("id", ""))
		if not id.is_empty():
			ids.append(id)
	return ids


static func get_title(id: String) -> String:
	return String(get_mission(id).get("title", ""))


static func get_briefing(id: String) -> String:
	return String(get_mission(id).get("briefing", ""))


# ─── M10: тексты экрана победы/поражения по миссии ──────────────────────────
## Блок `result` миссии: ВСЕГДА ровно RESULT_KEYS ключей (значение — строка, при битых или
## отсутствующих данных ""). Неизвестная миссия → две пустые строки, поэтому UI спокойно
## подставляет текст сцены и не падает.
static func get_result(id: String) -> Dictionary:
	var mission := get_mission(id)
	var raw: Variant = mission.get("result")
	var result := {}
	for key: String in RESULT_KEYS:
		var text := ""
		if typeof(raw) == TYPE_DICTIONARY:
			var value: Variant = (raw as Dictionary).get(key)
			if typeof(value) == TYPE_STRING:
				text = String(value)
		result[key] = text
	return result


static func get_result_win_title(id: String) -> String:
	return String(get_result(id).get("win_title", ""))


static func get_result_lose_title(id: String) -> String:
	return String(get_result(id).get("lose_title", ""))


## Волны «как в JSON» (массивы объектов enemies). Копию не делаем: данные только читаются.
static func get_waves(id: String) -> Array:
	var waves: Variant = get_mission(id).get("waves", [])
	return waves if typeof(waves) == TYPE_ARRAY else []


static func get_wave_count(id: String) -> int:
	return get_waves(id).size()


## id босса миссии ("he111"/"ju88"/"fw200"). Неизвестная миссия → "".
static func get_boss_type(id: String) -> String:
	return String(get_mission(id).get("boss", ""))


## Волна, из которой выпадает единственный ремкомплект миссии (0-based).
## Битые данные → −1 (WaveManager тогда не роняет подбор вовсе).
static func get_repair_wave(id: String) -> int:
	var raw: Variant = get_mission(id).get("repair_wave")
	if typeof(raw) != TYPE_FLOAT and typeof(raw) != TYPE_INT:
		return -1
	return int(raw)


## Типы «толстых» врагов, из которых падает ремкомплект. Всегда Array[String]:
## сравнение с id врага в WaveManager идёт по строкам, без жёсткой типизации классов.
static func get_repair_types(id: String) -> Array[String]:
	var result: Array[String] = []
	var raw: Variant = get_mission(id).get("repair_types")
	if typeof(raw) != TYPE_ARRAY:
		return result
	for item: Variant in raw:
		if typeof(item) == TYPE_STRING and not String(item).is_empty():
			result.append(String(item))
	return result


## M5.3a: порог счёта для третьей звезды миссии (GDD «Счёт, звёзды, снабжение»).
## Битые/отсутствующие данные → 0: тогда «счёт выше порога» выполняется всегда, и лучшее
## поведение — не потерять засчитанную победу из-за опечатки в JSON. Валидные значения
## проверяет validate().
static func get_star_score(id: String) -> int:
	var raw: Variant = get_mission(id).get("star_score")
	if not _is_number(raw):
		return 0
	return maxi(0, int(raw))


## Диапазон скорости вражеских пуль миссии (px/s). Обе величины из данных; при битых
## значениях — Vector2.ZERO, чтобы QA видел «нет данных», а не выдуманный баланс.
static func get_bullet_speed_range(id: String) -> Vector2:
	var mission := get_mission(id)
	var low: Variant = mission.get("bullet_speed_min")
	var high: Variant = mission.get("bullet_speed_max")
	if typeof(low) != TYPE_FLOAT and typeof(low) != TYPE_INT:
		return Vector2.ZERO
	if typeof(high) != TYPE_FLOAT and typeof(high) != TYPE_INT:
		return Vector2.ZERO
	return Vector2(float(low), float(high))


# ─── Сцены и глубина ────────────────────────────────────────────────────────
## Сцена врага или босса по строковому id. `null` — только для неизвестного id (все типы из
## VALID_TYPES/VALID_BOSSES имеют сцену с M5.2): вызывающий код обязан пропустить такой entry,
## а не падать.
static func scene_for_type(type: String) -> PackedScene:
	match type:
		"bf109":
			return BF109_SCENE
		"ju87":
			return JU87_SCENE
		"fw190":
			return FW190_SCENE
		"bf110":
			return BF110_SCENE
		"he111":
			return BOSS_HE111_SCENE
		"ju88":
			return BOSS_JU88_SCENE
		"fw200":
			return BOSS_FW200_SCENE
		_:
			return null


## Y спавна по строковой глубине. Неизвестная глубина → default (мягкий фолбэк:
## лучше враг на штатной глубине, чем падение на опечатке в JSON).
static func depth_y(depth: String) -> float:
	match depth:
		"back":
			return DEPTH_BACK
		"mid":
			return DEPTH_MID
		"lead":
			return DEPTH_LEAD
		"v":
			return DEPTH_V
		_:
			return DEPTH_DEFAULT


## Обратное преобразование asset_key → строковый id: enemy_ju87 → "ju87",
## boss_fw200 → "fw200". Нужно правилу ремкомплекта: типы приходят из JSON строками.
static func type_for_asset_key(key: StringName) -> String:
	var text := String(key)
	for prefix: String in ["enemy_", "boss_"]:
		if text.begins_with(prefix):
			return text.substr(prefix.length())
	return text


## Таблица волн в формате прежнего `WaveManager.wave_table()`:
## [{scene: PackedScene|null, position: Vector2}, ...]. `scene == null` — только для
## неизвестного типа из данных (M5.2: все штатные типы и боссы резолвятся в сцены).
static func get_wave_table(id: String) -> Array:
	var table: Array = []
	for wave: Variant in get_waves(id):
		if typeof(wave) != TYPE_DICTIONARY:
			table.append([])
			continue
		var entries: Array = []
		var raw: Variant = (wave as Dictionary).get("enemies", [])
		if typeof(raw) == TYPE_ARRAY:
			for entry: Variant in raw:
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var item: Dictionary = entry
				var type := String(item.get("type", ""))
				var x: Variant = item.get("x")
				var px := float(x) if typeof(x) == TYPE_FLOAT or typeof(x) == TYPE_INT else 0.0
				entries.append({
					"scene": scene_for_type(type),
					"position": Vector2(px, depth_y(String(item.get("depth", "default")))),
				})
		table.append(entries)
	return table


# ─── Валидатор ──────────────────────────────────────────────────────────────
## Проверка целостности данных (QA/тесты, dev-гейт M5.1). Возвращает список проблем;
## пустой массив = данные валидны. Никогда не падает и не пишет в лог.
static func validate() -> Array[String]:
	var errors: Array[String] = []
	var data := _data()
	if data.is_empty():
		errors.append("missions.json не загружен")
		return errors
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("schema_version: ожидался %d" % SCHEMA_VERSION)
	var missions: Array = data.get("missions", [])
	if missions.size() != MISSION_COUNT:
		errors.append("missions: ожидалось %d, найдено %d" % [MISSION_COUNT, missions.size()])
	var seen: Array[String] = []
	for mission: Variant in missions:
		if typeof(mission) != TYPE_DICTIONARY:
			errors.append("missions: элемент не объект")
			continue
		_validate_mission(mission as Dictionary, seen, errors)
	for required_id: String in MISSION_IDS:
		if not seen.has(required_id):
			errors.append("missions: нет обязательной миссии %s" % required_id)
	return errors


static func _validate_mission(mission: Dictionary, seen: Array[String], errors: Array[String]) -> void:
	var id := String(mission.get("id", ""))
	if id.is_empty():
		errors.append("mission: пустой id")
	elif seen.has(id):
		errors.append("mission %s: id повторяется" % id)
	else:
		seen.append(id)
	var label := id if not id.is_empty() else "?"
	if String(mission.get("title", "")).is_empty():
		errors.append("mission %s: пустой title" % label)
	if String(mission.get("briefing", "")).is_empty():
		errors.append("mission %s: пустой briefing" % label)
	# M10: result — объект с четырьмя непустыми строками в пределах лимитов длины (тексты
	# экранов исхода читаются UI напрямую: пустая строка = экран без заголовка).
	_validate_result(label, mission.get("result"), errors)
	var boss := String(mission.get("boss", ""))
	if not VALID_BOSSES.has(boss):
		errors.append("mission %s: недопустимый boss «%s»" % [label, boss])
	var low: Variant = mission.get("bullet_speed_min")
	var high: Variant = mission.get("bullet_speed_max")
	if not _is_number(low) or not _is_number(high):
		errors.append("mission %s: bullet_speed_min/max не числа" % label)
	elif float(low) <= 0.0 or float(high) < float(low):
		errors.append("mission %s: диапазон пуль %s…%s" % [label, low, high])
	# M5.3a: порог третьей звезды обязан быть положительным числом из данных.
	var star_score: Variant = mission.get("star_score")
	if not _is_number(star_score) or float(star_score) <= 0.0:
		errors.append("mission %s: star_score не положительное число (%s)" % [label, star_score])
	var waves: Variant = mission.get("waves", [])
	if typeof(waves) != TYPE_ARRAY or (waves as Array).is_empty():
		errors.append("mission %s: нет волн" % label)
		return
	_validate_waves(label, waves as Array, errors)
	var repair_wave := get_repair_wave(id)
	if repair_wave < 0 or repair_wave >= (waves as Array).size():
		errors.append("mission %s: repair_wave %d вне диапазона 0…%d"
			% [label, repair_wave, (waves as Array).size() - 1])
	var repair_types := get_repair_types(id)
	if repair_types.is_empty():
		errors.append("mission %s: пустой repair_types" % label)
	for type: String in repair_types:
		if not VALID_TYPES.has(type):
			errors.append("mission %s: repair_types — неизвестный тип «%s»" % [label, type])


## M10: проверка блока `result`. Ошибки в стиле остального валидатора, без исключений:
## битый JSON сюда уже не доходит, поэтому проверяем только тип/пустоту/длину.
## M11/T3: ключей осталось два (`win_title`/`lose_title`) — лимит заголовка один для обоих.
static func _validate_result(label: String, raw: Variant, errors: Array[String]) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("mission %s: нет объекта result" % label)
		return
	var result: Dictionary = raw
	for key: String in RESULT_KEYS:
		var value: Variant = result.get(key)
		if typeof(value) != TYPE_STRING:
			errors.append("mission %s: result.%s — не строка" % [label, key])
			continue
		var text := String(value)
		if text.is_empty():
			errors.append("mission %s: result.%s — пустая строка" % [label, key])
			continue
		if text.length() > RESULT_TITLE_MAX_CHARS:
			errors.append("mission %s: result.%s длиннее %d символов (%d)"
				% [label, key, RESULT_TITLE_MAX_CHARS, text.length()])


static func _validate_waves(label: String, waves: Array, errors: Array[String]) -> void:
	for index in waves.size():
		var wave: Variant = waves[index]
		if typeof(wave) != TYPE_DICTIONARY:
			errors.append("mission %s: волна %d — не объект" % [label, index])
			continue
		var enemies: Variant = (wave as Dictionary).get("enemies", [])
		if typeof(enemies) != TYPE_ARRAY or (enemies as Array).is_empty():
			errors.append("mission %s: волна %d пуста" % [label, index])
			continue
		for entry: Variant in enemies as Array:
			if typeof(entry) != TYPE_DICTIONARY:
				errors.append("mission %s: волна %d — entry не объект" % [label, index])
				continue
			var item: Dictionary = entry
			var type := String(item.get("type", ""))
			if not VALID_TYPES.has(type):
				errors.append("mission %s: волна %d — недопустимый тип «%s»" % [label, index, type])
			var depth := String(item.get("depth", ""))
			if not ["default", "back", "mid", "lead", "v"].has(depth):
				errors.append("mission %s: волна %d — недопустимая глубина «%s»"
					% [label, index, depth])
			var x: Variant = item.get("x")
			if not _is_number(x) or float(x) < 0.0 or float(x) > 540.0:
				errors.append("mission %s: волна %d — x вне поля: %s" % [label, index, x])


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
