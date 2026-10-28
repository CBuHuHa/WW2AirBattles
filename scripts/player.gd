# player.gd
# Purpose: Игрок (по умолчанию Ла-5). Относительное перетаскивание пальцем (1:1), автострельба,
#          3 HP, неуязвимость 1.5 с после попадания. Никакой обработки мыши: только
#          InputEventScreenTouch/Drag.
#          M6.1a: оружие вынесено в поля (число снарядов, урон, интервал, скорость, разброс,
#          ракеты, осколки, урон по боссу) — их пересчитывает apply_perks() по данным
#          `data/perks.json` из PerkData.
#          M6.2a: база оружия — выбранный самолёт ангара (`data/planes.json` через PlaneData).
#          apply_plane(id) переписывает БАЗУ (интервал/урон/скорость/хитбоксы/арт) и заново
#          накладывает активные перки; reset_perks() возвращает базу выбранного самолёта,
#          а не Ла-5. Без apply_plane (тесты, старые вызовы) база = Ла-5: 8 выстр./с,
#          1 урон, 800 px/s, r8, пуля r4 — поведение M1–M5 не меняется.
#          M6.2b: ливрея ангара — apply_livery(index) красит Visual.modulate тинтом
#          ArtStyle.LIVERY_TINTS (0 — без ливреи/белый). Выбор хранит SaveGame, применяет
#          LevelController.start_level().
# Dependencies: GameConfig, ArtStyle (через ShipVisual), PerkData (данные перков),
#               PlaneData (данные самолётов M6.2a), BulletLayer (через сигналы shot_fired/
#               rocket_fired).
# Author: Mechanics Developer Agent

class_name Player
extends Area2D

## Запрос на выстрел. LevelController маршрутизирует его в BulletLayer.
## damage — float (перки дают 0.85 / 1.1 / 2.0 и т.д.); без перков 1.0.
signal shot_fired(origin: Vector2, velocity: Vector2, damage: float)
## M6.1a «РС-82»: залп ракет (2 ракеты вверх). LevelController → BulletLayer.spawn_rocket.
signal rocket_fired(origin: Vector2, velocity: Vector2, damage: float, radius: float)
## HP изменился (HUD M2/M3).
signal health_changed(hp: int)
## Игрок получил попадание (точка — для будущего juice: вспышка/тряска).
signal damaged(hp: int, at: Vector2)
## HP = 0. LevelController показывает экран «Аэродром потерян».
signal died

# ─── Тюнинг (GDD «Mechanics → Игрок») ────────────────────────────────────────
## База Ла-5. Поля ниже — ТЕКУЩИЕ значения, которые пересчитываются apply_perks() от этих
## констант: перки никогда не «накапливаются» поверх прошлых перков.
const MAX_HP := 3                              # (tune) GDD «Игрок»: 3 HP
const HIT_RADIUS := 8.0                        # (tune) GDD «Игрок»: хитбокс круг r=8, меньше визуала
const FIRE_INTERVAL := 0.125                   # (tune) GDD «Игрок»: 8 выстрелов/с
const BULLET_SPEED := 800.0                    # (tune) GDD «Игрок»: снаряд 800 px/s
const BULLET_DAMAGE := 1                       # GDD «Игрок»: 1 урон
## GDD «Самолёты (ангар)»: Ла-5 — хитбокс пули 4 px (Аэрокобра — 6).
const BULLET_HIT_RADIUS := 4.0
## Самолёт по умолчанию (GDD: Ла-5 — старт). База полей до apply_plane() = Ла-5.
const DEFAULT_PLANE_ID := "la5"
const BASE_BULLETS_PER_SHOT := 1               # GDD «Игрок»: одна пуля в выстреле
const BASE_SPREAD_DEG := 0.0                   # GDD «Игрок»: без разброса
const INVULNERABILITY_TIME := 1.5              # (tune) GDD «Игрок»: 1.5 с неуязвимости после попадания

# ─── Ракеты «РС-82» (GDD «Временные перки») ──────────────────────────────────
const ROCKET_INTERVAL := 3.0                   # GDD: каждые 3 с
const ROCKET_COUNT := 2                        # GDD: 2 ракеты
const ROCKET_DAMAGE := 4.0                     # GDD: 4 урона
const ROCKET_RADIUS := 40.0                    # GDD: радиус взрыва 40 px
const ROCKET_SPEED := 420.0                    # (tune) скорость ракеты; в GDD не задана
const ROCKET_SPACING := 8.0                    # (tune) боковой разнос пары ракет, px

# ─── Управление (ТЗ M1) ──────────────────────────────────────────────────────
const TOUCH_SENSITIVITY := 1.0                 # (tune) ТЗ M1: смещение пальца переносится 1:1
## ЕДИНСТВЕННЫЙ источник стартовой позиции: main.tscn больше не задаёт position,
## Player._ready()/LevelController.start_level() ставят самолёт по этой константе.
const START_POSITION := Vector2(270.0, 840.0)  # ТЗ M1: старт внизу по центру
const MUZZLE_OFFSET := Vector2(0.0, -26.0)     # точка вылета снаряда над силуэтом
const BLINK_HALF_PERIOD := 0.08                # мигание альфой во время неуязвимости (функциональная индикация)
## Боковой разнос стволов при bullets_per_shot > 1 («Спарка ШВАК»). При одной пуле — 0:
## базовая стрельба остаётся точно вверх из MUZZLE_OFFSET.
const MULTI_BULLET_SPACING := 10.0

# ─── Оружие и защита: ТЕКУЩИЕ значения (пересчёт из базы самолёта + PerkData) ─
var bullets_per_shot: int = BASE_BULLETS_PER_SHOT
var bullet_damage: float = float(BULLET_DAMAGE)
var fire_interval: float = FIRE_INTERVAL
var bullet_speed: float = BULLET_SPEED
var spread_deg: float = BASE_SPREAD_DEG
## Хитбокс самолёта (круг CollisionShape2D). М6.2a: r=8 у Ла-5/Аэрокобры, r=7 у Як-3.
var hit_radius: float = HIT_RADIUS
## Хитбокс пули игрока (M6.2a, GDD): 4 px у Ла-5/Як-3, 6 px у Аэрокобры. Уходит в Bullet
## через LevelController → BulletLayer.fire_player().
var bullet_hit_radius: float = BULLET_HIT_RADIUS
## id выбранного самолёта ангара ("" не бывает: по умолчанию Ла-5).
var plane_id: String = DEFAULT_PLANE_ID
## Индекс выбранной ливреи (M6.2b): 0 — без ливреи, 1…3 — перекраска корпуса (ArtStyle.LIVERY_TINTS).
var livery_index: int = 0
## Урон по боссу (М6.1a «Тяжёлый калибр»: ×1.3). Обычные враги получают bullet_damage.
var boss_damage_mult: float = 1.0
## Осколки (М6.1a «Осколочные»): 0 — нет. splash_ratio — доля урона соседям в радиусе.
var splash_radius: float = 0.0
var splash_ratio: float = 0.0
## «РС-82»: пока перк активен, раз в rocket_interval вылетает rocket_count ракет.
var rocket_enabled: bool = false
var rocket_interval: float = ROCKET_INTERVAL
var rocket_count: int = ROCKET_COUNT
var rocket_damage: float = ROCKET_DAMAGE
var rocket_radius: float = ROCKET_RADIUS
## Неуязвимость после попадания (М6.1a «Хладнокровие»: 1.5 → 2.5).
var invuln_time: float = INVULNERABILITY_TIME
## Потолок HP (М6.1a «Ремонт»: 3 → 4 на миссию).
var max_hp: int = MAX_HP
## «Аварийный сброс»: при уроне чистятся вражеские пули в радиусе (M6.1b вызывает).
var emergency_clear: bool = false
var emergency_clear_radius: float = 0.0
var emergency_clear_cooldown: float = 0.0

var hp: int = MAX_HP
var is_alive: bool = true

var _invulnerability_left: float = 0.0
var _fire_cooldown: float = 0.0
var _rocket_cooldown: float = 0.0
## База ВЫБРАННОГО самолёта (M6.2a). apply_perks()/reset_perks() всегда считают от неё,
## поэтому перки не накапливаются и смена самолёта не оставляет следов прошлой базы.
var _base_fire_interval: float = FIRE_INTERVAL
var _base_bullet_damage: float = float(BULLET_DAMAGE)
var _base_bullet_speed: float = BULLET_SPEED
var _base_hit_radius: float = HIT_RADIUS
var _base_bullet_hit_radius: float = BULLET_HIT_RADIUS
## Активные карты, уже учтённые в полях: «Ремонт» лечит только за НОВУЮ карту
## (повторный apply_perks с тем же набором не должен лечить ещё раз).
var _applied_perk_ids: Array[String] = []
## Время последнего «Аварийного сброса» (мс, Time.get_ticks_msec).
var _emergency_used_msec: int = -1000000
## Индекс пальца, который сейчас ведёт самолёт (-1 — нет активного перетаскивания).
var _drag_touch_index: int = -1
var _last_drag_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	collision_layer = GameConfig.LAYER_PLAYER
	collision_mask = 0  # вражеские пули сами находят игрока (их маска включает слой player)
	_setup_hitbox()
	reset(START_POSITION)


## QA-правка #11: shape в player.tscn — общий сабресурс. Без duplicate() запись radius
## «протекала» бы в другие инстансы сцены (та же ловушка, что в EnemyBase._setup_hitbox()).
## M6.2a: радиус берётся из hit_radius (база самолёта). Дублируем, если радиус отличается:
## повторный вызов apply_plane() не плодит лишние ресурсы.
func _setup_hitbox() -> void:
	var shape_node := get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return
	var shared := shape_node.shape as CircleShape2D
	if shared == null:
		return
	if is_equal_approx(shared.radius, hit_radius):
		return
	var own := shared.duplicate() as CircleShape2D
	own.radius = hit_radius
	shape_node.shape = own


## M6.2a: применить самолёт ангара. Переписывает БАЗУ (интервал/урон/скорость/хитбокс
## самолёта и пули/ключ арта), пересобирает хитбокс и заново накладывает уже взятые перки —
## перки считаются от новой базы, а не от Ла-5. Вызывает LevelController на старте забега
## ДО player.reset(); повторный вызов с тем же id безопасен (эффекты не накапливаются и
## «Ремонт» не лечит: набор карт не менялся).
## Неизвестный id → false и НИЧЕГО не меняется (сейв уже отдаёт только валидные id).
func apply_plane(id: String) -> bool:
	var plane: Dictionary = PlaneData.get_plane(id)
	if plane.is_empty():
		return false
	var new_id := String(plane.get("id", DEFAULT_PLANE_ID))
	if new_id.is_empty():
		new_id = DEFAULT_PLANE_ID
	plane_id = new_id
	# Числа валидирует PlaneData.validate(); здесь soften-фолбэки на базу Ла-5, чтобы
	# опечатка в JSON не дала нулевой интервал/хитбокс.
	_base_fire_interval = PlaneData.get_number(new_id, "fire_interval", FIRE_INTERVAL)
	_base_bullet_damage = PlaneData.get_number(new_id, "damage", float(BULLET_DAMAGE))
	_base_bullet_speed = PlaneData.get_number(new_id, "bullet_speed", BULLET_SPEED)
	_base_hit_radius = PlaneData.get_number(new_id, "hit_radius", HIT_RADIUS)
	_base_bullet_hit_radius = PlaneData.get_number(new_id, "bullet_hit_radius",
		BULLET_HIT_RADIUS)
	hit_radius = _base_hit_radius
	bullet_hit_radius = _base_bullet_hit_radius
	_apply_plane_visual(PlaneData.get_asset_key(new_id))
	_setup_hitbox()
	# База новая — перки обязаны лечь на неё заново (тот же набор, без лечения).
	apply_perks(_applied_perk_ids.duplicate())
	return true


## Ключ арта в визуале. ShipVisual создаётся сценой player.tscn; если его нет (кастомный
## тестовый узел), визуал просто не меняется — механика от арта не зависит.
func _apply_plane_visual(asset_key: StringName) -> void:
	var visual := get_node_or_null(^"Visual") as ShipVisual
	if visual != null:
		visual.asset_key = asset_key


## M6.2b: ливрея корпуса (GDD «Самолёты (ангар)»: «перекраски корпуса»). Тинт ставится на
## Visual.modulate: self_modulate занят HitFlash (вспышка попадания), modulate.a узла Player —
## мигание неуязвимости, а CanvasItem рисует parent modulate × self_modulate, поэтому ливрея
## не спорит ни с одной из этих анимаций.
## Индекс вне 0…3 → false, визуал не меняется (сейв отдаёт только валидные индексы).
## Вызывается LevelController.start_level() сразу после apply_plane(); переживает
## reset() (тот трогает только modulate самого Player), поэтому ливрея не слетает на рестарте.
func apply_livery(index: int) -> bool:
	if index < 0 or index >= ArtStyle.LIVERY_TINTS.size():
		return false
	livery_index = index
	var visual := get_node_or_null(^"Visual") as CanvasItem
	if visual != null:
		visual.modulate = ArtStyle.livery_tint(index)
	return true


## Полный сброс игрока (старт уровня / рестарт). Перки сбрасываются: GDD «Временные перки»
## — «сбрасываются в начале каждой миссии и каждого забега».
## M6.2a: база оружия уже принадлежит выбранному самолёту (apply_plane вызван ДО reset).
func reset(start_position: Vector2) -> void:
	reset_perks()
	hp = max_hp
	is_alive = true
	_invulnerability_left = 0.0
	_fire_cooldown = 0.0
	_rocket_cooldown = 0.0
	_emergency_used_msec = -1000000
	_drag_touch_index = -1
	position = GameConfig.clamp_to_playfield(start_position)
	visible = true
	modulate.a = 1.0
	set_process(true)
	# reset() обязан вернуть и ввод, а не только process: begin_briefing() гасит оба канала
	# и включает их обратно строго после reset() (порядок reset()→disable сохранён), но
	# любой другой вызов reset() — рестарт, QA/тесты, будущие переходы состояний — не должен
	# оставлять Ла-5 без управления.
	set_process_unhandled_input(true)
	health_changed.emit(hp)


func _process(delta: float) -> void:
	if not is_alive:
		return
	_tick_invulnerability(delta)
	_tick_autofire(delta)
	_tick_rockets(delta)


# ─── Управление: относительное перетаскивание ────────────────────────────────
# Касание в ЛЮБОЙ точке экрана задаёт точку захвата; дальнейшее смещение пальца
# переносится на самолёт 1:1. При отпускании самолёт остаётся на месте,
# следующее касание заново задаёт точку захвата (ТЗ M1, GDD «Game feel»).
func _unhandled_input(event: InputEvent) -> void:
	if not is_alive:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _drag_touch_index == -1:
				_drag_touch_index = touch.index
				_last_drag_position = touch.position
		elif touch.index == _drag_touch_index:
			_drag_touch_index = -1
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index != _drag_touch_index:
			return
		var motion := (drag.position - _last_drag_position) * TOUCH_SENSITIVITY
		_last_drag_position = drag.position
		position = GameConfig.clamp_to_playfield(position + motion)


# ─── Урон и неуязвимость ─────────────────────────────────────────────────────
## Возвращает true, если попадание засчитано (пуля должна исчезнуть).
## Урон врага остаётся int: GDD «Враги» — «урон пули = 1».
func take_hit(damage: int = 1) -> bool:
	if not is_alive or _invulnerability_left > 0.0:
		return false
	hp = maxi(0, hp - damage)
	health_changed.emit(hp)
	damaged.emit(hp, global_position)
	if hp == 0:
		_die()
	else:
		grant_invulnerability(invuln_time)
	return true


## Ремкомплект / «Ремонт» (GDD «Волны и враги»): +amount HP до потолка max_hp.
## Возвращает false, если HP уже полный.
func heal(amount: int = 1) -> bool:
	if not is_alive or hp >= max_hp or amount <= 0:
		return false
	hp = mini(max_hp, hp + amount)
	health_changed.emit(hp)
	return true


## Неуязвимость на время взрыва бомбы (0.5 с по GDD) или после попадания.
func grant_invulnerability(seconds: float) -> void:
	_invulnerability_left = maxf(_invulnerability_left, seconds)


func _die() -> void:
	if not is_alive:
		return
	is_alive = false
	visible = false
	modulate.a = 1.0
	_drag_touch_index = -1
	died.emit()


func _tick_invulnerability(delta: float) -> void:
	if _invulnerability_left <= 0.0:
		return
	_invulnerability_left = maxf(0.0, _invulnerability_left - delta)
	if _invulnerability_left <= 0.0:
		modulate.a = 1.0
		return
	var blinking := fmod(_invulnerability_left, BLINK_HALF_PERIOD * 2.0) < BLINK_HALF_PERIOD
	modulate.a = 0.35 if blinking else 1.0


# ─── Стрельба ───────────────────────────────────────────────────────────────
func _tick_autofire(delta: float) -> void:
	_fire_cooldown -= delta
	if _fire_cooldown > 0.0:
		return
	_fire_cooldown += fire_interval  # накопление вместо обнуления — стабильный темп
	fire_volley()


## Один «выстрел» = bullets_per_shot снарядов. База: 1 снаряд ровно вверх из MUZZLE_OFFSET
## (800 px/s, урон 1.0) — прежнее поведение M1. «Спарка» добавляет ствол (боковой разнос),
## «Кучность» сужает разброс: веер строится по spread_deg вокруг вертикали.
## Публичный: автострельба и QA/тесты (проверка «сколько снарядов в залпе»).
func fire_volley() -> void:
	var count := maxi(1, bullets_per_shot)
	for index in count:
		var lateral := (float(index) - float(count - 1) * 0.5) * MULTI_BULLET_SPACING
		var angle_deg := 0.0
		if count > 1:
			angle_deg = -spread_deg * 0.5 + spread_deg * float(index) / float(count - 1)
		var velocity := Vector2.UP.rotated(deg_to_rad(angle_deg)) * bullet_speed
		shot_fired.emit(global_position + MUZZLE_OFFSET + Vector2(lateral, 0.0), velocity,
			bullet_damage)


# ─── Ракеты «РС-82» ─────────────────────────────────────────────────────────
func _tick_rockets(delta: float) -> void:
	if not rocket_enabled:
		return
	_rocket_cooldown -= delta
	if _rocket_cooldown > 0.0:
		return
	_rocket_cooldown += maxf(0.05, rocket_interval)
	_fire_rockets()


## Пара ракет вверх; пушки продолжают стрелять своим темпом (GDD: «пушки работают»).
func _fire_rockets() -> void:
	var count := maxi(1, rocket_count)
	for index in count:
		var lateral := (float(index) - float(count - 1) * 0.5) * ROCKET_SPACING
		var origin := global_position + MUZZLE_OFFSET + Vector2(lateral, 0.0)
		rocket_fired.emit(origin, Vector2.UP * ROCKET_SPEED, rocket_damage, rocket_radius)


# ─── Перки (M6.1a) ──────────────────────────────────────────────────────────
## Пересчитать оружие/защиту по активным картам. Всегда от БАЗЫ, поэтому порядок и повторный
## вызов безопасны: множители не накапливаются. Единственный потребитель — PerkSystem.apply_to().
func apply_perks(active_ids: Array[String]) -> void:
	var previous := _applied_perk_ids
	_applied_perk_ids = active_ids.duplicate()
	_reset_perk_fields()

	var damage_mult := 1.0
	var interval_mult := 1.0
	var speed_mult := 1.0
	var spread_mult := 1.0
	var bullets_add := 0
	var max_hp_add := 0
	var invuln_add := 0.0

	for id in active_ids:
		var effects := PerkData.get_effects(id)
		damage_mult *= float(effects.get("bullet_damage_mult", 1.0))
		interval_mult *= float(effects.get("fire_interval_mult", 1.0))
		speed_mult *= float(effects.get("bullet_speed_mult", 1.0))
		spread_mult *= float(effects.get("spread_mult", 1.0))
		bullets_add += int(effects.get("bullets_per_shot_add", 0))
		max_hp_add += int(effects.get("max_hp_add", 0))
		invuln_add += float(effects.get("invuln_time_add", 0.0))
		# «Тяжёлый калибр» не стакается: берём максимум, а не произведение.
		boss_damage_mult = maxf(boss_damage_mult, float(effects.get("boss_damage_mult", 1.0)))
		splash_radius = maxf(splash_radius, float(effects.get("splash_radius", 0.0)))
		splash_ratio = maxf(splash_ratio, float(effects.get("splash_ratio", 0.0)))
		if bool(effects.get("rocket_enabled", false)):
			rocket_enabled = true
			rocket_interval = float(effects.get("rocket_interval", rocket_interval))
			rocket_count = maxi(1, int(effects.get("rocket_count", rocket_count)))
			rocket_damage = float(effects.get("rocket_damage", rocket_damage))
			rocket_radius = float(effects.get("rocket_radius", rocket_radius))
		if bool(effects.get("emergency_clear", false)):
			emergency_clear = true
			emergency_clear_radius = float(effects.get(
				"emergency_clear_radius", emergency_clear_radius))
			emergency_clear_cooldown = float(effects.get(
				"emergency_clear_cooldown", emergency_clear_cooldown))

	# Производные значения — только после суммы множителей (Спарка+Бронебойные+Кучность).
	bullets_per_shot = BASE_BULLETS_PER_SHOT + bullets_add
	bullet_damage = _base_bullet_damage * damage_mult
	fire_interval = _base_fire_interval * interval_mult
	bullet_speed = _base_bullet_speed * speed_mult
	spread_deg = BASE_SPREAD_DEG * spread_mult
	invuln_time = INVULNERABILITY_TIME + invuln_add
	max_hp = MAX_HP + max_hp_add
	if hp > max_hp:
		hp = max_hp

	# «РС-82» только что включён — первый залп через полный интервал, а не в тот же кадр.
	if rocket_enabled and _rocket_cooldown <= 0.0:
		_rocket_cooldown = rocket_interval
	if not rocket_enabled:
		_rocket_cooldown = 0.0

	# «Ремонт»: лечение — за НОВУЮ карту (повторный apply с тем же набором не лечит).
	for id in active_ids:
		if previous.has(id):
			continue
		heal(int(PerkData.get_effects(id).get("heal_on_apply", 0)))


## Вернуть базовые значения ВЫБРАННОГО самолёта (старт миссии, reset, тесты).
## M6.2a: раньше здесь была база Ла-5; теперь — база самолёта из apply_plane().
func reset_perks() -> void:
	_applied_perk_ids.clear()
	_reset_perk_fields()
	hp = mini(hp, max_hp)


## Поля оружия/защиты — в базу самолёта. Отдельный helper, чтобы apply_perks и reset_perks
## не разъезжались в списке полей.
func _reset_perk_fields() -> void:
	bullets_per_shot = BASE_BULLETS_PER_SHOT
	bullet_damage = _base_bullet_damage
	fire_interval = _base_fire_interval
	bullet_speed = _base_bullet_speed
	spread_deg = BASE_SPREAD_DEG
	boss_damage_mult = 1.0
	splash_radius = 0.0
	splash_ratio = 0.0
	rocket_enabled = false
	rocket_interval = ROCKET_INTERVAL
	rocket_count = ROCKET_COUNT
	rocket_damage = ROCKET_DAMAGE
	rocket_radius = ROCKET_RADIUS
	invuln_time = INVULNERABILITY_TIME
	max_hp = MAX_HP
	emergency_clear = false
	emergency_clear_radius = 0.0
	emergency_clear_cooldown = 0.0


## «Аварийный сброс» (GDD): готов ли перк к срабатыванию (кулдаун 6 с).
## Триггер — M6.1b (в take_hit/на уроне); здесь только состояние.
func can_use_emergency_clear() -> bool:
	if not emergency_clear or emergency_clear_cooldown <= 0.0:
		return false
	var elapsed := float(Time.get_ticks_msec() - _emergency_used_msec) / 1000.0
	return elapsed >= emergency_clear_cooldown


func mark_emergency_clear_used() -> void:
	_emergency_used_msec = Time.get_ticks_msec()


## Доступ для QA/тестов: время с последнего «Аварийного сброса», с.
func get_seconds_since_emergency_clear() -> float:
	return float(Time.get_ticks_msec() - _emergency_used_msec) / 1000.0
