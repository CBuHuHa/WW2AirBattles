# bomb_flash.gd
# Purpose: Функциональный флеш взрыва бомбы — расширяющийся круг (ТЗ M1 разрешает только это,
#          частицы/тряска/hit-stop — M4 «Game feel»). Живёт до конца анимации и сам удаляется.
# Dependencies: ArtStyle.
# Author: Mechanics Developer Agent

class_name BombFlash
extends Node2D

const DURATION := 0.45
const START_RADIUS := 28.0
const FILL_ALPHA := 0.16
const RING_ALPHA := 0.85
const RING_WIDTH := 4.0

var _target_radius: float = 620.0
var _radius: float = START_RADIUS
var _progress: float = 0.0


## center — мировая точка взрыва, target_radius — радиус, закрывающий игровое поле.
func setup(center: Vector2, target_radius: float) -> void:
	global_position = center
	_target_radius = target_radius
	_radius = START_RADIUS
	_progress = 0.0


func _process(delta: float) -> void:
	_progress = minf(1.0, _progress + delta / DURATION)
	# Быстрый старт, замедление к концу — читаемо и без «джус»-полировки.
	_radius = lerpf(START_RADIUS, _target_radius, sqrt(_progress))
	queue_redraw()
	if _progress >= 1.0:
		queue_free()


func _draw() -> void:
	var fade := 1.0 - _progress
	draw_circle(Vector2.ZERO, _radius, Color(ArtStyle.CREAM, FILL_ALPHA * fade))
	draw_arc(
		Vector2.ZERO, _radius, 0.0, TAU, 64, Color(ArtStyle.CREAM, RING_ALPHA * fade), RING_WIDTH, true
	)
