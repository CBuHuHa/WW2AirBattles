# juice_integration.gd
# Purpose: Интеграционный тест juice M4 на РЕАЛЬНОЙ main.tscn: репарен World под ScreenShake,
#          режимы процесса на паузе, живость всех подписок (тряска/hit-stop/взрывы/вспышки),
#          ОТСУТСТВИЕ двойного взрыва на исходах, переиспользование узлов вспышек,
#          дым/огонь по HP и восстановление Engine.time_scale после hit-stop.
#          Быстрый (<10 с): прямые эмиты сигналов вместо секундных боёв; боевая логика пуль
#          почти не задействована (созданные вспомогательные пули сразу вычищаются).
#          M3C-QA-01: рекорд изолирован — прогон подменяет путь RunRecord на уникальный
#          user://qa_juice_*.cfg, реальный user://ww2_air_battles.cfg игрока не читается,
#          не создаётся и не перезаписывается (победа над боссом идёт через настоящий
#          _finish_run(true) → CampaignProgress.finish_mission → SaveGame сейва v2, M5.3a).
# Запуск: godot --headless --path . res://tests/juice_integration.tscn
# Author: Game Feel Developer Agent

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
## Замер аллокаций очереди босса: сколько снарядов выпускает каждый прогон (2 ствола на залп).
const BURST_SAMPLES := 40

# ─── M3C-QA-01: изоляция локального рекорда (user://) ────────────────────────
## Путь рекорда по умолчанию (файл игрока) — только для слепка «до/после».
const RECORD_DEFAULT_PATH := "user://ww2_air_battles.cfg"
## Формат файла принадлежит RunRecord: ровно одна секция и один ключ.
const RECORD_SECTION := "record"
const RECORD_KEY := "best_score"
## M5.3a: рекорды миссий сейва v2 — [records] best_m1..m3 (см. _read_record_best).
const SAVE_RECORDS_SECTION := "records"
## Начальный рекорд qa-файла ПЕРЕД победой: он должен быть ниже счёта победы, иначе
## строка оверлея зависела бы от рекорда на машине (7850 > 2750 → «Рекорд: 7850»).
const RECORD_SEED := 100

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
var _level: LevelController
## Уникальный qa-файл рекорда прогона + слепок реального файла игрока до старта.
var _record_path: String = ""
var _real_record_snapshot: Dictionary = {}


func _ready() -> void:
	Input.emulate_mouse_from_touch = false
	# Тест живёт и при get_tree().paused (проверка пауз/исходов).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	# M3C-QA-01: изоляция ДО первого инстанса main. Иначе победа над боссом (реальный
	# _finish_run(true) → RunRecord.submit) создавала бы/перезаписывала рекорд игрока:
	# на чистом профиле прогон оставлял user://ww2_air_battles.cfg с best=2750.
	_real_record_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_record_path = "user://qa_juice_%d.cfg" % Time.get_ticks_msec()
	RunRecord.set_save_path(_record_path)
	_remove_user_file(_record_path)
	await get_tree().process_frame
	await _run()
	# M3C-QA-01: уборка изоляции + доказательство, что реальный рекорд игрока не тронут.
	var qa_file_created := FileAccess.file_exists(_record_path)
	_remove_user_file(_record_path)
	RunRecord.reset_save_path()
	_check("рекорд: победа записала рекорд в qa-файл (запись не потеряна)",
		qa_file_created, _record_path)
	_check("рекорд: reset_save_path вернул путь по умолчанию",
		RunRecord.get_save_path() == RECORD_DEFAULT_PATH, RunRecord.get_save_path())
	_check("рекорд: qa-файл удалён после прогона",
		not FileAccess.file_exists(_record_path), _record_path)
	var real_after := _file_snapshot(RunRecord.DEFAULT_PATH)
	_check("рекорд: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_record_snapshot, real_after),
		"%s → %s" % [_snapshot_brief(_real_record_snapshot), _snapshot_brief(real_after)])
	print("JUICE_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("JUICE_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_boot_level()
	await _check_structure()
	await _check_pause_modes()
	await _check_event_wiring()
	await _check_muzzle_flash_nodes()
	await _check_boss_burst_allocations()
	await _check_damage_fx()
	await _check_boss_death_single_explosion()
	await _check_player_death_single_explosion()
	await _check_time_scale_restored()


# ─── Сценарии ───────────────────────────────────────────────────────────────
func _boot_level() -> void:
	_level = MAIN_SCENE.instantiate()
	add_child(_level)
	# Волны идут, но проверкам мешают — чистим поле, оставляя сам уровень.
	await _reset_level()


## Общая очистка: волны остановлены, поле пустое, счёт/заряды как на старте.
func _reset_level() -> void:
	_level.start_level()
	_level.stop_waves()
	await get_tree().process_frame
	_clear_enemies()
	_level.bullets.clear_all()
	await get_tree().process_frame


func _check_structure() -> void:
	var wrapper := _level.shake
	_check("структура: обёртка ScreenShake создана под Level",
		wrapper != null and wrapper.get_parent() == _level)
	_check("структура: World переподчинён под обёртку (Level → ScreenShake → World)",
		wrapper != null and _level.world.get_parent() == wrapper)
	_check("структура: обёртка ЯВНО PAUSABLE — тряска замирает с миром",
		wrapper != null and wrapper.process_mode == Node.PROCESS_MODE_PAUSABLE,
		str(wrapper.process_mode) if wrapper != null else "обёртки нет")
	_check("структура: World остался PAUSABLE (контракт AGENTS, не «починен» обратно)",
		_level.world.process_mode == Node.PROCESS_MODE_PAUSABLE)
	_check("структура: Effects живёт под World — взрывы трясутся с миром",
		_level.effects_root.get_parent() == _level.world)
	_check("структура: hit-stop узел существует (ALWAYS выставляет сам)",
		_level.hit_stop != null and _level.hit_stop.process_mode == Node.PROCESS_MODE_ALWAYS)
	_check("структура: у игрока по одному узлу вспышки и дыма/огня",
		_count_muzzle(_level.player) == 1 and _level.damage_fx != null
		and _level.player.has_node("DamageFx"))


func _check_pause_modes() -> void:
	get_tree().paused = true
	_check("пауза: World не обрабатывается", not _level.world.can_process())
	_check("пауза: тряска заморожена вместе с миром", not _level.shake.can_process())
	_check("пауза: Effects (взрывы/частицы) заморожены", not _level.effects_root.can_process())
	_check("пауза: игрок с дымом/огнём заморожен", not _level.player.can_process())
	_check("пауза: hit-stop живёт (ALWAYS) — время разморозится и на паузе",
		_level.hit_stop.can_process())
	_check("пауза: LevelController жив (оверлеи/ввод)", _level.can_process())
	get_tree().paused = false
	_check("снятие паузы: мир снова жив", _level.world.can_process())


func _check_event_wiring() -> void:
	# player_damaged → тряска 4 px / 0.15 с + hit-stop + вспышка визуала игрока.
	# Ревью: вспышка больше НЕ маскируется предокраской узла — проверяем реальный цикл
	# «нейтральный Color(1,1,1,1) → пик RGB > 1 → возврат к нейтральному».
	var neutral := Color(1.0, 1.0, 1.0, 1.0)
	_level.shake.stop()
	_level.player_visual.self_modulate = neutral
	_check("player_damaged: ДО вспышки self_modulate нейтрален (WHITE сам по себе — не эффект)",
		_level.player_visual.self_modulate == neutral,
		str(_level.player_visual.self_modulate))
	# Миг неуязвимости живёт на modulate.a КОРНЯ игрока (player.gd) — вспышка его не трогает.
	_level.player.modulate.a = 0.35
	var records_before := HitFlash.debug_active_records()
	_level.player_damaged.emit(2, _level.player.global_position)
	_check("player_damaged: тряска запущена", _level.shake.is_shaking())
	_check("player_damaged: hit-stop запущен", _level.hit_stop.is_frozen())
	_check("player_damaged: визуал игрока вспыхнул (пик RGB > 1, а не WHITE→WHITE)",
		_level.player_visual.self_modulate.r > 1.0
		and _level.player_visual.self_modulate.g > 1.0
		and _level.player_visual.self_modulate.b > 1.0,
		str(_level.player_visual.self_modulate))
	_check("player_damaged: миг неуязвимости (modulate.a корня) не затёрт вспышкой",
		is_equal_approx(_level.player.modulate.a, 0.35), str(_level.player.modulate.a))
	var player_flash_restored: bool = await _wait_until(
		func() -> bool: return _level.player_visual.self_modulate == neutral, 1.0
	)
	_check("player_damaged: вспышка вернулась к нейтральному Color(1,1,1,1)",
		player_flash_restored, str(_level.player_visual.self_modulate))
	_level.player.modulate.a = 1.0
	var records_player_only := HitFlash.debug_active_records()
	_check("hit_flash: вспышка живого игрока — ровно одна запись в кэше",
		records_player_only == records_before + 1,
		"записей %d, было %d" % [records_player_only, records_before])
	var restored_after_hit := await _await_time_scale_restored(0.5)
	_check("hit-stop: time_scale восстановился после player_damaged", restored_after_hit)

	# enemy_damaged → hit-flash врага (узел валиден только до конца кадра — флеш сразу).
	var enemy := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(120.0, 160.0))
	enemy.set_physics_process(false)
	var enemy_visual := enemy.get_node(^"Visual") as Node2D
	enemy_visual.self_modulate = neutral
	_level.enemy_damaged.emit(enemy, 5, enemy.global_position)
	_check("enemy_damaged: визуал врага вспыхнул (пик RGB > 1)",
		enemy_visual.self_modulate.r > 1.0, str(enemy_visual.self_modulate))
	var enemy_flash_restored: bool = await _wait_until(
		func() -> bool: return enemy_visual.self_modulate == neutral, 1.0
	)
	_check("enemy_damaged: вспышка врага вернулась к нейтральному",
		enemy_flash_restored, str(enemy_visual.self_modulate))
	_check("hit_flash: запись живого узла в кэше одна",
		HitFlash.debug_active_records() == records_player_only + 1,
		"записей %d, ожидалось %d" % [HitFlash.debug_active_records(), records_player_only + 1])

	# enemy_destroyed → ровно один малый взрыв в Effects, в ВЕРНОЙ точке
	# (регрессия QA: global_position ставится ПОСЛЕ add_child).
	_level.shake.stop()
	var small_before := _count_explosions(false)
	var death_at := Vector2(270.0, 300.0)
	_level.enemy_destroyed.emit(ArtStyle.KEY_ENEMY_BF109, death_at)
	var small_after := _count_explosions(false)
	_check("enemy_destroyed: ровно один малый взрыв", small_after == small_before + 1,
		"было %d, стало %d" % [small_before, small_after])
	var small_effect := _first_explosion(false)
	_check("enemy_destroyed: взрыв в точке гибели",
		small_effect != null and small_effect.global_position.is_equal_approx(death_at),
		str(small_effect.global_position) if small_effect != null else "взрыва нет")

	# boss_bomb_detonated → точечный флеш БЕЗ тряски (GDD «Game feel» её не задаёт).
	_level.shake.stop()
	var bomb_at := Vector2(270.0, 500.0)
	_level.boss_bomb_detonated.emit(bomb_at, BossBomb.BLAST_RADIUS)
	_check("boss_bomb_detonated: тряски нет", not _level.shake.is_shaking())
	_check("boss_bomb_detonated: искры добавлены без второго «круга-флеша»",
		_count_explosions(false) == small_before + 2,
		"было %d, стало %d" % [small_before, _count_explosions(false)])

	# bomb_detonated (бомба игрока) → тряска 6 px / 0.25 с.
	_level.bomb_detonated.emit(Vector2(270.0, 840.0), 620.0)
	_check("bomb_detonated: тряска запущена", _level.shake.is_shaking())
	_level.shake.stop()

	# boss_phase_changed → hit-stop 3 кадра.
	_level.boss_phase_changed.emit(2)
	_check("boss_phase_changed: hit-stop запущен", _level.hit_stop.is_frozen())
	var restored_after_phase := await _await_time_scale_restored(0.5)
	_check("hit-stop: time_scale восстановился после смены фазы", restored_after_phase)

	enemy.despawn()
	await get_tree().process_frame
	await get_tree().process_frame
	# Ревью: статик копил id убитых узлов — запись обязана умереть вместе с узлом.
	_check("hit_flash: запись убитого узла вычищена из кэша (WeakRef + tree_exited)",
		HitFlash.debug_active_records() == records_player_only,
		"записей %d, ожидалось %d" % [HitFlash.debug_active_records(), records_player_only])


func _check_muzzle_flash_nodes() -> void:
	# Игрок: узел один, любое число trigger'ов не создаёт новых узлов (8 выстр./с без аллокаций).
	var player_children := _level.player.get_child_count()
	for i in 5:
		_level.player_muzzle.trigger_at(Vector2(0.0, -26.0))
	_check("muzzle: у игрока один узел на любое число выстрелов",
		_count_muzzle(_level.player) == 1
		and _level.player.get_child_count() == player_children,
		"деталей %d → %d" % [player_children, _level.player.get_child_count()])
	_check("muzzle: вспышка активна после trigger", _level.player_muzzle.is_flashing())

	# Враг: один узел на борт; реальный путь сигнала (fire_direction) узлов не аллоцирует.
	var enemy := _level.spawn_enemy(LevelController.ENEMY_BF109_SCENE, Vector2(400.0, 160.0))
	enemy.set_physics_process(false)
	var enemy_children := enemy.get_child_count()
	var muzzle_offset := Vector2(0.0, EnemyBase.MUZZLE_OFFSET.y)
	enemy.fire_direction(enemy.global_position + muzzle_offset, Vector2.DOWN, 300.0)
	enemy.fire_direction(enemy.global_position + muzzle_offset, Vector2.DOWN, 300.0)
	_check("muzzle: у врага один узел, серия выстрелов не аллоцирует",
		_count_muzzle(enemy) == 1 and enemy.get_child_count() == enemy_children,
		"деталей %d → %d" % [enemy_children, enemy.get_child_count()])
	enemy.despawn()

	# Босс: ОДИН общий флеш на турели; два ствола в одном кадре → вспышка посередине.
	var boss := _level.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 200.0)) as BossHe111
	boss.set_physics_process(false)
	var boss_muzzle := boss.get_node(^"MuzzleFlash") as MuzzleFlash
	var turret_center := boss.global_position + Vector2(0.0, BossHe111.TURRET_OFFSET.y)
	boss.fire_direction(turret_center + Vector2(BossHe111.TURRET_OFFSET.x, 0.0), Vector2.DOWN, 300.0)
	boss.fire_direction(turret_center + Vector2(-BossHe111.TURRET_OFFSET.x, 0.0), Vector2.DOWN, 300.0)
	_check("muzzle: у босса один общий флеш на призыв", _count_muzzle(boss) == 1)
	_check("muzzle: два ствола в кадре → вспышка посередине (без дёрганья)",
		boss_muzzle.position.is_equal_approx(Vector2(0.0, BossHe111.TURRET_OFFSET.y)),
		str(boss_muzzle.position))
	boss.despawn()
	await get_tree().process_frame
	_level.bullets.clear_all()


## Ревью (MINOR): очередь турелей не аллоцирует ничего, кроме самих снарядов — литерал
## [-1.0, 1.0] на каждый залп заменён const BossHe111.TURRET_SIDES. Замер относительный:
## N снарядов из очереди против N «прямых» выстрелов тем же BulletLayer (одинаковый Bullet).
func _check_boss_burst_allocations() -> void:
	_level.bullets.clear_all()
	await get_tree().process_frame
	await get_tree().process_frame
	var boss := _level.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 200.0)) as BossHe111
	boss.set_physics_process(false)

	# База: ровно один Bullet на прямой выстрел.
	var base_before := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	for i in BURST_SAMPLES:
		_level.bullets.fire_enemy(Vector2(270.0, 300.0), Vector2.DOWN * 300.0, 1)
	var base_delta := int(Performance.get_monitor(Performance.OBJECT_COUNT)) - base_before
	_level.bullets.clear_all()
	await get_tree().process_frame
	await get_tree().process_frame

	# Очередь босса: те же BURST_SAMPLES снарядов, но через два ствола.
	var burst_before := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	for i in BURST_SAMPLES / 2:
		boss._fire_aimed_shot()
	var burst_delta := int(Performance.get_monitor(Performance.OBJECT_COUNT)) - burst_before
	_check("очередь босса: два ствола на залп = два снаряда",
		_level.bullets.count_bullets(true) == BURST_SAMPLES,
		"снарядов %d" % _level.bullets.count_bullets(true))
	_check("очередь босса: кроме Bullet ничего не аллоцируется (база %d, очередь %d)"
		% [base_delta, burst_delta], burst_delta == base_delta,
		"база %d, очередь %d" % [base_delta, burst_delta])
	_level.bullets.clear_all()
	boss.despawn()
	await get_tree().process_frame


func _check_damage_fx() -> void:
	var fx := _level.damage_fx
	_level.player.health_changed.emit(3)
	_check("damage_fx: 3 HP — тихо", not fx.is_smoking() and not fx.is_burning())
	_level.player.health_changed.emit(2)
	_check("damage_fx: 2 HP — дым", fx.is_smoking() and not fx.is_burning())
	_level.player.health_changed.emit(1)
	_check("damage_fx: 1 HP — огонь", fx.is_burning() and not fx.is_smoking())
	_level.player.health_changed.emit(0)
	_check("damage_fx: 0 HP — тихо (гибель)", not fx.is_smoking() and not fx.is_burning())
	_level.player.health_changed.emit(3)
	_check("damage_fx: рестарт (3 HP) выключает оба", not fx.is_smoking() and not fx.is_burning())


## РЕАЛЬНЫЙ путь гибели босса: boss_destroyed → _finish_run. Ровно ОДИН крупный взрыв,
## ни одного BombFlash (плейсхолдер M2 на исходе обязан быть убран — иначе двойной взрыв).
## M3C-QA-01: заодно проверяется, что локальный рекорд пишется в qa-файл, а строка оверлея
## не зависит от рекорда, лежащего на машине.
func _check_boss_death_single_explosion() -> void:
	await _reset_level()
	_check("рекорд: путь изолирован на qa_juice-файл перед победой",
		RunRecord.get_save_path() == _record_path
		and _record_path.begins_with("user://qa_juice_"),
		RunRecord.get_save_path())
	# Начальный рекорд НИЖЕ счёта победы: ветка «Новый рекорд» детерминирована на любой машине.
	_write_record_best(RECORD_SEED)
	var boss := _level.spawn_enemy(WaveManager.BOSS_SCENE, Vector2(270.0, 200.0)) as BossHe111
	boss.set_physics_process(false)
	boss.take_damage(9999)
	await get_tree().process_frame
	_check("гибель босса: ровно один КРУПНЫЙ взрыв и никаких малых",
		_count_explosions(true) == 1 and _count_explosions(false) == 0,
		"крупных %d, малых %d" % [_count_explosions(true), _count_explosions(false)])
	_check("гибель босса: без двойного взрыва — ни одного BombFlash", _count_bomb_flashes() == 0)
	_check("гибель босса: тряска 8 px / 0.4 с запущена", _level.shake.is_shaking())
	var win_shown: bool = await _wait_until(
		func() -> bool: return _level.win_overlay.visible and get_tree().paused, 2.5
	)
	_check("гибель босса: окно исхода завершилось паузой (WON)", win_shown)
	# Счёт победы (враг + бонус за оставшиеся HP) и есть записанный рекорд.
	var win_score := _level.get_score()
	_check("рекорд: RecordLine «Новый рекорд: N» не зависит от рекорда машины",
		String(_level.win_overlay.record_line.text) == "Новый рекорд: %d" % win_score,
		"счёт %d, строка «%s»" % [win_score, _level.win_overlay.record_line.text])
	_check("рекорд: qa-файл содержит рекорд миссии со счётом победы",
		_read_record_best() == win_score,
		"%d (ожидалось %d)" % [_read_record_best(), win_score])
	_level.start_level()
	await get_tree().process_frame


## РЕАЛЬНЫЙ путь гибели игрока: player_died → _finish_run(false). Ровно один взрыв,
## плейсхолдерного флеша нет.
func _check_player_death_single_explosion() -> void:
	await _reset_level()
	_level.player._invulnerability_left = 0.0
	_level.player.take_hit(Player.MAX_HP)
	await get_tree().process_frame
	_check("гибель игрока: ровно один взрыв на точке гибели (без крупного)",
		_count_explosions(false) == 1 and _count_explosions(true) == 0,
		"малых %d, крупных %d" % [_count_explosions(false), _count_explosions(true)])
	_check("гибель игрока: без двойного взрыва — ни одного BombFlash", _count_bomb_flashes() == 0)
	var death_shown: bool = await _wait_until(
		func() -> bool: return _level.death_overlay.visible and get_tree().paused, 2.5
	)
	_check("гибель игрока: окно исхода завершилось паузой (DEAD)", death_shown)
	_level.start_level()
	await get_tree().process_frame


## Глобальная страховка: после любого числа hit-stop'ов время всегда возвращается к 1.
func _check_time_scale_restored() -> void:
	var restored := await _await_time_scale_restored(1.0)
	_check("time_scale: восстановлен к 1 после всех сценариев", restored, str(Engine.time_scale))


# ─── Вспомогательные ────────────────────────────────────────────────────────
## Ждём восстановления Engine.time_scale по РЕАЛЬНОМУ времени (заморозка обнуляет delta).
func _await_time_scale_restored(timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not is_equal_approx(Engine.time_scale, 1.0) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return is_equal_approx(Engine.time_scale, 1.0)


func _wait_until(condition: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _clear_enemies() -> void:
	for child in _level.enemies_root.get_children():
		var enemy := child as EnemyBase
		if enemy != null:
			enemy.despawn()
		else:
			child.queue_free()


## Число узлов-вспышек у борта (ровно один — переиспользуемый).
func _count_muzzle(owner: Node2D) -> int:
	var total := 0
	for child in owner.get_children():
		if child is MuzzleFlash and not child.is_queued_for_deletion():
			total += 1
	return total


## Число взрывов заданного размера в Effects. Опознавание по ГРУППЕ: имена второго и
## последующих взрывов того же типа движок переименовывает (@Node2D@N) — см. Explosions.
func _count_explosions(big: bool) -> int:
	var total := 0
	for child in _level.effects_root.get_children():
		if child.is_queued_for_deletion():
			continue
		if child.is_in_group(Explosions.GROUP_EXPLOSION) and child.is_in_group(Explosions.GROUP_EXPLOSION_BOSS) == big:
			total += 1
	return total


func _first_explosion(big: bool) -> Node2D:
	for child in _level.effects_root.get_children():
		if child.is_queued_for_deletion():
			continue
		if child.is_in_group(Explosions.GROUP_EXPLOSION) and child.is_in_group(Explosions.GROUP_EXPLOSION_BOSS) == big:
			return child as Node2D
	return null


func _count_bomb_flashes() -> int:
	var total := 0
	for child in _level.effects_root.get_children():
		if child is BombFlash and not child.is_queued_for_deletion():
			total += 1
	return total


# ─── M3C-QA-01: файловые помощники рекорда (user://) ──────────────────────────
func _remove_user_file(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Перезаписать qa-файл начальным рекордом (ветка «Новый рекорд» на любой машине).
func _write_record_best(best: int) -> void:
	var config := ConfigFile.new()
	config.set_value(RECORD_SECTION, RECORD_KEY, best)
	config.save(_record_path)


## Рекорд из qa-файла читается напрямую с диска: M5.3a пишет рекорд миссии в
## [records] best_m1..m3 (забег идёт по m1_airfield), RunRecord в забеге больше не участвует.
func _read_record_best() -> int:
	var config := ConfigFile.new()
	if config.load(_record_path) != OK:
		return -1
	var best := -1
	for index in 3:
		best = maxi(best, int(config.get_value(SAVE_RECORDS_SECTION, "best_m%d" % (index + 1), -1)))
	return best


## Слепок user:// файла: существование, размер, mtime, текст. Разница «до/после» —
## доказательство, что прогон не создал и не перезаписал рекорд игрока.
func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": -1, "mtime": -1, "text": ""}
	var snapshot := {
		"exists": true, "size": -1, "mtime": FileAccess.get_modified_time(path), "text": ""
	}
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		snapshot["size"] = file.get_length()
		snapshot["text"] = file.get_as_text()
		file.close()
	return snapshot


## Dictionary == в GDScript сравнивает по ссылке — поля сравниваем явно.
func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	return bool(a.get("exists", false)) == bool(b.get("exists", false)) \
		and int(a.get("size", -1)) == int(b.get("size", -1)) \
		and int(a.get("mtime", -1)) == int(b.get("mtime", -1)) \
		and String(a.get("text", "")) == String(b.get("text", ""))


func _snapshot_brief(snapshot: Dictionary) -> String:
	if not bool(snapshot.get("exists", false)):
		return "файла нет"
	return "%d байт, mtime %d, «%s»" % [
		int(snapshot.get("size", -1)), int(snapshot.get("mtime", -1)),
		String(snapshot.get("text", "")).strip_edges()]


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
