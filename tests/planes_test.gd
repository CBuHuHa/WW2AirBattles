# planes_test.gd
# Purpose: Гейт M6.2a «данные трёх самолётов, открытие, снабжение и ливреи» (GDD «Самолёты
#          (ангар)», «Счёт, звёзды, снабжение», «Реализация v1» → «Сейв v2»). Проверяет:
#            • data/planes.json: PlaneData.validate() пуст, 3 самолёта, статы ровно по GDD
#              (Ла-5 0.125/1.0/800/r8/пуля 4; Як-3 0.1/0.85/800/r7/пуля 4;
#               P-39 0.153846/1.5/800/r8/пуля 6), ключи арта и правила открытия;
#            • выбор самолёта: закрытый/неизвестный id → false без изменения, открытый → true,
#              Ла-5 открыт всегда; выбранный id переживает чтение файла;
#            • открытие по прогрессу: m1+m2+m3 c ≥1 звездой → Як-3, 9/9 звёзд → Аэрокобра,
#              повторно не открываются, поражение не открывает ничего;
#            • spend_supply: строгое списание, не уходит ниже 0, отрицательная цена → false;
#            • ливреи: цены 300/600/900, покупка списывает ровно цену, повтор → false,
#              выбор только купленной (0 — всегда), цены вне диапазона → 0;
#            • Player.apply_plane(): статы/хитбокс/ключ визуала для всех трёх, перки ложатся
#              на базу самолёта, reset_perks() возвращает базу ВЫБРАННОГО, неизвестный id
#              ничего не меняет;
#            • Bullet: hit_radius дублирует CollisionShape2D (4 у Ла-5, 6 у P-39, 5 по
#              умолчанию), радиус одного снаряда не протекает в другой.
#          Ангара/UI и визуала ливрей здесь нет — это M6.2b.
#          Тест строит минимальное дерево (Player + BulletLayer), сейв изолирован в
#          user://qa_planes_*.cfg: реальный профиль не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/planes_test.tscn
# Dependencies: PlaneData, SaveGame, CampaignProgress, MissionData, Player, BulletLayer.
# Author: Mechanics Developer Agent

extends Node

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const BULLET_SCENE: PackedScene = preload("res://scenes/bullet.tscn")

const M1 := "m1_airfield"
const M2 := "m2_crossing"
const M3 := "m3_city"

## GDD «Самолёты (ангар)»: точные статы (tune). Интервал P-39 — 1 / 6.5.
const LA5 := {
	"fire_interval": 0.125, "damage": 1.0, "bullet_speed": 800.0,
	"hit_radius": 8.0, "bullet_hit_radius": 4.0,
	"asset_key": "player_la5", "unlock": "start",
}
const YAK3 := {
	"fire_interval": 0.1, "damage": 0.85, "bullet_speed": 800.0,
	"hit_radius": 7.0, "bullet_hit_radius": 4.0,
	"asset_key": "player_yak3", "unlock": "campaign",
}
const P39 := {
	"fire_interval": 0.153846, "damage": 1.5, "bullet_speed": 800.0,
	"hit_radius": 8.0, "bullet_hit_radius": 6.0,
	"asset_key": "player_p39", "unlock": "stars_9",
}

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}

var _world: Node2D
var _player: Player
var _bullets: BulletLayer
var _extra_player: Player


func _ready() -> void:
	_started_msec = Time.get_ticks_msec()
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_planes_%d.cfg" % Time.get_ticks_msec()
	SaveGame.set_save_path(_path)
	await _run()
	_teardown()
	_remove_file(_path)
	RunRecord.reset_save_path()
	_check("изоляция: путь вернулся к DEFAULT_PATH и qa-файл удалён",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH and not FileAccess.file_exists(_path),
		SaveGame.get_save_path())
	var real_after := _file_snapshot(RunRecord.DEFAULT_PATH)
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_snapshot, real_after),
		"%s → %s" % [_snapshot_brief(_real_snapshot), _snapshot_brief(real_after)])
	print("PLANES_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("PLANES_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_build_tree()
	_check_data()
	_check_selected_plane()
	_check_plane_unlocks()
	_check_supply()
	_check_liveries()
	_check_player_planes()
	_check_perks_on_planes()
	_check_bullet_radius()
	_check_hitbox_isolation()


# ─── Минимальное дерево ─────────────────────────────────────────────────────
func _build_tree() -> void:
	_world = Node2D.new()
	_world.name = "World"
	add_child(_world)
	_player = PLAYER_SCENE.instantiate() as Player
	_world.add_child(_player)
	_player.set_process(false)
	_bullets = BulletLayer.new()
	_bullets.name = "Bullets"
	_world.add_child(_bullets)


func _teardown() -> void:
	if is_instance_valid(_extra_player):
		_extra_player.queue_free()
		_extra_player = null
	if is_instance_valid(_world):
		_world.queue_free()
	_world = null
	_player = null
	_bullets = null


# ─── Данные ─────────────────────────────────────────────────────────────────
func _check_data() -> void:
	var errors := PlaneData.validate()
	_check("данные: PlaneData.validate() без ошибок", errors.is_empty(), str(errors))
	_check("данные: файл data/planes.json существует",
		FileAccess.file_exists(PlaneData.DATA_PATH), PlaneData.DATA_PATH)
	var all := PlaneData.get_all()
	_check("данные: 3 самолёта", all.size() == 3, str(all.size()))
	_check("данные: id и порядок — la5/yak3/p39",
		PlaneData.get_ids() == ["la5", "yak3", "p39"], str(PlaneData.get_ids()))
	_check("данные: Ла-5 — 0.125 с / 1.0 / 800 / r8 / пуля 4 / start",
		_stats_match("la5", LA5), _stats_brief("la5"))
	_check("данные: Як-3 — 0.1 с / 0.85 / 800 / r7 / пуля 4 / campaign",
		_stats_match("yak3", YAK3), _stats_brief("yak3"))
	_check("данные: P-39 — 0.153846 с / 1.5 / 800 / r8 / пуля 6 / stars_9",
		_stats_match("p39", P39), _stats_brief("p39"))
	var texts_ok := true
	var bad := ""
	for id: String in PlaneData.get_ids():
		if PlaneData.get_plane_name(id).is_empty() or PlaneData.get_description(id).is_empty():
			texts_ok = false
			bad = id
	_check("данные: у всех самолётов есть name и description", texts_ok, bad)
	_check("данные: неизвестный самолёт → {} и ключ арта Ла-5",
		PlaneData.get_plane("biplane").is_empty()
		and not PlaneData.has_plane("biplane")
		and PlaneData.get_asset_key("biplane") == &"player_la5",
		str(PlaneData.get_plane("biplane")))


# ─── Выбранный самолёт (сейв) ───────────────────────────────────────────────
func _check_selected_plane() -> void:
	_fresh()
	_check("выбор: на чистом профиле выбран Ла-5", SaveGame.get_selected_plane() == "la5",
		SaveGame.get_selected_plane())
	_check("выбор: закрытый Як-3 выбрать нельзя, значение не меняется",
		not SaveGame.select_plane("yak3") and SaveGame.get_selected_plane() == "la5",
		SaveGame.get_selected_plane())
	_check("выбор: неизвестный самолёт → false",
		not SaveGame.select_plane("biplane") and SaveGame.get_selected_plane() == "la5",
		SaveGame.get_selected_plane())
	_check("выбор: Ла-5 выбирается (открыт всегда)", SaveGame.select_plane("la5"))
	_check("выбор: закрытый P-39 выбрать нельзя", not SaveGame.select_plane("p39"))

	SaveGame.unlock_plane("yak3")
	_check("выбор: открытый Як-3 выбирается",
		SaveGame.select_plane("yak3") and SaveGame.get_selected_plane() == "yak3",
		SaveGame.get_selected_plane())
	SaveGame.unlock_plane("p39")
	_check("выбор: открытая Аэрокобра выбирается",
		SaveGame.select_plane("p39") and SaveGame.get_selected_plane() == "p39",
		SaveGame.get_selected_plane())
	var config := _load_config()
	_check("выбор: selected_plane записан в [profile]",
		config != null and String(config.get_value("profile", "selected_plane", "")) == "p39",
		str(config.get_sections()) if config != null else "нет конфига")
	# Закрытый самолёт в файле (ручная правка/откат профиля) не ломает забег: Ла-5,
	# но файл чтением не перезаписывается.
	_write_text("[meta]\nschema_version=2\n[profile]\nselected_plane=\"yak3\"\n")
	var after_write := _snapshot()
	_check("выбор: закрытый сохранённый самолёт → Ла-5 без перезаписи файла",
		SaveGame.get_selected_plane() == "la5"
		and _snapshots_equal(after_write, _snapshot()),
		"%s / %s" % [SaveGame.get_selected_plane(), _snapshot_brief(after_write)])


# ─── Открытие самолётов по прогрессу ────────────────────────────────────────
func _check_plane_unlocks() -> void:
	_fresh()
	var m1_star := MissionData.get_star_score(M1)
	# 1 звезда: счёт ниже порога, hp 0.
	var first: Dictionary = CampaignProgress.finish_mission(M1, true, 0, m1_star - 500, m1_star)
	_check("открытие Як-3: после m1 (1 звезда) ещё закрыт",
		_plane_ids(first).is_empty() and not SaveGame.is_plane_unlocked("yak3"),
		str(first.get("newly_unlocked_planes", [])))
	var second: Dictionary = CampaignProgress.finish_mission(M2, true, 0, 500, 5000)
	_check("открытие Як-3: после m2 (кампания не пройдена) ещё закрыт",
		_plane_ids(second).is_empty() and not SaveGame.is_plane_unlocked("yak3"),
		str(second.get("newly_unlocked_planes", [])))
	var third: Dictionary = CampaignProgress.finish_mission(M3, true, 0, 500, 7000)
	_check("открытие Як-3: все 3 миссии с ≥1 звездой → Як-3 открыт",
		_plane_ids(third) == ["yak3"] and SaveGame.is_plane_unlocked("yak3"),
		str(third.get("newly_unlocked_planes", [])))
	_check("открытие Як-3: Аэрокобра при 3/9 звёзд закрыта",
		not SaveGame.is_plane_unlocked("p39"))
	_check("открытие Як-3: открытый самолёт можно выбрать",
		SaveGame.select_plane("yak3") and SaveGame.get_selected_plane() == "yak3",
		SaveGame.get_selected_plane())
	var repeat: Dictionary = CampaignProgress.finish_mission(M3, true, 0, 500, 7000)
	_check("открытие Як-3: повторная победа не открывает его заново",
		_plane_ids(repeat).is_empty() and SaveGame.is_plane_unlocked("yak3"),
		str(repeat.get("newly_unlocked_planes", [])))

	# 9/9: все миссии по 3 звезды — Аэрокобра открывается этой же победой.
	_fresh()
	for id: String in [M1, M2, M3]:
		SaveGame.record_stars(id, 3)
	_check("открытие P-39: 9 суммарных звёзд набраны", SaveGame.total_stars() == 9,
		str(SaveGame.total_stars()))
	var nine: Dictionary = CampaignProgress.finish_mission(M1, true, 3, 9000,
		MissionData.get_star_score(M1))
	_check("открытие P-39: 9/9 звёзд → Аэрокобра открыта",
		_plane_ids(nine).has("p39") and SaveGame.is_plane_unlocked("p39"),
		str(nine.get("newly_unlocked_planes", [])))
	_check("открытие P-39: Як-3 открылся вместе с ней (все миссии со звёздами)",
		_plane_ids(nine) == ["yak3", "p39"], str(nine.get("newly_unlocked_planes", [])))
	_check("открытие P-39: открытую Аэрокобру можно выбрать",
		SaveGame.select_plane("p39") and SaveGame.get_selected_plane() == "p39")

	# Поражение не открывает самолёты даже при выполненных условиях по звёздам.
	_fresh()
	for id: String in [M1, M2, M3]:
		SaveGame.record_stars(id, 3)
	var snapshot := _snapshot()
	var loss: Dictionary = CampaignProgress.finish_mission(M1, false, 3, 9000,
		MissionData.get_star_score(M1))
	_check("поражение: самолёты не открываются",
		_plane_ids(loss).is_empty() and not SaveGame.is_plane_unlocked("yak3")
		and not SaveGame.is_plane_unlocked("p39"),
		str(loss.get("newly_unlocked_planes", [])))
	_check("поражение: файл сейва не перезаписан", _snapshots_equal(snapshot, _snapshot()),
		_snapshot_brief(snapshot))


# ─── Снабжение ──────────────────────────────────────────────────────────────
func _check_supply() -> void:
	_fresh()
	_check("снабжение: spend_supply(300) при 0 → false, баланс 0",
		not SaveGame.spend_supply(300) and SaveGame.get_supply() == 0,
		str(SaveGame.get_supply()))
	SaveGame.add_supply(600)
	_check("снабжение: spend_supply(300) при 600 → true, осталось 300",
		SaveGame.spend_supply(300) and SaveGame.get_supply() == 300,
		str(SaveGame.get_supply()))
	_check("снабжение: отрицательная цена → false, баланс не меняется",
		not SaveGame.spend_supply(-5) and SaveGame.get_supply() == 300,
		str(SaveGame.get_supply()))
	_check("снабжение: spend_supply(400) при 300 → false, баланс 300",
		not SaveGame.spend_supply(400) and SaveGame.get_supply() == 300,
		str(SaveGame.get_supply()))
	_check("снабжение: spend_supply(0) → true без списания",
		SaveGame.spend_supply(0) and SaveGame.get_supply() == 300,
		str(SaveGame.get_supply()))
	_check("снабжение: списание точной суммы обнуляет баланс (не ниже 0)",
		SaveGame.spend_supply(300) and SaveGame.get_supply() == 0,
		str(SaveGame.get_supply()))


# ─── Ливреи ─────────────────────────────────────────────────────────────────
func _check_liveries() -> void:
	_fresh()
	_check("ливреи: цены 0/300/600/900 и 0 вне диапазона",
		SaveGame.get_livery_cost(0) == 0 and SaveGame.get_livery_cost(1) == 300
		and SaveGame.get_livery_cost(2) == 600 and SaveGame.get_livery_cost(3) == 900
		and SaveGame.get_livery_cost(4) == 0 and SaveGame.get_livery_cost(-1) == 0,
		"%d/%d/%d/%d" % [SaveGame.get_livery_cost(0), SaveGame.get_livery_cost(1),
			SaveGame.get_livery_cost(2), SaveGame.get_livery_cost(3)])
	_check("ливреи: 0 = без ливреи доступна, 1…3 не куплены",
		SaveGame.is_livery_owned(0) and not SaveGame.is_livery_owned(1)
		and not SaveGame.is_livery_owned(2) and not SaveGame.is_livery_owned(3)
		and not SaveGame.is_livery_owned(4))
	_check("ливреи: покупка без снабжения → false",
		not SaveGame.buy_livery(1) and not SaveGame.is_livery_owned(1))
	SaveGame.add_supply(300)
	_check("ливреи: покупка 1 за 300 списывает ровно 300",
		SaveGame.buy_livery(1) and SaveGame.is_livery_owned(1)
		and SaveGame.get_supply() == 0,
		str(SaveGame.get_supply()))
	_check("ливреи: повторная покупка → false и без списания",
		not SaveGame.buy_livery(1) and SaveGame.get_supply() == 0,
		str(SaveGame.get_supply()))
	_check("ливреи: индекс 0 и 4 купить нельзя",
		not SaveGame.buy_livery(0) and not SaveGame.buy_livery(4)
		and not SaveGame.is_livery_owned(4))
	_check("ливреи: select_livery(1) для купленной → true",
		SaveGame.select_livery(1) and SaveGame.get_selected_livery() == 1,
		str(SaveGame.get_selected_livery()))
	_check("ливреи: select_livery(0) «без ливреи» → true",
		SaveGame.select_livery(0) and SaveGame.get_selected_livery() == 0,
		str(SaveGame.get_selected_livery()))
	_check("ливреи: select_livery(2) без покупки → false, выбор не меняется",
		not SaveGame.select_livery(2) and SaveGame.get_selected_livery() == 0,
		str(SaveGame.get_selected_livery()))
	_check("ливреи: select_livery(4)/(-1) → false",
		not SaveGame.select_livery(4) and not SaveGame.select_livery(-1))
	SaveGame.add_supply(1500)
	_check("ливреи: 2 и 3 покупаются за 600/900 (баланс 0)",
		SaveGame.buy_livery(2) and SaveGame.buy_livery(3) and SaveGame.get_supply() == 0
		and SaveGame.is_livery_owned(2) and SaveGame.is_livery_owned(3),
		str(SaveGame.get_supply()))
	var config := _load_config()
	_check("ливреи: флаги livery_1..3 и selected_livery в [profile]",
		config != null and bool(config.get_value("profile", "livery_1", false))
		and bool(config.get_value("profile", "livery_2", false))
		and bool(config.get_value("profile", "livery_3", false))
		and int(config.get_value("profile", "selected_livery", -1)) == 0,
		str(config.get_sections()) if config != null else "нет конфига")


# ─── Player.apply_plane ─────────────────────────────────────────────────────
func _check_player_planes() -> void:
	_check("игрок: по умолчанию Ла-5 (0.125/1.0/800/r8/пуля 4)",
		_player.plane_id == "la5" and _player_stats_match(LA5), _player_brief())
	_check("игрок: apply_plane(yak3) → 0.1/0.85/800/r7/пуля 4",
		_player.apply_plane("yak3") and _player.plane_id == "yak3" and _player_stats_match(YAK3),
		_player_brief())
	_check("игрок: Як-3 — ключ визуала player_yak3",
		_visual_key() == &"player_yak3", String(_visual_key()))
	_check("игрок: apply_plane(p39) → 0.153846/1.5/800/r8/пуля 6",
		_player.apply_plane("p39") and _player.plane_id == "p39" and _player_stats_match(P39),
		_player_brief())
	_check("игрок: P-39 — ключ визуала player_p39",
		_visual_key() == &"player_p39", String(_visual_key()))
	_check("игрок: apply_plane(la5) возвращает базу Ла-5",
		_player.apply_plane("la5") and _player.plane_id == "la5" and _player_stats_match(LA5),
		_player_brief())
	_check("игрок: неизвестный самолёт → false и база не меняется",
		not _player.apply_plane("biplane") and _player.plane_id == "la5"
		and _player_stats_match(LA5), _player_brief())
	# Хитбокс — свой ресурс на инстанс: смена самолёта не «протекает» в соседа.
	_extra_player = PLAYER_SCENE.instantiate() as Player
	_world.add_child(_extra_player)
	_extra_player.set_process(false)
	_player.apply_plane("yak3")
	_extra_player.apply_plane("p39")
	_check("игрок: хитбоксы двух инстансов независимы (7 и 8)",
		is_equal_approx(_hitbox_radius(_player), 7.0)
		and is_equal_approx(_hitbox_radius(_extra_player), 8.0),
		"%.0f / %.0f" % [_hitbox_radius(_player), _hitbox_radius(_extra_player)])
	_extra_player.queue_free()
	_extra_player = null
	_player.apply_plane("la5")


# ─── Перки на базе самолёта ────────────────────────────────────────────────
func _check_perks_on_planes() -> void:
	_player.apply_plane("yak3")
	_apply_ids(["ap"])
	_check("перки на Як-3: ×2 урона и ×1.4 интервала от базы (1.7 / 0.14)",
		is_equal_approx(_player.bullet_damage, 0.85 * 2.0)
		and is_equal_approx(_player.fire_interval, 0.1 * 1.4)
		and is_equal_approx(_player.bullet_speed, 800.0),
		"%.2f / %.3f" % [_player.bullet_damage, _player.fire_interval])
	_player.reset_perks()
	_check("reset_perks: возвращает базу ВЫБРАННОГО Як-3, а не Ла-5",
		_player.plane_id == "yak3" and _player_stats_match(YAK3), _player_brief())

	_player.apply_plane("p39")
	_apply_ids(["sparka"])
	_check("перки на P-39: Спарка от базы 1.5 → 1.275, 2 снаряда",
		_player.bullets_per_shot == 2 and is_equal_approx(_player.bullet_damage, 1.5 * 0.85),
		"%d × %.3f" % [_player.bullets_per_shot, _player.bullet_damage])
	_check("перки на P-39: хитбокс пули 6 перком не сбивается",
		is_equal_approx(_player.bullet_hit_radius, 6.0), str(_player.bullet_hit_radius))
	_player.apply_plane("la5")
	_check("смена самолёта с активным перком: база Ла-5 + Спарка (0.85, 2 снаряда)",
		_player.bullets_per_shot == 2
		and is_equal_approx(_player.bullet_damage, 1.0 * 0.85)
		and is_equal_approx(_player.fire_interval, 0.125),
		"%d × %.2f @ %.3f" % [_player.bullets_per_shot, _player.bullet_damage,
			_player.fire_interval])
	_player.reset_perks()
	_check("reset_perks: после возврата на Ла-5 база снова Ла-5",
		_player_stats_match(LA5), _player_brief())


# ─── Bullet: радиус хитбокса ───────────────────────────────────────────────
func _check_bullet_radius() -> void:
	var la5 := _spawn_bullet(4.0)
	_check("пуля: Ла-5 — hit_radius 4 на CollisionShape2D",
		la5 != null and is_equal_approx(la5.hit_radius, 4.0)
		and is_equal_approx(_bullet_shape_radius(la5), 4.0),
		"%.1f" % (_bullet_shape_radius(la5) if la5 != null else -1.0))
	var p39 := _spawn_bullet(6.0)
	_check("пуля: P-39 — hit_radius 6 на CollisionShape2D",
		p39 != null and is_equal_approx(p39.hit_radius, 6.0)
		and is_equal_approx(_bullet_shape_radius(p39), 6.0),
		"%.1f" % (_bullet_shape_radius(p39) if p39 != null else -1.0))
	_check("пуля: радиус одного снаряда не протекает в другой (4 и 6)",
		la5 != null and p39 != null
		and is_equal_approx(_bullet_shape_radius(la5), 4.0)
		and is_equal_approx(_bullet_shape_radius(p39), 6.0),
		"%.1f / %.1f" % [_bullet_shape_radius(la5), _bullet_shape_radius(p39)])
	var default_bullet := BULLET_SCENE.instantiate() as Bullet
	default_bullet.setup(Bullet.Kind.ENEMY, Vector2(100.0, 100.0), Vector2.DOWN * 300.0, 1.0)
	_check("пуля: без параметра радиус 5 (вражеские пули как раньше)",
		is_equal_approx(default_bullet.hit_radius, 5.0)
		and is_equal_approx(_bullet_shape_radius(default_bullet), 5.0),
		str(_bullet_shape_radius(default_bullet)))
	default_bullet.free()
	if la5 != null:
		la5.free()
	if p39 != null:
		p39.free()

	# BulletLayer.fire_player передаёт радиус самолёта в снаряд.
	_bullets.clear_all()
	_bullets.fire_player(Vector2(270.0, 700.0), Vector2.UP * 800.0, 1.5, 1.0, 0.0, 0.0, 6.0)
	var fired := _bullets.get_child(_bullets.get_child_count() - 1) as Bullet
	_check("пуля: fire_player(..., 6.0) создаёт снаряд с радиусом 6",
		fired != null and is_equal_approx(_bullet_shape_radius(fired), 6.0),
		"%.1f" % (_bullet_shape_radius(fired) if fired != null else -1.0))
	_bullets.clear_all()


# ─── Хитбокс игрока: независимость ресурса ─────────────────────────────────
func _check_hitbox_isolation() -> void:
	# Уже проверено выше на двух инстансах; здесь — что радиус равен hit_radius игрока
	# после каждого apply_plane (ресурс дублируется, а не пишется в общий сабресурс).
	_player.apply_plane("p39")
	var p39_ok := is_equal_approx(_hitbox_radius(_player), 8.0)
	_player.apply_plane("yak3")
	var yak3_ok := is_equal_approx(_hitbox_radius(_player), 7.0)
	_check("хитбокс: apply_plane пересобирает CollisionShape2D (8 → 7)",
		p39_ok and yak3_ok, "%.0f" % _hitbox_radius(_player))
	_player.apply_plane("la5")


# ─── Хелперы игрока/пуль ────────────────────────────────────────────────────
func _apply_ids(list: Array) -> void:
	var ids: Array[String] = []
	for id: Variant in list:
		ids.append(String(id))
	_player.apply_perks(ids)


func _player_stats_match(expected: Dictionary) -> bool:
	return is_equal_approx(_player.fire_interval, float(expected["fire_interval"])) \
		and is_equal_approx(_player.bullet_damage, float(expected["damage"])) \
		and is_equal_approx(_player.bullet_speed, float(expected["bullet_speed"])) \
		and is_equal_approx(_player.hit_radius, float(expected["hit_radius"])) \
		and is_equal_approx(_player.bullet_hit_radius, float(expected["bullet_hit_radius"]))


func _player_brief() -> String:
	return "%.4f / %.3f / %.0f / r%.0f / пуля %.0f" % [_player.fire_interval,
		_player.bullet_damage, _player.bullet_speed, _player.hit_radius,
		_player.bullet_hit_radius]


func _stats_match(id: String, expected: Dictionary) -> bool:
	var plane := PlaneData.get_plane(id)
	if plane.is_empty():
		return false
	for key: String in ["fire_interval", "damage", "bullet_speed", "hit_radius",
			"bullet_hit_radius"]:
		if not is_equal_approx(float(plane.get(key, -1.0)), float(expected[key])):
			return false
	return String(plane.get("asset_key", "")) == String(expected["asset_key"]) \
		and String(plane.get("unlock", "")) == String(expected["unlock"])


func _stats_brief(id: String) -> String:
	var plane := PlaneData.get_plane(id)
	return "%s / %s / %s / r%s / пуля %s / %s" % [plane.get("fire_interval", "?"),
		plane.get("damage", "?"), plane.get("bullet_speed", "?"),
		plane.get("hit_radius", "?"), plane.get("bullet_hit_radius", "?"),
		plane.get("unlock", "?")]


func _spawn_bullet(radius: float) -> Bullet:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	bullet.setup(Bullet.Kind.PLAYER, Vector2(270.0, 700.0), Vector2.UP * 800.0, 1.0,
		1.0, 0.0, 0.0, false, radius)
	return bullet


func _bullet_shape_radius(bullet: Bullet) -> float:
	var shape_node := bullet.get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return -1.0
	var shape := shape_node.shape as CircleShape2D
	return shape.radius if shape != null else -1.0


func _hitbox_radius(player: Player) -> float:
	var shape_node := player.get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return -1.0
	var shape := shape_node.shape as CircleShape2D
	return shape.radius if shape != null else -1.0


## Ключ арта визуала игрока (ShipVisual). Нет узла → пустой ключ.
func _visual_key() -> StringName:
	var visual := _player.get_node_or_null(^"Visual") as ShipVisual
	return visual.asset_key if visual != null else &""


# ─── Помощники сейва ────────────────────────────────────────────────────────
func _fresh() -> void:
	_remove_file(_path)


func _load_config() -> ConfigFile:
	var config := ConfigFile.new()
	if config.load(_path) != OK:
		return null
	return config


func _write_text(text: String) -> void:
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _remove_file(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _snapshot() -> Dictionary:
	return _file_snapshot(_path)


func _file_snapshot(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"exists": false, "size": -1, "mtime": -1, "text": ""}
	var snapshot := {
		"exists": true, "size": -1, "mtime": FileAccess.get_modified_time(path), "text": ""
	}
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		snapshot["text"] = file.get_as_text()
		snapshot["size"] = int(file.get_length())
		file.close()
	return snapshot


func _snapshots_equal(left: Dictionary, right: Dictionary) -> bool:
	return bool(left.get("exists")) == bool(right.get("exists")) \
		and int(left.get("size")) == int(right.get("size")) \
		and int(left.get("mtime")) == int(right.get("mtime")) \
		and String(left.get("text")) == String(right.get("text"))


func _snapshot_brief(snapshot: Dictionary) -> String:
	if not bool(snapshot.get("exists")):
		return "<нет файла>"
	return "%d B, mtime %d" % [int(snapshot.get("size")), int(snapshot.get("mtime"))]


## newly_unlocked_planes → обычный Array строк: сравнение не зависит от типизации массива.
func _plane_ids(result: Dictionary) -> Array:
	var ids := []
	var raw: Variant = result.get("newly_unlocked_planes", [])
	if typeof(raw) == TYPE_ARRAY:
		for item: Variant in raw:
			ids.append(String(item))
	return ids


# ─── Хелпер проверок ────────────────────────────────────────────────────────
func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
