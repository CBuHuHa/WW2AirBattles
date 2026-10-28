# hit_stop.gd
# Purpose: Hit-stop 2–3 кадра (GDD «Game feel»: при попадании по игроку и смене фазы босса).
#          Реализация: Engine.time_scale = 0 на frames кадров, восстановление по РЕАЛЬНОМУ
#          времени (Time.get_ticks_msec), которое не зависит от time_scale.
# Dependencies: нет.
# Author: Game Feel Developer Agent
#
# ПОЧЕМУ time_scale, А НЕ get_tree().paused (выбор для Android):
# 1) get_tree().paused останавливает дерево целиком и требует PROCESS_MODE у КАЖДОГО узла
#    уровня; пропущенный узел «протекает» сквозь hit-stop. Семантика паузы при этом смешивается
#    с будущим меню паузы (GDD «Controls»: кнопка паузы) — пауза игрока и hit-stop станут одним
#    состоянием, что ломает UX.
# 2) Engine.time_scale uniformно обнуляет delta у всех узлов (включая физику) без смены
#    process_mode и без конфликтов с паузой; рендер продолжается — кадр не «замирает» картинку,
#    а мир реально стоит. Это один Setter — надёжнее и дешевле на Android.
# 3) Восстановление привязано к реальным мс, поэтому hit-stop не «повисает», даже если
#    time_scale = 0 остановил все таймеры и твины. Узел живёт в PROCESS_MODE_ALWAYS.

class_name HitStop
extends Node

## Дизайнерский FPS (база GDD 540×960 → 60): 1 кадр = 1/60 с ≈ 16.7 мс.
const DESIGN_FPS := 60.0
## Заморозка: ноль дельты у всех; рендер и ввод продолжаются.
const FREEZE_TIME_SCALE := 0.0

var _frozen: bool = false
var _end_at_msec: int = 0
var _previous_time_scale: float = 1.0


func _ready() -> void:
	# Работает и во время паузы игрока, и при time_scale = 0.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Заморозить мир на frames кадров (GDD: 2–3 кадра).
## Защита от наложения: пока мир заморожен, повторный freeze только продлевает
## заморозку (максимум из оставшегося и нового) — двойное нажатие не удваивает и не сбрасывает.
func freeze(frames: int) -> void:
	if frames <= 0:
		return
	var msec := int(round(frames / DESIGN_FPS * 1000.0))
	if msec <= 0:
		return
	if _frozen:
		_end_at_msec = maxi(_end_at_msec, Time.get_ticks_msec() + msec)
		return
	_previous_time_scale = Engine.time_scale
	_frozen = true
	Engine.time_scale = FREEZE_TIME_SCALE
	_end_at_msec = Time.get_ticks_msec() + msec


func is_frozen() -> bool:
	return _frozen


func _process(_delta: float) -> void:
	# delta = 0 при заморозке — опираемся на реальные миллисекунды.
	if _frozen and Time.get_ticks_msec() >= _end_at_msec:
		_restore()


func _restore() -> void:
	if not _frozen:
		return
	_frozen = false
	# Возвращаем прошлое значение, только если time_scale всё ещё наша заморозка:
	# чужое вмешательство (другая juice-система) не затираем.
	if is_equal_approx(Engine.time_scale, FREEZE_TIME_SCALE):
		Engine.time_scale = _previous_time_scale


func _exit_tree() -> void:
	# Узел выходит из дерева (рестарт уровня, смена сцены) — время обязано вернуться,
	# иначе игра навсегда останется в 0×.
	_restore()
