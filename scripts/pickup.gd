# pickup.gd
# Purpose: Подбор (ремкомплект): падает вниз с умеренной скоростью, берётся перекрытием
#          с игроком, за нижним краем исчезает. Создаётся кодом, отдельной сцены не требует.
#          Единственный вид подбора — ремкомплект: GDD «Бомба» (Changelog 2026-10-26) фиксирует
#          ровно 1 заряд бомбы на забег без пополнений, поэтому подборов бомбы нет.
#          M7c: PNG `pickup_repair` (ArtAssets) рисуется в 32×32 с фильтром nearest; если файла
#          нет — прежний код-силуэт ArtStyle.draw_pickup_icon. Зона подбора (PICKUP_RADIUS)
#          от арта не зависит.
# Dependencies: GameConfig, ArtStyle, ArtAssets, Player.
# Author: Mechanics Developer Agent (M1/M2), Technical Artist Agent (M7c: иконка из PNG)

class_name Pickup
extends Area2D

## Подбор взят игроком (kind — Kind, at — мировая точка).
signal collected(kind: int, at: Vector2)

## Виды подбора. REPAIR — единственный; бомба не выпадает и не подбирается (GDD «Бомба»).
enum Kind { REPAIR }

const FALL_SPEED := 90.0        # (tune) умеренная скорость падения
const PICKUP_RADIUS := 16.0     # (tune) зона подбора перекрытием
const DESPAWN_PADDING := 40.0
## M7c: размер отрисовки иконки. PNG `pickup_repair` 64×64 → 32×32 — ровно 1/2, поэтому
## nearest не теряет пиксели контура (при 26 px коэффициент 0.406 давал рваный чёрный контур).
## 32 = диаметр зоны подбора (PICKUP_RADIUS × 2): что видно, то и подбирается.
## Сама зона подбора не менялась.
const DRAW_SIZE := 32.0

## Вид подбора по умолчанию. Kind — единственный вид (ремкомплект).
var kind: Kind = Kind.REPAIR

## M7c: рисовать PNG, если файл есть (как ShipVisual.use_sprite_art). false — код-силуэт
## ArtStyle: фолбэк остаётся рабочим до конца арт-пасса и проверяется тестом.
@export var use_sprite_art: bool = true:
	set(value):
		use_sprite_art = value
		_refresh_texture()
		if is_inside_tree():
			queue_redraw()

var _collected: bool = false
## Текущая текстура иконки (null — рисуем код-силуэт ArtStyle).
var _texture: Texture2D = null
## Конечный ключ файла (для QA); &"" без текстуры.
var _texture_key: StringName = &""


func setup(new_kind: Kind, start_position: Vector2) -> void:
	kind = new_kind
	# Вызывается после add_child (узел уже в дереве), поэтому global_position безопасен.
	global_position = start_position


func _ready() -> void:
	# Слой 0 и маска «player»: подбор видит игрока, но сам ничего не задевает
	# (пули и враги его игнорируют).
	collision_layer = 0
	collision_mask = GameConfig.LAYER_PLAYER
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = PICKUP_RADIUS
	shape.shape = circle
	add_child(shape)
	area_entered.connect(_on_area_entered)
	# Nearest только на этом узле: иконка-пиксель-арт не размывается, HUD и шрифты
	# остаются на настройках проекта.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_refresh_texture()
	queue_redraw()


func _physics_process(delta: float) -> void:
	position.y += FALL_SPEED * delta
	if GameConfig.is_outside_playfield(global_position, DESPAWN_PADDING):
		queue_free()


func _on_area_entered(area: Area2D) -> void:
	if _collected or not (area is Player):
		return
	var player := area as Player
	if not player.is_alive:
		return
	_collected = true
	collected.emit(kind, global_position)
	queue_free()


func _draw() -> void:
	if _texture != null:
		# Светлый гаечный ключ из листа сам по себе теряется на светлом небе (проверено
		# скриншотом 540×960), поэтому под иконкой остаётся кремовая подложка прежнего
		# код-силуэта: r = DRAW_SIZE/2 = PICKUP_RADIUS, то есть ровно зона подбора.
		var backing := DRAW_SIZE * 0.5
		draw_circle(Vector2.ZERO, backing, Color(ArtStyle.CREAM, 0.85))
		draw_arc(Vector2.ZERO, backing, 0.0, TAU, 24, Color(ArtStyle.PLAYER, 0.9), 1.5, true)
		draw_texture_rect(_texture,
			Rect2(-DRAW_SIZE * 0.5, -DRAW_SIZE * 0.5, DRAW_SIZE, DRAW_SIZE), false)
		return
	ArtStyle.draw_pickup_icon(self, Vector2.ZERO)


## QA/тесты: рисуется ли сейчас текстура (а не код-силуэт ArtStyle).
func is_using_texture() -> bool:
	return _texture != null


## QA/тесты: конечный ключ загруженного PNG (&"" — текстуры нет).
func get_texture_key() -> StringName:
	return _texture_key


## Пересобрать текстуру под текущий use_sprite_art (ArtAssets кэширует, повтор бесплатен).
func _refresh_texture() -> void:
	if not use_sprite_art:
		_texture = null
		_texture_key = &""
		return
	_texture = ArtAssets.texture(ArtStyle.KEY_PICKUP_REPAIR)
	_texture_key = ArtAssets.render_key(ArtStyle.KEY_PICKUP_REPAIR) if _texture != null else &""
