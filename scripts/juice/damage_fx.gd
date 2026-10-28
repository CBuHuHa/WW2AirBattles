# damage_fx.gd
# Purpose: Визуальные повреждения игрока (GDD «Mechanics → Игрок»: «2 HP — дым, 1 HP — огонь»;
#          «Game feel»: «дым при 2 HP, огонь при 1 HP»). Два ДОЛГОЖИВУЩИХ CPUParticles2D-эмитера,
#          создаются ОДИН раз в _ready — на лету ничего не аллоцируется (бюджет Android).
#          Механических эффектов от повреждений нет (GDD): только визуал.
# Dependencies: ArtStyle (палитра), Explosions (общая круговая текстура «искры»).
# Author: Game Feel Developer Agent
#
# ПОЧЕМУ CPUParticles2D И РЕБЁНОК PLAYER: CPU-частицы детерминированы на старых Mali/Adreno с
# GL Compatibility; узел лежит внутри Player → World (process_mode PAUSABLE), поэтому дым и
# огонь замирают вместе с миром на паузе и после окна исхода. local_coords остаётся включённым
# (по умолчанию): пuff'ы живут в системе координат Ла-5 — предсказуемо при тряске/паузе.

class_name PlayerDamageFx
extends Node2D

## ─── Дым (2 HP) ─────────────────────────────────────────────────────────────
## (tune) Частицы ≤ ~30 на эффект (бюджет Android из техтребований M4). Уменьшено в 3x для читаемости силуэта.
const SMOKE_AMOUNT := 4                        # было 12 × 0.33 ≈ 4
const SMOKE_LIFETIME := 0.9                    # (tune) высота и живучесть столба дыма
const SMOKE_POSITION := Vector2(0.0, 10.0)     # (tune) дым из хвоста/двигателя
const SMOKE_VELOCITY_MIN := 26.0               # (tune) px/s вверх
const SMOKE_VELOCITY_MAX := 52.0
## (tune) Серо-голубой: небо #8FA6B2, осветлённое, полупрозрачное (GDD «Палитра»).
const SMOKE_COLOR := Color(0.72, 0.78, 0.81, 0.55)

## ─── Огонь (1 HP) ───────────────────────────────────────────────────────────
## Уменьшено в 3x для читаемости силуэта.
const FIRE_AMOUNT := 3                         # было 10 × 0.3 ≈ 3
const FIRE_LIFETIME := 0.45                    # (tune) короткие языки пламени
const FIRE_POSITION := Vector2(0.0, 4.0)
const FIRE_VELOCITY_MIN := 70.0                # (tune) px/s вверх-в стороны
const FIRE_VELOCITY_MAX := 130.0

var _smoke: CPUParticles2D
var _fire: CPUParticles2D


func _ready() -> void:
	_smoke = _build_smoke()
	add_child(_smoke)
	_fire = _build_fire()
	add_child(_fire)


## hp по GDD «Игрок»: 3 — исправлен (тихо), 2 — дым, 1 — огонь; 0 и меньше — оба выключены
## (игрок сбит, визуал скрыт). Вызывается из player.health_changed (LevelController, juice).
func set_hp(hp: int) -> void:
	_smoke.emitting = hp == 2
	_fire.emitting = hp == 1


func is_smoking() -> bool:
	return _smoke.emitting


func is_burning() -> bool:
	return _fire.emitting


# ─── Сборка эмитеров (однократная, в _ready) ────────────────────────────────
## Дым: серо-голубые puff'ы вверх, растут и тают. Палитра #8FA6B2 (GDD «Палитра»).
func _build_smoke() -> CPUParticles2D:
	var particles := CPUParticles2D.new()
	particles.name = "Smoke"
	particles.amount = SMOKE_AMOUNT
	particles.lifetime = SMOKE_LIFETIME
	particles.one_shot = false
	particles.explosiveness = 0.35      # (tune) рваные «пuffs», а не непрерывная струя
	particles.texture = Explosions.spark_texture()
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 4.0
	particles.position = SMOKE_POSITION
	particles.direction = Vector2.UP
	particles.spread = 30.0
	particles.gravity = Vector2(0.0, -8.0)  # лёгкий подъём, столб не оседает
	particles.initial_velocity_min = SMOKE_VELOCITY_MIN
	particles.initial_velocity_max = SMOKE_VELOCITY_MAX
	particles.angular_velocity_min = -40.0
	particles.angular_velocity_max = 40.0
	particles.scale_amount_min = 6.0
	particles.scale_amount_max = 14.0
	var grow := Curve.new()             # puff'ы расширяются к концу жизни
	grow.add_point(Vector2(0.0, 0.0))
	grow.add_point(Vector2(1.0, 1.0))
	particles.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, SMOKE_COLOR)
	ramp.set_offset(0, 0.0)
	ramp.set_color(1, Color(SMOKE_COLOR.r, SMOKE_COLOR.g, SMOKE_COLOR.b, 0.0))
	ramp.set_offset(1, 1.0)
	particles.color_ramp = ramp
	return particles


## Огонь: оранжево-красные искры из палитры #FFD166 → #B23A2E (GDD «Палитра»/«Game feel»).
func _build_fire() -> CPUParticles2D:
	var particles := CPUParticles2D.new()
	particles.name = "Fire"
	particles.amount = FIRE_AMOUNT
	particles.lifetime = FIRE_LIFETIME
	particles.one_shot = false
	particles.explosiveness = 0.6       # (tune) частые языки пламени
	particles.texture = Explosions.spark_texture()
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = 5.0
	particles.position = FIRE_POSITION
	particles.direction = Vector2.UP
	particles.spread = 45.0
	particles.gravity = Vector2(0.0, -60.0)
	particles.initial_velocity_min = FIRE_VELOCITY_MIN
	particles.initial_velocity_max = FIRE_VELOCITY_MAX
	particles.angular_velocity_min = -240.0
	particles.angular_velocity_max = 240.0
	particles.scale_amount_min = 4.0
	particles.scale_amount_max = 7.0
	var shrink := Curve.new()           # искры сжигаются к концу жизни
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.15))
	particles.scale_amount_curve = shrink
	var ramp := Gradient.new()
	ramp.set_color(0, ArtStyle.BULLET_ENEMY)
	ramp.set_offset(0, 0.0)
	ramp.set_color(1, Color(ArtStyle.DANGER.r, ArtStyle.DANGER.g, ArtStyle.DANGER.b, 0.0))
	ramp.set_offset(1, 1.0)
	ramp.add_point(0.55, ArtStyle.DANGER)
	particles.color_ramp = ramp
	return particles
