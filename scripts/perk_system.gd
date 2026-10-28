# perk_system.gd
# Purpose: Слоты временных перков M6.1 (GDD «Временные перки»): 2 оружия + 1 утилита, без дублей.
#          Хранит активные карты, проверяет правила слотов, выдаёт предложения «1 из 2» без
#          повторов и пересчитывает оружие игрока через `Player.apply_perks()`.
#          UI выбора карт, пауза и триггер после волн — M6.1b: PerkSystem их не знает,
#          он только отвечает на вопросы «что можно взять» и «что сейчас активно».
# Dependencies: PerkData (данные карт), Player (apply_perks).
# Author: Mechanics Developer Agent

class_name PerkSystem
extends Node

## Активные карты изменились (взята карта / reset). Аргумент — снимок Array[String].
signal changed(active: Array)

## GDD «Временные перки»: 2 карты оружия + 1 утилита. Значения совпадают с data/perks.json
## (`slot_rules`), но продублированы как страховка: система обязана работать и на битых данных.
const WEAPON_SLOTS := 2
const UTILITY_SLOTS := 1

## Активные id в порядке взятия (стабильный порядок нужен UI и тестам).
var _active: Array[String] = []
## Общий ГПСЧ для roll_offers(null): тесты передают свой с фиксированным seed.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


# ─── Слоты ──────────────────────────────────────────────────────────────────
## Взять карту. false — неизвестный id, дубль или занятый слот категории (состояние не меняется).
func take(id: String) -> bool:
	if id.is_empty() or not PerkData.has_card(id):
		return false
	if _active.has(id):
		return false
	var category := PerkData.get_category(id)
	if not _can_take_category(category):
		return false
	_active.append(id)
	changed.emit(get_active())
	return true


func _can_take_category(category: String) -> bool:
	match category:
		PerkData.CATEGORY_WEAPON:
			return _count_category(category) < WEAPON_SLOTS
		PerkData.CATEGORY_UTILITY:
			return _count_category(category) < UTILITY_SLOTS
		_:
			return false


func _count_category(category: String) -> int:
	var total := 0
	for id in _active:
		if PerkData.get_category(id) == category:
			total += 1
	return total


## Снимок активных карт (копия — внешний код не может испортить состояние системы).
func get_active() -> Array[String]:
	return _active.duplicate()


func get_active_by_category(category: String) -> Array[String]:
	var result: Array[String] = []
	for id in _active:
		if PerkData.get_category(id) == category:
			result.append(id)
	return result


func has(id: String) -> bool:
	return _active.has(id)


func is_category_full(category: String) -> bool:
	return not _can_take_category(category)


## Карты, которые ещё можно взять: не активны и слот их категории свободен.
## Порядок — как в data/perks.json (детерминированный для UI и тестов).
func available_cards() -> Array[String]:
	var result: Array[String] = []
	for id in PerkData.get_ids():
		if _active.has(id):
			continue
		if not _can_take_category(PerkData.get_category(id)):
			continue
		result.append(id)
	return result


# ─── Предложение «1 из 2» (M6.1b вызывает после волн 2/3/4) ─────────────────
## Случайные до `count` карт из доступных, без дублей. Если доступна одна — вернётся одна,
## если ни одной — пустой массив. `rng` нужен тестам: без него используется общий ГПСЧ.
func roll_offers(count := 2, rng: RandomNumberGenerator = null) -> Array[String]:
	var result: Array[String] = []
	var wanted := maxi(0, count)
	if wanted == 0:
		return result
	var pool := available_cards()
	if pool.is_empty():
		return result
	var source := rng if rng != null else _rng
	# Перемешивание Fisher–Yates на копии: Array.shuffle() использует глобальный ГПСЧ,
	# а тестам нужен воспроизводимый результат по seed.
	for index in range(pool.size() - 1, 0, -1):
		var swap_index := source.randi_range(0, index)
		var swap := pool[index]
		pool[index] = pool[swap_index]
		pool[swap_index] = swap
	for index in mini(wanted, pool.size()):
		result.append(pool[index])
	return result


# ─── Применение к игроку ────────────────────────────────────────────────────
## Пересчитать оружие/защиту игрока по активным картам (единственный путь к Player.apply_perks).
func apply_to(player: Player) -> void:
	if player == null:
		return
	player.apply_perks(get_active())


## Сброс на старте миссии/забега (GDD: «Перки сбрасываются в начале каждой миссии»).
func reset() -> void:
	_active.clear()
	changed.emit(get_active())
