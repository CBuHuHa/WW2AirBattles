# perk_choice_test.gd
# Purpose: Гейт M6.1b «выбор перка после волн 2/3/4, пауза, HUD-слоты и аварийный сброс»
#          (GDD «Временные перки», «UI / HUD»):
#            * оверлей PerkChoice: 2 карточки, имена/категории/описания из PerkData, латч,
#              «чужой» id не применяется, корень IGNORE + кнопка STOP;
#            * LevelController: предложение после волн 2/3/4 (индексы 1/2/3), пауза дерева,
#              снятие паузы после выбора, ровно 3 выбора за миссию, без повторов,
#              PauseButton не открывает паузу поверх выбора;
#            * HUD: set_max_hp/set_perks — «HP 4/4», 4 иконки, 3 слота под HP (2+1), коды карт;
#            * «Аварийный сброс»: урон чистит вражеские пули в радиусе 120, кулдаун 6 с;
#            * set_perks_enabled(false) → оверлей не появляется;
#            * рестарт миссии → перки пусты, статы базовые (8 выстр./с, 1 урон, 800 px/s).
#          Дерево строится из main.tscn (реальная сцена), волны останавливаются сразу после
#          старта — сценарий управляет wave_cleared сам. Сейв изолирован во временный
#          user://qa_perk_*.cfg: победа/поражение реальный профиль не трогают.
# Запуск: godot --headless --path . res://tests/perk_choice_test.tscn
# Author: Mechanics Developer Agent (M6.1b)

extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")
## Контрольная вражеская пуля: далеко от игрока (≈412 px) и неподвижна — она обязана
## пережить радиальную очистку (доказательство, что перк чистит ТОЛЬКО радиус).
const CONTROL_BULLET_POS := Vector2(470.0, 480.0)
## Кулдаун «Аварийного сброса» из data/perks.json + запас на кадры.
const EMERGENCY_COOLDOWN_MARGIN := 0.35
## Неуязвимость после попадания (Player.INVULNERABILITY_TIME = 1.5 с) + запас.
const INVULNERABILITY_MARGIN := 0.2

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
var _save_path: String = ""
var _level: LevelController
## Эмиты perk_chosen: «ровно 3 выбора за миссию» проверяется по факту сигналов, а не по UI.
var _choice_events: Array[String] = []
## Сколько эмитов было до сценария «3 выбора» (реальный триггер тоже берёт карту).
var _events_baseline: int = 0


func _ready() -> void:
	Input.emulate_mouse_from_touch = false
	# Тест живёт и при get_tree().paused (пауза выбора — часть сценария).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_started_msec = Time.get_ticks_msec()
	# Изоляция сейва ДО первого инстанса main: поражение/победа не должны писать профиль.
	_save_path = "user://qa_perk_%d.cfg" % Time.get_ticks_msec()
	RunRecord.set_save_path(_save_path)
	_remove_user_file(_save_path)
	await get_tree().process_frame
	await _run()
	# Уборка изоляции: временный файл удалён, путь по умолчанию возвращён.
	_remove_user_file(_save_path)
	RunRecord.reset_save_path()
	print("PERK_CHOICE_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("PERK_CHOICE_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	await _boot()
	_check_wiring()
	await _check_real_wave_trigger()
	await _check_first_choice()
	await _check_three_choices()
	await _check_weapon_slots_rule()
	await _check_repair_hud()
	await _check_emergency_clear()
	await _check_perks_disabled()
	await _check_restart_and_base_stats()
	_check_hud_layout()
	_check_save_isolation()
	_teardown()


# ─── Стенд ──────────────────────────────────────────────────────────────────
func _boot() -> void:
	_level = MAIN_SCENE.instantiate() as LevelController
	add_child(_level)
	await get_tree().process_frame
	await get_tree().physics_frame
	_level.perk_choice.perk_chosen.connect(
		func(id: String) -> void: _choice_events.append(id))
	await _restart_mission()


## Свежий забег m1: волны и враги снимаются, чтобы сценарий сам решал, когда придёт
## wave_cleared (иначе волна 1 закроется через 1.2 с и сдвинет нумерацию).
func _restart_mission() -> void:
	_level.start_mission("m1_airfield")
	await get_tree().process_frame
	await get_tree().physics_frame
	_level.stop_waves()
	_clear_enemies()
	_level.bullets.clear_all()
	_level.hints.hide_hints()


func _clear_enemies() -> void:
	for group in [GameConfig.GROUP_ENEMIES, GameConfig.GROUP_BOSS]:
		for node in get_tree().get_nodes_in_group(group):
			var enemy := node as EnemyBase
			if enemy != null:
				enemy.despawn()


## Сбить всех живых врагов текущей волны (реальный триггер wave_cleared у WaveManager).
func _kill_current_wave() -> void:
	for node in get_tree().get_nodes_in_group(GameConfig.GROUP_ENEMIES):
		var enemy := node as EnemyBase
		if enemy != null and enemy.is_active:
			enemy.despawn()


func _teardown() -> void:
	_level.queue_free()
	_level = null


# ─── Обвязка оверлея ────────────────────────────────────────────────────────
func _check_wiring() -> void:
	var choice := _level.perk_choice
	_check("перки: PerkSystem создан узлом Perks",
		_level.get_perk_system() != null and _level.get_perk_system().name == "Perks"
		and _level.get_perk_system().get_parent() == _level,
		str(_level.get_perk_system()))
	_check("перки: новая миссия — система пуста, HUD без слотов, дерево не на паузе",
		_level.get_perk_system().get_active().is_empty()
		and _level.hud.get_perk_slot_count() == 0
		and not get_tree().paused)
	_check("оверлей: скрыт, карточек и предложений нет",
		not _level.is_perk_choice_visible() and choice.get_card_count() == 0
		and choice.get_offered_ids().is_empty())
	_check("оверлей: работает при паузе (PROCESS_MODE_ALWAYS)",
		choice.process_mode == Node.PROCESS_MODE_ALWAYS, str(choice.process_mode))
	_check("оверлей: корень прозрачен для тапов (IGNORE)",
		choice.mouse_filter == Control.MOUSE_FILTER_IGNORE, str(choice.mouse_filter))


# ─── Реальный триггер: волну закрывает сам WaveManager ─────────────────────
## Сценарий не эмитит wave_cleared руками, а сбивает волны через WaveManager: проверяется
## вся цепочка «последний враг волны 2 → пауза + оверлей» с настоящими таймерами брейка.
func _check_real_wave_trigger() -> void:
	_level.start_mission("m1_airfield")
	await get_tree().process_frame
	_level.hints.hide_hints()
	_check("реальный триггер: волна 1 запущена менеджером волн",
		_level.waves.is_active() and _level.waves.get_wave_index() == 0,
		str(_level.waves.get_wave_index()))
	_kill_current_wave()
	await get_tree().process_frame
	var waited := 0.0
	while waited < 4.0 and _level.waves.get_wave_index() < 1:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check("реальный триггер: после брейка пришла волна 2",
		_level.waves.get_wave_index() == 1, str(_level.waves.get_wave_index()))
	_kill_current_wave()
	await get_tree().process_frame
	_check("реальный триггер: закрытие волны 2 → оверлей выбора и пауза",
		_level.is_perk_choice_visible() and get_tree().paused)
	var picked: String = await _take_first_offer()
	_check("реальный триггер: выбор снял паузу и применил карту",
		not picked.is_empty() and not get_tree().paused
		and _level.get_perk_system().has(picked), picked)


# ─── Волна 2: первое предложение и выбор ────────────────────────────────────
func _check_first_choice() -> void:
	await _restart_mission()
	_events_baseline = _choice_events.size()
	_level.waves.wave_cleared.emit(0)  # волна 1 — карты не предлагаются
	await get_tree().process_frame
	_check("волна 1: карта не предлагается",
		not _level.is_perk_choice_visible() and not get_tree().paused)

	_level.waves.wave_cleared.emit(1)  # волна 2
	await get_tree().process_frame
	var offered := _level.perk_choice.get_offered_ids()
	_check("волна 2: оверлей выбора показан", _level.is_perk_choice_visible())
	_check("волна 2: игра на паузе (GDD: «игра на паузе»)", get_tree().paused)
	_check("волна 2: 2 карточки и 2 разных предложения",
		_level.perk_choice.get_card_count() == 2 and offered.size() == 2
		and offered[0] != offered[1], str(offered))
	var available := _level.get_perk_system().available_cards()
	_check("волна 2: предложены только доступные карты",
		not offered.is_empty() and available.has(offered[0]) and available.has(offered[1]))
	_check("волна 2: карточка берёт название/категорию/описание из PerkData",
		_card_texts_ok(offered[0]) and _card_texts_ok(offered[1]))
	var button := _card_button(offered[0])
	_check("волна 2: кнопка карточки потребляет тач (STOP, ≥64 px)",
		button != null and button.mouse_filter == Control.MOUSE_FILTER_STOP
		and button.custom_minimum_size.y >= 64.0,
		str(button.custom_minimum_size) if button != null else "нет кнопки")
	# Раскладка без скриншота: две карточки в поле 540×960, не перекрываются, ширина ≥ 200 px
	# (описание из PerkData переносится по словам, длинные строки не вылезают за карточку).
	var field := Rect2(Vector2.ZERO, GameConfig.REFERENCE_SIZE)
	var first_rect := _card_rect(offered[0])
	var second_rect := _card_rect(offered[1])
	_check("волна 2: карточки в поле 540×960 и не уже 200 px",
		first_rect.size.x >= 200.0 and field.encloses(first_rect)
		and field.encloses(second_rect),
		"%s / %s" % [first_rect, second_rect])
	_check("волна 2: карточки не перекрывают друг друга",
		not first_rect.intersects(second_rect), "%s × %s" % [first_rect, second_rect])

	# Пауза поверх обязательного выбора не открывается.
	_level.pause_button.pause_requested.emit()
	await get_tree().process_frame
	_check("выбор: PauseButton не открывает паузу поверх выбора",
		_level.get_state() == LevelController.State.PLAYING
		and not _level.pause_overlay.visible and _level.is_perk_choice_visible(),
		"state=%s, pause_overlay=%s" % [_level.get_state(), _level.pause_overlay.visible])

	_check("выбор: карта вне предложения игнорируется",
		not _level.perk_choice.request_perk("nope") and _level.is_perk_choice_visible())

	var picked := offered[0]
	_check("выбор: request_perk(первая карта) → true",
		_level.perk_choice.request_perk(picked))
	await get_tree().process_frame
	_check("выбор: оверлей скрыт, пауза снята",
		not _level.is_perk_choice_visible() and not get_tree().paused
		and _level.perk_choice.get_card_count() == 0)
	_check("выбор: карта активна в PerkSystem", _level.get_perk_system().has(picked),
		str(_level.get_perk_system().get_active()))
	_check("выбор: эффект карты применён к игроку", _card_effect_applied(picked), picked)
	_check("выбор: HUD показывает 1 слот с кодом карты",
		_level.hud.get_perk_slot_count() == 1
		and _level.hud.get_perk_slot_text(_slot_index_for(picked))
			== String(Hud.PERK_CODES.get(picked, "")),
		"%d / «%s»" % [_level.hud.get_perk_slot_count(),
			_level.hud.get_perk_slot_text(_slot_index_for(picked))])


# ─── Волны 2/3/4: ровно три выбора, без повторов ────────────────────────────
func _check_three_choices() -> void:
	# Повторный wave_cleared(1) в том же забеге вторую карту не предлагает.
	_level.waves.wave_cleared.emit(1)
	await get_tree().process_frame
	_check("волна 2 повторно: оверлей не появляется",
		not _level.is_perk_choice_visible() and not get_tree().paused)

	_level.waves.wave_cleared.emit(2)
	await get_tree().process_frame
	_check("волна 3: второе предложение показано",
		_level.is_perk_choice_visible() and get_tree().paused)
	var second: String = await _take_first_offer()
	_check("волна 3: второй выбор применён",
		not second.is_empty() and _level.get_perk_system().get_active().size() == 2
		and not get_tree().paused, str(_level.get_perk_system().get_active()))

	_level.waves.wave_cleared.emit(3)
	await get_tree().process_frame
	_check("волна 4: третье предложение показано",
		_level.is_perk_choice_visible() and get_tree().paused)
	var third: String = await _take_first_offer()
	_check("волна 4: третий выбор применён",
		not third.is_empty() and _level.get_perk_system().get_active().size() == 3,
		str(_level.get_perk_system().get_active()))
	_check("ровно 3 выбора за миссию (сигналов perk_chosen: 3)",
		_choice_events.size() - _events_baseline == 3,
		"%d сигналов" % (_choice_events.size() - _events_baseline))
	_check("HUD: заполнены все 3 слота перков",
		_level.hud.get_perk_slot_count() == 3,
		"%d слотов" % _level.hud.get_perk_slot_count())

	_level.waves.wave_cleared.emit(4)  # волна 5
	await get_tree().process_frame
	_check("волна 5: оверлея нет (3 выбора за миссию исчерпаны)",
		not _level.is_perk_choice_visible() and not get_tree().paused)


# ─── Слоты: третье оружие не предлагается ──────────────────────────────────
func _check_weapon_slots_rule() -> void:
	await _restart_mission()
	var system := _level.get_perk_system()
	# Занимаем оба оружейных слота данными: дальше предлагать можно только утилиту.
	system.take("sparka")
	system.take("ap")
	_level.waves.wave_cleared.emit(1)
	await get_tree().process_frame
	var offered := _level.perk_choice.get_offered_ids()
	var only_utility := not offered.is_empty()
	for id in offered:
		if PerkData.get_category(id) != PerkData.CATEGORY_UTILITY:
			only_utility = false
	_check("слоты: после 2 оружий третье оружие не предлагается (только утилиты)",
		only_utility and _level.perk_choice.get_card_count() == offered.size(), str(offered))
	var picked: String = await _take_first_offer()
	_check("слоты: утилита заняла третий слот (2 оружия + 1 утилита)",
		not picked.is_empty()
		and system.get_active_by_category(PerkData.CATEGORY_UTILITY).size() == 1
		and system.get_active_by_category(PerkData.CATEGORY_WEAPON).size() == 2,
		str(system.get_active()))


# ─── HUD: «Ремонт» → 4 HP ───────────────────────────────────────────────────
func _check_repair_hud() -> void:
	await _restart_mission()
	# Путь тот же, что в _on_perk_chosen (take → apply_to → HUD), но карта взята явно:
	# какие карты выпадут в руллонe, решает ГПСЧ, а 4 HP нужны детерминированно.
	_level.get_perk_system().take("repair")
	_level.get_perk_system().apply_to(_level.player)
	_level.hud.set_max_hp(_level.player.max_hp)
	_level.hud.set_hp(_level.player.hp)
	_level.hud.set_perks(_level.get_perk_system().get_active())
	_check("ремонт: потолок HP 4 у игрока и HUD",
		_level.player.max_hp == 4 and _level.hud.max_hp == 4,
		"игрок %d, HUD %d" % [_level.player.max_hp, _level.hud.max_hp])
	_check("ремонт: строка «HP 4/4»", String(_level.hud.hp_label.text) == "HP 4/4",
		String(_level.hud.hp_label.text))
	var icons_right := Hud.HP_ICON_ORIGIN.x + Hud.HP_ICON_STEP * 3.0 \
		+ ArtStyle.size_of(ArtStyle.KEY_UI_HP).x
	_check("ремонт: 4-я иконка HP не заходит под текст",
		icons_right <= _level.hud.hp_label.get_global_rect().position.x,
		"иконки до %.0f px, текст с %.0f px" % [
			icons_right, _level.hud.hp_label.get_global_rect().position.x])
	_check("ремонт: слот утилиты показывает «РЕ»",
		_level.hud.get_perk_slot_count() == 1
		and _level.hud.get_perk_slot_text(Hud.PERK_SLOT_COUNT - 1) == "РЕ",
		_level.hud.get_perk_slot_text(Hud.PERK_SLOT_COUNT - 1))


# ─── «Аварийный сброс»: урон → очистка пуль, кулдаун 6 с ────────────────────
func _check_emergency_clear() -> void:
	await _restart_mission()
	var player := _level.player
	var system := _level.get_perk_system()
	system.take("emergency")
	system.apply_to(player)
	_check("аварийный сброс: карта применена (флаг, радиус 120, кулдаун 6 с)",
		player.emergency_clear and is_equal_approx(player.emergency_clear_radius, 120.0)
		and is_equal_approx(player.emergency_clear_cooldown, 6.0),
		"флаг=%s, r=%.0f, кд=%.0f" % [player.emergency_clear,
			player.emergency_clear_radius, player.emergency_clear_cooldown])
	_check("аварийный сброс: первый сброс доступен сразу",
		player.can_use_emergency_clear())

	# 1. Готовый перк: урон чистит пули в радиусе 120, контрольная пуля остаётся.
	_prepare_bullets(player)
	player.take_hit(1)
	_check("аварийный сброс: урон уничтожил 2 пули в радиусе (контрольная жива)",
		_level.bullets.count_bullets(true) == 1,
		"вражеских пуль %d" % _level.bullets.count_bullets(true))
	_check("аварийный сброс: кулдаун запущен",
		not player.can_use_emergency_clear())

	# 2. Повторный урон в течение 6 с (неуязвимость 1.5 с уже прошла) пули НЕ чистит.
	await get_tree().create_timer(Player.INVULNERABILITY_TIME + INVULNERABILITY_MARGIN).timeout
	_prepare_bullets(player)
	player.take_hit(1)
	_check("аварийный сброс: повторный урон раньше 6 с пули не чистит",
		_level.bullets.count_bullets(true) == 3,
		"вражеских пуль %d" % _level.bullets.count_bullets(true))

	# 3. После кулдауна (6 с от первого сброса) перк снова работает.
	var remaining := player.emergency_clear_cooldown - player.get_seconds_since_emergency_clear()
	await get_tree().create_timer(maxf(remaining, 0.1) + EMERGENCY_COOLDOWN_MARGIN).timeout
	player.heal(1)  # чтобы смертельный удар не превратил проверку в экран поражения
	_check("аварийный сброс: после 6 с снова доступен", player.can_use_emergency_clear())
	_prepare_bullets(player)
	var hp_before := player.hp
	player.take_hit(1)
	_check("аварийный сброс: после кулдауна пули снова уничтожены",
		player.hp == hp_before - 1 and _level.bullets.count_bullets(true) == 1,
		"hp %d → %d, пуль %d" % [hp_before, player.hp,
			_level.bullets.count_bullets(true)])


# ─── Выключенные перки (путь smoke-теста) ───────────────────────────────────
func _check_perks_disabled() -> void:
	await _restart_mission()
	_level.set_perks_enabled(false)
	_level.waves.wave_cleared.emit(1)
	await get_tree().process_frame
	_check("set_perks_enabled(false): оверлей не появляется, паузы нет",
		not _level.is_perk_choice_visible() and not get_tree().paused
		and _level.get_perk_system().get_active().is_empty())
	_level.set_perks_enabled(true)


# ─── Рестарт и база Ла-5 ────────────────────────────────────────────────────
func _check_restart_and_base_stats() -> void:
	await _restart_mission()
	_level.waves.wave_cleared.emit(1)
	await get_tree().process_frame
	var picked: String = await _take_first_offer()
	_check("рестарт: перед рестартом перк активен",
		not picked.is_empty() and not _level.get_perk_system().get_active().is_empty(),
		picked)
	_level.start_level()
	await get_tree().process_frame
	_level.stop_waves()
	_clear_enemies()
	_check("рестарт: перки пусты", _level.get_perk_system().get_active().is_empty(),
		str(_level.get_perk_system().get_active()))
	_check("рестарт: HUD без слотов, 3 HP и «HP 3/3»",
		_level.hud.get_perk_slot_count() == 0 and _level.hud.max_hp == 3
		and String(_level.hud.hp_label.text) == "HP 3/3",
		"%d слотов, %s" % [_level.hud.get_perk_slot_count(), _level.hud.hp_label.text])
	_check("рестарт: оверлей скрыт, пауза снята",
		not _level.is_perk_choice_visible() and not get_tree().paused)

	var player := _level.player
	_check("база: 8 выстр./с, 1 урон, 800 px/s, 1 снаряд в залпе",
		is_equal_approx(player.fire_interval, 0.125)
		and is_equal_approx(player.bullet_damage, 1.0)
		and is_equal_approx(player.bullet_speed, 800.0)
		and player.bullets_per_shot == 1,
		"%.3f с, %.2f, %.0f px/s, %d" % [player.fire_interval, player.bullet_damage,
			player.bullet_speed, player.bullets_per_shot])
	var shots: Array = []
	var handler := func(origin: Vector2, velocity: Vector2, damage: float) -> void:
		shots.append({"origin": origin, "velocity": velocity, "damage": damage})
	player.shot_fired.connect(handler)
	player.fire_volley()
	player.shot_fired.disconnect(handler)
	var volley_ok := shots.size() == 1
	if volley_ok:
		volley_ok = (shots[0]["velocity"] as Vector2).is_equal_approx(Vector2(0.0, -800.0)) \
			and is_equal_approx(float(shots[0]["damage"]), 1.0) \
			and (shots[0]["origin"] as Vector2).is_equal_approx(
				player.global_position + Player.MUZZLE_OFFSET)
	_check("база: залп — 1 снаряд ровно вверх, урон 1.0", volley_ok, str(shots))


# ─── Раскладка HUD: слоты не мешают счёту/полосе босса ──────────────────────
func _check_hud_layout() -> void:
	var hud := _level.hud
	var icon_height := ArtStyle.size_of(ArtStyle.KEY_UI_HP).y
	var slots := Rect2(Hud.PERK_SLOT_ORIGIN,
		Vector2(Hud.PERK_SLOT_STEP * float(Hud.PERK_SLOT_COUNT - 1) + Hud.PERK_SLOT_SIZE.x,
			Hud.PERK_SLOT_SIZE.y))
	_check("раскладка: слоты перков под рядом HP",
		slots.position.y >= Hud.HP_ICON_ORIGIN.y + icon_height,
		"слоты с y=%.0f" % slots.position.y)
	_check("раскладка: слоты перков не заходят под счёт",
		slots.end.x <= hud.score_label.get_global_rect().position.x,
		"слоты до %.0f px, счёт с %.0f px" % [
			slots.end.x, hud.score_label.get_global_rect().position.x])
	_check("раскладка: слоты перков не перекрывают полосу HP босса",
		slots.end.y <= hud.boss_bar.get_global_rect().position.y,
		"слоты до y=%.0f, полоса с y=%.0f" % [
			slots.end.y, hud.boss_bar.get_global_rect().position.y])
	var font := hud.get_theme_default_font()
	_check("раскладка: код карты (2 буквы, 16 px) влезает в слот 26 px",
		font != null and font.get_string_size("СП", HORIZONTAL_ALIGNMENT_LEFT, -1,
			Hud.PERK_SLOT_FONT_SIZE).x <= Hud.PERK_SLOT_SIZE.x - 4.0,
		"%.1f px при слоте %.0f" % [
			font.get_string_size("СП", HORIZONTAL_ALIGNMENT_LEFT, -1,
				Hud.PERK_SLOT_FONT_SIZE).x if font != null else -1.0,
			Hud.PERK_SLOT_SIZE.x])


func _check_save_isolation() -> void:
	_check("сейв: прогон писал только во временный user://qa_perk_*.cfg",
		RunRecord.get_save_path() == _save_path and _save_path.begins_with("user://qa_perk_"),
		RunRecord.get_save_path())


# ─── Хелперы ────────────────────────────────────────────────────────────────
## Дождаться оверлея, взять первую карту. Возвращает id ("" — предложения не было).
func _take_first_offer() -> String:
	var offers := _level.perk_choice.get_offered_ids()
	if offers.is_empty():
		return ""
	var picked := offers[0]
	if not _level.perk_choice.request_perk(picked):
		return ""
	await get_tree().process_frame
	return picked


## Контрольная пуля вне радиуса + две пули в 120 px от игрока.
func _prepare_bullets(player: Player) -> void:
	_level.bullets.clear_all()
	_level.bullets.fire_enemy(CONTROL_BULLET_POS, Vector2.ZERO, 1)
	var at := player.global_position
	_level.bullets.fire_enemy(at + Vector2(-40.0, -60.0), Vector2.UP * 120.0, 1)
	_level.bullets.fire_enemy(at + Vector2(40.0, 60.0), Vector2.UP * 120.0, 1)


func _card_texts_ok(id: String) -> bool:
	var panel := _level.perk_choice.cards_box.get_node_or_null(
		NodePath("Card_" + id)) as Control
	if panel == null:
		return false
	var inner := panel.get_node_or_null(NodePath("Inner"))
	if inner == null:
		return false
	var name_label := inner.get_node_or_null(NodePath("NameLabel")) as Label
	var category_label := inner.get_node_or_null(NodePath("CategoryLabel")) as Label
	var description_label := inner.get_node_or_null(NodePath("DescriptionLabel")) as Label
	var expected_label := "Оружие"
	if PerkData.get_category(id) == PerkData.CATEGORY_UTILITY:
		expected_label = "Утилита"
	return name_label != null and String(name_label.text) == PerkData.get_card_name(id) \
		and category_label != null and String(category_label.text) == expected_label \
		and description_label != null \
		and String(description_label.text) == PerkData.get_card_description(id)


func _card_button(id: String) -> Button:
	var panel := _level.perk_choice.cards_box.get_node_or_null(
		NodePath("Card_" + id))
	if panel == null:
		return null
	return panel.get_node_or_null(NodePath("Inner/TakeButton")) as Button


func _card_rect(id: String) -> Rect2:
	var panel := _level.perk_choice.cards_box.get_node_or_null(
		NodePath("Card_" + id)) as Control
	if panel == null:
		return Rect2()
	return panel.get_global_rect()


## Эффект карты дошёл до полей игрока (единственный путь — PerkSystem.apply_to → Player).
func _card_effect_applied(id: String) -> bool:
	var player := _level.player
	match id:
		"sparka":
			return player.bullets_per_shot == 2
		"ap":
			return is_equal_approx(player.bullet_damage, 2.0)
		"rockets":
			return player.rocket_enabled
		"shatter":
			return player.splash_radius > 0.0
		"accuracy":
			return player.bullet_speed > Player.BULLET_SPEED
		"heavy":
			return player.boss_damage_mult > 1.0
		"repair":
			return player.max_hp == Player.MAX_HP + 1
		"coolhead":
			return player.invuln_time > Player.INVULNERABILITY_TIME
		"emergency":
			return player.emergency_clear
		_:
			return false


## Слот HUD для карты: утилита — последний, оружие — по порядку взятия (0…1).
func _slot_index_for(id: String) -> int:
	if PerkData.get_category(id) == PerkData.CATEGORY_UTILITY:
		return Hud.PERK_SLOT_COUNT - 1
	var index := 0
	for active in _level.get_perk_system().get_active():
		if active == id:
			return index
		if PerkData.get_category(active) != PerkData.CATEGORY_UTILITY:
			index += 1
	return 0


func _remove_user_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
