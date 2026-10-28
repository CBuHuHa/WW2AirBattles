# iap.gd
# Purpose: Адаптер встроенных покупок (M8b; GDD «Монетизация (заложена, не включена)» →
#          «каталог скинов (v1.1)», «адаптеры Ads/IAP с пустой реализацией»).
#          ЗАГЛУШКА: платёжного SDK и сетевых вызовов нет. purchase() ВСЕГДА false и колбэк
#          НЕ вызывает; каталог — статический список скинов-заглушек, отдаётся только при
#          поднятом флаге shop_enabled (по умолчанию false), иначе пустой массив.
#          Реальных SKU в сторах нет: id — внутренние (SKIN_*), их нельзя менять при
#          подключении SDK (иначе сопоставление с товарами стора разъедется).
# Dependencies: SaveGame (get_flag("shop_enabled")). Обратных зависимостей нет: UI слоты
#               магазина в v1 не показываются (GDD: каталог скинов — v1.1).
# Author: Mechanics Developer Agent (M8b)
#
# API (всё статическое):
#   is_available() -> bool            shop_enabled (default false)
#   get_catalog() -> Array            [] при выключенном флаге; иначе статический список
#                                     [{"sku", "title", "price", "kind"}] (скины-заглушки)
#   purchase(sku, callback) -> bool   ВСЕГДА false (заглушка), callback не вызывается
#   has_sku(sku) -> bool              есть ли sku в статическом каталоге
#
# GDD out-of-scope: подписок, валютных пакетов и «магазина» в v1 нет — только скины v1.1.

class_name Iap
extends RefCounted

## Ключ профиля (SaveGame [flags]) — единственный источник доступности каталога.
const FLAG_SHOP_ENABLED := "shop_enabled"

## Скины-заглушки (v1.1). Соответствуют трём ливреям ангара (SaveGame.LIVERY_KEYS):
## покупка скина в будущем = открытие ливреи без траты снабжения.
const SKIN_LIVERY_1 := "skin_livery_1"
const SKIN_LIVERY_2 := "skin_livery_2"
const SKIN_LIVERY_3 := "skin_livery_3"
## Порядок каталога стабилен: UI/тесты опираются на него, а не на порядок словаря.
const SKIN_IDS := [SKIN_LIVERY_1, SKIN_LIVERY_2, SKIN_LIVERY_3]

## Заглушки цен: реальных товаров нет, поэтому price — метка, а не число (никаких валют).
const PRICE_STUB := "—"


## Включён ли магазин в этой сборке/профиле. По умолчанию false.
static func is_available() -> bool:
	return SaveGame.get_flag(FLAG_SHOP_ENABLED, false)


## Каталог скинов. При выключенном флаге — ПУСТОЙ массив (никакого «серого» списка в UI).
## При включённом — статический список словарей; поля плоские, чтобы UI рисовал карточки
## без разбора вложенных структур.
static func get_catalog() -> Array:
	if not is_available():
		return []
	var catalog: Array = []
	for sku: String in SKIN_IDS:
		catalog.append({
			"sku": sku,
			"title": _title_for(sku),
			"price": PRICE_STUB,
			"kind": "skin",
		})
	return catalog


## Покупка. ЗАГЛУШКА: всегда false, callback НЕ вызывается (нет SDK → нет чека → нет выдачи).
static func purchase(sku: String, callback: Callable = Callable()) -> bool:
	if not is_available():
		# Выключенный магазин отказывает раньше любых проверок sku.
		return false
	var _unused_sku := sku
	var _unused_callback := callback
	return false


## Есть ли sku в статическом каталоге (не зависит от флага: проверка контракта, не UI).
static func has_sku(sku: String) -> bool:
	return SKIN_IDS.has(sku)


## Название скина для карточки (RU). Отдельная функция — единый источник текста для UI/тестов.
static func _title_for(sku: String) -> String:
	match sku:
		SKIN_LIVERY_1:
			return "Ливрея «Полевая»"
		SKIN_LIVERY_2:
			return "Ливрея «Пустыня»"
		SKIN_LIVERY_3:
			return "Ливрея «Ночь»"
		_:
			return sku
