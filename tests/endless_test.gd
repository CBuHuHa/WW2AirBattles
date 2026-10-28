# endless_test.gd
# Purpose: Гейт M6.3a — бесконечный режим БЕЗ UI (GDD «Бесконечный режим»). Проверяет:
#            • формулы EndlessRules: плотность, скорости, HP, боссы по кругу, множитель счёта,
#              волны босса/ремкомплекта/перка, детерминированный состав;
#            • WaveManager в режиме ENDLESS: волна 1 (3 Bf 109), рост плотности, полоса X
#              80…460 и чередование глубины, босс после волны 10 (He 111, круг 0) и после
#              continue_after_boss — следующая волна (не победа), is_active на всём пути;
#            • apply_difficulty: HP/скорость корпуса/скорость пуль, «не дважды», HP после
#              20-й волны (Bf 110 волны 21: 16 → 16.96, скорость 1.3, пули 1.5);
#            • ремкомплект: 5/10/15 волны — один подбор за волну, на 6-й — нет;
#            • LevelController: старт endless без брифинга, множитель счёта 1.05, перки
#              каждые 2 волны (и НЕ на 3), гибель босса не завершает забег, смерть пишет
#              отдельный рекорд (очки + волна, только вверх), режим кампании не изменился;
#            • SaveGame.is_endless_unlocked(): нужны ≥1 звезды во всех трёх миссиях.
#          Сейв изолирован в user://qa_endless_*.cfg: реальный профиль игрока не читается,
#          не создаётся и не перезаписывается (слепок до/после).
# Запуск: godot --headless --path . res://tests/endless_test.tscn
# Dependencies: EndlessRules, WaveManager, LevelController, EnemyBase/EnemyBf109, SaveGame.
# Author: Mechanics Developer Agent

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")

const M1 := "m1_airfield"
const M2 := "m2_crossing"
const M3 := "m3_city"

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона (сейв + legacy-рекорд идут в него).
var _path: String = ""
var _real_snapshot: Dictionary = {}
var _level: LevelController
## Контейнер для изолированных бортов (проверка apply_difficulty без уровня).
var _holder: Node2D
## Исходы run_finished в порядке эмита: [{"won": bool, "score": int}].
var _run_events: Array = []


func _ready() -> void:
	# Тест живёт и при get_tree().paused (проверка паузы выбора перка/экрана смерти).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	# Слепок реального профиля ДО любых операций с сейвом.
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_endless_%d.cfg" % _started_msec
	RunRecord.set_save_path(_path)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
	_holder = Node2D.new()
	_holder.name = "EndlessTestHolder"
	add_child(_holder)
	await _run()
	# Уборка: уровень, держатель, файл прогона, путь по умолчанию.
	if _level != null:
		_level.queue_free()
		_level = null
	_holder.queue_free()
	await get_tree().process_frame
	_remove_run_file()
	RunRecord.reset_save_path()
	_check("изоляция: путь вернулся к DEFAULT_PATH и qa-файл удалён",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH and not FileAccess.file_exists(_path),
		SaveGame.get_save_path())
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_snapshot, _file_snapshot(RunRecord.DEFAULT_PATH)),
		"%s → %s" % [_snapshot_brief(_real_snapshot),
			_snapshot_brief(_file_snapshot(RunRecord.DEFAULT_PATH))])
	_check("изоляция: дерево не осталось на паузе", not get_tree().paused,
		str(get_tree().paused))
	print("ENDLESS_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("ENDLESS_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


## Удалить qa-файл прогона (мог не создаться вовсе — тогда просто нет файла).
func _remove_run_file() -> void:
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))


func _run() -> void:
	_check_rules()
	await _check_start()
	await _check_wave_plan()
	await _check_wave_growth()
	_check_difficulty()
	await _check_hp_scaling_runtime()
	await _check_repair_waves()
	await _check_boss_endless()
	await _check_perks_every_two_waves()
	await _check_death_record()
	_check_endless_unlock()
	await _check_campaign_unchanged()


# ─── Формулы правил (M6.3a) ─────────────────────────────────────────────────
func _check_rules() -> void:
	_check("правила: врагов 3 / 4 / 8 / 12 на волнах 1/2/10/22",
		EndlessRules.enemy_count(1) == 3 and EndlessRules.enemy_count(2) == 4
		and EndlessRules.enemy_count(10) == 8 and EndlessRules.enemy_count(22) == 12,
		"%d/%d/%d/%d" % [EndlessRules.enemy_count(1), EndlessRules.enemy_count(2),
			EndlessRules.enemy_count(10), EndlessRules.enemy_count(22)])
	_check("правила: плотность клампится 3…12 (волна 0 и 40)",
		EndlessRules.enemy_count(0) == 3 and EndlessRules.enemy_count(40) == 12,
		"%d/%d" % [EndlessRules.enemy_count(0), EndlessRules.enemy_count(40)])
	_check("правила: скорость врагов 1.0 / 1.015 / 1.135 / 1.3",
		_approx(EndlessRules.enemy_speed_mult(1), 1.0)
		and _approx(EndlessRules.enemy_speed_mult(2), 1.015)
		and _approx(EndlessRules.enemy_speed_mult(10), 1.135)
		and _approx(EndlessRules.enemy_speed_mult(21), 1.3),
		"%.3f" % EndlessRules.enemy_speed_mult(21))
	_check("правила: скорость врагов упирается в 1.5 (+50%)",
		_approx(EndlessRules.enemy_speed_mult(35), 1.5)
		and _approx(EndlessRules.enemy_speed_mult(60), 1.5),
		"%.3f" % EndlessRules.enemy_speed_mult(60))
	_check("правила: скорость пуль 1.0 / 1.025 / 1.475 на волнах 1/2/20",
		_approx(EndlessRules.bullet_speed_mult(1), 1.0)
		and _approx(EndlessRules.bullet_speed_mult(2), 1.025)
		and _approx(EndlessRules.bullet_speed_mult(20), 1.475),
		"%.3f" % EndlessRules.bullet_speed_mult(20))
	_check("правила: скорость пуль упирается в 1.8 (+80%)",
		_approx(EndlessRules.bullet_speed_mult(33), 1.8)
		and _approx(EndlessRules.bullet_speed_mult(50), 1.8),
		"%.3f" % EndlessRules.bullet_speed_mult(50))
	_check("правила: HP врагов не растёт до 20-й волны",
		_approx(EndlessRules.hp_mult(1), 1.0) and _approx(EndlessRules.hp_mult(20), 1.0))
	_check("правила: HP врагов +6% с 21-й волны (1.06 / 1.6 на 30-й)",
		_approx(EndlessRules.hp_mult(21), 1.06) and _approx(EndlessRules.hp_mult(30), 1.6),
		"%.2f/%.2f" % [EndlessRules.hp_mult(21), EndlessRules.hp_mult(30)])
	_check("правила: босс по кругу he111 → ju88 → fw200 → he111",
		EndlessRules.boss_type(0) == "he111" and EndlessRules.boss_type(1) == "ju88"
		and EndlessRules.boss_type(2) == "fw200" and EndlessRules.boss_type(3) == "he111",
		"%s/%s/%s/%s" % [EndlessRules.boss_type(0), EndlessRules.boss_type(1),
			EndlessRules.boss_type(2), EndlessRules.boss_type(3)])
	_check("правила: HP босса ×(1 + 0.15 × круг): 1.0 / 1.15 / 1.3 / 1.45",
		_approx(EndlessRules.boss_hp_mult(0), 1.0)
		and _approx(EndlessRules.boss_hp_mult(1), 1.15)
		and _approx(EndlessRules.boss_hp_mult(2), 1.3)
		and _approx(EndlessRules.boss_hp_mult(3), 1.45),
		"%.2f" % EndlessRules.boss_hp_mult(3))
	_check("правила: множитель счёта 1.0 / 1.05 / 1.1025 после 0/1/2 волн",
		_approx(EndlessRules.score_multiplier(0), 1.0)
		and _approx(EndlessRules.score_multiplier(1), 1.05)
		and _approx(EndlessRules.score_multiplier(2), 1.1025),
		"%.4f" % EndlessRules.score_multiplier(2))
	_check("правила: множитель счёта растёт как 1.05^n (10 волн ≈ 1.629)",
		_approx(EndlessRules.score_multiplier(10), 1.6288946267774414, 0.0000001),
		"%.6f" % EndlessRules.score_multiplier(10))
	_check("правила: босс на 10/20/30, но не на 9/11/1",
		EndlessRules.is_boss_wave(10) and EndlessRules.is_boss_wave(20)
		and EndlessRules.is_boss_wave(30) and not EndlessRules.is_boss_wave(9)
		and not EndlessRules.is_boss_wave(11) and not EndlessRules.is_boss_wave(1))
	_check("правила: ремкомплект на 5/10/15, не на 6/14",
		EndlessRules.is_repair_wave(5) and EndlessRules.is_repair_wave(10)
		and EndlessRules.is_repair_wave(15) and not EndlessRules.is_repair_wave(6)
		and not EndlessRules.is_repair_wave(14))
	_check("правила: перки на 2/4, не на 3/5",
		EndlessRules.is_perk_wave(2) and EndlessRules.is_perk_wave(4)
		and not EndlessRules.is_perk_wave(3) and not EndlessRules.is_perk_wave(5))
	_check("правила: состав 1–4 — только Bf 109",
		EndlessRules.enemy_type_for(1, 0) == "bf109"
		and EndlessRules.enemy_type_for(4, 5) == "bf109",
		EndlessRules.enemy_type_for(4, 5))
	_check("правила: состав 5–9 — Bf 109 / Ju 87",
		EndlessRules.enemy_type_for(5, 0) == "bf109"
		and EndlessRules.enemy_type_for(5, 1) == "ju87"
		and EndlessRules.enemy_type_for(9, 3) == "ju87",
		"%s/%s" % [EndlessRules.enemy_type_for(5, 0), EndlessRules.enemy_type_for(5, 1)])
	_check("правила: состав 10–14 — Ju 87 / Fw 190",
		EndlessRules.enemy_type_for(10, 0) == "ju87"
		and EndlessRules.enemy_type_for(10, 1) == "fw190"
		and EndlessRules.enemy_type_for(14, 2) == "ju87",
		"%s/%s" % [EndlessRules.enemy_type_for(10, 0), EndlessRules.enemy_type_for(10, 1)])
	_check("правила: состав 15+ — Fw 190 / Bf 110 (Bf 110 с 15-й)",
		EndlessRules.enemy_type_for(15, 0) == "fw190"
		and EndlessRules.enemy_type_for(15, 1) == "bf110"
		and EndlessRules.enemy_type_for(20, 1) == "bf110",
		"%s/%s" % [EndlessRules.enemy_type_for(15, 0), EndlessRules.enemy_type_for(15, 1)])


# ─── Старт endless на реальной main.tscn ────────────────────────────────────
func _check_start() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame
	_level.set_perks_enabled(false)
	_level.run_finished.connect(_on_run_finished)
	# Кампанийный забег ДО endless: проверяем, что endless не подменяет миссию.
	_level.start_mission(M2)
	await get_tree().process_frame
	_check("старт: перед endless идёт кампанийная миссия m2",
		_level.get_mission_id() == M2 and _level.get_mode() == LevelController.Mode.CAMPAIGN,
		_level.get_mission_id())
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_check("старт: LevelController в режиме ENDLESS, PLAYING",
		_level.get_mode() == LevelController.Mode.ENDLESS and _level.is_endless()
		and _level.get_state() == LevelController.State.PLAYING,
		"mode=%d state=%d" % [_level.get_mode(), _level.get_state()])
	_check("старт: WaveManager в endless, волна 1 активна",
		_level.waves.is_endless() and _level.waves.get_mode() == WaveManager.Mode.ENDLESS
		and _level.waves.is_active() and _level.waves.get_wave_number() == 1,
		"wave=%d active=%s" % [_level.waves.get_wave_number(), _level.waves.is_active()])
	_check("старт: волна 1 — 3 Bf 109 (план совпал со спавном)",
		_level.waves.get_alive_count() == 3 and _count_type("bf109") == 3,
		"живых %d, bf109 %d" % [_level.waves.get_alive_count(), _count_type("bf109")])
	_check("старт: счёт 0, множитель 1.0, волн пройдено 0",
		_level.get_score() == 0 and _approx(_level.get_score_multiplier(), 1.0)
		and _level.get_waves_cleared() == 0,
		"score=%d mult=%.2f" % [_level.get_score(), _level.get_score_multiplier()])
	_check("старт: без брифинга и подсказок, HUD и бомба на месте",
		not _level.briefing.visible and not _level.hints.visible and _level.hud.visible
		and _level.get_bombs() == LevelController.BOMBS_AT_START,
		"briefing=%s hints=%s" % [_level.briefing.visible, _level.hints.visible])
	_check("старт: фиксированного списка волн нет (get_wave_count = 0)",
		_level.waves.get_wave_count() == 0, str(_level.waves.get_wave_count()))
	_check("старт: миссия кампании не подменена endless-забегом",
		_level.get_mission_id() == M2, _level.get_mission_id())


func _check_wave_plan() -> void:
	var plan1: Array = _level.waves.get_endless_wave_plan(1)
	var xs: Array[float] = []
	for item: Dictionary in plan1:
		xs.append((item.get("position", Vector2.ZERO) as Vector2).x)
	_check("план: волна 1 — 3 точки, x = 80 / 270 / 460 (симметрично)",
		plan1.size() == 3 and _approx(xs[0], 80.0) and _approx(xs[1], 270.0)
		and _approx(xs[2], 460.0), str(xs))
	_check("план: глубина чередуется default/back по чётности слота",
		String(plan1[0].get("depth", "")) == "default"
		and String(plan1[1].get("depth", "")) == "back"
		and String(plan1[2].get("depth", "")) == "default",
		"%s/%s/%s" % [plan1[0].get("depth"), plan1[1].get("depth"), plan1[2].get("depth")])
	var plan12: Array = _level.waves.get_endless_wave_plan(12)
	var first_x := (plan12[0].get("position", Vector2.ZERO) as Vector2).x
	var last_x := (plan12[plan12.size() - 1].get("position", Vector2.ZERO) as Vector2).x
	_check("план: волна 12 — 9 бортов в полосе 80…460",
		plan12.size() == 9 and _approx(first_x, 80.0) and _approx(last_x, 460.0),
		"%d бортов, %s…%s" % [plan12.size(), first_x, last_x])
	var plan20: Array = _level.waves.get_endless_wave_plan(20)
	_check("план: волна 20 — потолок 12 бортов, шаг 380/11",
		plan20.size() == 12
		and _approx((plan20[1].get("position", Vector2.ZERO) as Vector2).x, 80.0 + 380.0 / 11.0),
		"%d бортов" % plan20.size())


# ─── Рост плотности и множитель счёта ──────────────────────────────────────
func _check_wave_growth() -> void:
	_kill_all_enemies()
	await get_tree().process_frame
	_check("рост: волна 1 закрыта → 3×100 + бонус 250 × 1.05 = 563, множитель 1.05",
		_level.get_score() == 563 and _approx(_level.get_score_multiplier(), 1.05)
		and _level.get_waves_cleared() == 1,
		"score=%d mult=%.3f cleared=%d" % [_level.get_score(),
			_level.get_score_multiplier(), _level.get_waves_cleared()])
	var next := await _wait_wave(2, 5.0)
	_check("рост: после брейка пришла волна 2 (4 борта)",
		next and _level.waves.get_wave_number() == 2
		and _level.waves.get_alive_count() == 4,
		"wave=%d alive=%d" % [_level.waves.get_wave_number(), _level.waves.get_alive_count()])
	var before := _level.get_score()
	var victim := _first_alive()
	if victim != null:
		victim.take_damage(9999.0)
	await get_tree().process_frame
	_check("рост: убийство Bf 109 на волне 2 = 100 × 1.05 ≈ 105",
		_level.get_score() - before == 105,
		"прирост %d" % (_level.get_score() - before))
	_check("рост: ни одного исхода забега (run_finished) в endless",
		_run_events.is_empty(), str(_run_events))


# ─── apply_difficulty (EnemyBase) ──────────────────────────────────────────
func _check_difficulty() -> void:
	var plain := _probe_bf109()
	var buffed := _probe_bf109()
	if plain == null or buffed == null:
		_check("сложность: пробники Bf 109 созданы", false)
		return
	plain.patrol_altitude = 1000.0
	buffed.patrol_altitude = 1000.0
	plain.position = Vector2(270.0, 0.0)
	buffed.position = Vector2(270.0, 0.0)
	buffed.apply_difficulty(1.5, 1.8, 1.06)
	_check("сложность: HP Bf 109 4 → 4.24 и hp = max_hp",
		_approx(buffed.max_hp, 4.24) and _approx(buffed.hp, 4.24),
		"max=%.2f hp=%.2f" % [buffed.max_hp, buffed.hp])
	_check("сложность: скорость пуль 320 × 1.8 = 576",
		_approx(buffed.bullet_speed, 576.0), "%.1f" % buffed.bullet_speed)
	plain._move(1.0)
	buffed._move(1.0)
	_check("сложность: _move учитывает speed_mult (180 → 270 px за 1 с)",
		_approx(plain.position.y, 180.0) and _approx(buffed.position.y, 270.0),
		"%.1f / %.1f" % [plain.position.y, buffed.position.y])
	buffed.apply_difficulty(3.0, 3.0, 3.0)
	_check("сложность: повторный apply_difficulty игнорируется (не дважды)",
		_approx(buffed.max_hp, 4.24) and _approx(buffed.bullet_speed, 576.0)
		and _approx(buffed.speed_mult, 1.5),
		"max=%.2f bullet=%.1f" % [buffed.max_hp, buffed.bullet_speed])
	plain.despawn()
	buffed.despawn()


## Рантайм-проверка HP после 20-й волны и множителей волны 21 (hp ×1.06, пули ×1.5).
func _check_hp_scaling_runtime() -> void:
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_reset_waves_at(20)  # волна 21
	await get_tree().process_frame
	var bf110 := _first_alive_of_type("bf110")
	var fw190 := _first_alive_of_type("fw190")
	_check("HP: волна 21 спавнит Fw 190 / Bf 110 (12 бортов)",
		_level.waves.get_alive_count() == 12 and bf110 != null and fw190 != null,
		"живых %d" % _level.waves.get_alive_count())
	if bf110 == null or fw190 == null:
		return
	_check("HP: после 20-й волны Bf 110 16 → 16.96, Fw 190 12 → 12.72",
		_approx(bf110.max_hp, 16.96) and _approx(fw190.max_hp, 12.72),
		"%.2f / %.2f" % [bf110.max_hp, fw190.max_hp])
	_check("HP: множители волны 21 — скорость 1.3, пули 1.5, HP 1.06",
		_approx(bf110.speed_mult, 1.3) and _approx(bf110.bullet_speed_mult, 1.5)
		and _approx(bf110.hp_mult, 1.06),
		"speed=%.2f bullet=%.2f hp=%.2f" % [bf110.speed_mult, bf110.bullet_speed_mult,
			bf110.hp_mult])
	_check("HP: скорость пуль Bf 110 320 × 1.5 = 480",
		_approx(bf110.bullet_speed, 480.0), "%.1f" % bf110.bullet_speed)


# ─── Ремкомплект: 5 / 10 / 15, не на 6 ─────────────────────────────────────
func _check_repair_waves() -> void:
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	# Волна 5: Bf 109 / Ju 87 — «толстыми» считаются Ju 87.
	_reset_waves_at(4)
	await get_tree().process_frame
	var ju87 := _alive_of_type("ju87")
	_check("ремкомплект: волна 5 — 5 бортов, из них 2 Ju 87",
		_level.waves.get_alive_count() == 5 and ju87.size() == 2,
		"живых %d, Ju 87 %d" % [_level.waves.get_alive_count(), ju87.size()])
	for enemy in ju87:
		enemy.set_physics_process(false)
		enemy.take_damage(9999.0)
		await get_tree().process_frame
	_check("ремкомплект: волна 5 — последний Ju 87 даёт ровно один подбор",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())
	_kill_all_enemies()
	await get_tree().process_frame
	_check("ремкомплект: зачистка волны 5 не даёт второго подбора",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())
	# Волна 6 — не волна ремкомплекта.
	_reset_waves_at(5)
	await get_tree().process_frame
	_kill_all_enemies()
	await get_tree().process_frame
	_check("ремкомплект: волна 6 подбора не даёт (каждая 5-я, не 6-я)",
		_level.get_pickup_count() == 0, "подборов %d" % _level.get_pickup_count())
	# Волна 15: Fw 190 / Bf 110 — «толстый» Bf 110.
	_reset_waves_at(14)
	await get_tree().process_frame
	var bf110 := _alive_of_type("bf110")
	_check("ремкомплект: волна 15 — 10 бортов, из них 5 Bf 110",
		_level.waves.get_alive_count() == 10 and bf110.size() == 5,
		"живых %d, Bf 110 %d" % [_level.waves.get_alive_count(), bf110.size()])
	for enemy in bf110:
		enemy.set_physics_process(false)
		enemy.take_damage(9999.0)
		await get_tree().process_frame
	_check("ремкомплект: волна 15 — последний Bf 110 даёт ровно один подбор",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())


# ─── Босс endless: волна 10 (He 111, круг 0), continue_after_boss ───────────
func _check_boss_endless() -> void:
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_reset_waves_at(9)  # волна 10
	await get_tree().process_frame
	_check("босс: волна 10 — 8 бортов Ju 87 / Fw 190 (ремкомплект тоже здесь)",
		_level.waves.get_alive_count() == 8 and _count_type("ju87") == 4
		and _count_type("fw190") == 4,
		"живых %d" % _level.waves.get_alive_count())
	for enemy in _alive_of_type("ju87"):
		enemy.set_physics_process(false)
		enemy.take_damage(9999.0)
		await get_tree().process_frame
	_check("босс: волна 10 даёт ремкомплект (каждая 5-я волна)",
		_level.get_pickup_count() == 1, "подборов %d" % _level.get_pickup_count())
	_kill_all_enemies()
	await get_tree().process_frame
	var boss_ready := await _wait_for_boss(6.0)
	var boss := _level.waves.get_boss()
	_check("босс: после 10-й волны спавнится босс (He 111, круг 0)",
		boss_ready and boss is BossHe111 and _level.waves.get_boss_cycle() == 0,
		"boss=%s cycle=%d" % [boss, _level.waves.get_boss_cycle()])
	if boss == null:
		return
	_check("босс: номер волны 10, полоса HP в HUD, забег PLAYING",
		_level.waves.get_wave_number() == 10 and _level.hud.boss_bar.visible
		and _level.get_state() == LevelController.State.PLAYING,
		"wave=%d bar=%s" % [_level.waves.get_wave_number(), _level.hud.boss_bar.visible])
	_check("босс: HP 120, множители круга 0 не тронуты",
		_approx(boss.max_hp, 120.0) and _approx(boss.bullet_speed_mult,
			EndlessRules.bullet_speed_mult(10)),
		"hp=%.1f bullet_mult=%.3f" % [boss.max_hp, boss.bullet_speed_mult])
	var before := _level.get_score()
	boss.take_damage(99999.0)
	await get_tree().process_frame
	var expected := int(round(2000.0 * EndlessRules.score_multiplier(1))) \
		+ int(round(250.0 * EndlessRules.score_multiplier(2)))
	_check("босс: гибель босса НЕ победа — забег PLAYING, исхода нет",
		_level.get_state() == LevelController.State.PLAYING and _run_events.is_empty(),
		"state=%d events=%s" % [_level.get_state(), str(_run_events)])
	_check("босс: очки = 2000 × 1.05 + бонус волны × 1.1025 (%d)" % expected,
		_level.get_score() - before == expected,
		"прирост %d" % (_level.get_score() - before))
	_check("босс: башня волн продолжает работу (is_active, босса нет, HUD чист)",
		_level.waves.is_active() and _level.waves.get_boss() == null
		and not _level.hud.boss_bar.visible,
		"active=%s" % _level.waves.is_active())
	var advanced := await _wait_wave(11, 5.0)
	_check("босс: continue_after_boss ведёт на волну 11 (8 бортов Ju 87 / Fw 190)",
		advanced and _level.waves.get_wave_number() == 11
		and _level.waves.get_alive_count() == 8,
		"wave=%d alive=%d" % [_level.waves.get_wave_number(),
			_level.waves.get_alive_count()])
	_check("босс: после босса множитель продолжает расти (2 волны → 1.1025)",
		_approx(_level.get_score_multiplier(), EndlessRules.score_multiplier(2)),
		"%.4f" % _level.get_score_multiplier())


# ─── Перки: каждая 2-я волна, не каждая 3-я ─────────────────────────────────
func _check_perks_every_two_waves() -> void:
	_level.start_endless()
	await get_tree().process_frame
	_level.stop_waves()
	_level._clear_level()
	_level.set_perks_enabled(true)
	_level.waves.wave_cleared.emit(0)  # волна 1
	await get_tree().process_frame
	_check("перки: волна 1 не предлагает карту",
		not _level.is_perk_choice_visible() and not get_tree().paused)
	_level.waves.wave_cleared.emit(1)  # волна 2
	await get_tree().process_frame
	_check("перки: волна 2 предлагает 1 из 2 на паузе",
		_level.is_perk_choice_visible() and get_tree().paused
		and _level.perk_choice.get_offered_ids().size() == 2,
		str(_level.perk_choice.get_offered_ids()))
	var first := await _take_first_offer()
	_check("перки: карта волны 2 применена, пауза снята",
		not first.is_empty() and not get_tree().paused
		and _level.get_perk_system().has(first), first)
	_level.waves.wave_cleared.emit(2)  # волна 3
	await get_tree().process_frame
	_check("перки: волна 3 карту НЕ предлагает (только чётные)",
		not _level.is_perk_choice_visible() and not get_tree().paused)
	_level.waves.wave_cleared.emit(3)  # волна 4
	await get_tree().process_frame
	_check("перки: волна 4 снова предлагает карту",
		_level.is_perk_choice_visible() and get_tree().paused)
	var second := await _take_first_offer()
	_check("перки: две карты за забег, HUD знает про слоты",
		not second.is_empty() and _level.get_perk_system().get_active().size() == 2
		and _level.hud.get_perk_slot_count() == 2,
		str(_level.get_perk_system().get_active()))
	_level.set_perks_enabled(false)


# ─── Смерть: рекорд endless (очки + волна, только вверх) ────────────────────
func _check_death_record() -> void:
	_level.start_endless()
	await get_tree().process_frame
	_level.player.grant_invulnerability(999.0)
	_reset_waves_at(2)  # волна 3 — 6 Bf 109
	await get_tree().process_frame
	_kill_all_enemies()
	await get_tree().process_frame
	var score_at_death := _level.get_score()
	var wave_at_death := _level.waves.get_wave_number()
	_check("смерть: перед гибелью счёт и волна известны (%d очков, волна %d)"
		% [score_at_death, wave_at_death],
		score_at_death > 0 and wave_at_death == 3,
		"score=%d wave=%d" % [score_at_death, wave_at_death])
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	var died := await _wait_until(
		func() -> bool: return _level.get_state() == LevelController.State.DEAD, 2.0)
	_check("смерть: состояние DEAD, последний исход — поражение",
		died and _level.get_state() == LevelController.State.DEAD
		and _run_events.size() == 1 and not bool(_run_events[0].get("won", true)),
		str(_run_events))
	_check("смерть: рекорд endless записан (очки + волна)",
		SaveGame.get_endless_best() == score_at_death
		and SaveGame.get_endless_wave() == wave_at_death,
		"best=%d wave=%d" % [SaveGame.get_endless_best(), SaveGame.get_endless_wave()])
	_check("смерть: снимок для экрана итогов (best/is_new/wave)",
		_level.get_endless_best() == score_at_death and _level.get_endless_is_new()
		and _level.get_endless_wave() == wave_at_death,
		"best=%d new=%s wave=%d" % [_level.get_endless_best(),
			_level.get_endless_is_new(), _level.get_endless_wave()])
	var overlay_shown := await _wait_until(
		func() -> bool: return _level.death_overlay.visible, 2.0)
	_check("смерть: экран поражения — прежний DeathOverlay (видим, дерево на паузе)",
		overlay_shown and get_tree().paused)
	# Второй забег хуже: рекорд не понижается, is_new = false.
	_level.start_endless()
	await get_tree().process_frame
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(99)
	var died2 := await _wait_until(
		func() -> bool: return _level.get_state() == LevelController.State.DEAD, 2.0)
	_check("смерть: слабый второй забег рекорд не понижает",
		died2 and SaveGame.get_endless_best() == score_at_death
		and SaveGame.get_endless_wave() == wave_at_death
		and not _level.get_endless_is_new(),
		"best=%d new=%s" % [SaveGame.get_endless_best(), _level.get_endless_is_new()])
	_check("смерть: рестарт endless не выбрасывает в кампанию",
		_level.is_endless(), "mode=%d" % _level.get_mode())


# ─── Открытие endless (SaveGame.is_endless_unlocked) ────────────────────────
func _check_endless_unlock() -> void:
	_check("открытие: чистый профиль — endless закрыт",
		not SaveGame.is_endless_unlocked())
	SaveGame.record_stars(M1, 1)
	_check("открытие: одна звезда m1 мало (нужны все три миссии)",
		not SaveGame.is_endless_unlocked())
	SaveGame.record_stars(M2, 1)
	_check("открытие: m1 + m2 мало",
		not SaveGame.is_endless_unlocked())
	SaveGame.record_stars(M3, 1)
	_check("открытие: у всех трёх миссий ≥1 звезды — endless открыт",
		SaveGame.is_endless_unlocked())


# ─── Кампания не изменилась ─────────────────────────────────────────────────
func _check_campaign_unchanged() -> void:
	_level.start_mission(M1)
	await get_tree().process_frame
	_check("кампания: режим CAMPAIGN, 6 волн m1, волна 1",
		_level.get_mode() == LevelController.Mode.CAMPAIGN and not _level.is_endless()
		and not _level.waves.is_endless() and _level.waves.get_wave_count() == 6
		and _level.waves.get_wave_number() == 1,
		"mode=%d waves=%d" % [_level.get_mode(), _level.waves.get_wave_count()])
	_check("кампания: множитель счёта 1.0, волн endless не считается",
		_approx(_level.get_score_multiplier(), 1.0) and _level.get_waves_cleared() == 0,
		"mult=%.2f" % _level.get_score_multiplier())
	_check("кампания: волна 1 m1 — прежние 4 Bf 109",
		_level.waves.get_alive_count() == 4 and _count_type("bf109") == 4,
		"живых %d" % _level.waves.get_alive_count())
	_kill_all_enemies()
	await get_tree().process_frame
	_check("кампания: бонус волны без множителя (4×100 + 250 = 650)",
		_level.get_score() == 650, str(_level.get_score()))
	_check("кампания: WAVE_COUNT и wave_table m1 — 6 волн",
		WaveManager.WAVE_COUNT == 6 and WaveManager.wave_table().size() == 6,
		"%d / %d" % [WaveManager.WAVE_COUNT, WaveManager.wave_table().size()])
	_level.set_perks_enabled(true)


# ─── Хелперы ────────────────────────────────────────────────────────────────
func _on_run_finished(won: bool, score: int, _elapsed: float) -> void:
	_run_events.append({"won": won, "score": score})


## Свежий endless-забег, но волна сразу задаётся индексом (QA-хук start_at_wave).
func _reset_waves_at(index: int) -> void:
	_level.waves.stop()
	_level._clear_level()
	_level.waves.start_at_wave(index)


func _kill_all_enemies() -> void:
	for node in get_tree().get_nodes_in_group(GameConfig.GROUP_ENEMIES):
		var enemy := node as EnemyBase
		if enemy != null and enemy.is_active:
			enemy.take_damage(99999.0)


func _first_alive() -> EnemyBase:
	for node in get_tree().get_nodes_in_group(GameConfig.GROUP_ENEMIES):
		var enemy := node as EnemyBase
		if enemy != null and enemy.is_active:
			return enemy
	return null


func _alive_of_type(type: String) -> Array[EnemyBase]:
	var result: Array[EnemyBase] = []
	for child in _level.enemies_root.get_children():
		var enemy := child as EnemyBase
		if enemy == null or not enemy.is_active:
			continue
		if MissionData.type_for_asset_key(enemy.asset_key) == type:
			result.append(enemy)
	return result


func _first_alive_of_type(type: String) -> EnemyBase:
	var list := _alive_of_type(type)
	return list[0] if not list.is_empty() else null


func _count_type(type: String) -> int:
	return _alive_of_type(type).size()


## Пробник Bf 109 вне уровня: _ready отработал (hp = max_hp), физика выключена.
func _probe_bf109() -> EnemyBase:
	var enemy := LevelController.ENEMY_BF109_SCENE.instantiate() as EnemyBase
	if enemy == null:
		return null
	_holder.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy


func _wait_wave(number: int, timeout: float) -> bool:
	var probe := func() -> bool:
		return _level.waves.get_wave_number() == number \
			and _level.waves.get_alive_count() > 0
	return await _wait_until(probe, timeout)


func _wait_for_boss(timeout: float) -> bool:
	var probe := func() -> bool: return _level.waves.get_boss() != null
	return await _wait_until(probe, timeout)


func _wait_until(condition: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return bool(condition.call())


func _take_first_offer() -> String:
	var offers := _level.perk_choice.get_offered_ids()
	if offers.is_empty():
		return ""
	var picked := offers[0]
	if not _level.perk_choice.request_perk(picked):
		return ""
	await get_tree().process_frame
	return picked


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")


func _approx(a: float, b: float, epsilon: float = 0.0001) -> bool:
	return absf(a - b) <= epsilon


## Слепок файла: {существует, размер, sha256}. Чужой профиль не трогаем, но доказываем это.
func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": 0, "sha": ""}
	var bytes := FileAccess.get_file_as_bytes(path)
	return {"exists": true, "size": bytes.size(), "sha": bytes.get_string_from_utf8().sha256_text()}


func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	return bool(a.get("exists", false)) == bool(b.get("exists", false)) \
		and int(a.get("size", 0)) == int(b.get("size", 0)) \
		and String(a.get("sha", "")) == String(b.get("sha", ""))


func _snapshot_brief(snapshot: Dictionary) -> String:
	if not bool(snapshot.get("exists", false)):
		return "нет файла"
	return "%d B, %s" % [int(snapshot.get("size", 0)),
		String(snapshot.get("sha", "")).substr(0, 8)]
