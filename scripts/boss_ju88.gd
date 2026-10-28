# boss_ju88.gd
# Purpose: Босс Ju 88 (M5.2, миссия 2 «Переправа») — 160 HP, горизонтальный прочёс в верхней
#          части экрана, две фазы. Ф1: прицельные ОЧЕРЕДИ из двух турелей (по 2 снаряда).
#          Ф2 (порог 80 HP, переход односторонний): скорость пуль ×1.3, сброс бомб каждые
#          3.5 с (объект BossBomb создаёт LevelController по сигналу bomb_dropped) и веер вниз
#          из 7 пуль каждые 2.5 с. Новых врагов НЕ призывает (GDD «Боссы»). Наследник
#          EnemyBase с флагом is_boss: бомба игрока не убивает его мгновенно, 30 урона
#          приходят через LevelController.bomb_hit_boss().
# Dependencies: EnemyBase, ArtStyle, GameConfig.
# Author: Mechanics Developer Agent

class_name BossJu88
extends EnemyBase

## Смена фазы (juice/UI/аудио подписываются здесь). Переход только 1 → 2.
signal phase_changed(phase: int)

# ─── Тюнинг (GDD «Враги» / «Боссы») ──────────────────────────────────────────
const BOSS_HP := 160                           # GDD: 160 HP
const BOSS_SCORE := 3000                       # GDD: 3000 очков
const PHASE_2_HP_THRESHOLD := 80               # GDD: фаза 2 с 50% HP, переход односторонний

const ENTRY_SPEED := 140.0                     # (tune) вход в поле сверху
const ALTITUDE := 180.0                        # высота прочёса
const SWEEP_SPEED := 80.0                      # горизонтальный прочёс
const SWEEP_MARGIN := 120.0                    # отступ от краёв (силуэт 160 px целиком в поле)

## Ф1: две турели. Цикл PHASE1_AIMED_INTERVAL запускает очередь из AIMED_BURST_SHOTS залпов,
## внутри очереди — AIMED_BURST_INTERVAL (GDD: «прицельные очереди»).
const TURRET_OFFSET := Vector2(52.0, 22.0)
const TURRET_SIDES := [-1.0, 1.0]
const PHASE1_AIMED_INTERVAL := 2.2
const AIMED_BURST_SHOTS := 2                   # по 2 снаряда в очереди каждой турели
const AIMED_BURST_INTERVAL := 0.12
const PHASE1_BULLET_SPEED := 320.0             # GDD: 300–380 px/s (миссия 2)

## Ф2: бомбы по площади + веер вниз.
const PHASE2_SPEED_MULT := 1.3                 # GDD: скорость пуль ×1.3
const PHASE2_BOMB_INTERVAL := 3.5              # GDD: серии бомб по площади
const BOMB_MUZZLE_OFFSET := Vector2(0.0, 44.0) # точка сброса под корпусом
const PHASE2_FAN_INTERVAL := 2.5               # GDD: веер вниз
const PHASE2_FAN_COUNT := 7                    # 7 пуль в веере
const PHASE2_FAN_SPREAD_DEG := 60.0            # полураствор веера

var phase: int = 1
var _entered: bool = false
var _sweep_direction: float = 1.0
var _aimed_timer: float = 0.0
var _bomb_timer: float = 0.0
var _fan_timer: float = 0.0
## Состояние очереди: сколько залпов ещё выйдет и через сколько.
var _burst_shots_left: int = 0
var _burst_timer: float = 0.0


func _init() -> void:
	asset_key = ArtStyle.KEY_BOSS_JU88
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
	_bomb_timer = PHASE2_BOMB_INTERVAL
	_fan_timer = PHASE2_FAN_INTERVAL
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
		return
	_bomb_timer -= delta
	if _bomb_timer <= 0.0:
		_bomb_timer = PHASE2_BOMB_INTERVAL
		bomb_dropped.emit(global_position + BOMB_MUZZLE_OFFSET)
	_fan_timer -= delta
	if _fan_timer <= 0.0:
		_fan_timer = PHASE2_FAN_INTERVAL
		_fire_down_fan()


## Очередь турелей: цикл PHASE1_AIMED_INTERVAL запускает серию из AIMED_BURST_SHOTS залпов,
## внутри серии — AIMED_BURST_INTERVAL.
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
## Один залп очереди: по снаряду из каждой турели в ТЕКУЩУЮ позицию игрока.
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


# ─── Фаза 2 ──────────────────────────────────────────────────────────────────
## Веер вниз из PHASE2_FAN_COUNT пуль (широкий сектор под бомбардировщиком).
func _fire_down_fan() -> void:
	var origin := global_position + Vector2(0.0, 32.0)
	var step := (PHASE2_FAN_SPREAD_DEG * 2.0) / float(PHASE2_FAN_COUNT - 1)
	for index in PHASE2_FAN_COUNT:
		var angle_deg := -PHASE2_FAN_SPREAD_DEG + step * float(index)
		fire_direction(origin, Vector2.DOWN.rotated(deg_to_rad(angle_deg)),
			bullet_speed, bullet_damage)


# ─── Урон и фаза ─────────────────────────────────────────────────────────────
func take_damage(amount: float) -> bool:
	var destroyed := super.take_damage(amount)
	# Переход только сверху вниз (1 → 2) на пороге 80 HP; обратно фаза не возвращается.
	if not destroyed and is_active and phase == 1 and hp <= PHASE_2_HP_THRESHOLD:
		_enter_phase_two()
	return destroyed


func _enter_phase_two() -> void:
	phase = 2
	# M6.3a: множитель пуль endless переживает смену фазы (см. EnemyBase.apply_difficulty).
	bullet_speed = PHASE1_BULLET_SPEED * PHASE2_SPEED_MULT * bullet_speed_mult
	# Первая бомба и первый веер — с короткой задержкой после перехода, а не в тот же кадр.
	_bomb_timer = 1.2
	_fan_timer = 0.8
	# Незаконченная прицельная очередь в фазе 2 не продолжается (другой паттерн).
	_burst_shots_left = 0
	_burst_timer = 0.0
	phase_changed.emit(phase)
