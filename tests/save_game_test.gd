# save_game_test.gd
# Purpose: Гейт M5.3a «сейв v2 + звёзды + открытие миссий + снабжение» (GDD «Реализация v1»
#          → «Сейв v2», «Счёт, звёзды, снабжение»). Проверяет:
#            • схему файла: [meta] schema_version=2, [profile], [settings], [records];
#            • дефолты чистого профиля (снабжение 0, звёзды 0, m1 открыта, m2/m3 закрыты,
#              звук/вибрация включены) и что простое чтение НЕ создаёт файл;
#            • звёзды: только максимум, неизвестный id без записи, открытие m2 при 1 звезде
#              и m3 при 3 суммарных;
#            • рекорды миссий: только вверх; рекорд endless: очки + волна;
#            • CampaignProgress: звёзды по трём критериям, снабжение score/40 + 150×звёзд,
#              newly_unlocked; поражение не пишет ничего;
#            • миграцию v1 ([record] best_score → [records] endless_best, schema 2,
#              секция [record] остаётся, повторной миграции нет);
#            • совместимость: RunRecord.submit() больше не стирает [profile];
#            • битый файл (текст и бинарный мусор) → дефолты без падения и без ERROR;
#            • чужую секцию, которую сейв обязан сохранить;
#            • изоляцию: работаем только в user://qa_save_*.cfg, реальный
#              user://ww2_air_battles.cfg не читается и не пишется (слепок до/после).
# Запуск: godot --headless --path . res://tests/save_game_test.tscn
# Dependencies: SaveGame, CampaignProgress, RunRecord, MissionData (star_score).
# Author: Mechanics Developer Agent

extends Node

const SCHEMA_VERSION := 2
const SECTION_META := "meta"
const SECTION_PROFILE := "profile"
const SECTION_SETTINGS := "settings"
const SECTION_RECORDS := "records"
const SECTION_LEGACY := "record"
const SECTION_FOREIGN := "foreign"

const M1 := "m1_airfield"
const M2 := "m2_crossing"
const M3 := "m3_city"

var _failures: int = 0
var _checks: int = 0
var _started_msec: int = 0
## Уникальный qa-файл прогона: реальный профиль игрока не читается и не пишется.
var _path: String = ""
var _real_snapshot: Dictionary = {}


func _ready() -> void:
	_started_msec = Time.get_ticks_msec()
	# Слепок реального профиля ДО любых операций с сейвом.
	_real_snapshot = _file_snapshot(RunRecord.DEFAULT_PATH)
	_path = "user://qa_save_%d.cfg" % Time.get_ticks_msec()
	SaveGame.set_save_path(_path)
	await _run()
	# Уборка: файл прогона удаляется, путь возвращается к дефолтному.
	_remove_file(_path)
	RunRecord.reset_save_path()
	_check("изоляция: путь вернулся к DEFAULT_PATH и qa-файл удалён",
		SaveGame.get_save_path() == RunRecord.DEFAULT_PATH and not FileAccess.file_exists(_path),
		SaveGame.get_save_path())
	var real_after := _file_snapshot(RunRecord.DEFAULT_PATH)
	_check("изоляция: реальный user://ww2_air_battles.cfg не изменён прогоном",
		_snapshots_equal(_real_snapshot, real_after),
		"%s → %s" % [_snapshot_brief(_real_snapshot), _snapshot_brief(real_after)])
	print("SAVE_TIME=", "%.2f" % (float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	print("SAVE_RESULT failures=", _failures, " checks=", _checks)
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_check_path()
	_check_defaults()
	_check_schema_and_sections()
	_check_supply()
	_check_stars_and_unlock()
	_check_mission_best()
	_check_settings()
	_check_planes()
	_check_endless()
	_check_finish_mission_win()
	_check_finish_mission_loss()
	_check_migration()
	_check_run_record_compat()
	_check_foreign_section()
	_check_broken_file()
	_check_reset()


# ─── Путь и дефолты ─────────────────────────────────────────────────────────
func _check_path() -> void:
	_check("путь: SaveGame делегирует в RunRecord.set_save_path",
		SaveGame.get_save_path() == _path and RunRecord.get_save_path() == _path,
		"%s / %s" % [SaveGame.get_save_path(), RunRecord.get_save_path()])
	_runrecord_path_probe()


## Путь живёт в RunRecord: подмена через RunRecord видна и в SaveGame (изоляция smoke/juice).
func _runrecord_path_probe() -> void:
	RunRecord.set_save_path(_path)
	_check("путь: подмена через RunRecord видна SaveGame",
		SaveGame.get_save_path() == _path, SaveGame.get_save_path())


func _check_defaults() -> void:
	_fresh()
	_check("дефолты: снабжение 0", SaveGame.get_supply() == 0, str(SaveGame.get_supply()))
	_check("дефолты: звёзд нет и m1 открыта",
		SaveGame.get_stars(M1) == 0 and SaveGame.total_stars() == 0
		and SaveGame.is_mission_unlocked(M1),
		"звёзды %d/%d, m1 %s" % [SaveGame.get_stars(M1), SaveGame.total_stars(),
			SaveGame.is_mission_unlocked(M1)])
	_check("дефолты: m2 и m3 закрыты",
		not SaveGame.is_mission_unlocked(M2) and not SaveGame.is_mission_unlocked(M3))
	_check("дефолты: звук и вибрация включены",
		SaveGame.get_setting("sound") and SaveGame.get_setting("vibration"))
	_check("дефолты: рекорды миссий и endless = 0",
		SaveGame.get_mission_best(M1) == 0 and SaveGame.get_endless_best() == 0
		and SaveGame.get_endless_wave() == 0)
	_check("дефолты: неизвестная миссия — 0 и закрыта",
		SaveGame.get_stars("nope") == 0 and SaveGame.get_mission_best("nope") == 0
		and not SaveGame.is_mission_unlocked("nope"))
	_check("дефолты: чтение чистого профиля НЕ создаёт файл",
		not FileAccess.file_exists(_path), _path)


# ─── Схема и секции ─────────────────────────────────────────────────────────
func _check_schema_and_sections() -> void:
	_fresh()
	# Первая запись — через настройку (дефолт true → false, поэтому запись реальная).
	SaveGame.set_setting("sound", false)
	var config := _load_config()
	_check("схема: файл создан и schema_version = 2",
		config != null and int(config.get_value(SECTION_META, "schema_version", -1)) == SCHEMA_VERSION,
		"load=%s" % ("ok" if config != null else "fail"))
	_check("схема: секции meta/profile/settings присутствуют",
		config != null and config.has_section(SECTION_META)
		and config.has_section(SECTION_PROFILE) and config.has_section(SECTION_SETTINGS),
		str(config.get_sections()) if config != null else "нет конфига")
	SaveGame.set_setting("sound", true)


# ─── Снабжение ──────────────────────────────────────────────────────────────
func _check_supply() -> void:
	_fresh()
	_check("снабжение: add_supply(50) → 50", SaveGame.add_supply(50) == 50
		and SaveGame.get_supply() == 50, str(SaveGame.get_supply()))
	_check("снабжение: add_supply(-10) → 40", SaveGame.add_supply(-10) == 40
		and SaveGame.get_supply() == 40, str(SaveGame.get_supply()))
	_check("снабжение: ниже 0 не опускается", SaveGame.add_supply(-999) == 0
		and SaveGame.get_supply() == 0, str(SaveGame.get_supply()))


# ─── Звёзды и открытие миссий ───────────────────────────────────────────────
func _check_stars_and_unlock() -> void:
	_fresh()
	_check("звёзды: record_stars(m1, 2) → 2", SaveGame.record_stars(M1, 2) == 2
		and SaveGame.get_stars(M1) == 2, str(SaveGame.get_stars(M1)))
	_check("звёзды: повтор с 1 не понижает", SaveGame.record_stars(M1, 1) == 2
		and SaveGame.get_stars(M1) == 2, str(SaveGame.get_stars(M1)))
	_check("звёзды: total_stars() = 2", SaveGame.total_stars() == 2,
		str(SaveGame.total_stars()))
	_check("открытие: 2 звезды → m2 открыта, m3 закрыта",
		SaveGame.is_mission_unlocked(M2) and not SaveGame.is_mission_unlocked(M3))
	_check("звёзды: clamp 5 → 3, −1 → не понижает",
		SaveGame.record_stars(M1, 5) == 3 and SaveGame.record_stars(M1, -1) == 3,
		str(SaveGame.get_stars(M1)))
	_check("открытие: 3 суммарные звезды → m3 открыта",
		SaveGame.total_stars() == 3 and SaveGame.is_mission_unlocked(M3),
		"%d звёзд" % SaveGame.total_stars())
	_check("звёзды: неизвестный id не пишется и не ломает total",
		SaveGame.record_stars("nope", 3) == 0 and SaveGame.total_stars() == 3,
		str(SaveGame.total_stars()))


# ─── Рекорды миссий ─────────────────────────────────────────────────────────
func _check_mission_best() -> void:
	_fresh()
	var first: Dictionary = SaveGame.record_mission_result(M1, 3000)
	_check("рекорд миссии: 3000 → best 3000, новый",
		int(first.get("best", -1)) == 3000 and bool(first.get("is_new", false)), str(first))
	var lower: Dictionary = SaveGame.record_mission_result(M1, 2000)
	_check("рекорд миссии: 2000 → 3000, не новый",
		int(lower.get("best", -1)) == 3000 and not bool(lower.get("is_new", true)), str(lower))
	var equal: Dictionary = SaveGame.record_mission_result(M1, 3000)
	_check("рекорд миссии: равный счёт не новый",
		int(equal.get("best", -1)) == 3000 and not bool(equal.get("is_new", true)), str(equal))
	var higher: Dictionary = SaveGame.record_mission_result(M1, 4200)
	_check("рекорд миссии: 4200 → 4200, новый",
		int(higher.get("best", -1)) == 4200 and bool(higher.get("is_new", false)), str(higher))
	_check("рекорд миссии: get_mission_best = 4200", SaveGame.get_mission_best(M1) == 4200,
		str(SaveGame.get_mission_best(M1)))
	var config := _load_config()
	_check("рекорд миссии: неизвестный id не пишется",
		SaveGame.get_mission_best("nope") == 0 and SaveGame.record_mission_result("nope", 99)
		.get("best", -1) == 0 and int(config.get_value(SECTION_RECORDS, "best_m1", -1)) == 4200,
		str(config.get_sections()) if config != null else "нет конфига")


# ─── Настройки ──────────────────────────────────────────────────────────────
func _check_settings() -> void:
	_fresh()
	SaveGame.set_setting("sound", false)
	_check("настройки: sound=false читается", not SaveGame.get_setting("sound"))
	_check("настройки: vibration остаётся true", SaveGame.get_setting("vibration"))
	var config := _load_config()
	_check("настройки: записаны в [settings] на диск",
		config != null and not bool(config.get_value(SECTION_SETTINGS, "sound", true))
		and bool(config.get_value(SECTION_SETTINGS, "vibration", false)))
	_check("настройки: неизвестный ключ → true и без записи",
		SaveGame.get_setting("unknown_key") and not SaveGame.set_setting("unknown_key", false)
		and not _load_config().has_section_key(SECTION_SETTINGS, "unknown_key"))


# ─── Самолёты ───────────────────────────────────────────────────────────────
func _check_planes() -> void:
	_fresh()
	_check("самолёты: la5 открыт по умолчанию",
		SaveGame.is_plane_unlocked("la5") and not SaveGame.is_plane_unlocked("yak3")
		and not SaveGame.is_plane_unlocked("p39"))
	_check("самолёты: unlock_plane(yak3) сохраняется",
		SaveGame.unlock_plane("yak3") and SaveGame.is_plane_unlocked("yak3")
		and not SaveGame.is_plane_unlocked("p39"))
	_check("самолёты: неизвестный id не открывается",
		not SaveGame.unlock_plane("biplane") and not SaveGame.is_plane_unlocked("biplane"))


# ─── Endless ────────────────────────────────────────────────────────────────
func _check_endless() -> void:
	_fresh()
	var first: Dictionary = SaveGame.record_endless(9000, 7)
	_check("endless: 9000/7 записаны",
		int(first.get("best", -1)) == 9000 and int(first.get("wave", -1)) == 7
		and SaveGame.get_endless_best() == 9000 and SaveGame.get_endless_wave() == 7, str(first))
	SaveGame.record_endless(8000, 5)
	_check("endless: худший результат не понижает рекорд",
		SaveGame.get_endless_best() == 9000 and SaveGame.get_endless_wave() == 7,
		"%d/%d" % [SaveGame.get_endless_best(), SaveGame.get_endless_wave()])
	SaveGame.record_endless(12000, 3)
	_check("endless: очки вверх, волна не понижается",
		SaveGame.get_endless_best() == 12000 and SaveGame.get_endless_wave() == 7,
		"%d/%d" % [SaveGame.get_endless_best(), SaveGame.get_endless_wave()])


# ─── CampaignProgress: победа ───────────────────────────────────────────────
## Три критерия: пройдена + сохранено HP + счёт выше порога. star_score берём из данных
## миссии, снабжение — score / 40 + 150 × звёзд (GDD).
func _check_finish_mission_win() -> void:
	_fresh()
	var star_score := MissionData.get_star_score(M1)
	_check("данные: star_score миссии 1 = 4500", star_score == 4500, str(star_score))

	# 1) Счёт ниже порога, hp 0 → только «пройдена» = 1 звезда.
	var low_score := star_score - 500
	var poor: Dictionary = CampaignProgress.finish_mission(M1, true, 0, low_score, star_score)
	_check("звёзды: счёт ниже порога и hp 0 → 1", int(poor.get("stars", -1)) == 1, str(poor))
	_check("снабжение: 1 звезда → score/40 + 150",
		int(poor.get("supply_gained", -1)) == low_score / 40 + 150
		and SaveGame.get_supply() == int(poor.get("supply_gained", -1)),
		"начислено %d, баланс %d" % [int(poor.get("supply_gained", -1)), SaveGame.get_supply()])
	_check("открытие: первая звезда открывает m2 (и только её)",
		_ids(poor) == [M2]
		and SaveGame.is_mission_unlocked(M2) and not SaveGame.is_mission_unlocked(M3),
		str(poor.get("newly_unlocked", [])))

	# 2) Счёт выше порога, hp 0 → 2 звезды (пройдена + счёт), m3 ещё закрыта.
	var rich: Dictionary = CampaignProgress.finish_mission(M2, true, 0, star_score, star_score)
	_check("звёзды: счёт выше порога и hp 0 → 2", int(rich.get("stars", -1)) == 2, str(rich))
	_check("звёзды: total_stars() = 3 после 1 + 2",
		int(rich.get("total_stars", -1)) == 3 and SaveGame.total_stars() == 3,
		str(SaveGame.total_stars()))
	_check("открытие: 3 суммарные звезды открывают m3",
		_ids(rich) == [M3] and SaveGame.is_mission_unlocked(M3),
		str(rich.get("newly_unlocked", [])))

	# 3) Счёт выше порога, hp 3 → 3 звезды, рекорд миссии и снабжение по формуле.
	var perfect_score := MissionData.get_star_score(M3) + 500
	var perfect: Dictionary = CampaignProgress.finish_mission(M3, true, 3, perfect_score,
		MissionData.get_star_score(M3))
	_check("звёзды: счёт выше порога и hp 3 → 3", int(perfect.get("stars", -1)) == 3, str(perfect))
	_check("снабжение: 3 звезды → score/40 + 450",
		int(perfect.get("supply_gained", -1)) == perfect_score / 40 + 450, str(perfect))
	_check("рекорд миссии: best и is_new из finish_mission",
		int(perfect.get("best", -1)) == perfect_score and bool(perfect.get("is_new", false))
		and SaveGame.get_mission_best(M3) == perfect_score, str(perfect))
	var expected_supply := low_score / 40 + 150 + star_score / 40 + 300 + perfect_score / 40 + 450
	_check("снабжение: баланс суммарный по трём исходам",
		int(perfect.get("supply_total", -1)) == SaveGame.get_supply()
		and SaveGame.get_supply() == expected_supply,
		"%d (ожидалось %d)" % [SaveGame.get_supply(), expected_supply])
	_check("открытие: у третьей миссии ничего нового не открывается",
		_ids(perfect).is_empty(), str(perfect.get("newly_unlocked", [])))


# ─── CampaignProgress: поражение ────────────────────────────────────────────
func _check_finish_mission_loss() -> void:
	_fresh()
	SaveGame.record_mission_result(M1, 5000)
	var supply_before := SaveGame.get_supply()
	var snapshot := _snapshot()
	var loss: Dictionary = CampaignProgress.finish_mission(M1, false, 0, 9000,
		MissionData.get_star_score(M1))
	_check("поражение: 0 звёзд", int(loss.get("stars", -1)) == 0, str(loss))
	_check("поражение: 0 снабжения", int(loss.get("supply_gained", -1)) == 0
		and SaveGame.get_supply() == supply_before, str(loss))
	_check("поражение: рекорд миссии не меняется",
		int(loss.get("best", -1)) == 5000 and not bool(loss.get("is_new", true))
		and SaveGame.get_mission_best(M1) == 5000, str(loss))
	_check("поражение: файл сейва не перезаписан", _snapshots_equal(snapshot, _snapshot()),
		_snapshot_brief(snapshot))
	_check("поражение: ничего не открылось",
		_ids(loss).is_empty() and not SaveGame.is_mission_unlocked(M2),
		str(loss.get("newly_unlocked", [])))


# ─── Миграция v1 → v2 ───────────────────────────────────────────────────────
func _check_migration() -> void:
	_fresh()
	_write_text("[record]\nbest_score=1234\n")
	_check("миграция: [record] best_score → endless_best при первом чтении",
		SaveGame.get_endless_best() == 1234, str(SaveGame.get_endless_best()))
	var config := _load_config()
	_check("миграция: schema_version = 2 в файле",
		config != null and int(config.get_value(SECTION_META, "schema_version", -1)) == 2,
		"нет файла/секции" if config == null else str(config.get_sections()))
	_check("миграция: секция [record] сохранена",
		config != null and int(config.get_value(SECTION_LEGACY, "best_score", -1)) == 1234,
		"секция потеряна" if config == null else str(config.get_sections()))
	var after_migration := _snapshot()
	SaveGame.get_endless_best()
	_check("миграция: повторного чтения-записи нет",
		_snapshots_equal(after_migration, _snapshot()), _snapshot_brief(after_migration))
	_check("миграция: endless_wave остаётся 0", SaveGame.get_endless_wave() == 0)


# ─── Совместимость с RunRecord ──────────────────────────────────────────────
func _check_run_record_compat() -> void:
	_fresh()
	SaveGame.record_stars(M1, 2)
	SaveGame.add_supply(77)
	var submit: Dictionary = RunRecord.submit(500)
	_check("совместимость: RunRecord.submit(500) пишет [record] best_score",
		int(submit.get("best", -1)) == 500 and RunRecord.get_best_score() == 500, str(submit))
	var config := _load_config()
	_check("совместимость: [profile] не стёрт записью RunRecord",
		config != null and int(config.get_value(SECTION_PROFILE, "supply", -1)) == 77
		and int(config.get_value(SECTION_PROFILE, "stars_m1", -1)) == 2,
		str(config.get_sections()) if config != null else "нет конфига")
	_check("совместимость: SaveGame видит свои значения после RunRecord",
		SaveGame.get_supply() == 77 and SaveGame.get_stars(M1) == 2
		and SaveGame.total_stars() == 2,
		"%d / %d" % [SaveGame.get_supply(), SaveGame.total_stars()])
	_check("совместимость: schema_version не потерян",
		config != null and int(config.get_value(SECTION_META, "schema_version", -1)) == 2)


# ─── Чужая секция ───────────────────────────────────────────────────────────
func _check_foreign_section() -> void:
	_fresh()
	_write_text("[foreign]\ngift=42\n")
	SaveGame.add_supply(5)
	var config := _load_config()
	_check("чужие секции: [foreign] сохранена при записи сейва",
		config != null and int(config.get_value(SECTION_FOREIGN, "gift", -1)) == 42,
		str(config.get_sections()) if config != null else "нет конфига")


# ─── Битый файл ─────────────────────────────────────────────────────────────
func _check_broken_file() -> void:
	_fresh()
	_write_text("not an ini at all\n<<<мусор>>>\n")
	_check("битый файл: мусор → дефолты без падения",
		SaveGame.get_supply() == 0 and SaveGame.total_stars() == 0
		and SaveGame.get_mission_best(M1) == 0 and SaveGame.get_setting("sound"),
		str(SaveGame.get_supply()))
	# Бинарный мусор с NUL: FileAccess.get_as_text/ConfigFile.load молча терял бы байты.
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file != null:
		file.store_buffer(PackedByteArray([0x00, 0x01, 0x3D, 0x61, 0x62, 0x00]))
		file.close()
	_check("битый файл: NUL-мусор → дефолты",
		SaveGame.get_supply() == 0 and SaveGame.get_endless_best() == 0)
	SaveGame.add_supply(3)
	_check("битый файл: запись поверх мусора восстанавливает профиль",
		SaveGame.get_supply() == 3
		and int(_load_config().get_value(SECTION_META, "schema_version", -1)) == 2,
		str(SaveGame.get_supply()))


# ─── Сброс (QA) ─────────────────────────────────────────────────────────────
func _check_reset() -> void:
	_fresh()
	SaveGame.record_stars(M1, 1)
	SaveGame.reset()
	_check("сброс: файл удалён, значения по умолчанию, путь не изменён",
		not FileAccess.file_exists(_path) and SaveGame.get_supply() == 0
		and SaveGame.total_stars() == 0 and SaveGame.get_save_path() == _path,
		SaveGame.get_save_path())


# ─── Помощники ──────────────────────────────────────────────────────────────
## Чистый профиль: удалить qa-файл перед сценарием.
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


## Слепок qa-файла: размер, mtime и текст (доказательство «писания» без записи).
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


## newly_unlocked → обычный Array строк: сравнение не зависит от типизации массива.
func _ids(result: Dictionary) -> Array:
	var ids := []
	var raw: Variant = result.get("newly_unlocked", [])
	if typeof(raw) == TYPE_ARRAY:
		for item: Variant in raw:
			ids.append(String(item))
	return ids


func _check(label: String, condition: bool, details: String = "") -> void:
	_checks += 1
	if condition:
		print("PASS  ", label)
	else:
		_failures += 1
		print("FAIL  ", label, (" | " + details) if details != "" else "")
