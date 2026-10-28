# pause_button.gd
# Purpose: Кнопка паузы справа сверху (GDD «Controls»). Зона тапа 48×48, touch-only.
#          PROCESS_MODE_ALWAYS: тем же тапом пауза снимается, даже когда дерево на паузе.
# Dependencies: ArtStyle (палитра, ключ ui_pause).
# Author: Mechanics Developer Agent

class_name PauseButton
extends Control

signal pause_requested

const TOUCH_SIZE := Vector2(48.0, 48.0)
## Радиус/контур согласованы с кнопкой бомбы (46 из 96 → 23 из 48): общий ритм HUD.
const CIRCLE_RADIUS := 23.0
const OUTLINE_WIDTH := 2.0


func _ready() -> void:
	custom_minimum_size = TOUCH_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	accept_event()  # тап по кнопке не начинает драг самолёта
	if touch.pressed:
		pause_requested.emit()


func _draw() -> void:
	var center := size * 0.5
	draw_circle(center, CIRCLE_RADIUS, Color(ArtStyle.ENEMY, 0.55))
	draw_arc(center, CIRCLE_RADIUS, 0.0, TAU, 32, Color(ArtStyle.CREAM, 0.9), OUTLINE_WIDTH, true)
	# Иконка «пауза» (ключ ui_pause): две вертикальные полосы.
	draw_rect(Rect2(center + Vector2(-7.0, -9.0), Vector2(4.0, 18.0)), ArtStyle.CREAM)
	draw_rect(Rect2(center + Vector2(3.0, -9.0), Vector2(4.0, 18.0)), ArtStyle.CREAM)
