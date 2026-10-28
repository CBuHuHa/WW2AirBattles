# enemy_fw190.gd
# Purpose: Fw 190 — элита. Быстро входит в поле, затем прочёсывает экран по горизонтали,
#          стреляя широким веером из 5 пуль. С серым силуэтом и красным акцентом (ArtStyle).
# Dependencies: EnemyBase, ArtStyle, GameConfig.
# Author: Mechanics Developer Agent

class_name EnemyFw190
extends EnemyBase

# ─── Тюнинг (GDD «Волны и враги» → Fw 190) ──────────────────────────────────
const FW190_HP := 12                           # GDD: 12 HP (было 18 × 0.7 ≈ 12.6, округлено вниз)
const FW190_SCORE := 300                       # GDD: 300 очков (tune)
const FW190_SPEED := 240.0                     # GDD: 240 px/s (tune) — скорость входа и прочёса
const FW190_FIRE_INTERVAL := 1.5               # GDD: веер из 5 пуль каждые 1.5 с (tune)
const FW190_BULLET_SPEED := 300.0              # GDD: 260–420 px/s
const FW190_FAN_ANGLES := [-52.0, -26.0, 0.0, 26.0, 52.0]  # (tune) веер из 5 пуль

# ─── Патруль (tune) ─────────────────────────────────────────────────────────
const PATROL_ALTITUDE := 200.0                 # высота прочёса
const SWEEP_MARGIN := 70.0                     # не заходит за край (полуширина 22 + запас)

var patrol_altitude: float = PATROL_ALTITUDE
var _entered: bool = false
var _sweep_direction: float = 1.0


func _init() -> void:
	asset_key = ArtStyle.KEY_ENEMY_FW190
	max_hp = FW190_HP
	hp = FW190_HP
	score_value = FW190_SCORE
	fire_interval = FW190_FIRE_INTERVAL
	bullet_speed = FW190_BULLET_SPEED
	bullet_damage = 1
	face_down = true


func _on_spawn() -> void:
	_entered = position.y >= patrol_altitude
	# Прочёс идёт от того края, где враг появился, к центру.
	_sweep_direction = 1.0 if position.x <= GameConfig.REFERENCE_SIZE.x * 0.5 else -1.0


func _move(delta: float) -> void:
	if not _entered:
		position.y += FW190_SPEED * speed_mult * delta
		if position.y >= patrol_altitude:
			position.y = patrol_altitude
			_entered = true
		return
	position.x += FW190_SPEED * speed_mult * _sweep_direction * delta
	if position.x <= SWEEP_MARGIN:
		position.x = SWEEP_MARGIN
		_sweep_direction = 1.0
	elif position.x >= GameConfig.REFERENCE_SIZE.x - SWEEP_MARGIN:
		position.x = GameConfig.REFERENCE_SIZE.x - SWEEP_MARGIN
		_sweep_direction = -1.0


## Широкий веер из 5 пуль (элита закрывает сектор, а не целится в точку).
func _fire_at_target() -> void:
	var origin := _muzzle_position()
	for angle_deg: float in FW190_FAN_ANGLES:
		fire_direction(origin, Vector2.DOWN.rotated(deg_to_rad(angle_deg)), bullet_speed, bullet_damage)
