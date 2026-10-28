# campaign_boss_test.gd
# Purpose: Гейт M5.2 — новые враги и боссы кампании. Проверяет:
#          * MissionData.scene_for_type для bf110 / ju88 / fw200 резолвится в сцены, сцены
#            инстанцируются и содержат Visual + CollisionShape2D (структура как у старых врагов);
#          * таблицу ArtStyle (ключи и размеры 64×64 / 160×112 / 192×128);
#          * Bf 110: 16 HP / 400 очков / не босс, патруль и «двойная прицельная очередь»,
#            гибель ровно после 16 урона;
#          * Ju 88: 160 HP / 3000 / босс, порог фазы 2 на 80 HP, сигнал phase_changed(2),
#            скорость пуль ×1.3; константы бомб и веера (по таймеру не стреляем — тест быстрый);
#          * Fw 200: 220 HP / 4000 / босс, фаза 2 на 110, усиление на 55 (is_enraged, интервалы
#            /1.3, пули ×1.1, повторного phase_changed нет);
#          * после add_child боссы только в GROUP_BOSS, Bf 110 — только в GROUP_ENEMIES;
#          * рантайм на real main.tscn: start_mission(m2_crossing / m3_city), волна 3 миссии 3
#            спавнит Bf 110, боссы Ju 88 / Fw 200 спавнятся и регистрируются в HUD.
#          Пользовательские файлы (рекорд user://) не читаются и не пишутся: забег не доводится
#          до исхода, RunRecord не вызывается.
# Запуск: godot --headless --path . res://tests/campaign_boss_test.tscn
# Author: Mechanics Developer Agent

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
const BF110_SCENE: PackedScene = preload("res://scenes/enemy_bf110.tscn")
const JU88_SCENE: PackedScene = preload("res://scenes/boss_ju88.tscn")
const FW200_SCENE: PackedScene = preload("res://scenes/boss_fw200.tscn")

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Сейв изолирован: start_mission() читает SaveGame (выбранный самолёт), поэтому реальный
## user://ww2_air_battles.cfg не должен участвовать даже в чтении/миграции.
var _save_path: String = ""
## Контейнер для тестовых бортов: узлы в дереве (нужны группы и _ready), но физика выключена —
## статистика и сигналы проверяются без движения и стрельбы по таймеру.
var _holder: Node2D
var _level: LevelController


func _ready() -> void:
	# Тест не зависит от пауз дерева (LevelController может поставить paused в исходе забега).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	_save_path = "user://qa_campaign_boss_%d.cfg" % _started_msec
	RunRecord.set_save_path(_save_path)
	_holder = Node2D.new()
	_holder.name = "BossTestHolder"
	add_child(_holder)
	await _run()
	RunRecord.reset_save_path()
	if FileAccess.file_exists(_save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_save_path))
	if _level != null:
		_level.queue_free()
		_level = null
	_holder.queue_free()
	await get_tree().process_frame
	print("CAMPAIGN_BOSS_TIME=",
		"%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("CAMPAIGN_BOSS_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_check_scene_resolution()
	_check_bf110()
	_check_ju88()
	_check_fw200()
	_check_groups()
	await _check_runtime()


# ─── Сцены и таблица ArtStyle ───────────────────────────────────────────────
func _check_scene_resolution() -> void:
	var bf110 := MissionData.scene_for_type("bf110")
	var ju88 := MissionData.scene_for_type("ju88")
	var fw200 := MissionData.scene_for_type("fw200")
	_check("MissionData: bf110 → enemy_bf110.tscn (не null)",
		bf110 != null and bf110.resource_path == "res://scenes/enemy_bf110.tscn",
		"null" if bf110 == null else bf110.resource_path)
	_check("MissionData: ju88 → boss_ju88.tscn (не null)",
		ju88 != null and ju88.resource_path == "res://scenes/boss_ju88.tscn",
		"null" if ju88 == null else ju88.resource_path)
	_check("MissionData: fw200 → boss_fw200.tscn (не null)",
		fw200 != null and fw200.resource_path == "res://scenes/boss_fw200.tscn",
		"null" if fw200 == null else fw200.resource_path)

	_check_scene_structure("Bf 110", BF110_SCENE)
	_check_scene_structure("Ju 88", JU88_SCENE)
	_check_scene_structure("Fw 200", FW200_SCENE)

	_check("ArtStyle: enemy_bf110 64×64",
		ArtStyle.size_of(ArtStyle.KEY_ENEMY_BF110) == Vector2(64.0, 64.0),
		str(ArtStyle.size_of(ArtStyle.KEY_ENEMY_BF110)))
	_check("ArtStyle: boss_ju88 160×112",
		ArtStyle.size_of(ArtStyle.KEY_BOSS_JU88) == Vector2(160.0, 112.0),
		str(ArtStyle.size_of(ArtStyle.KEY_BOSS_JU88)))
	_check("ArtStyle: boss_fw200 192×128",
		ArtStyle.size_of(ArtStyle.KEY_BOSS_FW200) == Vector2(192.0, 128.0),
		str(ArtStyle.size_of(ArtStyle.KEY_BOSS_FW200)))


## Сцена без добавления в дерево: структура (скрипт в корне, Visual, CollisionShape2D).
func _check_scene_structure(label: String, scene: PackedScene) -> void:
	var probe := scene.instantiate()
	var visual := probe.get_node_or_null(^"Visual")
	var shape := probe.get_node_or_null(^"CollisionShape2D")
	_check("%s: Area2D + Visual (ShipVisual) + CollisionShape2D" % label,
		probe is Area2D and visual is ShipVisual and shape is CollisionShape2D
		and probe.get_script() != null,
		"Area2D=%s Visual=%s Shape=%s" % [probe is Area2D, visual is ShipVisual,
			shape is CollisionShape2D])
	probe.free()


# ─── Bf 110 ────────────────────────────────────────────────────────────────
func _check_bf110() -> void:
	var bf := _spawn(BF110_SCENE)
	_check("Bf 110: 16 HP / 400 очков",
		bf.max_hp == 16 and bf.score_value == 400,
		"%d HP, %d очк." % [bf.max_hp, bf.score_value])
	_check("Bf 110: не босс, asset_key enemy_bf110",
		not bf.is_boss and bf.asset_key == ArtStyle.KEY_ENEMY_BF110,
		"boss=%s key=%s" % [bf.is_boss, bf.asset_key])
	_check("Bf 110: 2.0 с / пули 320 / урон 1 / нос вниз",
		is_equal_approx(bf.fire_interval, 2.0) and is_equal_approx(bf.bullet_speed, 320.0)
		and bf.bullet_damage == 1 and bf.face_down,
		"%.2f с, %.0f px/s" % [bf.fire_interval, bf.bullet_speed])
	_check("Bf 110: сближение 150, патруль 230 (амплитуда 120, ω 0.7)",
		is_equal_approx(EnemyBf110.BF110_SPEED, 150.0)
		and is_equal_approx(EnemyBf110.PATROL_ALTITUDE, 230.0)
		and is_equal_approx(EnemyBf110.PATROL_AMPLITUDE, 120.0)
		and is_equal_approx(EnemyBf110.PATROL_ANGULAR_SPEED, 0.7),
		"%.0f / %.0f / %.0f / %.2f" % [EnemyBf110.BF110_SPEED,
			EnemyBf110.PATROL_ALTITUDE, EnemyBf110.PATROL_AMPLITUDE,
			EnemyBf110.PATROL_ANGULAR_SPEED])
	_check("Bf 110: двойная очередь — 2 выстрела с крыльев (±16,+16) через 0.12 с",
		EnemyBf110.BURST_SHOTS == 2
		and is_equal_approx(EnemyBf110.BURST_INTERVAL, 0.12)
		and EnemyBf110.WING_OFFSET == Vector2(16.0, 16.0)
		and EnemyBf110.WING_SIDES == [-1.0, 1.0],
		"%d × %.2f, offset %s" % [EnemyBf110.BURST_SHOTS, EnemyBf110.BURST_INTERVAL,
			EnemyBf110.WING_OFFSET])

	# 15 урона не убивают «толстого» Bf 110, 16-й — сбивает.
	var survived := not bf.take_damage(15)
	_check("Bf 110: после 15 урона жив (1 HP)", survived and bf.hp == 1 and bf.is_active,
		"hp %d" % bf.hp)
	var died := []
	bf.died.connect(func(enemy: EnemyBase) -> void: died.append(enemy))
	var destroyed := bf.take_damage(1)
	_check("Bf 110: гибнет после 16 урона (died, hp 0)",
		destroyed and bf.hp == 0 and not bf.is_active and died.size() == 1,
		"destroyed=%s hp=%d, died %d" % [destroyed, bf.hp, died.size()])


# ─── Ju 88 ─────────────────────────────────────────────────────────────────
func _check_ju88() -> void:
	var ju := _spawn(JU88_SCENE)
	_check("Ju 88: 160 HP / 3000 / босс / не деспавнится за экран",
		ju.max_hp == 160 and ju.score_value == 3000 and ju.is_boss
		and not ju.despawns_offscreen,
		"%d HP, %d очк., boss=%s" % [ju.max_hp, ju.score_value, ju.is_boss])
	_check("Ju 88: asset_key boss_ju88, силуэт 160×112",
		ju.asset_key == ArtStyle.KEY_BOSS_JU88
		and ArtStyle.size_of(ju.asset_key) == Vector2(160.0, 112.0),
		str(ju.asset_key))
	_check("Ju 88: вход 180, прочёс 80, отступ 120",
		is_equal_approx(BossJu88.ALTITUDE, 180.0)
		and is_equal_approx(BossJu88.SWEEP_SPEED, 80.0)
		and is_equal_approx(BossJu88.SWEEP_MARGIN, 120.0),
		"%.0f / %.0f / %.0f" % [BossJu88.ALTITUDE, BossJu88.SWEEP_SPEED,
			BossJu88.SWEEP_MARGIN])
	_check("Ju 88 Ф1: 2 турели, очередь 2 × 0.12 с каждые 2.2 с, пули 320",
		BossJu88.TURRET_SIDES.size() == 2
		and BossJu88.AIMED_BURST_SHOTS == 2
		and is_equal_approx(BossJu88.AIMED_BURST_INTERVAL, 0.12)
		and is_equal_approx(BossJu88.PHASE1_AIMED_INTERVAL, 2.2)
		and is_equal_approx(BossJu88.PHASE1_BULLET_SPEED, 320.0),
		"%d × %.2f / %.1f с" % [BossJu88.AIMED_BURST_SHOTS,
			BossJu88.AIMED_BURST_INTERVAL, BossJu88.PHASE1_AIMED_INTERVAL])
	_check("Ju 88 Ф2: ×1.3, бомбы 3.5 с (offset (0,44)), веер 7 каждые 2.5 с",
		is_equal_approx(BossJu88.PHASE2_SPEED_MULT, 1.3)
		and is_equal_approx(BossJu88.PHASE2_BOMB_INTERVAL, 3.5)
		and BossJu88.BOMB_MUZZLE_OFFSET == Vector2(0.0, 44.0)
		and is_equal_approx(BossJu88.PHASE2_FAN_INTERVAL, 2.5)
		and BossJu88.PHASE2_FAN_COUNT == 7,
		"бомбы %.1f с, веер %d" % [BossJu88.PHASE2_BOMB_INTERVAL,
			BossJu88.PHASE2_FAN_COUNT])
	_check("Ju 88: порог фазы 2 = 80 HP", BossJu88.PHASE_2_HP_THRESHOLD == 80,
		str(BossJu88.PHASE_2_HP_THRESHOLD))

	# Порог: 79 урона (81 HP) фазу НЕ меняют.
	var ju_below := _spawn(JU88_SCENE)
	var phases_below := []
	ju_below.phase_changed.connect(func(phase: int) -> void: phases_below.append(phase))
	ju_below.take_damage(79)
	_check("Ju 88: 81 HP — ещё фаза 1, сигнала нет",
		ju_below.phase == 1 and phases_below.is_empty(),
		"phase %d, сигналов %d" % [ju_below.phase, phases_below.size()])

	# Порог: 80 урона (80 HP) → фаза 2 и ровно один phase_changed(2).
	var phases := []
	ju.phase_changed.connect(func(phase: int) -> void: phases.append(phase))
	ju.take_damage(80)
	_check("Ju 88: 80 HP → фаза 2 и phase_changed(2)",
		ju.phase == 2 and phases == [2],
		"phase %d, сигналы %s" % [ju.phase, phases])
	_check("Ju 88: в фазе 2 скорость пуль ×1.3 (416)",
		is_equal_approx(ju.bullet_speed, 416.0), str(ju.bullet_speed))
	ju.take_damage(40)
	_check("Ju 88: переход односторонний — обратно в фазу 1 не возвращается",
		ju.phase == 2 and phases == [2],
		"phase %d, сигналы %s" % [ju.phase, phases])


# ─── Fw 200 ────────────────────────────────────────────────────────────────
func _check_fw200() -> void:
	var fw := _spawn(FW200_SCENE)
	_check("Fw 200: 220 HP / 4000 / босс / не деспавнится за экран",
		fw.max_hp == 220 and fw.score_value == 4000 and fw.is_boss
		and not fw.despawns_offscreen,
		"%d HP, %d очк., boss=%s" % [fw.max_hp, fw.score_value, fw.is_boss])
	_check("Fw 200: asset_key boss_fw200, силуэт 192×128",
		fw.asset_key == ArtStyle.KEY_BOSS_FW200
		and ArtStyle.size_of(fw.asset_key) == Vector2(192.0, 128.0),
		str(fw.asset_key))
	_check("Fw 200: вход 160, прочёс 70, отступ 140",
		is_equal_approx(BossFw200.ALTITUDE, 160.0)
		and is_equal_approx(BossFw200.SWEEP_SPEED, 70.0)
		and is_equal_approx(BossFw200.SWEEP_MARGIN, 140.0),
		"%.0f / %.0f / %.0f" % [BossFw200.ALTITUDE, BossFw200.SWEEP_SPEED,
			BossFw200.SWEEP_MARGIN])
	_check("Fw 200 Ф1: 4 турели (±48/±72, +24), одиночные 2.6 с, веер 7 × 300 каждые 3 с",
		BossFw200.TURRET_X_OFFSETS == [48.0, 72.0]
		and BossFw200.TURRET_SIDES.size() == 2
		and is_equal_approx(BossFw200.TURRET_Y_OFFSET, 24.0)
		and is_equal_approx(BossFw200.PHASE1_AIMED_INTERVAL, 2.6)
		and BossFw200.PHASE1_FAN_COUNT == 7
		and is_equal_approx(BossFw200.PHASE1_FAN_INTERVAL, 3.0)
		and is_equal_approx(BossFw200.PHASE1_BULLET_SPEED, 300.0),
		"турелей %d, веер %.1f с" % [BossFw200.TURRET_X_OFFSETS.size() * 2,
			BossFw200.PHASE1_FAN_INTERVAL])
	_check("Fw 200 Ф2: радиаль 16 × 320 каждые 2.4 с, пороги 110/55",
		BossFw200.PHASE2_RADIAL_COUNT == 16
		and is_equal_approx(BossFw200.PHASE2_BULLET_SPEED, 320.0)
		and is_equal_approx(BossFw200.PHASE2_RADIAL_INTERVAL, 2.4)
		and BossFw200.PHASE_2_HP_THRESHOLD == 110
		and BossFw200.ENRAGE_HP_THRESHOLD == 55,
		"порог фазы %d, усиление %d" % [BossFw200.PHASE_2_HP_THRESHOLD,
			BossFw200.ENRAGE_HP_THRESHOLD])

	var phases := []
	fw.phase_changed.connect(func(phase: int) -> void: phases.append(phase))
	fw.take_damage(110)
	_check("Fw 200: 110 HP → фаза 2 и phase_changed(2)",
		fw.phase == 2 and phases == [2],
		"phase %d, сигналы %s" % [fw.phase, phases])
	_check("Fw 200: на 110 HP усиления ещё нет",
		not fw.is_enraged and is_equal_approx(fw.bullet_speed, 320.0),
		"enraged=%s speed %.0f" % [fw.is_enraged, fw.bullet_speed])

	fw.take_damage(55)
	_check("Fw 200: 55 HP → is_enraged, phase остаётся 2, повторного phase_changed нет",
		fw.is_enraged and fw.phase == 2 and phases == [2],
		"enraged=%s phase %d, сигналы %s" % [fw.is_enraged, fw.phase, phases])
	_check("Fw 200: усиление — интервалы /1.3 (2.0 / 2.31 / 1.85), пули ×1.1 (352)",
		is_equal_approx(fw.aimed_interval, BossFw200.PHASE1_AIMED_INTERVAL / 1.3)
		and is_equal_approx(fw.fan_interval, BossFw200.PHASE1_FAN_INTERVAL / 1.3)
		and is_equal_approx(fw.radial_interval, BossFw200.PHASE2_RADIAL_INTERVAL / 1.3)
		and is_equal_approx(fw.bullet_speed, 352.0),
		"%.2f / %.2f / %.2f, %.0f px/s" % [fw.aimed_interval, fw.fan_interval,
			fw.radial_interval, fw.bullet_speed])


# ─── Группы ────────────────────────────────────────────────────────────────
## Босс обязан жить ТОЛЬКО в GROUP_BOSS: иначе одна бомба убивала бы его через GROUP_ENEMIES
## (контракт EnemyBase). Проверяется после add_child — группы вешает _register_groups() в _ready.
func _check_groups() -> void:
	var bf := _spawn(BF110_SCENE)
	_check("группы: Bf 110 — в enemies, не в boss",
		bf.is_in_group(GameConfig.GROUP_ENEMIES)
		and not bf.is_in_group(GameConfig.GROUP_BOSS))
	var ju := _spawn(JU88_SCENE)
	_check("группы: Ju 88 — в boss, не в enemies",
		ju.is_in_group(GameConfig.GROUP_BOSS)
		and not ju.is_in_group(GameConfig.GROUP_ENEMIES))
	var fw := _spawn(FW200_SCENE)
	_check("группы: Fw 200 — в boss, не в enemies",
		fw.is_in_group(GameConfig.GROUP_BOSS)
		and not fw.is_in_group(GameConfig.GROUP_ENEMIES))


# ─── Рантайм на реальной main.tscn ─────────────────────────────────────────
## Волны и боссы проверяются без полного прогона: start_mission + start_at_wave для волны 3
## миссии 3 и ручной вызов WaveManager._spawn_boss() (публичного хука для «спавна босса» нет,
## а ждать шесть волн в тесте нельзя).
func _check_runtime() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	await get_tree().process_frame

	_level.start_mission("m2_crossing")
	await get_tree().process_frame
	_check("рантайм: m2_crossing стартовала (6 волн, миссия в WaveManager)",
		_level.get_mission_id() == "m2_crossing"
		and _level.waves.get_mission_id() == "m2_crossing"
		and _level.waves.get_wave_count() == 6,
		"миссия %s, волн %d" % [_level.waves.get_mission_id(),
			_level.waves.get_wave_count()])

	_level.start_mission("m3_city")
	await get_tree().process_frame
	_level.waves.start_at_wave(2)
	await get_tree().process_frame
	_check("рантайм: M3 волна 3 — 2 Bf 110 + 3 Bf 109 (5 бортов)",
		_level.waves.get_alive_count() == 5 and _count_bf110() == 2,
		"живых %d, Bf110 %d" % [_level.waves.get_alive_count(), _count_bf110()])

	# Босс Fw 200 миссии 3: спавнится и регистрируется в HUD.
	_level.waves._spawn_boss()
	await get_tree().process_frame
	var fw_boss := _level.get_boss()
	_check("рантайм: M3 спавнит босса Fw 200, get_boss() его видит",
		fw_boss is BossFw200 and fw_boss.is_boss
		and fw_boss.is_in_group(GameConfig.GROUP_BOSS),
		"boss=%s" % fw_boss)
	_check("рантайм: полоса HP босса Fw 200 показана в HUD",
		fw_boss != null and _level.hud.boss_bar.visible,
		"bar visible=%s" % (_level.hud.boss_bar.visible if fw_boss != null else false))

	# Босс Ju 88 миссии 2: старт миссии заново + спавн босса.
	_level.start_mission("m2_crossing")
	await get_tree().process_frame
	_level.waves._spawn_boss()
	await get_tree().process_frame
	var ju_boss := _level.get_boss()
	_check("рантайм: M2 спавнит босса Ju 88, get_boss() его видит",
		ju_boss is BossJu88 and ju_boss.is_boss
		and ju_boss.is_in_group(GameConfig.GROUP_BOSS)
		and _level.hud.boss_bar.visible,
		"boss=%s" % ju_boss)

	# Уборка: мир не должен уйти в исход/паузу от тестового босса.
	_level.stop_waves()


## Сколько живых Bf 110 в мире уровня (по enemies_root, без групп).
func _count_bf110() -> int:
	if _level == null:
		return 0
	var total := 0
	for child in _level.enemies_root.get_children():
		if child is EnemyBf110 and (child as EnemyBase).is_active:
			total += 1
	return total


## Инстанс борта в тестовом контейнере: _ready (группы/хитбокс/визуал) отработал, физика выкл.
func _spawn(scene: PackedScene) -> EnemyBase:
	var enemy := scene.instantiate() as EnemyBase
	_holder.add_child(enemy)
	enemy.set_physics_process(false)
	return enemy


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
