# perks_test.gd
# Purpose: Гейт M6.1a «данные перков, слоты и оружейная математика» (GDD «Временные перки»):
#          9 карт (6 оружия + 3 утилиты) из `data/perks.json`, слоты 2+1 без дублей,
#          предложение «1 из 2» без повторов, пересчёт оружия игрока (Спарка / Бронебойные /
#          РС-82 / Осколочные / Кучность / Тяжёлый калибр / Ремонт / Хладнокровие /
#          Аварийный сброс), комбинации множителей и урон по float-HP врагов.
#          UI выбора карт, пауза и триггер после волн — M6.1b, здесь их нет.
#          Тест строит МИНИМАЛЬНОЕ дерево (Player + BulletLayer + враги из сцен): main.tscn,
#          звук, UI и `user://` не трогаются вовсе — ни чтения, ни записи.
# Запуск: godot --headless --path . res://tests/perks_test.tscn
# Author: Mechanics Developer Agent

extends Node

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const BF109_SCENE: PackedScene = preload("res://scenes/enemy_bf109.tscn")
const BOSS_HE111_SCENE: PackedScene = preload("res://scenes/boss_he111.tscn")

## Ожидаемый порядок карт GDD («Временные перки»): 6 оружия, затем 3 утилиты.
const EXPECTED_IDS := [
	"sparka", "ap", "rockets", "shatter", "accuracy", "heavy",
	"repair", "coolhead", "emergency",
]

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0

var _player: Player
var _bullets: BulletLayer
## Контейнер врагов (не LevelController: тест не поднимает уровень и не пишет рекорды).
var _world: Node2D


func _ready() -> void:
	_started_msec = Time.get_ticks_msec()
	await _run()
	print("PERKS_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("PERKS_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_build_tree()
	_check_data()
	await _check_slots()
	await _check_offers()
	_check_effects()
	_check_volley()
	await _check_damage()
	await _check_rocket_and_splash()
	_check_radius_clear()
	_teardown()


# ─── Минимальное дерево ─────────────────────────────────────────────────────
func _build_tree() -> void:
	_world = Node2D.new()
	_world.name = "World"
	add_child(_world)
	_player = PLAYER_SCENE.instantiate() as Player
	_world.add_child(_player)
	# Автострельба в тесте не нужна: залпы проверяются явно (fire_volley).
	_player.set_process(false)
	_bullets = BulletLayer.new()
	_bullets.name = "Bullets"
	_world.add_child(_bullets)


func _teardown() -> void:
	_world.queue_free()
	_player = null
	_bullets = null


## Свежий Bf 109 в дереве (без физики: не двигается и не стреляет).
func _spawn_bf109(at: Vector2) -> EnemyBase:
	var enemy := BF109_SCENE.instantiate() as EnemyBase
	enemy.position = at
	_world.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy


func _spawn_boss(at: Vector2) -> EnemyBase:
	var boss := BOSS_HE111_SCENE.instantiate() as EnemyBase
	boss.position = at
	_world.add_child(boss)
	boss.set_physics_process(false)
	return boss


## Карта через публичный путь Player: тот же вход, что у PerkSystem.apply_to().
func _apply_ids(list: Array) -> void:
	var ids: Array[String] = []
	for id: Variant in list:
		ids.append(String(id))
	_player.apply_perks(ids)


# ─── Данные ─────────────────────────────────────────────────────────────────
func _check_data() -> void:
	var errors := PerkData.validate()
	_check("данные: PerkData.validate() без ошибок", errors.is_empty(), str(errors))
	_check("данные: файл data/perks.json существует",
		FileAccess.file_exists(PerkData.DATA_PATH), PerkData.DATA_PATH)
	var cards := PerkData.get_all()
	_check("данные: 9 карт", cards.size() == 9, str(cards.size()))
	var weapons := PerkData.get_by_category(PerkData.CATEGORY_WEAPON)
	var utilities := PerkData.get_by_category(PerkData.CATEGORY_UTILITY)
	_check("данные: 6 карт оружия", weapons.size() == 6, str(weapons.size()))
	_check("данные: 3 карты утилиты", utilities.size() == 3, str(utilities.size()))
	var expected: Array[String] = []
	for id: String in EXPECTED_IDS:
		expected.append(id)
	_check("данные: id и порядок как в GDD", PerkData.get_ids() == expected,
		str(PerkData.get_ids()))
	var texts_ok := true
	var bad := ""
	for id: String in PerkData.get_ids():
		if PerkData.get_card_name(id).is_empty() \
				or PerkData.get_card_description(id).is_empty():
			texts_ok = false
			bad = id
	_check("данные: у всех карт есть name и description", texts_ok, bad)
	_check("данные: неизвестная карта → {} и пустые эффекты",
		PerkData.get_card("nope").is_empty() and PerkData.get_effects("nope").is_empty()
		and not PerkData.has_card("nope"))
	_check("данные: слоты из данных 2 оружия + 1 утилита",
		PerkData.get_slot_count(PerkData.CATEGORY_WEAPON) == 2
		and PerkData.get_slot_count(PerkData.CATEGORY_UTILITY) == 1,
		"%d + %d" % [PerkData.get_slot_count(PerkData.CATEGORY_WEAPON),
			PerkData.get_slot_count(PerkData.CATEGORY_UTILITY)])


# ─── Слоты ──────────────────────────────────────────────────────────────────
func _check_slots() -> void:
	var system := PerkSystem.new()
	system.name = "PerkSystem"
	add_child(system)
	var changes: Array = []
	system.changed.connect(func(active: Array) -> void: changes.append(active.size()))

	_check("слоты: новая система пуста, доступны все 9 карт",
		system.get_active().is_empty() and system.available_cards().size() == 9,
		"активных %d, доступно %d" % [system.get_active().size(),
			system.available_cards().size()])
	_check("слоты: первое оружие берётся", system.take("sparka"), "sparka")
	_check("слоты: второе оружие берётся", system.take("ap"), "ap")
	_check("слоты: третье оружие отклоняется",
		not system.take("heavy") and system.get_active_by_category(
			PerkData.CATEGORY_WEAPON).size() == 2,
		str(system.get_active()))
	_check("слоты: утилита берётся", system.take("repair"), "repair")
	_check("слоты: вторая утилита отклоняется",
		not system.take("coolhead") and system.get_active_by_category(
			PerkData.CATEGORY_UTILITY).size() == 1,
		str(system.get_active()))
	_check("слоты: дубль отклоняется", not system.take("sparka"), str(system.get_active()))
	_check("слоты: неизвестный id отклоняется", not system.take("nope"))
	_check("слоты: сигнал changed эмитится на каждое успешное взятие (3)",
		changes == [1, 2, 3], str(changes))
	_check("слоты: при занятых слотах доступных карт нет",
		system.available_cards().is_empty(), str(system.available_cards()))
	# apply_to() — единственный путь от системы к игроку (так карты и попадут в забег).
	_player.reset_perks()
	system.apply_to(_player)
	_check("слоты: apply_to() переносит активные карты в оружие игрока",
		_player.bullets_per_shot == 2
		and is_equal_approx(_player.bullet_damage, 1.7)
		and _player.max_hp == 4,
		"%d × %.2f, hp %d/%d" % [_player.bullets_per_shot, _player.bullet_damage,
			_player.hp, _player.max_hp])
	_player.reset_perks()
	system.reset()
	_check("слоты: reset() очищает активные и возвращает 9 карт",
		system.get_active().is_empty() and system.available_cards().size() == 9
		and changes.size() == 4,
		"активных %d, доступно %d, сигналов %d" % [system.get_active().size(),
			system.available_cards().size(), changes.size()])
	await get_tree().process_frame
	system.queue_free()
	await get_tree().process_frame


# ─── Предложение «1 из 2» ───────────────────────────────────────────────────
func _check_offers() -> void:
	var system := PerkSystem.new()
	system.name = "OffersSystem"
	add_child(system)
	var offers := system.roll_offers(2)
	var available := system.available_cards()
	_check("предложение: 2 карты из доступных без дублей",
		offers.size() == 2 and offers[0] != offers[1]
		and available.has(offers[0]) and available.has(offers[1]),
		str(offers))
	_check("предложение: roll_offers(1) — ровно одна карта",
		system.roll_offers(1).size() == 1)
	_check("предложение: roll_offers(0) — пусто", system.roll_offers(0).is_empty())
	var all_offers := system.roll_offers(99)
	_check("предложение: count больше доступных — вернутся все доступные (9)",
		all_offers.size() == 9, str(all_offers.size()))

	# Воспроизводимость по seed (UI M6.1b будет полагаться на разные seed).
	var left := RandomNumberGenerator.new()
	left.seed = 123456
	var right := RandomNumberGenerator.new()
	right.seed = 123456
	var first := system.roll_offers(2, left)
	var second := system.roll_offers(2, right)
	_check("предложение: одинаковый seed → одинаковые карты", first == second,
		"%s / %s" % [first, second])

	# Занятые карты и занятые слоты не предлагаются: берём 1 оружие + 1 утилиту,
	# во втором слоте оружия остаются только 5 карт оружия.
	system.take("sparka")
	system.take("repair")
	var after := system.available_cards()
	_check("предложение: при 1 свободном слоте оружия доступны только 5 карт оружия",
		after.size() == 5 and not after.has("sparka") and not after.has("coolhead")
		and not after.has("emergency"), str(after))
	var offers_after := system.roll_offers(2)
	var offers_ok := offers_after.size() == 2
	var bad := ""
	for id in offers_after:
		if not after.has(id) or system.get_active().has(id):
			offers_ok = false
			bad = id
	_check("предложение: не предлагает занятые карты и занятые слоты", offers_ok,
		"%s из %s (плохая: %s)" % [offers_after, after, bad])
	system.queue_free()
	await get_tree().process_frame


# ─── Эффекты по одной карте ─────────────────────────────────────────────────
func _check_effects() -> void:
	_player.reset_perks()
	_apply_ids(["sparka"])
	_check("эффект Спарка: 2 снаряда, урон 0.85",
		_player.bullets_per_shot == 2 and is_equal_approx(_player.bullet_damage, 0.85),
		"%d снаряда, урон %.2f" % [_player.bullets_per_shot, _player.bullet_damage])

	_player.reset_perks()
	_apply_ids(["ap"])
	_check("эффект Бронебойные: урон 2.0, интервал 0.175",
		is_equal_approx(_player.bullet_damage, 2.0)
		and is_equal_approx(_player.fire_interval, 0.175),
		"урон %.2f, интервал %.3f" % [_player.bullet_damage, _player.fire_interval])

	_player.reset_perks()
	_apply_ids(["rockets"])
	_check("эффект РС-82: флаг, 3 с, 2 ракеты, 4 урона, радиус 40",
		_player.rocket_enabled
		and is_equal_approx(_player.rocket_interval, 3.0)
		and _player.rocket_count == 2
		and is_equal_approx(_player.rocket_damage, 4.0)
		and is_equal_approx(_player.rocket_radius, 40.0),
		"флаг=%s, интервал %.1f, %d × %.1f, r=%.0f" % [_player.rocket_enabled,
			_player.rocket_interval, _player.rocket_count, _player.rocket_damage,
			_player.rocket_radius])

	_player.reset_perks()
	_apply_ids(["shatter"])
	_check("эффект Осколочные: радиус 28, доля 0.5",
		is_equal_approx(_player.splash_radius, 28.0)
		and is_equal_approx(_player.splash_ratio, 0.5),
		"r=%.0f, доля %.2f" % [_player.splash_radius, _player.splash_ratio])

	_player.reset_perks()
	_apply_ids(["accuracy"])
	_check("эффект Кучность: скорость 1120, урон 1.1, разброс 0",
		is_equal_approx(_player.bullet_speed, 1120.0)
		and is_equal_approx(_player.bullet_damage, 1.1)
		and is_equal_approx(_player.spread_deg, 0.0),
		"скорость %.0f, урон %.2f, разброс %.1f" % [_player.bullet_speed,
			_player.bullet_damage, _player.spread_deg])

	_player.reset_perks()
	_apply_ids(["heavy"])
	_check("эффект Тяжёлый калибр: урон по боссу ×1.3",
		is_equal_approx(_player.boss_damage_mult, 1.3),
		"×%.2f" % _player.boss_damage_mult)

	_player.reset_perks()
	_apply_ids(["repair"])
	_check("эффект Ремонт: +1 HP, потолок 4",
		_player.max_hp == 4 and _player.hp == 4,
		"hp %d/%d" % [_player.hp, _player.max_hp])

	_player.reset_perks()
	_apply_ids(["coolhead"])
	_check("эффект Хладнокровие: неуязвимость 2.5 с",
		is_equal_approx(_player.invuln_time, 2.5), "%.1f с" % _player.invuln_time)

	_player.reset_perks()
	_apply_ids(["emergency"])
	_check("эффект Аварийный сброс: флаг, радиус 120, кулдаун 6 с",
		_player.emergency_clear
		and is_equal_approx(_player.emergency_clear_radius, 120.0)
		and is_equal_approx(_player.emergency_clear_cooldown, 6.0),
		"флаг=%s, r=%.0f, кд=%.0f" % [_player.emergency_clear,
			_player.emergency_clear_radius, _player.emergency_clear_cooldown])
	_check("эффект Аварийный сброс: первый сброс доступен сразу",
		_player.can_use_emergency_clear())

	# Комбинация: множители перемножаются, число снарядов складывается.
	_player.reset_perks()
	_apply_ids(["sparka", "ap"])
	_check("комбинация Спарка + Бронебойные: 2 снаряда, урон 1.7, интервал 0.175",
		_player.bullets_per_shot == 2
		and is_equal_approx(_player.bullet_damage, 1.7)
		and is_equal_approx(_player.fire_interval, 0.175),
		"%d × %.2f, %.3f" % [_player.bullets_per_shot, _player.bullet_damage,
			_player.fire_interval])

	# Повторный apply с тем же набором не лечит ещё раз («Ремонт» — только за новую карту).
	var hp_before := _player.hp
	_apply_ids(["sparka", "ap"])
	_check("комбинация: повторный apply_perks не накапливает эффекты",
		_player.bullets_per_shot == 2
		and is_equal_approx(_player.bullet_damage, 1.7)
		and _player.hp == hp_before,
		"%d × %.2f, hp %d" % [_player.bullets_per_shot, _player.bullet_damage,
			_player.hp])

	_player.reset_perks()
	_check("сброс: reset_perks() возвращает базу Ла-5",
		_player.bullets_per_shot == 1
		and is_equal_approx(_player.bullet_damage, 1.0)
		and is_equal_approx(_player.fire_interval, 0.125)
		and is_equal_approx(_player.bullet_speed, 800.0)
		and is_equal_approx(_player.spread_deg, 0.0)
		and is_equal_approx(_player.boss_damage_mult, 1.0)
		and is_equal_approx(_player.splash_radius, 0.0)
		and is_equal_approx(_player.splash_ratio, 0.0)
		and not _player.rocket_enabled
		and is_equal_approx(_player.invuln_time, 1.5)
		and _player.max_hp == 3
		and not _player.emergency_clear,
		"%d × %.2f @ %.3f, hp %d" % [_player.bullets_per_shot, _player.bullet_damage,
			_player.fire_interval, _player.max_hp])


# ─── Залп ───────────────────────────────────────────────────────────────────
func _check_volley() -> void:
	var shots: Array = []
	var handler := func(origin: Vector2, velocity: Vector2, damage: float) -> void:
		shots.append({"origin": origin, "velocity": velocity, "damage": damage})
	_player.shot_fired.connect(handler)

	_player.reset_perks()
	_player.fire_volley()
	var base_ok := shots.size() == 1
	if base_ok:
		var origin: Vector2 = shots[0]["origin"]
		var velocity: Vector2 = shots[0]["velocity"]
		base_ok = velocity.is_equal_approx(Vector2(0.0, -800.0)) \
			and origin.is_equal_approx(_player.position + Player.MUZZLE_OFFSET) \
			and is_equal_approx(float(shots[0]["damage"]), 1.0)
	_check("залп: база — 1 снаряд ровно вверх из дула, урон 1.0", base_ok, str(shots))

	shots.clear()
	_apply_ids(["sparka"])
	_player.fire_volley()
	var sparka_ok := shots.size() == 2
	if sparka_ok:
		var left_origin: Vector2 = shots[0]["origin"]
		var right_origin: Vector2 = shots[1]["origin"]
		sparka_ok = absf(right_origin.x - left_origin.x) > 0.0 \
			and (shots[0]["velocity"] as Vector2).is_equal_approx(Vector2(0.0, -800.0)) \
			and (shots[1]["velocity"] as Vector2).is_equal_approx(Vector2(0.0, -800.0)) \
			and is_equal_approx(float(shots[0]["damage"]), 0.85) \
			and is_equal_approx(float(shots[1]["damage"]), 0.85)
	_check("залп: Спарка — 2 снаряда параллельно вверх, урон 0.85 каждый",
		sparka_ok, str(shots))
	_player.shot_fired.disconnect(handler)
	_player.reset_perks()


# ─── Урон (float HP) ────────────────────────────────────────────────────────
func _check_damage() -> void:
	# База: 1 урон × 4 попадания убивает Bf 109 (4 HP).
	var base := _spawn_bf109(Vector2(100.0, 200.0))
	var hits := 0
	var destroyed := false
	while hits < 6 and not destroyed:
		hits += 1
		destroyed = base.take_damage(1.0)
	_check("урон: база — Bf 109 умирает за 4 попадания", destroyed and hits == 4,
		"%d попаданий" % hits)

	# Бронебойные: урон 2.0 → 2 попадания.
	_player.reset_perks()
	_apply_ids(["ap"])
	var ap := _spawn_bf109(Vector2(100.0, 200.0))
	var ap_damage := _player.bullet_damage
	var ap_hits := 0
	var ap_destroyed := false
	while ap_hits < 6 and not ap_destroyed:
		ap_hits += 1
		ap_destroyed = ap.take_damage(ap_damage)
	_check("урон: Бронебойные (×2) — Bf 109 умирает за 2 попадания",
		ap_destroyed and ap_hits == 2, "%.1f урона, %d попаданий" % [ap_damage, ap_hits])

	# Спарка: 0.85 × 5 = 4.25 → 5 попаданий (4 дают только 3.4).
	_player.reset_perks()
	_apply_ids(["sparka"])
	var sparka := _spawn_bf109(Vector2(100.0, 200.0))
	var sparka_damage := _player.bullet_damage
	var sparka_hits := 0
	var sparka_destroyed := false
	while sparka_hits < 8 and not sparka_destroyed:
		sparka_hits += 1
		sparka_destroyed = sparka.take_damage(sparka_damage)
	_check("урон: Спарка (×0.85) — Bf 109 умирает за 5 попаданий (4.25)",
		sparka_destroyed and sparka_hits == 5,
		"%.2f урона, %d попаданий" % [sparka_damage, sparka_hits])

	# Босс: «Тяжёлый калибр» ×1.3 к урону игрока по боссу.
	_player.reset_perks()
	_apply_ids(["heavy"])
	var boss := _spawn_boss(Vector2(270.0, 120.0))
	var boss_hp_before := boss.hp
	boss.take_damage(_player.bullet_damage * _player.boss_damage_mult)
	_check("урон: босс получает ×1.3 от «Тяжёлого калибра» (120 → 118.7)",
		is_equal_approx(boss_hp_before, 120.0) and is_equal_approx(boss.hp, 118.7),
		"%.2f → %.2f" % [boss_hp_before, boss.hp])
	_player.reset_perks()
	boss.take_damage(_player.bullet_damage)
	_check("урон: без перка босс получает ровно 1.0 (обычный урон)",
		is_equal_approx(boss.hp, 117.7), "%.2f" % boss.hp)
	if is_instance_valid(boss):
		boss.despawn()

	# Контракт health_changed: int, живой враг никогда не отдаёт 0.
	var reported: Array = []
	var hp_handler := func(hp: int) -> void: reported.append(hp)
	var wounded := _spawn_bf109(Vector2(100.0, 200.0))
	wounded.health_changed.connect(hp_handler)
	wounded.hp = 0.4
	wounded.take_damage(0.1)
	var alive_report: int = reported[-1] if not reported.is_empty() else -1
	wounded.take_damage(1.0)
	var death_report: int = reported[-1] if not reported.is_empty() else -1
	_check("урон: health_changed(int) — живой отдаёт 1, смертельный удар 0",
		alive_report == 1 and death_report == 0,
		"живой %d, смерть %d" % [alive_report, death_report])
	if is_instance_valid(wounded):
		wounded.health_changed.disconnect(hp_handler)
		wounded.despawn()
	await get_tree().process_frame


# ─── Ракета и осколки ───────────────────────────────────────────────────────
func _check_rocket_and_splash() -> void:
	# Ракета: тот же Bullet с is_rocket, урон 4, радиус 40, полный урон в радиусе.
	var rocket := _bullets.spawn_rocket(Vector2(100.0, 700.0),
		Vector2.UP * Player.ROCKET_SPEED, 4.0, 40.0)
	_check("ракета: урон 4 / радиус 40 / is_rocket / splash 100%",
		rocket != null
		and is_equal_approx(rocket.damage, 4.0)
		and is_equal_approx(rocket.splash_radius, 40.0)
		and rocket.is_rocket
		and is_equal_approx(rocket.splash_ratio, 1.0),
		"урон %.1f, r=%.0f, ракета=%s, доля %.1f" % [rocket.damage,
			rocket.splash_radius, rocket.is_rocket, rocket.splash_ratio])
	rocket.despawn()
	# «Тяжёлый калибр» доходит и до ракет (LevelController передаёт player.boss_damage_mult).
	var heavy_rocket := _bullets.spawn_rocket(Vector2(100.0, 700.0),
		Vector2.UP * Player.ROCKET_SPEED, 4.0, 40.0, 1.3)
	_check("ракета: множитель урона по боссу доходит до снаряда (1.3)",
		heavy_rocket != null and is_equal_approx(heavy_rocket.boss_damage_mult, 1.3),
		"×%.2f" % (heavy_rocket.boss_damage_mult if heavy_rocket != null else -1.0))
	heavy_rocket.despawn()

	# Осколочные: полный урон цели + 50% соседям в радиусе 28; босс осколков не получает.
	# Снаряд ставится в точку цели, соседи — в 15/20/70 px от неё.
	var target := _spawn_bf109(Vector2(200.0, 400.0))
	var neighbor := _spawn_bf109(Vector2(215.0, 400.0))
	var far := _spawn_bf109(Vector2(200.0, 470.0))
	var boss := _spawn_boss(Vector2(200.0, 420.0))
	var boss_hp_before := boss.hp
	_bullets.fire_player(Vector2(200.0, 400.0), Vector2.UP * 800.0, 1.0, 1.0, 28.0, 0.5)
	var bullet := _bullets.get_child(_bullets.get_child_count() - 1) as Bullet
	# Прямой вызов обработчика: проверяется правило осколков, а не физика (детерминизм).
	bullet._on_area_entered(target)
	await get_tree().process_frame
	_check("осколки: цель получает полный урон 1.0 (4 → 3)",
		is_instance_valid(target) and is_equal_approx(target.hp, 3.0),
		"%.2f" % (target.hp if is_instance_valid(target) else -1.0))
	_check("осколки: сосед в радиусе 28 получает 50% (4 → 3.5)",
		is_instance_valid(neighbor) and is_equal_approx(neighbor.hp, 3.5),
		"%.2f" % (neighbor.hp if is_instance_valid(neighbor) else -1.0))
	_check("осколки: враг вне радиуса не задет (4 → 4)",
		is_instance_valid(far) and is_equal_approx(far.hp, 4.0),
		"%.2f" % (far.hp if is_instance_valid(far) else -1.0))
	_check("осколки: босс не получает осколочный урон",
		is_instance_valid(boss) and is_equal_approx(boss.hp, boss_hp_before),
		"%.2f → %.2f" % [boss_hp_before,
			boss.hp if is_instance_valid(boss) else -1.0])

	for enemy: EnemyBase in [target, neighbor, far, boss]:
		if is_instance_valid(enemy):
			enemy.despawn()
	await get_tree().process_frame


# ─── «Аварийный сброс»: радиальная очистка пуль ─────────────────────────────
func _check_radius_clear() -> void:
	_bullets.clear_all()
	_bullets.fire_enemy(Vector2(100.0, 100.0), Vector2.DOWN * 200.0, 1)
	_bullets.fire_enemy(Vector2(110.0, 100.0), Vector2.DOWN * 200.0, 1)
	_bullets.fire_enemy(Vector2(400.0, 400.0), Vector2.DOWN * 200.0, 1)
	_bullets.fire_player(Vector2(100.0, 600.0), Vector2.UP * 800.0, 1.0)
	var cleared := _bullets.clear_enemy_bullets_in_radius(Vector2(100.0, 100.0), 120.0)
	_check("аварийный сброс: в радиусе 120 чистятся 2 вражеские пули",
		cleared == 2, "очищено %d" % cleared)
	_check("аварийный сброс: пуля вне радиуса и снаряд игрока остаются",
		_bullets.count_bullets(true) == 1 and _bullets.count_bullets() == 2,
		"вражеских %d, всего %d" % [_bullets.count_bullets(true),
			_bullets.count_bullets()])
	_check("аварийный сброс: нулевой радиус ничего не чистит",
		_bullets.clear_enemy_bullets_in_radius(Vector2(400.0, 400.0), 0.0) == 0)
	_bullets.clear_all()


# ─── Хелпер проверок ────────────────────────────────────────────────────────
func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
