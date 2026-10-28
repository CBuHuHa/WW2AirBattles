# wave_manager.gd
# Purpose: Менеджер волн M5.1. Состав волн, босс и правило ремкомплекта больше НЕ хардкодятся
#          здесь, а читаются из `data/missions.json` через MissionData по id миссии
#          (GDD «Реализация v1» → «Данные миссии»). Правило завершения волны прежнее —
#          уничтожены ИЛИ покинули поле ВСЕ враги этой волны (у Ju 87 это штатный уход за
#          нижний край). Между волнами короткая пауза.
#          Спавн держится в границах поля по X (с GameConfig.PLAYFIELD_MARGIN, силуэт целиком
#          на экране) и выше EnemyBase.despawn_padding (−96 px) по Y, иначе враг удалится
#          в первом кадре (QA-замечание).
#          Правило ремкомплекта (GDD «Волны и враги», «Challenge and progression») полностью
#          принадлежит ЭТОМУ узлу: ровно один подбор создаётся в момент удаления последнего
#          ЖИВОГО «толстого» врага волны `repair_wave` — тип врага и номер волны приходят
#          из данных миссии (см. _try_drop_repair). Флага на враге и дропа из
#          LevelController больше нет.
#          Миссия 1 (m1_airfield): 6 волн и He 111 (M5.3c — волны 1–5 по-прежнему 1:1 с прежним
#          хардкодом, волна 6 добавлена по GDD «Волны миссий»).
#          Данные могут ссылаться на сцену, которой ещё нет (новый тип до реализации):
#          такой entry пропускается с push_warning один раз, узел не падает.
#
# ─── БЕСКОНЕЧНЫЙ РЕЖИМ (M6.3a) ─────────────────────────────────────────────
# Режим задаётся set_mode()/start_endless() ДО start(): Mode.MISSION читает волны миссии из
# MissionData (поведение M1–M6.2b не менялось), Mode.ENDLESS ГЕНЕРИРУЕТ волны из EndlessRules.
# В endless нет фиксированного списка волн (`_waves` пуст, get_wave_count() = 0):
#   * номер волны n = _wave_index + 1, состав и координаты — get_endless_wave_plan(n);
#   * после закрытия волны, номер которой кратен 10, идёт БОСС (EndlessRules.is_boss_wave),
#     тип — по кругу (He 111 → Ju 88 → Fw 200), HP ×(1 + 0.15 × круг);
#   * гибель босса НЕ завершает забег: LevelController зовёт continue_after_boss(), и режим
#     продолжает со следующей волны (all_waves_cleared в endless не эмитится вовсе);
#   * ремкомплект — на каждой 5-й волне из последнего живого «толстого» (Ju 87 / Bf 110),
#     ровно один за волну: _repair_dropped сбрасывается на КАЖДОЙ новой волне endless;
#   * сложность спавна — EndlessRules.enemy_speed_mult / bullet_speed_mult / hp_mult через
#     EnemyBase.apply_difficulty (для босса скорость не масштабируется, HP и пули — да).
# Dependencies: LevelController (host.spawn_enemy / host.spawn_pickup), MissionData, EndlessRules,
#               EnemyBase, сцены врагов.
# Author: Mechanics Developer Agent

class_name WaveManager
extends Node

## Режим менеджера волн: кампания (данные миссии) или бесконечный (генератор M6.3a).
enum Mode { MISSION, ENDLESS }

signal wave_started(index: int, count: int)
signal wave_cleared(index: int)
signal boss_spawned(boss: EnemyBase)
## Эмитится ТОЛЬКО в MISSION (босс миссии уничтожен = уровень пройден). В endless забег
## не заканчивается гибелью босса, поэтому сигнал не приходит (см. continue_after_boss).
signal all_waves_cleared()

# ─── Тюнинг (tune) ───────────────────────────────────────────────────────────
const WAVE_BREAK_DELAY := 1.2        # пауза между волнами
const BOSS_DELAY := 1.5              # пауза перед боссом

## Совместимость: smoke-тест и QA читают WAVE_COUNT как «волн в миссии 1» (M5.3c: 6).
## Внутри узла длина берётся из данных (_waves.size()): у всех трёх миссий волн шесть.
const WAVE_COUNT := 6

## Волна миссии 1, из которой выпадает единственный ремкомплект уровня (GDD «Волны и враги»).
## Оставлено для совместимости smoke-теста; рантайм берёт число из данных миссии.
const REPAIR_WAVE_INDEX := 3

const DEFAULT_MISSION_ID := "m1_airfield"

## Полоса спавна endless по X: силуэт любого врага целиком в поле (540 px) с запасом,
## как в GDD «Волны миссий» (80…460 — колонны миссии 1). Внутри полосы точки распределяются
## равномерно по количеству бортов волны (см. get_endless_wave_plan).
const ENDLESS_X_MIN := 80.0
const ENDLESS_X_MAX := 460.0
## «Толстые» враги endless, из которых падает ремкомплект (GDD «Бесконечный режим»:
## «из последнего элитного врага каждые 5 волн»). Ju 87 — с 5-й волны, Bf 110 — с 15-й.
const ENDLESS_REPAIR_TYPES: Array[String] = ["ju87", "bf110"]

## Сцены миссии 1 — публичные константы для тестов/QA (smoke сравнивает entry["scene"]).
## Реальные сцены берутся через MissionData.scene_for_type().
const BF109_SCENE: PackedScene = preload("res://scenes/enemy_bf109.tscn")
const JU87_SCENE: PackedScene = preload("res://scenes/enemy_ju87.tscn")
const FW190_SCENE: PackedScene = preload("res://scenes/enemy_fw190.tscn")
const BOSS_SCENE: PackedScene = preload("res://scenes/boss_he111.tscn")

## Глубина спавна: все значения выше −96 px (иначе сработает авто-деспавн EnemyBase).
## Значения дублируют MissionData.DEPTH_* — тесты сверяют форму волны 2 по этим константам.
const SPAWN_DEPTH := -70.0
const SPAWN_DEPTH_BACK := -88.0
const SPAWN_DEPTH_MID := -34.0
const SPAWN_DEPTH_LEAD := -46.0
const SPAWN_DEPTH_V := -64.0
const BOSS_SPAWN_POSITION := Vector2(270.0, -70.0)

## Хост — LevelController. Не типизируем жёстко, чтобы не плодить циклические ссылки классов.
var host: Node = null

## Id текущей миссии. Меняется ТОЛЬКО set_mission() до start()/start_at_wave().
var mission_id: String = DEFAULT_MISSION_ID

## Текущий режим (M6.3a). Меняется через set_mode()/start_endless() до start().
var _mode: Mode = Mode.MISSION
## Номер волны endless (1-based) = _wave_index + 1. В MISSION не используется.
var _boss_cycle: int = 0
## Следующий шаг endless — босс (волна N была кратна 10), а не обычная волна.
var _pending_boss: bool = false

var _wave_index: int = -1
var _active: bool = false
var _alive: Array[EnemyBase] = []
var _break_left: float = -1.0
var _pending_step: int = -1
var _boss: EnemyBase = null
## Волны текущей миссии в формате MissionData.get_wave_table():
## [{scene: PackedScene|null, position: Vector2}, ...]. Обновляется в _refresh_waves().
var _waves: Array = []
## Волна ремкомплекта и типы «толстых» врагов текущей миссии (из данных).
var _repair_wave: int = -1
var _repair_types: Array[String] = []
## Ремкомплект уровня уже создан. Сбрасывается в start()/start_at_wave(): второй подбор
## за забег невозможен (GDD «Challenge and progression»: один ремкомплект за уровень).
var _repair_dropped: bool = false
## Один push_warning на класс проблемы: битые данные не должны заливать лог каждый кадр.
var _warned: Dictionary = {}


func _ready() -> void:
	_refresh_waves()


# ─── Таблица волн (GDD «Волны и враги») ─────────────────────────────────────
## Состав волн миссии 1 в прежнем формате [{scene, position}, ...].
## Данные и координаты — в `data/missions.json` (m1_airfield: волны 1–5 — точная копия прежнего
## хардкода, волна 6 добавлена в M5.3c по GDD «Волны миссий»).
## X каждой точки — внутри полосы, где силуэт целиком в поле с учётом GameConfig.PLAYFIELD_MARGIN
## (Ju 87 48 px → 50…490, Fw 190 44 px → 48…492, Bf 109 40 px → 46…494): иначе борт вроде
## прежнего Ju 87 на x = 600 улетал бы вниз за правым краем, стреляя из-за экрана.
## Y строго > −EnemyBase.DEFAULT_DESPAWN_PADDING (−96 px), иначе авто-деспавн в первом кадре.
## Флагов дропа в таблице НЕТ: подборов бомбы не существует (GDD «Бомба»: 1 заряд на забег,
## пополнений нет), а ремкомплект — рантайм-правило (см. _try_drop_repair).
static func wave_table() -> Array:
	return MissionData.get_wave_table(DEFAULT_MISSION_ID)


# ─── Миссия ─────────────────────────────────────────────────────────────────
## Выбрать миссию ДО start()/start_at_wave(). Смена на ходу не перезапускает волну:
## данные перечитаются при следующем старте.
func set_mission(id: String) -> void:
	mission_id = id if not id.is_empty() else DEFAULT_MISSION_ID
	_refresh_waves()


func get_mission_id() -> String:
	return mission_id


# ─── Режим (M6.3a) ──────────────────────────────────────────────────────────
## Переключить режим. Зовётся ДО start()/start_endless(): активный забег не перезапускается,
## но и не продолжается в новом режиме — LevelController всегда останавливает волны сам.
## MISSION заново подхватывает волны миссии (endless их не использует).
func set_mode(mode: Mode) -> void:
	_mode = mode
	if _mode == Mode.MISSION:
		_refresh_waves()
	else:
		_waves = []
		_pending_boss = false


func get_mode() -> Mode:
	return _mode


func is_endless() -> bool:
	return _mode == Mode.ENDLESS


## Старт бесконечного забега: режим + волна 1 из генератора.
func start_endless() -> void:
	set_mode(Mode.ENDLESS)
	start()


## Подхватить волны/ремкомплект выбранной миссии из MissionData. Вызывается на _ready()
## (host уже назначен к этому моменту), в start(), start_at_wave() и set_mission().
func _refresh_waves() -> void:
	_waves = MissionData.get_wave_table(mission_id)
	_repair_wave = MissionData.get_repair_wave(mission_id)
	_repair_types = MissionData.get_repair_types(mission_id)
	if _waves.is_empty():
		_warn_once("empty_waves", "MissionData: у миссии «%s» нет волн" % mission_id)


# ─── Жизненный цикл ─────────────────────────────────────────────────────────
func start() -> void:
	_active = true
	_wave_index = -1
	_alive.clear()
	_break_left = -1.0
	_pending_step = -1
	_pending_boss = false
	_boss = null
	_boss_cycle = 0
	_repair_dropped = false
	_warned.clear()
	if _mode == Mode.ENDLESS:
		_spawn_endless_wave(0)
		return
	_refresh_waves()
	_spawn_wave(0)


## Остановить прогресс (смерть игрока, победа, рестарт). Сами враги удаляются LevelController.
func stop() -> void:
	_active = false
	_alive.clear()
	_break_left = -1.0
	_pending_step = -1
	_pending_boss = false


func _process(delta: float) -> void:
	if not _active or _break_left < 0.0:
		return
	_break_left -= delta
	if _break_left > 0.0:
		return
	_break_left = -1.0
	# Endless: следующая волна генерируется, верхней границы нет; после волны, кратной 10,
	# шаг — босс (флаг выставляет _on_wave_cleared).
	if _mode == Mode.ENDLESS:
		var step := _pending_step
		_pending_step = -1
		if _pending_boss:
			_pending_boss = false
			_spawn_endless_boss(step)
		elif step >= 0:
			_spawn_endless_wave(step)
		return
	if _pending_step >= 0 and _pending_step < _waves.size():
		_spawn_wave(_pending_step)
	elif _pending_step >= _waves.size():
		_spawn_boss()


# ─── Волны ──────────────────────────────────────────────────────────────────
func _spawn_wave(index: int) -> void:
	_wave_index = index
	_alive.clear()
	# Волны нет в данных (пустая/битая миссия): не падаем и не зацикливаемся —
	# прогресс останавливается, в лог уходит одна строка.
	if index < 0 or index >= _waves.size():
		_warn_once("wave_%d" % index, "WaveManager: волна %d отсутствует (миссия «%s»)"
			% [index, mission_id])
		_pending_step = -1
		_break_left = -1.0
		return
	var entries: Array = _waves[index]
	for entry: Dictionary in entries:
		var enemy := _spawn_entry(entry)
		if enemy != null:
			_alive.append(enemy)
	wave_started.emit(index, _alive.size())
	if _alive.is_empty():
		_on_wave_cleared(index)


# ─── Генератор endless (M6.3a) ──────────────────────────────────────────────
## План волны `wave_number`: [{type, depth, position}, ...] — ровно то, что спавнится.
## Публичный: тест/QA проверяет состав и полосу X без запуска уровня (сцена не нужна).
## X распределяется равномерно по полосе 80…460 (шаг = 380 / (count−1)), один борт — центр.
## Глубина чередуется default/back по чётности слота: волна «дышит» по высоте, как в данных
## миссий, и обе глубины безопасны для авто-деспавна (> −96 px).
func get_endless_wave_plan(wave_number: int) -> Array:
	var count := EndlessRules.enemy_count(wave_number)
	var plan: Array = []
	for slot in count:
		var depth := "back" if slot % 2 == 1 else "default"
		plan.append({
			"type": EndlessRules.enemy_type_for(wave_number, slot),
			"depth": depth,
			"position": Vector2(_endless_x(slot, count), MissionData.depth_y(depth)),
		})
	return plan


## X слота в полосе endless. Первый борт — ENDLESS_X_MIN, последний — ENDLESS_X_MAX
## (симметрично относительно центра поля 270); один борт в волне — по центру.
func _endless_x(slot: int, count: int) -> float:
	if count <= 1:
		return (ENDLESS_X_MIN + ENDLESS_X_MAX) * 0.5
	var step := (ENDLESS_X_MAX - ENDLESS_X_MIN) / float(count - 1)
	return ENDLESS_X_MIN + step * float(slot)


## Волна endless по индексу (0-based). Номер волны = index + 1. Сложность волны считается
## ОДИН раз и применяется к каждому борту (EndlessRules: скорость, пули, HP).
func _spawn_endless_wave(index: int) -> void:
	_wave_index = maxi(0, index)
	var number := _wave_index + 1
	_alive.clear()
	_pending_step = -1
	_pending_boss = false
	_break_left = -1.0
	# GDD «Бесконечный режим»: ремкомплект — каждые 5 волн, ровно один за волну.
	_repair_dropped = false
	var speed_mult := EndlessRules.enemy_speed_mult(number)
	var bullet_mult := EndlessRules.bullet_speed_mult(number)
	var hp_mult := EndlessRules.hp_mult(number)
	for item: Dictionary in get_endless_wave_plan(number):
		var enemy := _spawn_entry({
			"scene": MissionData.scene_for_type(String(item.get("type", ""))),
			"position": item.get("position", Vector2.ZERO),
		}, speed_mult, bullet_mult, hp_mult)
		if enemy != null:
			_alive.append(enemy)
	wave_started.emit(_wave_index, _alive.size())
	# Пустая волна (все сцены не резолвятся) не должна вешать режим: закрываем и идём дальше.
	if _alive.is_empty():
		_on_wave_cleared(_wave_index)


## Босс endless: тип по кругу (cycle 0 → He 111 на волне 10), HP ×(1 + 0.15 × cycle),
## скорость пуль — по номеру волны (EndlessRules.bullet_speed_mult), скорость корпуса
## не масштабируется. all_waves_cleared НЕ эмитится: забег продолжается.
func _spawn_endless_boss(wave_index: int) -> void:
	_wave_index = maxi(0, wave_index)
	var number := _wave_index + 1
	_pending_step = -1
	_pending_boss = false
	_break_left = -1.0
	_boss_cycle = maxi(0, number / EndlessRules.BOSS_WAVE_STEP - 1)
	var boss_type := EndlessRules.boss_type(_boss_cycle)
	var boss_scene := MissionData.scene_for_type(boss_type)
	if boss_scene == null:
		_warn_once("endless_boss_%s" % boss_type,
			"WaveManager: нет сцены босса «%s» (endless, волна %d)" % [boss_type, number])
		# Без босса волна не может закрыться — продолжаем следующей (узел не виснет).
		_pending_step = _wave_index + 1
		_break_left = BOSS_DELAY
		return
	if host == null or not host.has_method(&"spawn_enemy"):
		return
	_boss = host.spawn_enemy(boss_scene, BOSS_SPAWN_POSITION)
	if _boss == null:
		return
	_boss.apply_difficulty(1.0, EndlessRules.bullet_speed_mult(number),
		EndlessRules.boss_hp_mult(_boss_cycle))
	boss_spawned.emit(_boss)


## Босс endless сбит: LevelController начислил очки и зовёт этот метод. Забег НЕ
## заканчивается — следующая волна встаёт в брейк (GDD «Бесконечный режим»).
## wave_cleared(index) эмитится здесь же: волна с боссом считается пройденной, поэтому
## бонус за волну и правило перков/множителя счёта работают как у обычной волны.
func continue_after_boss() -> void:
	if not _active or _mode != Mode.ENDLESS:
		return
	_boss = null
	_pending_boss = false
	_pending_step = _wave_index + 1
	_break_left = BOSS_DELAY
	wave_cleared.emit(_wave_index)


func _spawn_entry(
	entry: Dictionary, speed_mult: float = 1.0, bullet_mult: float = 1.0, hp_mult: float = 1.0
) -> EnemyBase:
	if host == null or not host.has_method(&"spawn_enemy"):
		return null
	var scene: PackedScene = entry.get("scene") as PackedScene
	# Сцены нет (неизвестный тип/новый враг до реализации): entry пропускается, волна живёт
	# остальными бортами. Один push_warning на тип — не на каждый спавн.
	if scene == null:
		# Ключ один на всю миссию: список отсутствующих сцен не должен повторяться в логе.
		_warn_once("scene_null",
			"WaveManager: нет сцены для entry %s (миссия «%s»)" % [entry, mission_id])
		return null
	var enemy: EnemyBase = host.spawn_enemy(
		scene,
		entry.get("position", Vector2.ZERO) as Vector2
	)
	if enemy == null:
		return null
	# M6.3a: сложность endless применяется ДО подписок — враг уже в дереве (_ready отработал,
	# hp = max_hp), поэтому apply_difficulty поднимает и потолок, и текущее HP.
	if _mode == Mode.ENDLESS:
		enemy.apply_difficulty(speed_mult, bullet_mult, hp_mult)
	enemy.died.connect(_on_enemy_died_in_wave)
	enemy.despawned.connect(_on_enemy_despawned_in_wave)
	return enemy


func _on_enemy_died_in_wave(enemy: EnemyBase) -> void:
	_on_enemy_removed(enemy, false)


func _on_enemy_despawned_in_wave(enemy: EnemyBase) -> void:
	_on_enemy_removed(enemy, true)


## Единая точка удаления врага из волны. despawned == true — враг ушёл за нижний край
## (despawn), false — сбит (died). Очки начисляет LevelController только на died; ремкомплект
## же не должен теряться ни при одном из исходов, поэтому его решает WaveManager здесь.
func _on_enemy_removed(enemy: EnemyBase, despawned: bool) -> void:
	if not _active:
		return
	_alive.erase(enemy)
	if _is_repair_wave_active() and _is_repair_target(enemy):
		_try_drop_repair(enemy, despawned)
	if _alive.is_empty() and _break_left < 0.0:
		_on_wave_cleared(_wave_index)


## Волна ремкомплекта: MISSION — номер из данных миссии, ENDLESS — каждая 5-я волна.
func _is_repair_wave_active() -> bool:
	if _mode == Mode.ENDLESS:
		return EndlessRules.is_repair_wave(_wave_index + 1)
	return _wave_index == _repair_wave


## Враг этой волны — «толстый» (Ju 87 / Bf 110 по данным миссии)? Тип сравнивается
## строками: enemy_ju87 → "ju87", чтобы новые враги (M5.2) подключались без правок здесь.
## В endless «толстыми» считаются Ju 87 и Bf 110 (GDD «Бесконечный режим»: элитный враг).
func _is_repair_target(enemy: EnemyBase) -> bool:
	var type := MissionData.type_for_asset_key(enemy.asset_key)
	if _mode == Mode.ENDLESS:
		return ENDLESS_REPAIR_TYPES.has(type)
	return _repair_types.has(type)


## GDD «Волны и враги»: ремкомплект выпадает из ПОСЛЕДНЕГО «толстого» врага волны
## repair_wave — ровно один за уровень (GDD «Challenge and progression»). «Живой» = is_active:
## _die()/despawn() снимают флаг ДО эмита сигнала, поэтому гибнущий борт сам себя уже не считает.
##  * удалён НЕ последний живой → дропа нет (лечение не «переезжает» на другого борта);
##  * удалён последний и сбит → подбор в точке гибели (global_position);
##  * удалён последний и ушёл за нижний край → подбор в последней ВИДИМОЙ точке
##    (get_last_visible_position): сырая точка деспавна уже за экраном и недостижима.
## Точка клампится в поле: борт может погибнуть от бомбы за верхней границей.
## _repair_dropped исключает повторный дроп (stop()/рестарт не создают подбор вовсе: они
## снимают _active, а _on_enemy_removed выходит по гварду).
func _try_drop_repair(removed: EnemyBase, despawned: bool) -> void:
	if _repair_dropped or _living_repair_target_count() > 0:
		return
	if host == null or not host.has_method(&"spawn_pickup"):
		return
	_repair_dropped = true
	var at := removed.get_last_visible_position() if despawned else removed.global_position
	host.spawn_pickup(Pickup.Kind.REPAIR, GameConfig.clamp_to_playfield(at))


## Сколько «толстых» врагов волны ещё живо. is_active снимается в EnemyBase._die()/despawn()
## ДО сигнала, поэтому удалённый борт в счёт не входит.
func _living_repair_target_count() -> int:
	var total := 0
	for enemy in _alive:
		if is_instance_valid(enemy) and enemy.is_active and _is_repair_target(enemy):
			total += 1
	return total


func _on_wave_cleared(index: int) -> void:
	if not _active:
		return
	# Endless: волн конечного списка нет. Волна, номер которой кратен 10, ведёт к боссу
	# (шаг = босс), остальные — к следующей сгенерированной волне. Бонус/перки начисляет
	# LevelController по сигналу wave_cleared, как и в кампании.
	if _mode == Mode.ENDLESS:
		_pending_boss = EndlessRules.is_boss_wave(index + 1)
		_pending_step = index if _pending_boss else index + 1
		_break_left = BOSS_DELAY if _pending_boss else WAVE_BREAK_DELAY
		wave_cleared.emit(index)
		return
	_pending_step = index + 1
	_break_left = BOSS_DELAY if index + 1 >= _waves.size() else WAVE_BREAK_DELAY
	wave_cleared.emit(index)


# ─── Босс ───────────────────────────────────────────────────────────────────
## Босс миссии — по строке `boss` из данных (he111/ju88/fw200). Сцены ju88 и fw200
## появятся позже: до тех пор босс просто не спавнится (с одним push_warning), узел жив.
func _spawn_boss() -> void:
	_pending_step = -1
	_break_left = -1.0
	_wave_index = _waves.size()
	if host == null or not host.has_method(&"spawn_enemy"):
		return
	var boss_type := MissionData.get_boss_type(mission_id)
	var boss_scene := MissionData.scene_for_type(boss_type)
	if boss_scene == null:
		_warn_once("boss_%s" % boss_type,
			"WaveManager: нет сцены босса «%s» (миссия «%s»)" % [boss_type, mission_id])
		return
	_boss = host.spawn_enemy(boss_scene, BOSS_SPAWN_POSITION)
	if _boss == null:
		return
	boss_spawned.emit(_boss)
	all_waves_cleared.emit()


# ─── Доступ для тестов/QA ───────────────────────────────────────────────────
## QA/smoke: запустить конкретную волну, не проходя предыдущие (проверка правил волны 4).
## M6.3a: в endless индекс 0-based тоже работает (start_at_wave(9) → волна 10 + босс после
## неё), верхней границы нет — волны генерируются.
func start_at_wave(index: int) -> void:
	_active = true
	_wave_index = -1
	_alive.clear()
	_break_left = -1.0
	_pending_step = -1
	_pending_boss = false
	_boss = null
	_boss_cycle = 0
	_repair_dropped = false
	_warned.clear()
	if _mode == Mode.ENDLESS:
		_spawn_endless_wave(maxi(0, index))
		return
	_refresh_waves()
	if _waves.is_empty():
		_warn_once("empty_waves", "WaveManager: у миссии «%s» нет волн" % mission_id)
		return
	_spawn_wave(clampi(index, 0, _waves.size() - 1))


func get_wave_index() -> int:
	return _wave_index


## Номер волны (1-based): _wave_index + 1. В endless — номер сгенерированной волны
## (волна 10 = волна перед первым боссом), в миссии — позиция волны в уровне + 1.
func get_wave_number() -> int:
	return _wave_index + 1


## Круг босса endless (0 — первый босс, волна 10). В MISSION не используется (всегда 0).
func get_boss_cycle() -> int:
	return _boss_cycle


## Сколько волн у текущей миссии (QA: у всех трёх миссий — шесть).
## В endless фиксированного списка нет — 0.
func get_wave_count() -> int:
	return _waves.size()


func is_active() -> bool:
	return _active


func get_alive_count() -> int:
	return _alive.size()


func get_boss() -> EnemyBase:
	return _boss


## push_warning ровно один раз на ключ проблемы: битые данные не заливают лог.
func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
