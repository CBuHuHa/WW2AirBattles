# bullet.gd
# Purpose: Снаряд (игрока или вражеский): полёт, очистка за экраном, попадание в цель.
#          Один класс на оба типа — различаются слоями столкновений, цветом и уроном.
#          M6.1a: урон float (перки дают 0.85 / 1.1 / 2.0), плюс модификаторы перка —
#          boss_damage_mult («Тяжёлый калибр»), splash_radius/splash_ratio («Осколочные»)
#          и is_rocket («РС-82», отдельная векторная отрисовка).
#          M6.2a: hit_radius — радиус CollisionShape2D (GDD «Самолёты (ангар)»: пуля Ла-5/Як-3
#          4 px, Аэрокобра 6 px; вражеские пули остаются 5 px). Shape дублируется, иначе
#          радиус «протекал» бы в другие снаряды общего сабресурса scenes/bullet.tscn.
# Dependencies: GameConfig, ArtStyle, Player, EnemyBase.
# Author: Mechanics Developer Agent

class_name Bullet
extends Area2D

enum Kind { PLAYER, ENEMY }

## Запас за экраном, после которого снаряд освобождается.
const OFFSCREEN_PADDING := 48.0
## Радиус по умолчанию (вражеские пули и прежние вызовы без параметра): 5 px.
const DEFAULT_HIT_RADIUS := 5.0

var kind: Kind = Kind.PLAYER
var damage: float = 1.0
var velocity: Vector2 = Vector2.ZERO
## M6.2a: радиус хитбокса снаряда (CollisionShape2D.radius).
var hit_radius: float = DEFAULT_HIT_RADIUS
## «Тяжёлый калибр»: множитель урона ТОЛЬКО по боссу (обычные враги — чистый damage).
var boss_damage_mult: float = 1.0
## «Осколочные»: 0 — осколков нет. Иначе splash_ratio урона всем обычным врагам в радиусе.
var splash_radius: float = 0.0
var splash_ratio: float = 0.0
## «РС-82»: ракета — тот же Bullet, но со своей отрисовкой и полным уроном в радиусе.
var is_rocket: bool = false

var _alive: bool = false


func _ready() -> void:
	area_entered.connect(_on_area_entered)


## Инициализация до/после add_child(). Задаёт слои: кто кого ищет.
## Параметры перков/самолёта необязательны: вызовы M1–M5 (3–8 аргументов) работают как раньше.
## hit_radius — радиус хитбокса снаряда (M6.2a); <= 0 → DEFAULT_HIT_RADIUS.
func setup(
	new_kind: Kind,
	origin: Vector2,
	new_velocity: Vector2,
	new_damage: float,
	new_boss_damage_mult: float = 1.0,
	new_splash_radius: float = 0.0,
	new_splash_ratio: float = 0.0,
	new_is_rocket: bool = false,
	new_hit_radius: float = DEFAULT_HIT_RADIUS
) -> void:
	kind = new_kind
	damage = new_damage
	velocity = new_velocity
	boss_damage_mult = new_boss_damage_mult
	splash_radius = new_splash_radius
	splash_ratio = new_splash_ratio
	is_rocket = new_is_rocket
	hit_radius = new_hit_radius if new_hit_radius > 0.0 else DEFAULT_HIT_RADIUS
	global_position = origin
	if kind == Kind.PLAYER:
		collision_layer = GameConfig.LAYER_PLAYER_BULLET
		collision_mask = GameConfig.LAYER_ENEMY
	else:
		collision_layer = GameConfig.LAYER_ENEMY_BULLET
		collision_mask = GameConfig.LAYER_PLAYER
	_setup_hitbox()
	_alive = true
	queue_redraw()


## Радиус попадания на CollisionShape2D. Shape в bullet.tscn — общий сабресурс: пишем только
## в duplicate(), иначе радиус пули одного типа менялся бы у всех снарядов (та же ловушка,
## что в Player._setup_hitbox). Дублируем один раз на снаряд — пули создаются на выстрел.
func _setup_hitbox() -> void:
	var shape_node := get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var shared := shape_node.shape as CircleShape2D
	if shared == null:
		return
	if is_equal_approx(shared.radius, hit_radius):
		return
	var own := shared.duplicate() as CircleShape2D
	own.radius = hit_radius
	shape_node.shape = own


func _physics_process(delta: float) -> void:
	if not _alive:
		return
	global_position += velocity * delta
	if GameConfig.is_outside_playfield(global_position, OFFSCREEN_PADDING):
		despawn()


func _on_area_entered(area: Area2D) -> void:
	if not _alive:
		return
	if kind == Kind.PLAYER:
		var enemy := area as EnemyBase
		if enemy != null:
			# Полный урон цели; по боссу — с множителем «Тяжёлого калибра».
			var dealt := damage
			if enemy.is_boss:
				dealt *= boss_damage_mult
			# Позиция запоминается ДО урона: узел врага освобождается в этом же кадре.
			var at := global_position
			enemy.take_damage(dealt)
			if splash_radius > 0.0 and splash_ratio > 0.0:
				_apply_splash(enemy, at)
			despawn()
		return
	var player := area as Player
	if player != null and player.take_hit(int(damage)):
		# Если игрок был неуязвим, take_hit() вернул false — пуля летит дальше.
		despawn()


## Осколки: splash_ratio урона всем ОБЫЧНЫМ врагам в радиусе, кроме цели (ей уже пришёл
## полный урон). Босс получает только прямой урон: он в GROUP_BOSS, а не в GROUP_ENEMIES,
## поэтому дублирования нет.
func _apply_splash(primary: EnemyBase, center: Vector2) -> void:
	var splash_damage := damage * splash_ratio
	if splash_damage <= 0.0:
		return
	for node in get_tree().get_nodes_in_group(GameConfig.GROUP_ENEMIES):
		var enemy := node as EnemyBase
		if enemy == null or enemy == primary or not enemy.is_active:
			continue
		if enemy.global_position.distance_to(center) <= splash_radius:
			enemy.take_damage(splash_damage)


## Мгновенно убрать снаряд (бомба, рестарт, попадание).
func despawn() -> void:
	if not _alive:
		return
	_alive = false
	set_deferred(&"monitoring", false)
	queue_free()


func _draw() -> void:
	if is_rocket:
		ArtStyle.draw_rocket(self)
		return
	ArtStyle.draw_bullet(self, kind == Kind.ENEMY)
