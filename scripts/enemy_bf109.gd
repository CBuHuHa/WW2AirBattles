# enemy_bf109.gd
# Purpose: Bf 109 — первый враг и мишень вехи M1. Спускается до высоты патруля и ходит
#          горизонтальной синусоидой, стреляя одиночными прицельными пулями.
# Dependencies: EnemyBase, GameConfig, ArtStyle.
# Author: Mechanics Developer Agent

class_name EnemyBf109
extends EnemyBase

# ─── Тюнинг (GDD «Волны и враги» → Bf 109) ───────────────────────────────────
const BF109_HP := 4                            # GDD: 4 HP (было 6 × 0.7 ≈ 4.2)
const BF109_SCORE := 100                       # GDD: 100 очков (tune)
const BF109_SPEED := 180.0                     # GDD: 180 px/s (tune) — скорость сближения
const BF109_FIRE_INTERVAL := 1.2               # GDD: одиночный прицельный выстрел каждые 1.2 с (tune)
const BF109_BULLET_SPEED := 320.0              # (tune) GDD: 260–420 px/s
const BF109_BULLET_DAMAGE := 1                 # GDD: попадание = 1 урон

# ─── Паттерн мишени M1 (ТЗ M1) ───────────────────────────────────────────────
const PATROL_ALTITUDE := 220.0                 # ТЗ M1: спуститься к y ≈ 220
const PATROL_AMPLITUDE := 150.0                # ТЗ M1: патрулирование синусоидой по горизонтали
const PATROL_ANGULAR_SPEED := 0.85             # (tune) рад/с, период ≈ 7.4 с
const PATROL_X_MARGIN := 90.0                  # клэмп центра патруля при спавне

enum Phase { DESCEND, PATROL }

# QA-замечание #10: синусоида с центром у края (волна 2: x = 120 и 420) уезжала в
# x ≈ −30…600. Такой враг не деспавнился (спасал только padding 96 px), но и не добивался
# с экрана: пара волны 2 оставалась «вечно живой». Теперь амплитуда подрезается под коридор
# И результат дополнительно клампится — борт всегда целиком в поле.

var _phase: Phase = Phase.DESCEND
var _patrol_center_x: float = GameConfig.REFERENCE_SIZE.x * 0.5
var _patrol_time: float = 0.0

# Тюнинг патруля как переменные: волны и smoke-тест задают свои значения,
# поведение по умолчанию совпадает с константами M1.
var patrol_altitude: float = PATROL_ALTITUDE
var patrol_amplitude: float = PATROL_AMPLITUDE
var patrol_angular_speed: float = PATROL_ANGULAR_SPEED


func _init() -> void:
	asset_key = ArtStyle.KEY_ENEMY_BF109
	max_hp = BF109_HP
	hp = BF109_HP
	score_value = BF109_SCORE
	fire_interval = BF109_FIRE_INTERVAL
	bullet_speed = BF109_BULLET_SPEED
	bullet_damage = BF109_BULLET_DAMAGE
	face_down = true


func _on_spawn() -> void:
	_patrol_time = 0.0
	_phase = Phase.DESCEND
	# Центр синусоиды — точка спавна, поджатая к экрану.
	_patrol_center_x = clampf(
		position.x,
		PATROL_X_MARGIN,
		GameConfig.REFERENCE_SIZE.x - PATROL_X_MARGIN
	)
	# Амплитуда подрезается под коридор: патруль не выезжает за игровое поле.
	patrol_amplitude = minf(
		patrol_amplitude,
		maxf(0.0, minf(_patrol_center_x - _corridor_min(), _corridor_max() - _patrol_center_x))
	)


## Коридор горизонтального патруля = полоса, где силуэт полностью в поле.
func _corridor_min() -> float:
	return GameConfig.PLAYFIELD_MARGIN


func _corridor_max() -> float:
	return GameConfig.REFERENCE_SIZE.x - GameConfig.PLAYFIELD_MARGIN


func _move(delta: float) -> void:
	match _phase:
		Phase.DESCEND:
			position.y += BF109_SPEED * speed_mult * delta
			if position.y >= patrol_altitude:
				position.y = patrol_altitude
				_phase = Phase.PATROL
				_patrol_time = 0.0
		Phase.PATROL:
			_patrol_time += delta
			# Хард-кламп результата: даже если амплитуду поменяли в рантайме (волны/тесты),
			# Bf 109 не уходит за край и остаётся добиваемым.
			position.x = clampf(
				_patrol_center_x + sin(_patrol_time * patrol_angular_speed) * patrol_amplitude,
				_corridor_min(),
				_corridor_max()
			)
			position.y = patrol_altitude
