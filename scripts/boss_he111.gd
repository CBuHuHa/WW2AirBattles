# boss_he111.gd
# Purpose: Босс He 111 — 120 HP, горизонтальный прочёс в верхней части экрана, две фазы.
#          Фаза 1: ПРИЦЕЛЬНЫЕ ОЧЕРЕДИ из двух турелей (2–3 снаряда с интервалом 0.1–0.15 с)
#          + боковой веер. Фаза 2 (порог 60 HP, переход односторонний): скорость пуль +30%,
#          радиальный залп каждые 2 с, сброс бомб с задержкой (объект BossBomb создаёт
#          LevelController). Новых врагов НЕ призывает (GDD «Босс»). Наследник EnemyBase
#          с флагом is_boss: бомба не убивает его мгновенно, 30 урона приходят через
#          LevelController.bomb_hit_boss().
# Dependencies: EnemyBase, ArtStyle, GameConfig.
# Author: Mechanics Developer Agent

class_name BossHe111
extends EnemyBase

## Смена фазы (juice/UI подписываются здесь).
signal phase_changed(phase: int)

# ─── Тюнинг (GDD «Босс» / «Волны и враги») ───────────────────────────────────
const BOSS_HP := 120                           # GDD: 120 HP (tune)
const BOSS_SCORE := 2000                       # GDD: 2000 очков (tune)
const PHASE_2_HP_THRESHOLD := 60               # GDD: фаза 2 с 50% HP (tune), переход односторонний

const ENTRY_SPEED := 140.0                     # (tune) вход в поле сверху
const ALTITUDE := 170.0                        # (tune) высота прочёса «в верхней части экрана»
const SWEEP_SPEED := 90.0                      # (tune) горизонтальный прочёс
const SWEEP_MARGIN := 110.0                    # полуширина 80 + запас, чтобы не срезать крылья

const PHASE1_AIMED_INTERVAL := 2.2             # (tune) цикл прицельных очередей из турелей
## GDD «Босс»: «прицельные ОЧЕРЕДИ» — 3 снаряда из каждой турели с интервалом 0.12 с.
const AIMED_BURST_SHOTS := 3                   # (tune) снарядов в очереди (GDD: 2–3)
const AIMED_BURST_INTERVAL := 0.12             # (tune) интервал внутри очереди (GDD: 0.10–0.15)
const PHASE1_FAN_INTERVAL := 3.0               # (tune) боковой веер
const PHASE1_BULLET_SPEED := 300.0             # GDD: 260–420 px/s
const PHASE1_FAN_ANGLES := [-55.0, -30.0, 0.0, 30.0, 55.0]  # (tune) вниз и по диагоналям
const TURRET_OFFSET := Vector2(48.0, 20.0)     # точки вылета двух турелей
## Стороны турелей: const, чтобы залп не аллоцировал литерал массива на каждый выстрел.
const TURRET_SIDES := [-1.0, 1.0]

const PHASE2_SPEED_MULT := 1.3                 # GDD: в фазе 2 скорость пуль +30% (tune)
const PHASE2_RADIAL_INTERVAL := 2.0            # GDD: радиальные залпы каждые 2 с
const PHASE2_RADIAL_COUNT := 12                # (tune) лучей в залпе
const PHASE2_BOMB_INTERVAL := 3.5              # GDD: бомбы с задержкой (tune)
const BOMB_MUZZLE_OFFSET := Vector2(0.0, 40.0)

var phase: int = 1
var _entered: bool = false
var _sweep_direction: float = 1.0
var _aimed_timer: float = 0.0
var _fan_timer: float = 0.0
var _radial_timer: float = 0.0
var _bomb_timer: float = 0.0
## Состояние очереди: сколько снарядов ещё выйдет и через сколько.
var _burst_shots_left: int = 0
var _burst_timer: float = 0.0


func _init() -> void:
	asset_key = ArtStyle.KEY_BOSS_HE111
	is_boss = true                 # регистрируется только в GROUP_BOSS
	despawns_offscreen = false     # босс патрулирует внутри поля
	max_hp = BOSS_HP
	hp = BOSS_HP
	score_value = BOSS_SCORE
	fire_interval = PHASE1_AIMED_INTERVAL
	bullet_speed = PHASE1_BULLET_SPEED
	bullet_damage = 1
	face_down = true


func _on_spawn() -> void:
	phase = 1
	_entered = false
	_sweep_direction = 1.0
	_aimed_timer = PHASE1_AIMED_INTERVAL
	_fan_timer = PHASE1_FAN_INTERVAL * 0.5
	_radial_timer = PHASE2_RADIAL_INTERVAL
	_bomb_timer = PHASE2_BOMB_INTERVAL
	_burst_shots_left = 0
	_burst_timer = 0.0


func _move(delta: float) -> void:
	if not _entered:
		position.y += ENTRY_SPEED * delta
		if position.y >= ALTITUDE:
			position.y = ALTITUDE
			_entered = true
		return
	position.x += SWEEP_SPEED * _sweep_direction * delta
	if position.x <= SWEEP_MARGIN:
		position.x = SWEEP_MARGIN
		_sweep_direction = 1.0
	elif position.x >= GameConfig.REFERENCE_SIZE.x - SWEEP_MARGIN:
		position.x = GameConfig.REFERENCE_SIZE.x - SWEEP_MARGIN
		_sweep_direction = -1.0


## Собственный график стрельбы вместо базового одиночного выстрела.
func _tick_weapon(delta: float) -> void:
	if target == null or not target.is_alive or not _entered:
		return
	if phase == 1:
		_tick_aimed_burst(delta)
		_fan_timer -= delta
		if _fan_timer <= 0.0:
			_fan_timer = PHASE1_FAN_INTERVAL
			_fire_side_fan()
		return
	_radial_timer -= delta
	if _radial_timer <= 0.0:
		_radial_timer = PHASE2_RADIAL_INTERVAL
		_fire_radial_volley()
	_bomb_timer -= delta
	if _bomb_timer <= 0.0:
		_bomb_timer = PHASE2_BOMB_INTERVAL
		bomb_dropped.emit(global_position + BOMB_MUZZLE_OFFSET)


## Очередь из турелей (GDD «Босс»: «прицельные очереди»): цикл PHASE1_AIMED_INTERVAL
## запускает серию из AIMED_BURST_SHOTS залпов, внутри серии — AIMED_BURST_INTERVAL.
func _tick_aimed_burst(delta: float) -> void:
	if _burst_shots_left > 0:
		_burst_timer -= delta
		if _burst_timer <= 0.0:
			_fire_aimed_shot()
			_burst_shots_left -= 1
			_burst_timer = AIMED_BURST_INTERVAL
		return
	_aimed_timer -= delta
	if _aimed_timer <= 0.0:
		_aimed_timer = PHASE1_AIMED_INTERVAL
		_fire_aimed_shot()
		_burst_shots_left = AIMED_BURST_SHOTS - 1
		_burst_timer = AIMED_BURST_INTERVAL


# ─── Фаза 1 ──────────────────────────────────────────────────────────────────
## Один залп прицельной очереди: по снаряду из каждой турели в ТЕКУЩУЮ позицию игрока.
## Прицел пересчитывается на каждый снаряд серии — стоящего на месте очередь догоняет.
func _fire_aimed_shot() -> void:
	if target == null or not target.is_alive:
		return
	var origin_center := global_position + Vector2(0.0, TURRET_OFFSET.y)
	for side: float in TURRET_SIDES:
		var origin := origin_center + Vector2(TURRET_OFFSET.x * side, 0.0)
		var direction := target.global_position - origin
		if direction.length_squared() < 1.0:
			direction = Vector2.DOWN
		fire_direction(origin, direction, bullet_speed, bullet_damage)


## Боковой веер: 5 снарядов из центра корпуса вниз и в стороны.
func _fire_side_fan() -> void:
	var origin := global_position + Vector2(0.0, 28.0)
	for angle_deg: float in PHASE1_FAN_ANGLES:
		fire_direction(origin, Vector2.DOWN.rotated(deg_to_rad(angle_deg)), bullet_speed, bullet_damage)


# ─── Фаза 2 ──────────────────────────────────────────────────────────────────
## Радиальный залп: 12 снарядов по кругу (GDD «радиальные залпы каждые 2 с»).
func _fire_radial_volley() -> void:
	var origin := global_position
	for i in PHASE2_RADIAL_COUNT:
		var angle := TAU * float(i) / float(PHASE2_RADIAL_COUNT)
		fire_direction(origin, Vector2.DOWN.rotated(angle), bullet_speed, bullet_damage)


# ─── Урон и фаза ─────────────────────────────────────────────────────────────
func take_damage(amount: float) -> bool:
	var destroyed := super.take_damage(amount)
	# Переход только сверху вниз (1 → 2) на пороге 60 HP; обратно фаза не возвращается.
	if not destroyed and is_active and phase == 1 and hp <= PHASE_2_HP_THRESHOLD:
		_enter_phase_two()
	return destroyed


func _enter_phase_two() -> void:
	phase = 2
	# M6.3a: глобальный множитель пуль endless сохраняется при смене фазы (иначе босс
	# в endless терял бы ускорение пуль после 50% HP).
	bullet_speed = PHASE1_BULLET_SPEED * PHASE2_SPEED_MULT * bullet_speed_mult
	_radial_timer = 0.5
	_bomb_timer = 1.2
	# Незаконченная прицельная очередь в фазе 2 не продолжается (другой паттерн).
	_burst_shots_left = 0
	_burst_timer = 0.0
	phase_changed.emit(phase)
