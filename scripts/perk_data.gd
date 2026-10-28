# perk_data.gd
# Purpose: Данные временных перков M6.1 (GDD «Временные перки»): 9 карт (6 оружия + 3 утилиты)
#          читаются из `data/perks.json`. Эффекты — структурированные множители/флаги, поэтому
#          в коде нет магии: `Player.apply_perks()` раскладывает `effects` по полям, а новый
#          перк добавляется данными, а не правкой логики (нужен только новый ключ эффекта
#          и его обработка в Player/PerkSystem).
#          JSON кэшируется на процесс: одно чтение файла + `JSON.parse_string`, повторные
#          вызовы (в т.ч. из тестов) файл не читают. Битый/отсутствующий файл не роняет игру:
#          `push_error` один раз и пустые данные → перки просто не предлагаются.
# Dependencies: `data/perks.json`. Обратных зависимостей нет: PerkData — RefCounted-утилита
#               без узлов и сигналов (как MissionData). Player/PerkSystem читают её статически.
# Author: Mechanics Developer Agent
#
# СХЕМА КАРТЫ:
#   id            — стабильный ключ (никогда не переименовывается, сейв/тесты держат его)
#   name          — название на карте (RU, player-facing)
#   description   — текст карты (RU, player-facing)
#   category      — "weapon" (слотов 2) или "utility" (слот 1)
#   effects       — словарь известных ключей (KNOWN_EFFECTS), значения-числа/флаги:
#     bullets_per_shot_add : int   (+N снарядов в выстреле)
#     bullet_damage_mult   : float (множитель урона снаряда)
#     fire_interval_mult   : float (множитель ПАУЗЫ между выстрелами: темп ×0.7 → 1.4)
#     bullet_speed_mult    : float (множитель скорости снаряда)
#     spread_mult          : float (множитель разброса)
#     boss_damage_mult     : float (множитель урона по боссу, не стакается — берётся max)
#     splash_radius        : float (радиус осколков, px; 0 — нет осколков)
#     splash_ratio         : float (доля урона соседям в радиусе)
#     rocket_enabled       : bool  (+ rocket_interval / rocket_count / rocket_damage / rocket_radius)
#     max_hp_add           : int   (прибавка к потолку HP)
#     heal_on_apply        : int   (лечение в момент получения карты)
#     invuln_time_add      : float (прибавка к неуязвимости после попадания, с)
#     emergency_clear      : bool  (+ emergency_clear_radius / emergency_clear_cooldown, с)

class_name PerkData
extends RefCounted

const DATA_PATH := "res://data/perks.json"
const SCHEMA_VERSION := 1

const CATEGORY_WEAPON := "weapon"
const CATEGORY_UTILITY := "utility"
const CATEGORIES := [CATEGORY_WEAPON, CATEGORY_UTILITY]

## GDD «Временные перки»: 6 карт оружия + 3 утилиты.
const CARD_COUNT := 9
const WEAPON_COUNT := 6
const UTILITY_COUNT := 3

## Порядок карт из GDD (порядок в файле и в UI выбора, M6.1b).
const CARD_IDS := [
	"sparka", "ap", "rockets", "shatter", "accuracy", "heavy",
	"repair", "coolhead", "emergency",
]

## Известные ключи эффектов и род их значения. Неизвестный ключ в данных — ошибка validate():
## иначе опечатка в JSON молча не давала бы эффекта в игре.
enum ValueKind { NUMBER, FLAG }

const KNOWN_EFFECTS := {
	"bullets_per_shot_add": ValueKind.NUMBER,
	"bullet_damage_mult": ValueKind.NUMBER,
	"fire_interval_mult": ValueKind.NUMBER,
	"bullet_speed_mult": ValueKind.NUMBER,
	"spread_mult": ValueKind.NUMBER,
	"boss_damage_mult": ValueKind.NUMBER,
	"splash_radius": ValueKind.NUMBER,
	"splash_ratio": ValueKind.NUMBER,
	"rocket_enabled": ValueKind.FLAG,
	"rocket_interval": ValueKind.NUMBER,
	"rocket_count": ValueKind.NUMBER,
	"rocket_damage": ValueKind.NUMBER,
	"rocket_radius": ValueKind.NUMBER,
	"max_hp_add": ValueKind.NUMBER,
	"heal_on_apply": ValueKind.NUMBER,
	"invuln_time_add": ValueKind.NUMBER,
	"emergency_clear": ValueKind.FLAG,
	"emergency_clear_radius": ValueKind.NUMBER,
	"emergency_clear_cooldown": ValueKind.NUMBER,
}

## Кэш разобранного JSON на процесс. `_load_attempted` отделяет «ещё не читали» от
## «прочитали и получили пусто» — второй раз файл и `push_error` не повторяются.
static var _cache: Dictionary = {}
static var _load_attempted: bool = false


# ─── Загрузка / кэш ─────────────────────────────────────────────────────────
## Корень JSON ({"schema_version", "slot_rules", "cards"}). Никогда не null: при ошибке {}.
static func _data() -> Dictionary:
	if not _load_attempted:
		_load_attempted = true
		_cache = _read_file()
	return _cache


## Единственное чтение файла. Любая проблема → push_error один раз (кэш уже помечен
## загруженным) и {} — вызывающий код обязан пережить пустые данные.
static func _read_file() -> Dictionary:
	if not FileAccess.file_exists(DATA_PATH):
		push_error("PerkData: файл %s не найден — перки недоступны" % DATA_PATH)
		return {}
	var text := FileAccess.get_file_as_string(DATA_PATH)
	if text.is_empty():
		push_error("PerkData: файл %s пуст или недоступен" % DATA_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("PerkData: %s — невалидный JSON (ожидался объект)" % DATA_PATH)
		return {}
	var data: Dictionary = parsed
	if typeof(data.get("cards")) != TYPE_ARRAY:
		push_error("PerkData: %s — нет массива cards" % DATA_PATH)
		return {}
	return data


## QA/тесты: сбросить кэш (например, после правки JSON на ходу). Игровой код не вызывает.
static func reload() -> void:
	_load_attempted = false
	_cache.clear()


# ─── Публичный доступ к картам ──────────────────────────────────────────────
## Все карты в порядке файла. Копию не делаем: данные только читаются.
static func get_all() -> Array:
	var cards: Variant = _data().get("cards", [])
	return cards if typeof(cards) == TYPE_ARRAY else []


## Карта по id. Неизвестный id / битые данные → {} (никогда не null).
static func get_card(id: String) -> Dictionary:
	for card: Variant in get_all():
		if typeof(card) != TYPE_DICTIONARY:
			continue
		var item: Dictionary = card
		if String(item.get("id", "")) == id:
			return item
	return {}


## id карт в порядке файла. Пустой массив при битых данных.
static func get_ids() -> Array[String]:
	var ids: Array[String] = []
	for card: Variant in get_all():
		if typeof(card) != TYPE_DICTIONARY:
			continue
		var id := String((card as Dictionary).get("id", ""))
		if not id.is_empty():
			ids.append(id)
	return ids


static func has_card(id: String) -> bool:
	return not get_card(id).is_empty()


static func get_category(id: String) -> String:
	return String(get_card(id).get("category", ""))


## Имя карты для UI (M6.1b). Не `get_name()`: GDScript-класс уже имеет одноимённый член,
## вызов `PerkData.get_name(id)` падает в рантайме (проверено perks_test).
static func get_card_name(id: String) -> String:
	return String(get_card(id).get("name", ""))


static func get_card_description(id: String) -> String:
	return String(get_card(id).get("description", ""))


## Эффекты карты как есть (только чтение). Неизвестная карта → {}.
static func get_effects(id: String) -> Dictionary:
	var raw: Variant = get_card(id).get("effects", {})
	return raw if typeof(raw) == TYPE_DICTIONARY else {}


## Карты категории в порядке файла. Неизвестная категория → пустой массив.
static func get_by_category(category: String) -> Array:
	var result: Array = []
	for card: Variant in get_all():
		if typeof(card) != TYPE_DICTIONARY:
			continue
		if String((card as Dictionary).get("category", "")) == category:
			result.append(card)
	return result


## Количество слотов категории из данных (`slot_rules`): weapon 2, utility 1.
## Битые данные → 0 (перки не предлагаются, но игра не падает).
static func get_slot_count(category: String) -> int:
	var rules: Variant = _data().get("slot_rules", {})
	if typeof(rules) != TYPE_DICTIONARY:
		return 0
	var raw: Variant = (rules as Dictionary).get(category)
	if not _is_number(raw):
		return 0
	return maxi(0, int(raw))


# ─── Валидатор ──────────────────────────────────────────────────────────────
## Проверка целостности данных (QA/тесты, dev-гейт M6.1). Возвращает список проблем;
## пустой массив = данные валидны. Никогда не падает и не пишет в лог.
static func validate() -> Array[String]:
	var errors: Array[String] = []
	var data := _data()
	if data.is_empty():
		errors.append("perks.json не загружен")
		return errors
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("schema_version: ожидался %d" % SCHEMA_VERSION)
	# Слоты: правила тоже данные — 2 оружия + 1 утилита по GDD.
	if get_slot_count(CATEGORY_WEAPON) <= 0:
		errors.append("slot_rules: нет положительного числа слотов weapon")
	if get_slot_count(CATEGORY_UTILITY) <= 0:
		errors.append("slot_rules: нет положительного числа слотов utility")
	if get_slot_count(CATEGORY_WEAPON) != 2 or get_slot_count(CATEGORY_UTILITY) != 1:
		errors.append("slot_rules: ожидалось 2 weapon + 1 utility, найдено %d + %d"
			% [get_slot_count(CATEGORY_WEAPON), get_slot_count(CATEGORY_UTILITY)])

	var cards := get_all()
	if cards.size() != CARD_COUNT:
		errors.append("cards: ожидалось %d карт, найдено %d" % [CARD_COUNT, cards.size()])

	var seen: Array[String] = []
	var weapon_total := 0
	var utility_total := 0
	for card: Variant in cards:
		if typeof(card) != TYPE_DICTIONARY:
			errors.append("cards: элемент не объект")
			continue
		var item: Dictionary = card
		var id := String(item.get("id", ""))
		if id.is_empty():
			errors.append("card: пустой id")
		elif seen.has(id):
			errors.append("card %s: id повторяется" % id)
		else:
			seen.append(id)
		var label := id if not id.is_empty() else "?"
		if String(item.get("name", "")).is_empty():
			errors.append("card %s: пустое name" % label)
		if String(item.get("description", "")).is_empty():
			errors.append("card %s: пустое description" % label)
		var category := String(item.get("category", ""))
		if category == CATEGORY_WEAPON:
			weapon_total += 1
		elif category == CATEGORY_UTILITY:
			utility_total += 1
		else:
			errors.append("card %s: неизвестная категория «%s»" % [label, category])
		_validate_effects(label, item.get("effects", {}), errors)

	if weapon_total != WEAPON_COUNT:
		errors.append("cards: ожидалось %d карт weapon, найдено %d"
			% [WEAPON_COUNT, weapon_total])
	if utility_total != UTILITY_COUNT:
		errors.append("cards: ожидалось %d карт utility, найдено %d"
			% [UTILITY_COUNT, utility_total])
	for required_id: String in CARD_IDS:
		if not seen.has(required_id):
			errors.append("cards: нет обязательной карты %s" % required_id)
	return errors


static func _validate_effects(label: String, raw: Variant, errors: Array[String]) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("card %s: effects не объект" % label)
		return
	var effects: Dictionary = raw
	if effects.is_empty():
		errors.append("card %s: пустые effects" % label)
	for key: Variant in effects.keys():
		var effect_key := String(key)
		if not KNOWN_EFFECTS.has(effect_key):
			errors.append("card %s: неизвестный эффект «%s»" % [label, effect_key])
			continue
		var value: Variant = effects[key]
		var kind: int = KNOWN_EFFECTS[effect_key]
		if kind == ValueKind.FLAG:
			if typeof(value) != TYPE_BOOL:
				errors.append("card %s: эффект %s должен быть bool" % [label, effect_key])
		elif not _is_number(value):
			errors.append("card %s: эффект %s должен быть числом" % [label, effect_key])


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
