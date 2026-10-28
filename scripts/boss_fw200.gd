# boss_fw200.gd
# Purpose: Босс Fw 200 (M5.2, миссия 3 «Город») — 220 HP, горизонтальный прочёс, две фазы
#          и финальное усиление. Ф1: 4 турели с прицельными одиночными каждые 2.6 с и широкий
#          веер из 7 пуль каждые 3.0 с (скорость 300). Ф2 (порог 110 HP): радиальный залп из
#          16 пуль каждые 2.4 с (скорость 320). На 55 HP (25%) — усиление: интервалы огня /1.3,
#          скорость пуль ×1.1. Усиление НЕ меняет phase (остаётся 2) и не эмитит повторный
#          phase_changed — наружу виден флаг is_enraged (тесты/QA/juice).
#          Новых врагов НЕ призывает (GDD «Боссы»). Бомба игрока не убивает босса мгновенно.
# Dependencies: EnemyBase, ArtStyle, GameConfig.
# Author: Mechanics Developer Agent

class_name BossFw200
extends EnemyBase

## Смена фазы (juice/UI/аудио подписываются здесь). Переход только 1 → 2.
signal phase_changed(phase: int)

# ─── Тюнинг (GDD «Враги» / «Боссы») ──────────────────────────────────────────
const BOSS_HP := 220                           # GDD: 220 HP
const BOSS_SCORE := 4000                       # GDD: 4000 очков
const PHASE_2_HP_THRESHOLD := 110              # GDD: фаза 2 с 50% HP, переход односторонний
const ENRAGE_HP_THRESHOLD := 55                # GDD: финальное усиление на 25% HP

const ENTRY_SPEED := 140.0                     # (tune) вход в поле сверху
const ALTITUDE := 160.0                        # высота прочёса
const SWEEP_SPEED := 70.0                      # медленный горизонтальный прочёс
const SWEEP_MARGIN := 140.0                    # отступ от краёв (силуэт 192 px целиком в поле)

## Ф1: четыре турели — внутренняя и внешняя пара на каждом крыле.
const TURRET_X_OFFSETS := [48.0, 72.0]
const TURRET_Y_OFFSET := 24.0
const TURRET_SIDES := [-1.0, 1.0]
const PHASE1_AIMED_INTERVAL := 2.6
const PHASE1_FAN_INTERVAL := 3.0
const PHASE1_BULLET_SPEED := 300.0             # GDD: миссия 3 — 340–420, босс медленнее
const PHASE1_FAN_COUNT := 7
const PHASE1_FAN_SPREAD_DEG := 75.0            # широкий медленный веер

## Ф2: радиальный залп.
const PHASE2_RADIAL_INTERVAL := 2.4
const PHASE2_RADIAL_COUNT := 16
const PHASE2_BULLET_SPEED := 320.0

## Финальное усиление (25% HP): темп огня ×1.3 (интервалы /1.3), пули +10%.
const ENRAGE_RATE_MULT := 1.3
const ENRAGE_SPEED_MULT := 1.1

var phase: int = 1
## Внутренний флаг усиления — публичный для тестов/QA (нового phase_changed он не эмитит).
var is_enraged: bool = false
## Текущие интервалы огня: стартуют с констант фазы 1 и уменьшаются при усилении.
## Публичные — тесты сверяют «интервалы уменьшаются» без доступа к приватным таймерам.
var aimed_interval: float = PHASE1_AIMED_INTERVAL
var fan_interval: float = PHASE1_FAN_INTERVAL
var radial_interval: float = PHASE2_RADIAL_INTERVAL

var _entered: bool = false
var _sweep_direction: float = 1.0
var _aimed_timer: float = 0.0
var _fan_timer: float = 0.0
var _radial_timer: float = 0.0


func _init() -> void:
	asset_key = ArtStyle.KEY_BOSS_FW200
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
	is_enraged = false
	aimed_interval = PHASE1_AIMED_INTERVAL
	fan_interval = PHASE1_FAN_INTERVAL
	radial_interval = PHASE2_RADIAL_INTERVAL
	_entered = false
	_sweep_direction = 1.0
	_aimed_timer = PHASE1_AIMED_INTERVAL
	_fan_timer = PHASE1_FAN_INTERVAL
	_radial_timer = PHASE2_RADIAL_INTERVAL


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


## Собственный график стрельбы: базовый одиночный выстрел здесь не используется.
func _tick_weapon(delta: float) -> void:
	if target == null or not target.is_alive or not _entered:
		return
	if phase == 1:
		_aimed_timer -= delta
		if _aimed_timer <= 0.0:
			_aimed_timer = aimed_interval
			_fire_turret_volley()
		_fan_timer -= delta
		if _fan_timer <= 0.0:
			_fan_timer = fan_interval
			_fire_wide_fan()
		return
	_radial_timer -= delta
	if _radial_timer <= 0.0:
		_radial_timer = radial_interval
		_fire_radial_volley()


# ─── Фаза 1 ──────────────────────────────────────────────────────────────────
## Прицельный залп четырёх турелей: по снаряду из каждой точки в текущую позицию игрока.
func _fire_turret_volley() -> void:
	if target == null or not target.is_alive:
		return
	for side: float in TURRET_SIDES:
		for offset: float in TURRET_X_OFFSETS:
			var origin := global_position + Vector2(side * offset, TURRET_Y_OFFSET)
			var direction := target.global_position - origin
			if direction.length_squared() < 1.0:
				direction = Vector2.DOWN
			fire_direction(origin, direction, bullet_speed, bullet_damage)


## Широкий веер вниз: PHASE1_FAN_COUNT пуль на весь сектор ±PHASE1_FAN_SPREAD_DEG.
func _fire_wide_fan() -> void:
	var origin := global_position + Vector2(0.0, 24.0)
	var step := (PHASE1_FAN_SPREAD_DEG * 2.0) / float(PHASE1_FAN_COUNT - 1)
	for index in PHASE1_FAN_COUNT:
		var angle_deg := -PHASE1_FAN_SPREAD_DEG + step * float(index)
		fire_direction(origin, Vector2.DOWN.rotated(deg_to_rad(angle_deg)),
			bullet_speed, bullet_damage)


# ─── Фаза 2 ──────────────────────────────────────────────────────────────────
## Радиальный залп: PHASE2_RADIAL_COUNT пуль по кругу (GDD «Боссы»: радиальные залпы).
func _fire_radial_volley() -> void:
	var origin := global_position
	for index in PHASE2_RADIAL_COUNT:
		var angle := TAU * float(index) / float(PHASE2_RADIAL_COUNT)
		fire_direction(origin, Vector2.DOWN.rotated(angle), bullet_speed, bullet_damage)


# ─── Урон, фазы и усиление ──────────────────────────────────────────────────
func take_damage(amount: float) -> bool:
	var destroyed := super.take_damage(amount)
	if destroyed or not is_active:
		return destroyed
	# Переход только сверху вниз (1 → 2) на пороге 110 HP.
	if phase == 1 and hp <= PHASE_2_HP_THRESHOLD:
		_enter_phase_two()
	# Усиление — только в фазе 2 и только на пороге 55 HP (25%). phase остаётся 2,
	# phase_changed повторно НЕ эмитится.
	if phase == 2 and not is_enraged and hp <= ENRAGE_HP_THRESHOLD:
		_enter_enrage()
	return destroyed


func _enter_phase_two() -> void:
	phase = 2
	# M6.3a: множитель пуль endless переживает смену фазы (см. EnemyBase.apply_difficulty).
	bullet_speed = PHASE2_BULLET_SPEED * bullet_speed_mult
	# Первый радиальный залп — с короткой задержкой после перехода.
	_radial_timer = 0.8
	phase_changed.emit(phase)


## Финальное усиление (GDD «Боссы»: «темп ×1.3» на 25% HP). Меняет только темп и скорость
## пуль — фаза и сигналы наружу не меняются.
func _enter_enrage() -> void:
	is_enraged = true
	aimed_interval = PHASE1_AIMED_INTERVAL / ENRAGE_RATE_MULT
	fan_interval = PHASE1_FAN_INTERVAL / ENRAGE_RATE_MULT
	radial_interval = PHASE2_RADIAL_INTERVAL / ENRAGE_RATE_MULT
	bullet_speed *= ENRAGE_SPEED_MULT
	# Уже идущие таймеры не должны «доигрывать» старый интервал: подрезаем их новым.
	_aimed_timer = minf(_aimed_timer, aimed_interval)
	_fan_timer = minf(_fan_timer, fan_interval)
	_radial_timer = minf(_radial_timer, radial_interval)
