# enemy_base.gd
# Purpose: Базовый класс врага: HP, группировка, прицельный огонь по игроку, гибель, реакция на бомбу.
#          Движение и тюнинг задаются наследниками (Ju 87, Fw 190, He 111).
# Dependencies: GameConfig, ArtStyle (через ShipVisual), Player (цель).
# Author: Mechanics Developer Agent
#
# КАК РАСШИРЯТЬ: новый враг = новый скрипт extends EnemyBase + своя сцена;
# переопределить _on_spawn(), _move(delta) (и при необходимости _tick_weapon/_muzzle_position),
# задать тюнинг в _init(). Базовая логика урона, стрельбы и смерти переиспользуется без изменений.
#
# ГРУППЫ (M2): обычный враг регистрируется в GameConfig.GROUP_ENEMIES, босс — ТОЛЬКО в
# GameConfig.GROUP_BOSS. LevelController.use_bomb() убивает всех обычных врагов через
# GROUP_ENEMIES; если бы босс там оказался, одна бомба убивала бы его до начисления 30 урона.

class_name EnemyBase
extends Area2D

## Враг уничтожен (убит игроком или бомбой). LevelController начисляет очки и ведёт волны.
signal died(enemy: EnemyBase)
## Враг тихо покинул уровень (уход за экран, рестарт). Без очков — только для учёта волны.
signal despawned(enemy: EnemyBase)
## Враг стреляет. LevelController маршрутизирует в BulletLayer.fire_enemy.
signal shot_fired(origin: Vector2, velocity: Vector2, damage: int)
## HP изменился (полоса HP босса, будущий juice). Значение — int для UI/сигнального контракта:
## M6.1a перевёл HP врага в float (перки дают 0.85/1.1/1.7 урона), а наружу отдаётся
## округление к ближайшему; живой враг никогда не отдаёт 0 (иначе LevelController принял бы
## несмертельный удар за смертельный и погасил hit-flash). Мёртвый — ровно 0.
signal health_changed(hp: int)
## Босс сбросил бомбу с задержкой. LevelController создаёт объект BossBomb.
## Это ЕДИНСТВЕННЫЙ эмиттер сигнала: у обычных врагов сброса бомб нет (волна 2 босса).
signal bomb_dropped(origin: Vector2)

## Хитбокс как доля ширины силуэта: враг крупнее визуально, но попадать должно быть комфортно.
const HIT_RADIUS_RATIO := 0.4
## Точка вылета пули относительно центра: под силуэтом (враги смотрят вниз), чтобы пуля не появлялась внутри корпуса.
const MUZZLE_OFFSET := Vector2(0.0, 16.0)
## Запас за краем поля, после которого враг удаляется. Должен быть БОЛЬШЕ глубины спавна волн
## (WaveManager держит спавн выше −88 px), иначе враг умирал бы в первом кадре.
const DEFAULT_DESPAWN_PADDING := 96.0

# Тюнинг по умолчанию (наследники переопределяют в _init() своими константами).
## M6.1a: HP float — перки дают дробный урон (0.85 / 1.1 / 1.7), иначе урон терялся бы
## на округлении. Целые значения из наследников (4, 8, 120) присваиваются без потерь.
var max_hp: float = 6.0
var hp: float = 6.0
var score_value: int = 100
var fire_interval: float = 1.2
var bullet_speed: float = 320.0
var bullet_damage: int = 1
var asset_key: StringName = ArtStyle.KEY_ENEMY_BF109
var face_down: bool = true

## Босс: регистрируется только в GROUP_BOSS и не умирает от одной бомбы.
var is_boss: bool = false

## Уход за экран. Босс патрулирует внутри поля и off-screen не удаляется.
var despawns_offscreen: bool = true
var despawn_padding: float = DEFAULT_DESPAWN_PADDING

## Цель для прицельных выстрелов (игрок). Ставится спавнером до add_child().
var target: Player = null
var is_active: bool = false

var _fire_timer: float = 0.0
## Группы, в которые враг реально вписан. Единая точка снятия — _unregister_groups().
var _registered_groups: Array[StringName] = []
## Последняя позиция, где центр врага был В поле. Нужна, чтобы дроп не терялся, когда
## враг уходит за край (Ju 87 в волне 4 → ремкомплект): см. get_last_visible_position().
var _last_visible_position: Vector2 = Vector2.ZERO

# ─── Сложность endless (M6.3a) ──────────────────────────────────────────────
## Множители, полученные от WaveManager на спавне (EndlessRules). В кампании остаются 1.0.
## Наследники ОБЯЗАНЫ умножать свою скорость движения на speed_mult в _move() (боссы —
## не обязаны: они патрулируют фиксированную высоту, GDD масштабирует их HP и пули).
## bullet_speed множится в apply_difficulty один раз — цельность дальнейших фаз босса
## обеспечивают сами боссы (умножают новый базис на bullet_speed_mult).
var speed_mult: float = 1.0
var bullet_speed_mult: float = 1.0
var hp_mult: float = 1.0
## apply_difficulty применён. Второй вызов игнорируется: HP/скорость не должны перемножаться
## дважды (волны endless зовут метод один раз на борт, QA/тесты могут звать повторно).
var _difficulty_applied: bool = false


func _ready() -> void:
	_register_groups()
	collision_layer = GameConfig.LAYER_ENEMY
	collision_mask = 0  # снаряды игрока сами находят врага
	_setup_hitbox()
	_setup_visual()
	hp = max_hp
	is_active = true
	_last_visible_position = global_position
	# Первый выстрел — не мгновенно на спавне, а через fire_interval (иначе пуля прилетает из-за края экрана).
	_fire_timer = fire_interval
	_on_spawn()


func _physics_process(delta: float) -> void:
	if not is_active:
		return
	_move(delta)
	_tick_weapon(delta)
	# Точка «последней видимой позиции» — до проверки ухода за экран: если враг сейчас
	# в поле, запоминаем её; если уже за краем, остаётся предыдущая.
	if not GameConfig.is_outside_playfield(global_position, 0.0):
		_last_visible_position = global_position
	# Враги, улетевшие за экран, освобождаются автоматически (Ju 87 в волне 4 так и уходит).
	if despawns_offscreen and GameConfig.is_outside_playfield(global_position, despawn_padding):
		despawn()


## Последняя позиция, в которой враг был виден в поле (снимок, не ссылка на узел).
## Используется для переноса дропа в точку, где подбор ещё можно собрать.
func get_last_visible_position() -> Vector2:
	return _last_visible_position


# ─── Сложность endless (M6.3a) ──────────────────────────────────────────────
## Применить множители бесконечного режима ОДИН раз (GDD «Бесконечный режим»): скорость
## корпуса, скорость пуль и HP. HP поднимается вместе с потолком — враг появляется уже
## усиленным, а не «долечивается» до нового максимума.
## Множители клампятся снизу (0.01): ноль/минус из формул сделали бы врага неуязвимым или
## неподвижным, а такое должно быть видно в тесте, а не в бою.
## Имена аргументов с окончанием _scale намеренно НЕ совпадают с полями (speed_mult/hp/…):
## параметр `hp` затенял бы поле `hp` и «усиление» HP терялось бы молча.
func apply_difficulty(speed_scale: float, bullet_scale: float, hp_scale: float) -> void:
	if _difficulty_applied:
		return
	_difficulty_applied = true
	speed_mult = maxf(0.01, speed_scale)
	bullet_speed_mult = maxf(0.01, bullet_scale)
	hp_mult = maxf(0.01, hp_scale)
	max_hp = max_hp * hp_mult
	hp = max_hp
	bullet_speed = bullet_speed * bullet_speed_mult


# ─── Группы и визуал ─────────────────────────────────────────────────────────
## Регистрация в группах. Переопределяемый хук: босс по умолчанию идёт только в GROUP_BOSS.
func _register_groups() -> void:
	if is_boss:
		add_to_group(GameConfig.GROUP_BOSS)
		_registered_groups.append(GameConfig.GROUP_BOSS)
		return
	add_to_group(GameConfig.GROUP_ENEMIES)
	_registered_groups.append(GameConfig.GROUP_ENEMIES)


func _unregister_groups() -> void:
	for group in _registered_groups:
		remove_from_group(group)
	_registered_groups.clear()


## QA-правка: shape в .tscn — общий сабресурс на все инстансы сцены. Без duplicate()
## radius, записанный одним врагом, «протекал» в уже существующих врагов с другим asset_key.
func _setup_hitbox() -> void:
	var shape_node := get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var shared_shape := shape_node.shape as CircleShape2D
	if shared_shape == null:
		return
	var own_shape := shared_shape.duplicate() as CircleShape2D
	own_shape.radius = ArtStyle.size_of(asset_key).x * HIT_RADIUS_RATIO
	shape_node.shape = own_shape


func _setup_visual() -> void:
	var visual := get_node_or_null(^"Visual") as ShipVisual
	if visual != null:
		visual.asset_key = asset_key
		visual.face_down = face_down


# ─── Хуки наследников ────────────────────────────────────────────────────────
## Вызывается после входа в дерево; здесь фиксируются параметры паттерна.
func _on_spawn() -> void:
	pass


## Движение за физический кадр. Переопределяется наследником.
func _move(_delta: float) -> void:
	pass


# ─── Стрельба ────────────────────────────────────────────────────────────────
func _tick_weapon(delta: float) -> void:
	# После смерти игрока враги молчат (проверяется smoke-тестом).
	if target == null or not target.is_alive:
		return
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = fire_interval
	_fire_at_target()


func _fire_at_target() -> void:
	var origin := _muzzle_position()
	var direction := target.global_position - origin
	if direction.length_squared() < 1.0:
		direction = Vector2.DOWN
	shot_fired.emit(origin, direction.normalized() * bullet_speed, bullet_damage)


## Выстрел в произвольном направлении (веера Ju 87 / Fw 190, паттерны босса).
func fire_direction(origin: Vector2, direction: Vector2, speed: float, damage: int = 1) -> void:
	var velocity := direction.normalized() * speed
	shot_fired.emit(origin, velocity, damage)


## Точка вылета пули. Переопределяется наследниками с другой геометрией (турели He 111).
func _muzzle_position() -> Vector2:
	return global_position + MUZZLE_OFFSET


# ─── Урон и смерть ───────────────────────────────────────────────────────────
## Возвращает true, если враг уничтожен. Урон float (M6.1a): 0.85 / 1.1 / 1.3 / 1.7.
## HP хранится как float, наружу (`health_changed`) уходит int — см. _hp_for_report().
func take_damage(amount: float) -> bool:
	if not is_active or amount <= 0.0:
		return false
	hp = maxf(0.0, hp - amount)
	health_changed.emit(_hp_for_report())
	if hp > 0.0:
		return false
	_die()
	return true


## HP для сигналов/UI: округление к ближайшему (3.15 → 3, 0.6 → 1). Живой враг всегда
## отдаёт ≥ 1: LevelController фильтрует `hp <= 0` как смертельный удар, и «0 при живом HP»
## погасил бы hit-flash. Мёртвый (hp = 0) — ровно 0.
func _hp_for_report() -> int:
	if hp <= 0.0:
		return 0
	return maxi(1, int(round(hp)))


## Бомба уничтожает обычных врагов мгновенно (GDD «Бомба»). Босс игнорирует этот вызов:
## его 30 урона приходят отдельно через LevelController.bomb_hit_boss().
func on_bomb_hit() -> void:
	if is_boss:
		return
	take_damage(maxf(hp, 1.0))


## Бесшумно убрать врага (рестарт уровня / уход за экран). Без очков.
func despawn() -> void:
	if is_queued_for_deletion():
		return
	is_active = false
	_unregister_groups()
	despawned.emit(self)
	queue_free()


func _die() -> void:
	if not is_active:
		return
	is_active = false
	_unregister_groups()
	died.emit(self)
	queue_free()
