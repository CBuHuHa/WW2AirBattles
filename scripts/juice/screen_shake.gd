# screen_shake.gd
# Purpose: Тряска экрана (GDD «Game feel») — случайное смещение ОДНОГО корневого узла-обёртки
#          с экспоненциальным затуханием. Без вращения, без ассетов (GDD: «без динамического зума»).
# Dependencies: нет (только Node2D, randf).
# Author: Game Feel Developer Agent
#
# ИНТЕГРАЦИЯ M4: LevelController вставляет этот узел-обёртку НАД World
# (Level → ScreenShake → World) и вызывает shake(pixels, seconds) из событий.
# Смещается только собственный position обёртки ПОСЛЕ add_child — global_position
# не читается и не пишется, поэтому QA-замечание про «global_position до add_child» не задето.
# Трясутся одновременно игрок, враги, пули и взрывы — но НЕ HUD (он в CanvasLayer).

class_name ScreenShake
extends Node2D

# ─── Дефолтные пары из GDD «Game feel» (все значения (tune)) ─────────────────
## (tune) GDD «Game feel»: 4 px / 0.15 с — попадание по игроку.
const SHAKE_PLAYER_HIT := Vector2(4.0, 0.15)
## (tune) GDD «Game feel»: 6 px / 0.25 с — взрыв бомбы.
const SHAKE_BOMB := Vector2(6.0, 0.25)
## (tune) GDD «Game feel»: 8 px / 0.4 с — смерть босса He 111.
const SHAKE_BOSS_DEATH := Vector2(8.0, 0.4)

## Экспоненциальный спад: за duration амплитуда падает в e^DECAY_EXP раз (≈0.7% от пика).
const DECAY_EXP := 5.0
## Ниже этой амплитуды тряску считаем оконченной (порог «не дрожать вхолостую»).
const STOP_THRESHOLD_PX := 0.25

var _origin := Vector2.ZERO
var _amplitude := 0.0
var _time_left := 0.0
var _decay_rate := 0.0


func _ready() -> void:
	# Кэшируем локальную точку покоя. Обёртка живёт в (0,0); position здесь же и смещается —
	# только локальные координаты, никаких зависимостей от порядка add_child.
	_origin = position


## Тряска: pixels — пиковая амплитуда, seconds — длительность.
## Защита от наложения: новая тряска НЕ обрывает текущую — амплитуда и время
## берутся как максимум из текущих и запрошенных (простое правило, без очередей).
func shake(pixels: float, seconds: float) -> void:
	if pixels <= 0.0 or seconds <= 0.0:
		return
	_amplitude = maxf(_amplitude, pixels)
	_time_left = maxf(_time_left, seconds)
	_decay_rate = DECAY_EXP / _time_left


## Досрочная остановка (рестарт уровня) с гарантированным возвратом в покой.
func stop() -> void:
	_time_left = 0.0
	_amplitude = 0.0
	position = _origin


func is_shaking() -> bool:
	return _time_left > 0.0


func _process(delta: float) -> void:
	if _time_left <= 0.0:
		return
	_time_left -= delta
	# Экспоненциальное затухание; per-frame exp() даёт frame-rate-независимый результат.
	_amplitude = maxf(_amplitude * exp(-_decay_rate * delta), 0.0)
	var offset := Vector2(
		randf_range(-_amplitude, _amplitude),
		randf_range(-_amplitude, _amplitude)
	)
	position = _origin + offset
	if _time_left <= 0.0 or _amplitude < STOP_THRESHOLD_PX:
		stop()
