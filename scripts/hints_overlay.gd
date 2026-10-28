# hints_overlay.gd
# Purpose: Обучающие подсказки первого забега (GDD «First 30 seconds», п.2):
#          «Веди пальцем», «Стрельба автоматическая», «Бомба — справа снизу».
#          Появляются после старта: 0 с / 1.2 с / 2.4 с, каждая держится 2.5 с и плавно гаснет.
#          Показываются ТОЛЬКО в первом забеге за запуск приложения (флаг в LevelController).
#          Анимация — свой таймлайн в _process: на паузе узел PAUSABLE не обрабатывается,
#          поэтому таймеры и плавное исчезновение замирают вместе с миром.
# Dependencies: scenes/hints_overlay.tscn (три плашки Hint1..Hint3 с Label Text).
# Author: Mechanics Developer Agent

class_name HintsOverlay
extends Control

## Задержка появления каждой подсказки от старта забега (с).
const HINT_DELAYS: Array[float] = [0.0, 1.2, 2.4]
## (tune) сколько подсказка держится на полной альфе после появления.
const HOLD_TIME := 2.5
const FADE_IN_TIME := 0.18
const FADE_OUT_TIME := 0.35
## Порог «плашка больше не читается». Ниже него плашка гасится целиком (visible=false),
## иначе после fade-out остаётся полупрозрачный «призрак» до alpha 0.001 (QA M3-B).
const GHOST_ALPHA_THRESHOLD := 0.05

@onready var _plates: Array[Control] = [
	$Hint1 as Control, $Hint2 as Control, $Hint3 as Control
]

var _active: bool = false
var _elapsed: float = 0.0


func _ready() -> void:
	# PAUSABLE: наследование дало бы ALWAYS от LevelController, и таймеры шли бы на паузе.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide_hints()


## Запустить показ с нуля (старт первого забега). Повторный вызов перезапускает таймлайн.
func show_hints() -> void:
	_elapsed = 0.0
	_active = true
	visible = true
	for plate in _plates:
		plate.modulate.a = 0.0
		plate.visible = false


## Немедленно скрыть и остановить таймлайн (исход забега / рестарт / брифинг).
func hide_hints() -> void:
	_active = false
	_elapsed = 0.0
	visible = false
	for plate in _plates:
		plate.modulate.a = 0.0
		plate.visible = false


## Идёт ли ещё показ (QA/тесты: проверить, что в первом забеге подсказки запущены).
func is_showing() -> bool:
	return _active


## Таймлайн подсказок. delta масштабируется Engine.time_scale (hit-stop): это ожидаемо —
## hit-stop длится 2–3 кадра, подсказки не должны «перескакивать» через него.
func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	var all_done := true
	for i in _plates.size():
		var plate := _plates[i]
		var alpha := _alpha_at(_elapsed - HINT_DELAYS[i])
		plate.modulate.a = alpha
		# alpha < 0.05 — плашка уже не читается: скрываем сразу, чтобы не оставался
		# полупрозрачный «призрак» на время хвоста fade-out. Тайминги/таймлайн не меняются.
		plate.visible = alpha >= GHOST_ALPHA_THRESHOLD
		if alpha > 0.0 or _elapsed < HINT_DELAYS[i]:
			all_done = false
	if all_done:
		_active = false
		visible = false


## Альфа плашки в момент t от её собственного появления: 0 → fade-in → hold → fade-out → 0.
static func _alpha_at(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t < FADE_IN_TIME:
		return t / FADE_IN_TIME
	var hold_end := FADE_IN_TIME + HOLD_TIME
	if t < hold_end:
		return 1.0
	var left := hold_end + FADE_OUT_TIME - t
	if left <= 0.0:
		return 0.0
	return clampf(left / FADE_OUT_TIME, 0.0, 1.0)
