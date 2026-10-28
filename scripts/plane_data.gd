# plane_data.gd
# Purpose: Данные самолётов ангара M6.2a (GDD «Mechanics → Самолёты (ангар)»): 3 самолёта
#          (Ла-5, Як-3, Аэрокобра) читаются из `data/planes.json` — темп стрельбы, урон,
#          скорость снаряда, хитбокс самолёта, хитбокс пули, ключ арта и правило открытия.
#          Числа — данные, а не константы: баланс правится JSON-ом, `Player.apply_plane()`
#          только раскладывает поля. Новый самолёт = запись в файле + ID в PLANE_IDS.
#          JSON кэшируется на процесс: одно чтение файла + `JSON.parse_string`, повторные
#          вызовы (в т.ч. из тестов) файл не читают. Битый/отсутствующий файл не роняет игру:
#          `push_error` один раз и пустые данные → `apply_plane()` оставляет базу Ла-5.
# Dependencies: `data/planes.json`. Обратных зависимостей нет: PlaneData — RefCounted-утилита
#               без узлов и сигналов (как MissionData/PerkData). SaveGame/Player/CampaignProgress
#               читают её статически.
# Author: Mechanics Developer Agent
#
# СХЕМА САМОЛЁТА:
#   id                — стабильный ключ (никогда не переименовывается: сейв/тесты держат его)
#   name              — название (RU, player-facing, для ангара M6.2b)
#   asset_key         — ключ ArtStyle (player_la5 / player_yak3 / player_p39)
#   fire_interval     — пауза между выстрелами, с (0.125 = 8 выстр./с)
#   damage            — урон одной пули (float: 0.85 / 1.0 / 1.5)
#   bullet_speed      — скорость снаряда, px/s
#   hit_radius        — радиус хитбокса самолёта (круг, меньше визуала)
#   bullet_hit_radius — радиус хитбокса пули игрока (Ла-5/Як-3 — 4, Аэрокобра — 6)
#   unlock            — "start" (Ла-5) / "campaign" (все 3 миссии ≥1 звезды) / "stars_9" (9/9)
#   description       — текст для ангара (RU, player-facing)

class_name PlaneData
extends RefCounted

const DATA_PATH := "res://data/planes.json"
const SCHEMA_VERSION := 1

## GDD «Самолёты (ангар)»: три самолёта в порядке ангара.
const PLANE_COUNT := 3
const PLANE_IDS := ["la5", "yak3", "p39"]
const DEFAULT_PLANE := "la5"

## Правила открытия. Само открытие живёт в CampaignProgress (M6.2a), здесь — только
## допустимые значения поля `unlock`.
const UNLOCK_START := "start"
const UNLOCK_CAMPAIGN := "campaign"
const UNLOCK_STARS_9 := "stars_9"
const VALID_UNLOCKS := [UNLOCK_START, UNLOCK_CAMPAIGN, UNLOCK_STARS_9]

## Ключи арта GDD «Assets» (нужны для визуала и валидатора: опечатка в ключе молча
## оставила бы Ла-5 на экране).
const VALID_ASSET_KEYS := ["player_la5", "player_yak3", "player_p39"]

## Кэш разобранного JSON на процесс. `_load_attempted` отделяет «ещё не читали» от
## «прочитали и получили пусто» — второй раз файл и `push_error` не повторяются.
static var _cache: Dictionary = {}
static var _load_attempted: bool = false


# ─── Загрузка / кэш ─────────────────────────────────────────────────────────
## Корень JSON ({"schema_version", "planes"}). Никогда не null: при ошибке {}.
static func _data() -> Dictionary:
	if not _load_attempted:
		_load_attempted = true
		_cache = _read_file()
	return _cache


## Единственное чтение файла. Любая проблема → push_error один раз (кэш уже помечен
## загруженным) и {} — вызывающий код обязан пережить пустые данные.
static func _read_file() -> Dictionary:
	if not FileAccess.file_exists(DATA_PATH):
		push_error("PlaneData: файл %s не найден — самолёты недоступны" % DATA_PATH)
		return {}
	var text := FileAccess.get_file_as_string(DATA_PATH)
	if text.is_empty():
		push_error("PlaneData: файл %s пуст или недоступен" % DATA_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("PlaneData: %s — невалидный JSON (ожидался объект)" % DATA_PATH)
		return {}
	var data: Dictionary = parsed
	if typeof(data.get("planes")) != TYPE_ARRAY:
		push_error("PlaneData: %s — нет массива planes" % DATA_PATH)
		return {}
	return data


## QA/тесты: сбросить кэш (например, после правки JSON на ходу). Игровой код не вызывает.
static func reload() -> void:
	_load_attempted = false
	_cache.clear()


# ─── Публичный доступ к самолётам ───────────────────────────────────────────
## Все самолёты в порядке файла. Копию не делаем: данные только читаются.
static func get_all() -> Array:
	var planes: Variant = _data().get("planes", [])
	return planes if typeof(planes) == TYPE_ARRAY else []


## Самолёт по id. Неизвестный id / битые данные → {} (никогда не null).
static func get_plane(id: String) -> Dictionary:
	for plane: Variant in get_all():
		if typeof(plane) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = plane
		if String(item.get("id", "")) == id:
			return item
	return {}


## id самолётов в порядке файла. Пустой массив при битых данных.
static func get_ids() -> Array[String]:
	var ids: Array[String] = []
	for plane: Variant in get_all():
		if typeof(plane) != TYPE_DICTIONARY:
			continue
		var id := String((plane as Dictionary).get("id", ""))
		if not id.is_empty():
			ids.append(id)
	return ids


static func has_plane(id: String) -> bool:
	return not get_plane(id).is_empty()


## Имя самолёта для ангара (M6.2b). Не `get_name()`: у RefCounted-класса уже есть
## одноимённый член, вызов `PlaneData.get_name(id)` падал бы в рантайме.
static func get_plane_name(id: String) -> String:
	return String(get_plane(id).get("name", ""))


static func get_description(id: String) -> String:
	return String(get_plane(id).get("description", ""))


## Ключ арта ArtStyle. Неизвестный самолёт → ключ Ла-5 (мягкий фолбэк для визуала).
static func get_asset_key(id: String) -> StringName:
	var key := String(get_plane(id).get("asset_key", ""))
	return StringName(key) if not key.is_empty() else StringName(VALID_ASSET_KEYS[0])


static func get_unlock(id: String) -> String:
	return String(get_plane(id).get("unlock", ""))


## Числовое поле самолёта с фолбэком (неизвестный самолёт/битое значение → fallback).
## Валидность положительных чисел проверяет validate(); здесь — только безопасное чтение.
static func get_number(id: String, key: String, fallback: float) -> float:
	var raw: Variant = get_plane(id).get(key)
	if not _is_number(raw):
		return fallback
	var value := float(raw)
	if not is_finite(value) or value <= 0.0:
		return fallback
	return value


# ─── Валидатор ──────────────────────────────────────────────────────────────
## Проверка целостности данных (QA/тесты, dev-гейт M6.2a). Возвращает список проблем;
## пустой массив = данные валидны. Никогда не падает и не пишет в лог.
static func validate() -> Array[String]:
	var errors: Array[String] = []
	var data := _data()
	if data.is_empty():
		errors.append("planes.json не загружен")
		return errors
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("schema_version: ожидался %d" % SCHEMA_VERSION)

	var planes := get_all()
	if planes.size() != PLANE_COUNT:
		errors.append("planes: ожидалось %d, найдено %d" % [PLANE_COUNT, planes.size()])

	var seen: Array[String] = []
	for plane: Variant in planes:
		if typeof(plane) != TYPE_DICTIONARY:
			errors.append("planes: элемент не объект")
			continue
		var item: Dictionary = plane
		var id := String(item.get("id", ""))
		if id.is_empty():
			errors.append("plane: пустой id")
		elif seen.has(id):
			errors.append("plane %s: id повторяется" % id)
		else:
			seen.append(id)
		var label := id if not id.is_empty() else "?"
		if String(item.get("name", "")).is_empty():
			errors.append("plane %s: пустое name" % label)
		if String(item.get("description", "")).is_empty():
			errors.append("plane %s: пустое description" % label)
		var asset_key := String(item.get("asset_key", ""))
		if not VALID_ASSET_KEYS.has(asset_key):
			errors.append("plane %s: неизвестный asset_key «%s»" % [label, asset_key])
		var unlock := String(item.get("unlock", ""))
		if not VALID_UNLOCKS.has(unlock):
			errors.append("plane %s: неизвестное правило открытия «%s»" % [label, unlock])
		for number_key: String in ["fire_interval", "damage", "bullet_speed", "hit_radius",
				"bullet_hit_radius"]:
			var raw: Variant = item.get(number_key)
			if not _is_number(raw) or float(raw) <= 0.0:
				errors.append("plane %s: %s не положительное число (%s)"
					% [label, number_key, raw])

	for required_id: String in PLANE_IDS:
		if not seen.has(required_id):
			errors.append("planes: нет обязательного самолёта %s" % required_id)
	return errors


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
