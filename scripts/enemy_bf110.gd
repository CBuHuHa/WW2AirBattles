# enemy_bf110.gd
# Purpose: Bf 110 (M5.2) — «толстый» двухмоторный тяжёлый истребитель миссии 3. Спускается до
#          высоты патруля и ходит горизонтальной синусоидой (как Bf 109), стреляя «двойной
#          прицельной очередью»: на каждый цикл огня по одному прицельному выстрелу из каждой
#          точки крыла (±16 px по X, +16 по Y) с интервалом 0.12 с. Из Bf 110 выпадает
#          ремкомплект миссии 3 — это правило WaveManager, здесь ничего про дроп не нужно.
# Dependencies: EnemyBase, GameConfig, ArtStyle.
# Author: Mechanics Developer Agent

class_name EnemyBf110
extends EnemyBase

# ─── Тюнинг (GDD «Враги» → Bf 110) ───────────────────────────────────────────
const BF110_HP := 16                           # GDD: 16 HP
const BF110_SCORE := 400                       # GDD: 400 очков
const BF110_SPEED := 150.0                     # GDD: 150 px/s — скорость сближения
const BF110_FIRE_INTERVAL := 2.0               # GDD: двойная прицельная очередь каждые 2 с
const BF110_BULLET_SPEED := 320.0              # GDD: 260–420 px/s
const BF110_BULLET_DAMAGE := 1                 # GDD: попадание = 1 урон

# ─── Патруль (M5.2, как у Bf 109) ───────────────────────────────────────────
const PATROL_ALTITUDE := 230.0                 # высота горизонтального патруля
const PATROL_AMPLITUDE := 120.0                # амплитуда синусоиды
const PATROL_ANGULAR_SPEED := 0.7              # рад/с, период ≈ 9 с
const PATROL_X_MARGIN := 90.0                  # клэмп центра патруля при спавне

# ─── Двойная прицельная очередь ─────────────────────────────────────────────
## Точки вылета: две мотогондолы на крыле. Y — под силуэтом (нос вниз), чтобы пуля
## не появлялась внутри корпуса (как EnemyBase.MUZZLE_OFFSET.y).
const WING_OFFSET := Vector2(16.0, 16.0)
const WING_SIDES := [-1.0, 1.0]
const BURST_SHOTS := 2                         # два снаряда в цикле: левое и правое крыло
const BURST_INTERVAL := 0.12                   # интервал между выстрелами очереди

enum Phase { DESCEND, PATROL }

var _phase: Phase = Phase.DESCEND
var _patrol_center_x: float = GameConfig.REFERENCE_SIZE.x * 0.5
var _patrol_time: float = 0.0

# Патруль как переменные: волны/тесты могут задать свои значения, поведение по умолчанию
# совпадает с константами (тот же приём, что у Bf 109).
var patrol_altitude: float = PATROL_ALTITUDE
var patrol_amplitude: float = PATROL_AMPLITUDE
var patrol_angular_speed: float = PATROL_ANGULAR_SPEED

## Состояние очереди: сколько выстрелов осталось, через сколько и с какого крыла.
var _burst_shots_left: int = 0
var _burst_timer: float = 0.0
var _burst_side_index: int = 0


func _init() -> void:
	asset_key = ArtStyle.KEY_ENEMY_BF110
	max_hp = BF110_HP
	hp = BF110_HP
	score_value = BF110_SCORE
	fire_interval = BF110_FIRE_INTERVAL
	bullet_speed = BF110_BULLET_SPEED
	bullet_damage = BF110_BULLET_DAMAGE
	face_down = true


func _on_spawn() -> void:
	_patrol_time = 0.0
	_phase = Phase.DESCEND
	_burst_shots_left = 0
	_burst_timer = 0.0
	_burst_side_index = 0
	_patrol_center_x = clampf(
		position.x,
		PATROL_X_MARGIN,
		GameConfig.REFERENCE_SIZE.x - PATROL_X_MARGIN
	)
	# Амплитуда подрезается под коридор: силуэт 64 px целиком в поле, патруль не выезжает
	# за край (та же защита, что у Bf 109, но с учётом собственной полуширины).
	patrol_amplitude = minf(
		patrol_amplitude,
		maxf(0.0, minf(_patrol_center_x - _corridor_min(), _corridor_max() - _patrol_center_x))
	)


## Коридор горизонтального патруля: полоса, где силуэт полностью в поле.
## PLAYFIELD_MARGIN (26) — общий минимум; Bf 110 шире (полуширина 32), поэтому берём
## большее из двух, иначе крыло обрезалось бы о край экрана.
func _corridor_min() -> float:
	return maxf(GameConfig.PLAYFIELD_MARGIN, ArtStyle.size_of(asset_key).x * 0.5)


func _corridor_max() -> float:
	return GameConfig.REFERENCE_SIZE.x - _corridor_min()


func _move(delta: float) -> void:
	match _phase:
		Phase.DESCEND:
			position.y += BF110_SPEED * speed_mult * delta
			if position.y >= patrol_altitude:
				position.y = patrol_altitude
				_phase = Phase.PATROL
				_patrol_time = 0.0
		Phase.PATROL:
			_patrol_time += delta
			# Хард-кламп результата: даже если амплитуду поменяли в рантайме, борт остаётся
			# целиком в поле и добиваемым (как у Bf 109).
			position.x = clampf(
				_patrol_center_x + sin(_patrol_time * patrol_angular_speed) * patrol_amplitude,
				_corridor_min(),
				_corridor_max()
			)
			position.y = patrol_altitude


# ─── Стрельба: двойная прицельная очередь ───────────────────────────────────
## Свой график вместо базового одиночного выстрела: цикл fire_interval запускает очередь из
## BURST_SHOTS прицельных выстрелов (по одному с каждого крыла) с BURST_INTERVAL между ними.
func _tick_weapon(delta: float) -> void:
	# После смерти игрока враги молчат (контракт EnemyBase).
	if target == null or not target.is_alive:
		return
	if _burst_shots_left > 0:
		_burst_timer -= delta
		if _burst_timer <= 0.0:
			_fire_wing_shot()
			_burst_shots_left -= 1
			_burst_timer = BURST_INTERVAL
		return
	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = fire_interval
	_burst_side_index = 0
	_fire_wing_shot()
	_burst_shots_left = BURST_SHOTS - 1
	_burst_timer = BURST_INTERVAL


## Базовый хук EnemyBase (_fire_at_target) оставлен рабочим: одиночный выстрел с левого крыла.
func _fire_at_target() -> void:
	_burst_side_index = 0
	_fire_wing_shot()


## Прицельный выстрел из текущей точки крыла в позицию игрока. Прицел пересчитывается на
## каждый снаряд очереди — стоящего на месте очередь догоняет.
func _fire_wing_shot() -> void:
	if target == null or not target.is_alive:
		return
	var side: float = WING_SIDES[_burst_side_index % WING_SIDES.size()]
	var origin := global_position + Vector2(WING_OFFSET.x * side, WING_OFFSET.y)
	var direction := target.global_position - origin
	if direction.length_squared() < 1.0:
		direction = Vector2.DOWN
	fire_direction(origin, direction, bullet_speed, bullet_damage)
	_burst_side_index = (_burst_side_index + 1) % WING_SIDES.size()
