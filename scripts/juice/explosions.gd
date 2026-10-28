# explosions.gd
# Purpose: Плейсхолдерные взрывы по ключам GDD «Assets»: explosion_small (32×32, 4 кадра)
#          и explosion_boss (160×160, 6 кадров). Без текстур-ассетов: CPUParticles2D с
#          кодовой круговой текстурой (GradientTexture2D) + полигональная вспышка-«кадр».
#          Цвета палитры GDD: #FFD166 (пули) → #B23A2E (опасность) → тлеющий пепел → fade.
# Dependencies: ArtStyle (палитра).
# Author: Game Feel Developer Agent
#
# ПОЧЕМУ CPUParticles2D, А НЕ GPUParticles2D (Android): CPU-частицы детерминированы,
# не требуют поддержки частицных шейдеров и ведут себя одинаково на старых Mali/Adreno с
# GL Compatibility (проект: rendering_method gl_compatibility). Счётчики намеренно
# десятков частиц — на 540×960 бюджет GPU почти не задет.

class_name Explosions
extends RefCounted

# ─── Ключи GDD «Assets» ──────────────────────────────────────────────────────
## GDD «Assets»: explosion_small — 32×32, 4 кадра.
const FRAMES_SMALL := 4
const SIZE_SMALL := 32.0
const PARTICLES_SMALL := 14
## GDD «Assets»: explosion_boss — 160×160, 6 кадров.
const FRAMES_BOSS := 6
const SIZE_BOSS := 160.0
const PARTICLES_BOSS := 26

## (tune) Длительность одного «кадра» анимации — задаёт общее время жизни взрыва.
const FRAME_TIME_SMALL := 0.05   # 4 кадра × 0.05 с = 0.2 с
const FRAME_TIME_BOSS := 0.08    # 6 кадров × 0.08 с ≈ 0.48 с
## (tune) Радиус полигональной вспышки-«кадра» относительно размера взрыва.
const FLASH_RADIUS_FACTOR := 0.55

## Одна кодовая текстура на все взрывы проекта (круг с жёстким краем — флэт-вектор).
static var _spark_texture: Texture2D = null
## Кэш рампы цвета и кривой сжатия: они одинаковы для обоих размеров взрыва и не мутируются,
## поэтому создаются ОДИН раз на процесс, а не на каждый взрыв (ревью: аллокации в hot-path).
static var _color_ramp: Gradient = null
static var _shrink_curve: Curve = null

# ─── Группы для учёта/QA ─────────────────────────────────────────────────────
## Контейнеры взрывов помечаются группами: имена при повторном добавлении одного и того же
## имени движок переименовывает (@Node2D@N), поэтому опознавать взрывы по имени ненадёжно.
const GROUP_EXPLOSION := &"juice_explosion"
const GROUP_EXPLOSION_BOSS := &"juice_explosion_big"


## pos — МИРОВАЯ точка взрыва. Порядок строгий: сначала add_child, потом global_position —
## QA-замечание про ненадёжность global_position до add_child соблюдено.
## parent — usually World/Effects Level-контроллера, чтобы взрыв тряслась вместе с миром.
static func spawn(parent: Node, pos: Vector2, big: bool = false) -> void:
	if parent == null:
		return
	var size := SIZE_BOSS if big else SIZE_SMALL
	var frames := FRAMES_BOSS if big else FRAMES_SMALL
	var frame_time := FRAME_TIME_BOSS if big else FRAME_TIME_SMALL
	var amount := PARTICLES_BOSS if big else PARTICLES_SMALL
	var lifetime := frames * frame_time

	var container := Node2D.new()
	container.name = "ExplosionBoss" if big else "ExplosionSmall"
	container.add_to_group(GROUP_EXPLOSION)
	if big:
		container.add_to_group(GROUP_EXPLOSION_BOSS)
	parent.add_child(container)
	if container.is_inside_tree():
		container.global_position = pos
	else:
		container.position = pos

	var particles := CPUParticles2D.new()
	container.add_child(particles)
	_configure(particles, size, amount, lifetime)
	# finished (one_shot) — когда все частицы дообработались; fallback-таймер страхует,
	# если сигнал по какой-то причине не придёт. Прямые callable-ы (не лямбды): при
	# освобождении container соединения снимаются движком автоматически.
	particles.finished.connect(container.queue_free)
	var fallback := container.get_tree().create_timer(lifetime + 0.5)
	fallback.timeout.connect(container.queue_free)
	particles.emitting = true

	var flash := _BlastFlash.new()
	container.add_child(flash)
	flash.setup(size * FLASH_RADIUS_FACTOR, lifetime * 0.5)


## Параметры «кадров/радиуса/цвета» из GDD-ключей. amount — десятки: бюджет Android.
static func _configure(particles: CPUParticles2D, size: float, amount: int, lifetime: float) -> void:
	particles.one_shot = true
	particles.amount = amount
	particles.lifetime = lifetime
	particles.explosiveness = 1.0  # весь залп сразу — «кадровая» вспышка, а не струя
	particles.texture = _get_spark_texture()

	# Радиус разлёта = размеру взрыва из таблицы Assets.
	particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = size * 0.08
	var burst_speed := size / lifetime
	particles.initial_velocity_min = burst_speed * 0.55
	particles.initial_velocity_max = burst_speed
	particles.spread = 180.0
	particles.gravity = Vector2.ZERO
	particles.angular_velocity_min = -180.0
	particles.angular_velocity_max = 180.0

	# Цвет по GDD-палитре: #FFD166 → #B23A2E → тлеющий пепел → fade на финале.
	particles.color_ramp = _get_color_ramp()

	# Частицы тают к концу жизни — «затухание кадра» без текстурных атласов.
	particles.scale_amount_curve = _get_shrink_curve()
	particles.scale_amount_min = size / 24.0
	particles.scale_amount_max = size / 10.0


## Градиент взрыва (кэш на процесс): #FFD166 → #B23A2E → тлеющий пепел → fade.
static func _get_color_ramp() -> Gradient:
	if _color_ramp != null:
		return _color_ramp
	var ramp := Gradient.new()
	ramp.set_color(0, ArtStyle.BULLET_ENEMY)
	ramp.set_offset(0, 0.0)
	ramp.set_color(1, Color(0.32, 0.30, 0.28, 0.0))
	ramp.set_offset(1, 1.0)
	ramp.add_point(0.45, ArtStyle.DANGER)
	ramp.add_point(0.75, Color(0.32, 0.30, 0.28))
	_color_ramp = ramp
	return ramp


## Кривая сжатия частиц (кэш на процесс): от полного размера к 0.2.
static func _get_shrink_curve() -> Curve:
	if _shrink_curve != null:
		return _shrink_curve
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.2))
	_shrink_curve = shrink
	return shrink


## Публичный доступ к ОБЩЕЙ круговой текстуре «искры»: ею же пользуется PlayerDamageFx —
## один сгенерированный ресурс на весь проект (бюджет Android).
static func spark_texture() -> Texture2D:
	return _get_spark_texture()


## Круглая текстура «искры», сгенерированная кодом (solid до 0.8 радиуса, обрыв к краю).
static func _get_spark_texture() -> Texture2D:
	if _spark_texture != null:
		return _spark_texture
	var gradient := Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_offset(0, 0.0)
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	gradient.set_offset(1, 1.0)
	gradient.add_point(0.8, Color.WHITE)  # жёсткое тело — флэт-вектор, не блоб
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 32
	texture.height = 32
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	_spark_texture = texture
	return texture


## Вспышка-«кадр»: расширяющийся восьмиугольник, белый → #FFD166, alpha тает.
## Это плейсхолдер «N кадров атласа» из GDD «Assets» — полигонами, без спрайтшитов.
class _BlastFlash extends Node2D:
	const SIDES := 8

	var _radius_max: float = 16.0
	var _duration: float = 0.1
	var _progress: float = 0.0

	func setup(radius_max: float, duration: float) -> void:
		_radius_max = maxf(radius_max, 1.0)
		_duration = maxf(duration, 0.01)
		_progress = 0.0

	func _process(delta: float) -> void:
		_progress = minf(1.0, _progress + delta / _duration)
		queue_redraw()
		if _progress >= 1.0:
			set_process(false)
			visible = false

	func _draw() -> void:
		var fade := 1.0 - _progress
		var radius := _radius_max * lerpf(0.35, 1.0, sqrt(_progress))
		var points := PackedVector2Array()
		points.resize(SIDES)
		for i in SIDES:
			var angle := TAU * float(i) / float(SIDES)
			points[i] = Vector2(cos(angle), sin(angle)) * radius
		var color := ArtStyle.BULLET_ENEMY.lerp(Color.WHITE, clampf(1.0 - _progress * 2.0, 0.0, 1.0))
		draw_colored_polygon(points, Color(color, 0.9 * fade))
