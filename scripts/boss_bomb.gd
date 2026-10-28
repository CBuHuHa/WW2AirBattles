# boss_bomb.gd
# Purpose: Бомба босса «с задержкой» (GDD «Босс», фаза 2): видимый объект падает вниз, зона
#          поражения нарисована заранее (её видно всё время падения), затем короткая задержка
#          и детонация воздушной зоной. Игрок уклоняется горизонтально — зона читается заранее.
# Dependencies: GameConfig, ArtStyle, Player.
# Author: Mechanics Developer Agent
#
# ГЕОМЕТРИЯ ДЕТОНАЦИИ (QA-замечание #9): раньше взрыв всегда был на y=760, а игрок ходит до
# y=934 — нижние ~80 px были неуязвимой «слепой полосой», бомба не угрожала стоящему внизу.
# Теперь высота детонации = Y игрока В МОМЕНТ СБРОСА, зажатая в полосу поля
# [MIN_DETONATION_Y, REFERENCE_SIZE.y − PLAYFIELD_MARGIN]. Это не «смерть-зона до упора»:
# X бомбы фиксирован, поэтому сброс по-прежнему уклоняется ГОРИЗОНТАЛЬНО (радиус 92 px),
# а предупреждающий круг нарисован в будущей точке взрыва с момента сброса.

class_name BossBomb
extends Node2D

## Детонация (juice: взрыв/тряска подписываются здесь). at — центр зоны, radius — радиус.
signal detonated(at: Vector2, radius: float)

const FALL_SPEED := 300.0              # (tune) скорость падения
## (tune) Высота срабатывания, если в момент сброса нет живой цели (fallback).
const DETONATION_Y := 760.0
## (tune) Ближе к боссу бомба не взрывается: зона не должна накрывать точку сброса.
const MIN_DETONATION_Y := 240.0
const FUSE_AFTER_ARRIVAL := 0.35       # (tune) задержка после прихода в точку
const BLAST_RADIUS := 92.0             # (tune) радиус воздушной зоны урона
const WARNING_ALPHA := 0.30
const WARNING_FILL_ALPHA := 0.10
const FLASH_DURATION := 0.25

var _player: Player = null
## Точка будущей детонации (X — точка сброса, Y — полоса игрока). Считается один раз в setup().
var _blast_point: Vector2 = Vector2.ZERO
var _arrived: bool = false
var _fuse_left: float = FUSE_AFTER_ARRIVAL
var _detonated: bool = false
var _flash_left: float = 0.0


func setup(origin: Vector2, player: Player) -> void:
	# Вызывается после add_child (узел уже в дереве).
	global_position = origin
	_player = player
	_blast_point = Vector2(origin.x, _resolve_detonation_y(origin))


## Y детонации = Y игрока на момент сброса, зажатый так, чтобы зона реально накрывала
## полосу, где игрок может стоять (QA #9). Игрок мёртв/нет — историческая высота 760.
func _resolve_detonation_y(origin: Vector2) -> float:
	var max_y := GameConfig.REFERENCE_SIZE.y - GameConfig.PLAYFIELD_MARGIN
	if _player == null or not is_instance_valid(_player) or not _player.is_alive:
		return clampf(DETONATION_Y, MIN_DETONATION_Y, max_y)
	return clampf(_player.global_position.y, MIN_DETONATION_Y, max_y)


## Контракт для juice/QA: где и с каким радиусом рванёт (валидно с момента сброса).
func get_blast_point() -> Vector2:
	return _blast_point


func get_blast_radius() -> float:
	return BLAST_RADIUS


func _process(delta: float) -> void:
	if _detonated:
		_flash_left = maxf(0.0, _flash_left - delta)
		queue_redraw()
		if _flash_left <= 0.0:
			queue_free()
		return
	if not _arrived:
		position.y = minf(_blast_point.y, position.y + FALL_SPEED * delta)
		if position.y >= _blast_point.y:
			_arrived = true
	else:
		_fuse_left -= delta
		if _fuse_left <= 0.0:
			_detonate()
	queue_redraw()


func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	_flash_left = FLASH_DURATION
	# Взрыв строго в просчитанной точке (бомба долетает до неё, но позиция — источник истины).
	global_position = _blast_point
	if _player != null and is_instance_valid(_player) and _player.is_alive:
		if global_position.distance_to(_player.global_position) <= BLAST_RADIUS:
			_player.take_hit(1)
	detonated.emit(global_position, BLAST_RADIUS)


func _draw() -> void:
	if _detonated:
		var progress := 1.0 - _flash_left / FLASH_DURATION
		var radius := lerpf(BLAST_RADIUS * 0.4, BLAST_RADIUS, sqrt(progress))
		var fade := 1.0 - progress
		draw_circle(Vector2.ZERO, radius, Color(ArtStyle.DANGER, 0.28 * fade))
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, Color(ArtStyle.CREAM, 0.9 * fade), 3.0, true)
		return
	# Предупреждение о зоне поражения — в БУДУЩЕЙ точке взрыва, видно с момента сброса.
	var blast_offset := _blast_point - global_position
	draw_circle(blast_offset, BLAST_RADIUS, Color(ArtStyle.DANGER, WARNING_FILL_ALPHA))
	draw_arc(blast_offset, BLAST_RADIUS, 0.0, TAU, 48, Color(ArtStyle.DANGER, WARNING_ALPHA), 2.0, true)
	# Траектория падения: тонкий пунктир от корпуса к зоне.
	draw_line(Vector2.ZERO, blast_offset, Color(ArtStyle.DANGER, WARNING_ALPHA), 2.0)
	# Корпус бомбы: тёмный серый цилиндр с красным стабилизатором.
	draw_rect(Rect2(Vector2(-5.0, -8.0), Vector2(10.0, 16.0)), ArtStyle.ENEMY.darkened(0.2))
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(-8.0, -12.0), Vector2(8.0, -12.0), Vector2(4.0, -5.0), Vector2(-4.0, -5.0),
		]),
		ArtStyle.DANGER
	)
	draw_circle(Vector2(0.0, 7.0), 3.0, ArtStyle.DANGER)
