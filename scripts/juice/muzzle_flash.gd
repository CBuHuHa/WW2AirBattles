# muzzle_flash.gd
# Purpose: Вспышка выстрела (GDD «Game feel»: «Вспышки выстрелов»; цвет — палитра GDD
#          «Art direction»). ОДИН переиспользуемый узел на стрелка/борт: у игрока (8 выстр./с),
#          у каждого врага и ОДИН общий у босса (турели). Никаких аллокаций на выстрел:
#          только trigger_at() + переиспользуемый полигон, кэшированный в setup().
# Dependencies: ArtStyle (палитра).
# Author: Game Feel Developer Agent
#
# ОДИН УЗЕЛ НА БОРТ — ПОЧЕМУ: выстрелы идут пачками (веер Ju 87 — 3 пули из одной точки,
# очередь босса — 2 турели в ОДНОМ кадре). Узел один, а trigger_at() усредняет позиции,
# пришедшие в одном кадре: общая вспышка босса вспыхивает ПОСЕРЕДИНЕ между турелями и не
# дёргается. На Android это минимум узлов и ноль созданий Node в hot-path (GDD — 60 FPS).

class_name MuzzleFlash
extends Node2D

## (tune) Длительность вспышки: короче интервала автострельбы игрока (0.125 с — GDD «Игрок»,
## 8 выстрелов/с), поэтому серия выстрелов не накапливает несколько вспышек на одном узле.
const DURATION := 0.06
## 4 луча = 8 вершин звезды (флэт-вектор, без текстур).
const RAYS := 4
## (tune) Внутренний радиус луча относительно внешнего.
const INNER_RATIO := 0.38
## (tune) Сжатие звезды к концу жизни — вспышка «схлопывается», а не просто гаснет.
const END_SCALE := 0.45

## Кэш полигона: пересоздаётся ТОЛЬКО в setup(), _draw() ничего не аллоцирует.
var _points: PackedVector2Array = PackedVector2Array()
var _size: float = 8.0
var _color: Color = ArtStyle.BULLET_ENEMY

var _life_left: float = 0.0
## Усреднение позиций за ТЕКУЩИЙ кадр (см. шапку файла).
var _last_frame: int = -1
var _frame_origin_sum := Vector2.ZERO
var _frame_shots: int = 0


## size — внешний радиус вспышки в px (tune); color — палитра GDD: игрок — кремовый
## (его белые трассеры), враги/босс — #FFD166 (цвет их пуль).
func setup(size: float, color: Color) -> void:
	_size = maxf(size, 1.0)
	_color = color
	_points = _build_star(_size)
	_life_left = 0.0
	visible = false
	set_process(false)


## local_pos — точка вылета в ЛОКАЛЬНЫХ координатах узла-владельца (child стрелка).
## Повтор в том же кадре усредняется (турели босса), позиции разных кадров не смешиваются.
func trigger_at(local_pos: Vector2) -> void:
	if _points.is_empty():
		return
	var frame := int(Engine.get_process_frames())
	if frame == _last_frame and _frame_shots > 0:
		_frame_origin_sum += local_pos
		_frame_shots += 1
	else:
		_frame_origin_sum = local_pos
		_frame_shots = 1
		_last_frame = frame
	position = _frame_origin_sum / float(_frame_shots)
	_life_left = DURATION
	visible = true
	set_process(true)
	queue_redraw()


## Для тестов/QA: горит ли вспышка прямо сейчас.
func is_flashing() -> bool:
	return _life_left > 0.0


func _process(delta: float) -> void:
	_life_left -= delta
	if _life_left <= 0.0:
		_life_left = 0.0
		visible = false
		set_process(false)
		return
	queue_redraw()


## Рисунок без аллокаций: полигон кэширован, transform задаётся через draw_set_transform.
func _draw() -> void:
	if _points.is_empty():
		return
	var progress := clampf(1.0 - _life_left / DURATION, 0.0, 1.0)
	var scale := lerpf(1.0, END_SCALE, progress)
	var alpha := 1.0 - progress
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * scale)
	draw_colored_polygon(_points, Color(_color, alpha))
	# Раскалённое ядро дула — кремово-белая точка в центре звезды.
	draw_circle(Vector2.ZERO, _size * 0.3, Color(1.0, 1.0, 1.0, alpha * 0.9))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Звезда из RAYS лучей: внешние/внутренние вершины через один.
func _build_star(radius: float) -> PackedVector2Array:
	var vertices := RAYS * 2
	var points := PackedVector2Array()
	points.resize(vertices)
	for i in vertices:
		var angle := TAU * float(i) / float(vertices) - PI * 0.5
		var r := radius if i % 2 == 0 else radius * INNER_RATIO
		points[i] = Vector2(cos(angle), sin(angle)) * r
	return points
