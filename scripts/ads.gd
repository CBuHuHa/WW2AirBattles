# ads.gd
# Purpose: Адаптер рекламы (M8b; GDD «Монетизация (заложена, не включена)» → «Абстракция:
#          адаптеры Ads/IAP с пустой реализацией, remote-флаги (ads_enabled, shop_enabled)»).
#          ЗАГЛУШКА: SDK не подключён, сетевых вызовов и платёжных API здесь нет и не будет
#          до v1.1. Показ рекламы ВСЕГДА возвращает false и колбэк НЕ вызывает: UI-слоты
#          (revive на экране поражения, ×2 снабжение на экране победы) существуют, но скрыты,
#          пока флаг ads_enabled не поднят.
#          Доступность читается из профиля (SaveGame [flags] ads_enabled, по умолчанию false),
#          а не из константы: будущий remote-config просто выставит флаг.
# Dependencies: SaveGame (get_flag("ads_enabled")). LevelController зовёт is_available() в
#               момент исхода забега (один раз за забег, не в кадре).
# Author: Mechanics Developer Agent (M8b)
#
# API (всё статическое):
#   is_available() -> bool                 ads_enabled (default false); SDK нет — true лишь
#                                          разрешает показать слот, но показ всё равно false
#   show_rewarded(kind, callback) -> bool  ВСЕГДА false (заглушка), callback не вызывается
#   get_placement(kind) -> String          id плейсмента для будущего SDK ("" — неизвестный)
#
# GDD «Монетизация»: только rewarded (revive 1 раз за забег, ×2 снабжение после миссии).
# Баннеров и интерстишлов в проекте нет — констант под них тоже нет.

class_name Ads
extends RefCounted

## GDD «Win, fail, restart»: rewarded-revive на экране поражения (скрыт флагом до v1.1).
const REVIVE := "revive"
## GDD «Монетизация»: rewarded ×2 снабжение после миссии.
const DOUBLE_SUPPLY := "double_supply"

## Ключ профиля (SaveGame [flags]) — единственный источник доступности.
const FLAG_ADS_ENABLED := "ads_enabled"

## Плейсменты будущего SDK. Значение стабильное: его нельзя менять при подключении SDK,
## иначе настройки рекламной сети разъедутся с кодом.
const PLACEMENT_REVIVE := "revive_after_death"
const PLACEMENT_DOUBLE_SUPPLY := "supply_double_after_win"


## Разрешена ли реклама в этой сборке/профиле. По умолчанию false (флаг есть, значение нет).
static func is_available() -> bool:
	return SaveGame.get_flag(FLAG_ADS_ENABLED, false)


## Показать rewarded-рекламу. ЗАГЛУШКА: всегда false, callback НЕ вызывается — награды нет,
## поэтому вызывающий код обязан обработать отказ (сейчас UI-слоты скрыты и не вызывают).
static func show_rewarded(kind: String, callback: Callable = Callable()) -> bool:
	# Параметры читаются намеренно: сигнатура — контракт будущего SDK (kind → плейсмент,
	# callback → выдача награды). Заглушка их не использует.
	var _unused_placement := get_placement(kind)
	var _unused_callback := callback
	return false


## id плейсмента по типу награды ("" — неизвестный тип: вызывающий не должен показывать слот).
static func get_placement(kind: String) -> String:
	match kind:
		REVIVE:
			return PLACEMENT_REVIVE
		DOUBLE_SUPPLY:
			return PLACEMENT_DOUBLE_SUPPLY
		_:
			return ""
