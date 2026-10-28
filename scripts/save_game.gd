# save_game.gd
# Purpose: Сейв v2 (M5.3a; GDD «Реализация v1» → «Сейв v2», «Счёт, звёзды, снабжение»):
#          один файл на профиль с секциями
#              [meta]     schema_version=2
#              [profile]  supply, stars_m1..3, unlocked_yak3, unlocked_p39, livery_1..3,
#                         selected_plane, selected_livery
#              [settings] sound, vibration
#              [records]  best_m1..3, endless_best, endless_wave
#              [flags]    ads_enabled, shop_enabled (M8b: адаптеры Ads/IAP, default false)
#          Путь НЕ свой: берётся из RunRecord.get_save_path(), а set_save_path() делегирует
#          в RunRecord.set_save_path(). Так существующие QA/смоук-тесты, которые подменяют
#          путь рекорда на уникальный user://, автоматически изолируют и сейв v2.
#          Чтение/запись — ConfigFile, но ФАЙЛ ПЕРЕД ПАРСОМ проверяется по байтам и
#          нормализуется (NUL/управляющие/структура), поэтому мусор даёт значения по
#          умолчанию без ERROR в логе движка — та же политика, что в RunRecord.
#          Чужие секции/ключи не теряются: каждая запись начинается с загрузки
#          существующего файла, а не с пустого ConfigFile.
#          Миграция v1 (один раз): нет [meta] schema_version, но файл не пуст →
#          legacy [record] best_score переносится в [records] endless_best, ставится
#          schema_version=2, секция [record] остаётся на месте.
# Dependencies: RunRecord (путь файла + legacy-ключ best_score), MissionData.MISSION_IDS
#               (только константа списка миссий — JSON не читается), PlaneData (M6.2a —
#               только список известных id для валидации выбранного самолёта). Обратных
#               зависимостей нет: CampaignProgress/LevelController зовут SaveGame, не наоборот.
# Author: Mechanics Developer Agent
#
# API (всё статическое; инстансы не нужны):
#   get_save_path()/set_save_path(path)      путь = путь RunRecord (изоляция тестов)
#   get_supply() -> int                      0 по умолчанию, отрицательное клампится в 0
#   add_supply(n) -> int                     новое значение (не уходит ниже 0)
#   get_stars(id) -> int                     0…3; неизвестный id → 0
#   record_stars(id, stars) -> int           только максимум, 0…3; неизвестный id — без записи
#   total_stars() -> int                     сумма звёзд кампании (0…9)
#   is_mission_unlocked(id) -> bool          m1 всегда; m2 при ≥1; m3 при ≥3 (GDD)
#   is_endless_unlocked() -> bool            M6.3a: у всех 3 миссий ≥1 звезды (GDD)
#   get_mission_best(id) -> int              0 по умолчанию; неизвестный id → 0
#   record_mission_result(id, score)         {"best": int, "is_new": bool}, только вверх
#   get_endless_best()/get_endless_wave()    рекорд endless: очки + достигнутая волна
#   record_endless(score, wave)              {"best", "wave", "is_new"}; обе величины только вверх
#   get_setting(name)/set_setting(name, v)   sound / vibration (default true)
#   get_flag(name, default=false)            M8b: [flags] ads_enabled / shop_enabled
#   set_flag(name, value) -> bool            только известные флаги; запись на диск при смене
#   is_plane_unlocked(id)/unlock_plane(id)   la5 всегда; yak3 / p39 — по флагу профиля
#   get_selected_plane()/select_plane(id)    выбранный самолёт (M6.2a): только открытый,
#                                            неизвестный/закрытый → false без записи
#   get_selected_livery()/select_livery(i)   ливрея ангара (M6.2a): 0…3, 0 = без ливреи;
#                                            купленная (или 0) — иначе false
#   buy_livery(index) -> bool               покупка ливреи за снабжение 300/600/900
#   spend_supply(cost) -> bool              списание снабжения без ухода в минус
#   get_livery_cost(index)/is_livery_owned(index)
#   reset()                                  удалить файл (QA), путь не меняется
#
# Ошибки записи/чтения НЕ роняют игру и НЕ пишут push_error/warning: недоступный user://
# (read-only, переполнение) — приемлемая потеря прогресса, но не падение забега.

class_name SaveGame
extends RefCounted

## Версия схемы сейва (GDD «Реализация v1» → «Сейв v2»).
const SCHEMA_VERSION := 2

const SECTION_META := "meta"
const SECTION_PROFILE := "profile"
const SECTION_SETTINGS := "settings"
const SECTION_RECORDS := "records"
## M8b: флаги фич (remote-совместимые). Только читаются адаптерами Ads/IAP, UI их не показывает.
const SECTION_FLAGS := "flags"
## Legacy-секция v1: остаётся на месте после миграции (её пишет RunRecord).
const SECTION_LEGACY := "record"

const KEY_SCHEMA_VERSION := "schema_version"
const KEY_SUPPLY := "supply"
const KEY_SOUND := "sound"
const KEY_VIBRATION := "vibration"
const KEY_BEST_SCORE_LEGACY := "best_score"
const KEY_ENDLESS_BEST := "endless_best"
const KEY_ENDLESS_WAVE := "endless_wave"
const KEY_UNLOCKED_YAK3 := "unlocked_yak3"
const KEY_UNLOCKED_P39 := "unlocked_p39"
## M6.2a: ангар — выбранный самолёт и выбранная ливрея (0 = без ливреи).
const KEY_SELECTED_PLANE := "selected_plane"
const KEY_SELECTED_LIVERY := "selected_livery"
## M8b: флаги монетизации (GDD «Монетизация»: remote-флаги ads_enabled / shop_enabled).
## Оба по умолчанию false: слоты рекламы/магазина скрыты, SDK нет.
const KEY_ADS_ENABLED := "ads_enabled"
const KEY_SHOP_ENABLED := "shop_enabled"
## Известные флаги: неизвестное имя не читается и не пишется (не плодим мусор в файле).
const FLAG_KEYS := [KEY_ADS_ENABLED, KEY_SHOP_ENABLED]
## Ливреи (GDD: 3 бесплатные за снабжение 300/600/900). Покупка/выбор — M6.2a.
const LIVERY_KEYS := ["livery_1", "livery_2", "livery_3"]
## Цена ливреи по индексу: 0 — без ливреи (бесплатно и всегда доступна), 1…3 — по GDD.
const LIVERY_COSTS := [0, 300, 600, 900]
## Сколько ливрей всего (включая «без ливреи»): индексы 0…3.
const LIVERY_SLOTS := 4

## Максимум звёзд на миссию (GDD «Счёт, звёзды, снабжение»: 3 звезды на миссию).
const MAX_STARS := 3
## Сколько СУММАРНЫХ звёзд открывает миссию, по индексу в MissionData.MISSION_IDS.
## GDD: миссия 1 — сразу, миссия 2 — 1 звезда, миссия 3 — 3 звезды суммарно.
const UNLOCK_STARS := [0, 1, 3]

## Звёзды/рекорды миссий адресуются ключами stars_m1..m3 / best_m1..m3 (порядок = MISSION_IDS).
const STAR_KEY_PREFIX := "stars_m"
const BEST_KEY_PREFIX := "best_m"

## Самолёт по умолчанию и флаги ангара (GDD: Ла-5 — старт, Як-3 — полное прохождение,
## Аэрокобра — 9/9 звёзд). Открытие по звёздам — правило M6, здесь только хранение флага.
const PLANE_DEFAULT := "la5"
const PLANE_YAK3 := "yak3"
const PLANE_P39 := "p39"

## Потолок размера файла: профиль — десятки коротких строк. 256 KB отсекают попытку
## скормить парсеру случайно подсунутый крупный файл, оставляя запас на ручные правки.
const MAX_CONFIG_BYTES := 256 * 1024
## Максимум цифр в числовом литерале (18 < 2^63−1): длинное число VariantParser не осилит
## и напечатает ERROR о переполнении int64 — отсекаем такие значения до парсера.
const MAX_INT_DIGITS := 18


# ─── Путь файла (делегируется RunRecord) ────────────────────────────────────
## QA/тесты: подменить файл. Путь живёт в RunRecord, поэтому подмена изолирует и сейв v2,
## и локальный рекорд одним движением (smoke/juice уже так делают).
static func set_save_path(path: String) -> void:
	RunRecord.set_save_path(path)


static func get_save_path() -> String:
	return RunRecord.get_save_path()


# ─── Снабжение ──────────────────────────────────────────────────────────────
static func get_supply() -> int:
	return _profile_int(KEY_SUPPLY)


## Прибавить снабжение. Возвращает новое значение; ниже 0 не опускается (отрицательная
## дельта не должна «уводить в долг» — GDD не задаёт отрицательного снабжения).
static func add_supply(amount: int) -> int:
	var config := _load()
	var supply := maxi(0, _as_int(config.get_value(SECTION_PROFILE, KEY_SUPPLY, 0), 0))
	var updated := maxi(0, supply + amount)
	if updated != supply:
		config.set_value(SECTION_PROFILE, KEY_SUPPLY, updated)
		_store(config)
	return updated


## M6.2a: строгое списание (покупка ливреи). Возвращает false, если снабжения не хватает
## или цена отрицательная — баланс при этом НЕ меняется и файл не пишется.
## Баланс физически не может уйти ниже 0: списание разрешено только при supply >= cost.
static func spend_supply(cost: int) -> bool:
	if cost < 0:
		return false
	if cost == 0:
		return true
	var config := _load()
	var supply := maxi(0, _as_int(config.get_value(SECTION_PROFILE, KEY_SUPPLY, 0), 0))
	if supply < cost:
		return false
	config.set_value(SECTION_PROFILE, KEY_SUPPLY, supply - cost)
	_store(config)
	return true


# ─── Звёзды и открытие миссий ───────────────────────────────────────────────
static func get_stars(mission_id: String) -> int:
	var index := _mission_index(mission_id)
	if index < 0:
		return 0
	return clampi(_profile_int(_star_key(index)), 0, MAX_STARS)


## Записать звёзды миссии: только МАКСИМУМ (переигранная миссия хуже не становится).
## Возвращает актуальное значение. Неизвестный id — без записи, 0.
static func record_stars(mission_id: String, stars: int) -> int:
	var index := _mission_index(mission_id)
	if index < 0:
		return 0
	var config := _load()
	var current := clampi(_as_int(config.get_value(SECTION_PROFILE, _star_key(index), 0), 0),
		0, MAX_STARS)
	var updated := clampi(stars, 0, MAX_STARS)
	if updated > current:
		config.set_value(SECTION_PROFILE, _star_key(index), updated)
		_store(config)
		return updated
	return current


static func total_stars() -> int:
	var config := _load()
	var total := 0
	for index in MissionData.MISSION_IDS.size():
		total += clampi(_as_int(config.get_value(SECTION_PROFILE, _star_key(index), 0), 0),
			0, MAX_STARS)
	return total


## GDD «Счёт, звёзды, снабжение»: m1 доступна всегда, m2 — при 1 звезде, m3 — при 3.
static func is_mission_unlocked(mission_id: String) -> bool:
	var index := _mission_index(mission_id)
	if index < 0:
		return false
	var required := int(UNLOCK_STARS[index]) if index < UNLOCK_STARS.size() else MAX_STARS * 3
	return total_stars() >= required


## GDD «Бесконечный режим»: режим открывается после первого полного прохождения кампании —
## у КАЖДОЙ из трёх миссий есть хотя бы одна звезда (то же условие, что у Як-3 в
## CampaignProgress, но читается из профиля, поэтому гейт UI M6.3b не зависит от забега).
static func is_endless_unlocked() -> bool:
	for id: String in MissionData.MISSION_IDS:
		if get_stars(id) < 1:
			return false
	return true


# ─── Рекорды миссий и endless ───────────────────────────────────────────────
static func get_mission_best(mission_id: String) -> int:
	var index := _mission_index(mission_id)
	if index < 0:
		return 0
	return maxi(0, _records_int(_best_key(index)))


## Засчитать счёт миссии. Возвращает {"best": актуальный лучший, "is_new": был ли рекорд}.
## Пишем только при новом рекорде: лишних записей на диск (износ flash на Android) нет.
static func record_mission_result(mission_id: String, score: int) -> Dictionary:
	var index := _mission_index(mission_id)
	if index < 0:
		return {"best": 0, "is_new": false}
	var config := _load()
	var current := maxi(0, _as_int(config.get_value(SECTION_RECORDS, _best_key(index), 0), 0))
	var candidate := maxi(0, score)
	if candidate > current:
		config.set_value(SECTION_RECORDS, _best_key(index), candidate)
		_store(config)
		return {"best": candidate, "is_new": true}
	return {"best": current, "is_new": false}


static func get_endless_best() -> int:
	return maxi(0, _records_int(KEY_ENDLESS_BEST))


static func get_endless_wave() -> int:
	return maxi(0, _records_int(KEY_ENDLESS_WAVE))


## Засчитать результат endless: очки и достигнутая волна, обе величины — только вверх
## (GDD «Бесконечный режим»: отдельный рекорд «очки + достигнутая волна»).
static func record_endless(score: int, wave: int) -> Dictionary:
	var config := _load()
	var best := maxi(0, _as_int(config.get_value(SECTION_RECORDS, KEY_ENDLESS_BEST, 0), 0))
	var best_wave := maxi(0, _as_int(config.get_value(SECTION_RECORDS, KEY_ENDLESS_WAVE, 0), 0))
	var candidate := maxi(0, score)
	var candidate_wave := maxi(0, wave)
	var is_new := candidate > best
	if is_new or candidate_wave > best_wave:
		if is_new:
			best = candidate
		if candidate_wave > best_wave:
			best_wave = candidate_wave
		config.set_value(SECTION_RECORDS, KEY_ENDLESS_BEST, best)
		config.set_value(SECTION_RECORDS, KEY_ENDLESS_WAVE, best_wave)
		_store(config)
	return {"best": best, "wave": best_wave, "is_new": is_new}


# ─── Настройки ──────────────────────────────────────────────────────────────
## sound / vibration. Неизвестный ключ → true (безопасный дефолт: фича включена).
static func get_setting(name: String) -> bool:
	var key := _setting_key(name)
	if key.is_empty():
		return true
	var config := _load()
	return _as_bool(config.get_value(SECTION_SETTINGS, key, true), true)


## Записать настройку. Неизвестный ключ игнорируется (не плодим мусор в файле).
## Возвращает актуальное значение.
static func set_setting(name: String, value: bool) -> bool:
	var key := _setting_key(name)
	if key.is_empty():
		return value
	var config := _load()
	if _as_bool(config.get_value(SECTION_SETTINGS, key, not value), not value) != value:
		config.set_value(SECTION_SETTINGS, key, value)
		_store(config)
	return value


# ─── Флаги фич (M8b) ────────────────────────────────────────────────────────
## Флаг фичи из секции [flags]. Неизвестное имя → default_value (false по умолчанию).
## Значение по умолчанию НЕ записывается при чтении: чтение не создаёт файл (как у settings).
static func get_flag(name: String, default_value: bool = false) -> bool:
	if not FLAG_KEYS.has(name):
		return default_value
	var config := _load()
	return _as_bool(config.get_value(SECTION_FLAGS, name, default_value), default_value)


## Записать флаг. Неизвестное имя игнорируется (возвращается value без записи).
## Возвращает записанное значение — так же, как set_setting().
static func set_flag(name: String, value: bool) -> bool:
	if not FLAG_KEYS.has(name):
		return value
	var config := _load()
	if _as_bool(config.get_value(SECTION_FLAGS, name, not value), not value) != value:
		config.set_value(SECTION_FLAGS, name, value)
		_store(config)
	return value


# ─── Самолёты ───────────────────────────────────────────────────────────────
## la5 — стартовый и открыт всегда; yak3/p39 — по флагу профиля (правило выдачи — M6).
static func is_plane_unlocked(plane_id: String) -> bool:
	if plane_id == PLANE_DEFAULT:
		return true
	var key := _plane_key(plane_id)
	if key.is_empty():
		return false
	return _as_bool(_profile_value(key, false), false)


static func unlock_plane(plane_id: String) -> bool:
	var key := _plane_key(plane_id)
	if key.is_empty():
		return false
	var config := _load()
	if not _as_bool(config.get_value(SECTION_PROFILE, key, false), false):
		config.set_value(SECTION_PROFILE, key, true)
		_store(config)
	return true


# ─── Ангар: выбранный самолёт и ливреи (M6.2a) ──────────────────────────────
## Выбранный самолёт. Закрытый/неизвестный сохранённый id (ручная правка, откат профиля)
## не ломает забег: возвращается Ла-5, но файл НЕ перезаписывается чтением.
static func get_selected_plane() -> String:
	var stored := _as_string(_profile_value(KEY_SELECTED_PLANE, PLANE_DEFAULT), PLANE_DEFAULT)
	if stored.is_empty() or not PlaneData.has_plane(stored):
		return PLANE_DEFAULT
	if not is_plane_unlocked(stored):
		return PLANE_DEFAULT
	return stored


## Выбрать самолёт. Неизвестный или ещё закрытый id → false, значение не меняется.
## Повторный выбор уже выбранного самолёта — true (идемпотентно, без записи на диск).
static func select_plane(plane_id: String) -> bool:
	if not PlaneData.has_plane(plane_id):
		return false
	if not is_plane_unlocked(plane_id):
		return false
	var config := _load()
	if _as_string(config.get_value(SECTION_PROFILE, KEY_SELECTED_PLANE, ""), "") != plane_id:
		config.set_value(SECTION_PROFILE, KEY_SELECTED_PLANE, plane_id)
		_store(config)
	return true


## Цена ливреи по индексу 0…3: 0 / 300 / 600 / 900 (GDD). Вне диапазона → 0.
static func get_livery_cost(index: int) -> int:
	if index < 0 or index >= LIVERY_COSTS.size():
		return 0
	return int(LIVERY_COSTS[index])


## Куплена ли ливрея. Индекс 0 — «без ливреи», доступна всегда.
static func is_livery_owned(index: int) -> bool:
	if index == 0:
		return true
	var key := _livery_key(index)
	if key.is_empty():
		return false
	return _as_bool(_profile_value(key, false), false)


## Выбранная ливрея 0…3. Если сохранённая ливрея не куплена (правка файла/откат) — 0,
## файл при этом не трогается.
static func get_selected_livery() -> int:
	var stored := _as_int(_profile_value(KEY_SELECTED_LIVERY, 0), 0)
	if stored < 0 or stored >= LIVERY_SLOTS:
		return 0
	if not is_livery_owned(stored):
		return 0
	return stored


## Выбрать ливрею: 0 — всегда, 1…3 — только купленную. Иначе false без записи.
static func select_livery(index: int) -> bool:
	if index < 0 or index >= LIVERY_SLOTS:
		return false
	if not is_livery_owned(index):
		return false
	var config := _load()
	if _as_int(config.get_value(SECTION_PROFILE, KEY_SELECTED_LIVERY, -1), -1) != index:
		config.set_value(SECTION_PROFILE, KEY_SELECTED_LIVERY, index)
		_store(config)
	return true


## Купить ливрею 1…3 за снабжение (300/600/900). false — уже куплена, индекс вне 1…3
## или снабжения не хватает (тогда баланс не меняется). Покупка не выбирает ливрею:
## выбор — отдельный select_livery() (ангар M6.2b покажет обе кнопки).
static func buy_livery(index: int) -> bool:
	var key := _livery_key(index)
	if key.is_empty():
		return false
	if is_livery_owned(index):
		return false
	if not spend_supply(get_livery_cost(index)):
		return false
	var config := _load()
	config.set_value(SECTION_PROFILE, key, true)
	_store(config)
	return true


# ─── Сброс (QA) ─────────────────────────────────────────────────────────────
## Удалить файл профиля. Путь сохранения НЕ меняется: тест продолжает работать в своём
## user:// и не уходит на реальный профиль игрока.
static func reset() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RunRecord.get_save_path()))


# ─── Внутреннее: ключи и чтение значений ────────────────────────────────────
static func _mission_index(mission_id: String) -> int:
	return MissionData.MISSION_IDS.find(mission_id)


static func _star_key(index: int) -> String:
	return "%s%d" % [STAR_KEY_PREFIX, index + 1]


static func _best_key(index: int) -> String:
	return "%s%d" % [BEST_KEY_PREFIX, index + 1]


static func _setting_key(name: String) -> String:
	match name:
		"sound":
			return KEY_SOUND
		"vibration":
			return KEY_VIBRATION
		_:
			return ""


static func _plane_key(plane_id: String) -> String:
	match plane_id:
		PLANE_YAK3:
			return KEY_UNLOCKED_YAK3
		PLANE_P39:
			return KEY_UNLOCKED_P39
		_:
			return ""


## Ключ ливреи `livery_1..3` по индексу 1…3. Вне диапазона (0, 4, −1) → "" (не ключ).
static func _livery_key(index: int) -> String:
	if index < 1 or index > LIVERY_KEYS.size():
		return ""
	return LIVERY_KEYS[index - 1]


static func _profile_int(key: String) -> int:
	return maxi(0, _as_int(_profile_value(key, 0), 0))


static func _records_int(key: String) -> int:
	var config := _load()
	return _as_int(config.get_value(SECTION_RECORDS, key, 0), 0)


static func _profile_value(key: String, default_value: Variant) -> Variant:
	var config := _load()
	return config.get_value(SECTION_PROFILE, key, default_value)


## Значение из ConfigFile → int. Ручные правки могут дать float/строку: берём то, что
## безопасно приводится, всё остальное — default.
static func _as_int(value: Variant, default_value: int) -> int:
	match typeof(value):
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			var as_float := float(value)
			if not is_finite(as_float):
				return default_value
			return int(as_float)
		TYPE_BOOL:
			return 1 if bool(value) else 0
		_:
			return default_value


static func _as_bool(value: Variant, default_value: bool) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value) != 0
		TYPE_FLOAT:
			var as_float := float(value)
			if not is_finite(as_float):
				return default_value
			return int(as_float) != 0
		_:
			return default_value


## Строка из ConfigFile (selected_plane). Не строка → default (файл правлен руками).
static func _as_string(value: Variant, default_value: String) -> String:
	if typeof(value) == TYPE_STRING:
		return String(value)
	return default_value


# ─── Внутреннее: загрузка, миграция, запись ─────────────────────────────────
## Конфиг профиля с применённой миграцией. Никогда не null; битый/отсутствующий файл даёт
## пустой ConfigFile (все геттеры вернут дефолты).
static func _load() -> ConfigFile:
	var config := _read_config()
	if config.has_section_key(SECTION_META, KEY_SCHEMA_VERSION):
		return config
	# Пустой/нечитаемый файл миграции не подлежит: иначе простое чтение создавало бы файл.
	if not config.get_sections().is_empty():
		_migrate(config)
	return config


## Миграция v1 → v2: legacy [record] best_score становится рекордом endless (GDD).
## Секция [record] НЕ удаляется — её по-прежнему пишет RunRecord. После записи
## schema_version появится, поэтому повторной миграции не будет.
static func _migrate(config: ConfigFile) -> void:
	var legacy := maxi(0, _as_int(
		config.get_value(SECTION_LEGACY, KEY_BEST_SCORE_LEGACY, 0), 0))
	var endless := maxi(0, _as_int(config.get_value(SECTION_RECORDS, KEY_ENDLESS_BEST, 0), 0))
	if legacy > endless:
		config.set_value(SECTION_RECORDS, KEY_ENDLESS_BEST, legacy)
	_store(config)


## Сохранить конфиг вместе со schema_version. Результат save() намеренно игнорируется:
## недоступный user:// не должен ни ронять игру, ни сорить в логах тестов.
## Перед записью дописываются отсутствующие ключи схемы: файл остаётся самодостаточным
## (QA/ручная правка видят все поля), а значения по умолчанию не «теряются» между записями.
static func _store(config: ConfigFile) -> void:
	config.set_value(SECTION_META, KEY_SCHEMA_VERSION, SCHEMA_VERSION)
	_ensure_defaults(config)
	config.save(get_save_path())


## Дописать ТОЛЬКО отсутствующие ключи секций (существующие значения не трогаем).
static func _ensure_defaults(config: ConfigFile) -> void:
	if not config.has_section_key(SECTION_PROFILE, KEY_SUPPLY):
		config.set_value(SECTION_PROFILE, KEY_SUPPLY, 0)
	for index in MissionData.MISSION_IDS.size():
		if not config.has_section_key(SECTION_PROFILE, _star_key(index)):
			config.set_value(SECTION_PROFILE, _star_key(index), 0)
		if not config.has_section_key(SECTION_RECORDS, _best_key(index)):
			config.set_value(SECTION_RECORDS, _best_key(index), 0)
	for key: String in [KEY_UNLOCKED_YAK3, KEY_UNLOCKED_P39]:
		if not config.has_section_key(SECTION_PROFILE, key):
			config.set_value(SECTION_PROFILE, key, false)
	for key: String in LIVERY_KEYS:
		if not config.has_section_key(SECTION_PROFILE, key):
			config.set_value(SECTION_PROFILE, key, false)
	# M6.2a: ангар. Значения = стартовое состояние (Ла-5, без ливреи); выбранный
	# самолёт/ливрея не сбрасываются существующими ключами.
	if not config.has_section_key(SECTION_PROFILE, KEY_SELECTED_PLANE):
		config.set_value(SECTION_PROFILE, KEY_SELECTED_PLANE, PLANE_DEFAULT)
	if not config.has_section_key(SECTION_PROFILE, KEY_SELECTED_LIVERY):
		config.set_value(SECTION_PROFILE, KEY_SELECTED_LIVERY, 0)
	if not config.has_section_key(SECTION_SETTINGS, KEY_SOUND):
		config.set_value(SECTION_SETTINGS, KEY_SOUND, true)
	if not config.has_section_key(SECTION_SETTINGS, KEY_VIBRATION):
		config.set_value(SECTION_SETTINGS, KEY_VIBRATION, true)
	if not config.has_section_key(SECTION_RECORDS, KEY_ENDLESS_BEST):
		config.set_value(SECTION_RECORDS, KEY_ENDLESS_BEST, 0)
	if not config.has_section_key(SECTION_RECORDS, KEY_ENDLESS_WAVE):
		config.set_value(SECTION_RECORDS, KEY_ENDLESS_WAVE, 0)
	# M8b: флаги монетизации — выключены по умолчанию (слоты Ads/IAP скрыты).
	for key: String in FLAG_KEYS:
		if not config.has_section_key(SECTION_FLAGS, key):
			config.set_value(SECTION_FLAGS, key, false)


## Прочитать файл в ConfigFile с сохранением ВСЕХ секций. Пустой/битый файл → пустой
## ConfigFile, а не исключение: вызывающий код получает дефолты и не падает.
static func _read_config() -> ConfigFile:
	var sanitized := _sanitize_config(_read_validated_text(get_save_path()))
	if sanitized.is_empty():
		return ConfigFile.new()
	var probe := ConfigFile.new()
	if probe.parse(sanitized) != OK:
		# Мусор не должен терять уже разобранные секции: отдаём чистый конфиг.
		return ConfigFile.new()
	return probe


## Прочитать файл и отсеять всё, что не является «текстовым INI», ещё на уровне БАЙТОВ:
## пустой файл, NUL/DEL, C0-управляющие (кроме \t \n \r), превышение размера, ошибка
## чтения. Иначе ConfigFile печатал бы ERROR и мог бы прочитать NUL-мусор как валидный INI.
static func _read_validated_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var length := int(file.get_length())
	if length <= 0 or length > MAX_CONFIG_BYTES:
		file.close()
		return ""
	var bytes := file.get_buffer(length)
	file.close()
	if bytes.size() != length:
		return ""
	for i in length:
		var byte := bytes[i]
		if byte == 0x00 or byte == 0x7F:
			return ""
		if byte < 0x20 and byte != 0x09 and byte != 0x0A and byte != 0x0D:
			return ""
	return bytes.get_string_from_utf8()


## Структурная проверка INI + нормализация: комментарии и пустые строки выбрасываются,
## каждая содержательная строка — [section] или key=value. Мусор без «=», пустые имена
## и неподдерживаемые значения → "" (отказ, дефолты). Значения ограничены числом, bool и
## строкой в кавычках — этого достаточно для v1/v2; произвольные выражения не пропускаем,
## чтобы VariantParser не печатал ERROR.
static func _sanitize_config(text: String) -> String:
	var lines := PackedStringArray()
	for raw_line in text.replace("\r", "\n").split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("["):
			if not line.ends_with("]"):
				return ""
			if not _is_plain_name(line.substr(1, line.length() - 2)):
				return ""
			lines.append(line)
			continue
		var eq := line.find("=")
		if eq < 0:
			return ""
		var key := line.substr(0, eq).strip_edges()
		if not _is_plain_name(key):
			return ""
		var value := _strip_value_comment(line.substr(eq + 1).strip_edges())
		if not _is_parseable_value(value):
			return ""
		lines.append(key + "=" + value)
	if lines.is_empty():
		return ""
	return "\n".join(lines) + "\n"


## Имя секции/ключа: непустое, только [A-Za-z0-9_.-]. Уже, чем допускает ConfigFile, но
## кавычки/пробелы в имени заставляют парсер печатать «Unterminated string» и терять секцию.
static func _is_plain_name(name: String) -> bool:
	if name.is_empty():
		return false
	for i in name.length():
		var code := name.unicode_at(i)
		var is_alnum := (code >= 0x30 and code <= 0x39) \
			or (code >= 0x41 and code <= 0x5A) \
			or (code >= 0x61 and code <= 0x7A)
		if not (is_alnum or code == 0x5F or code == 0x2E or code == 0x2D):
			return false
	return true


## Отрезать хвостовой комментарий значения: "13 ; note" и "13 # note" — это 13.
static func _strip_value_comment(value: String) -> String:
	var cut := value.find(";")
	var hash_cut := value.find("#")
	if hash_cut >= 0 and (cut < 0 or hash_cut < cut):
		cut = hash_cut
	if cut >= 0:
		return value.substr(0, cut).strip_edges()
	return value


## Число, true/false или строка в кавычках — единственные формы, которые мы пишем сами и
## которые встречаются в v1. Всё остальное (массивы, словари, идентификаторы) — отказ.
static func _is_parseable_value(value: String) -> bool:
	if value == "true" or value == "false":
		return true
	if value.length() >= 2 and value.begins_with("\"") and value.ends_with("\""):
		# Строка без экранированной кавычки внутри: парсер не должен упираться в хвост.
		return value.substr(1, value.length() - 2).find("\"") < 0
	return _is_plain_number(value)


## Число: опциональный «-», 1..18 цифр, опциональная дробная часть через точку.
static func _is_plain_number(value: String) -> bool:
	var i := 0
	if value.begins_with("-"):
		i = 1
	var int_start := i
	while i < value.length() and _is_digit_at(value, i):
		i += 1
	var int_digits := i - int_start
	if int_digits == 0 or int_digits > MAX_INT_DIGITS:
		return false
	if i == value.length():
		return true
	if value.unicode_at(i) != 0x2E:  # '.'
		return false
	i += 1
	var frac_start := i
	while i < value.length() and _is_digit_at(value, i):
		i += 1
	return i - frac_start > 0 and i == value.length()


static func _is_digit_at(text: String, index: int) -> bool:
	var code := text.unicode_at(index)
	return code >= 0x30 and code <= 0x39
