# art_assets.gd
# Purpose: Реестр текстур M7b: единственная точка «ключ ассета GDD → Texture2D» с кэшем.
#          Ключи берутся из ArtStyle (const KEY_*) и НЕ переименовываются: файл лежит по
#          `res://assets/art/<gdd_key>.png`. Пока арта на все типы нет, часть ключей
#          временно рендерится существующим PNG (решение владельца 2026-10-28): Bf 110 берёт
#          спрайт Bf 109, боссы He 111 / Ju 88 / Fw 200 — спрайт Fw 190. Отличие этих врагов
#          от прототипа остаётся только в механике; хитбоксы и SIZES ArtStyle не меняются.
#          Иконки перков — 9 PNG 24×24 `ui_perk_<id>.png` (SpriteCook, лист 2026-10-28).
#          Отсутствие файла — не ошибка: texture() возвращает null, и вызывающий узел рисует
#          код-силуэт ArtStyle. Новые ассеты здесь не появляются, только чтение.
#          M9: существование проверяется ТОЛЬКО через ResourceLoader.exists() (понимает remap
#          на импортированные .ctex). Проверять ресурсы через FileAccess/DirAccess нельзя:
#          исходных PNG в экспортированной сборке нет, и на устройстве такой гейт всегда
#          закрыт (симптом — все самолёты рисовались код-силуэтами при зелёном headless-тесте).
# Dependencies: ArtStyle (размеры и ключи — но не наоборот, цикла нет: ArtStyle о текстурах не знает).
# Author: Technical Artist Agent (M7b, M9 fix)

class_name ArtAssets
extends RefCounted

## Каталог финальных PNG (см. assets/art/README.md). Расширение одно — .png.
const ART_DIR := "res://assets/art/"
const EXTENSION := ".png"

## Временное переиспользование арта (2026-10-28): ключ GDD → ключ уже сгенерированного PNG.
## Убирать запись можно только когда появится собственный спрайт: SIZES хитбоксов от этого
## маппинга не зависят, поэтому замена файла ничего не ломает.
const RENDER_KEYS := {
	&"enemy_bf110": &"enemy_bf109",
	&"boss_he111": &"enemy_fw190",
	&"boss_ju88": &"enemy_fw190",
	&"boss_fw200": &"enemy_fw190",
}

## id карт из data/perks.json → файл `ui_perk_<id>.png`. Порядок как в GDD («Временные перки»).
const PERK_ICON_IDS := [
	&"sparka", &"ap", &"rockets", &"shatter", &"accuracy", &"heavy",
	&"repair", &"coolhead", &"emergency",
]
## Префикс файла иконки перка: ui_perk_<id>.png.
const PERK_ICON_PREFIX := "ui_perk_"

## Кэш «ключ запроса → Texture2D или null». Статический: спрайты грузятся один раз за сессию,
## а не на каждом спавне волны (требование «без загрузки текстур в кадре»). Промах тоже
## кэшируется — повторный вопрос о ключе без файла не трогает диск.
static var _cache: Dictionary = {}


## Ключ PNG, которым временно рисуется ассет. Для ключей без своего арта — ключ-прототип из
## RENDER_KEYS; для обычных ключей — он сам (если ресурс есть). Неизвестный/пустой ключ → &"".
## ВАЖНО (M9, регресс с устройства): существование проверяется ТОЛЬКО через
## ResourceLoader.exists(). Исходные PNG в собранную игру не попадают — там лежат лишь их
## импортированные `.ctex` в `res://.godot/imported/` и remap, поэтому FileAccess-проверка
## файла в PCK всегда false: на Android все самолёты рисовались код-силуэтами ArtStyle, а в
## редакторе/headless (файл на диске) тест был зелёным. ResourceLoader понимает remap.
static func render_key(key: StringName) -> StringName:
	var requested := StringName(key)
	if requested == &"":
		return &""
	if RENDER_KEYS.has(requested):
		return StringName(RENDER_KEYS[requested])
	if ResourceLoader.exists(path_for(requested)):
		return requested
	return &""


## Текстура по ключу GDD. null — файла нет (вызывающий рисует код-силуэт). Кэш общий.
static func texture(key: StringName) -> Texture2D:
	var requested := StringName(key)
	if _cache.has(requested):
		return _cache[requested] as Texture2D
	var tex: Texture2D = null
	var resolved := render_key(requested)
	if resolved != &"":
		var path := path_for(resolved)
		if ResourceLoader.exists(path):
			tex = load(path) as Texture2D
	_cache[requested] = tex
	return tex


## Есть ли за ключом реальный файл (после временного маппинга).
static func has_texture(key: StringName) -> bool:
	return texture(key) != null


## Ключ файла иконки перка: `ui_perk_<id>`. Неизвестный id → &"" (слот нарисует код карты).
static func perk_icon_key(id: String) -> StringName:
	if id.is_empty() or not PERK_ICON_IDS.has(StringName(id)):
		return &""
	return StringName(PERK_ICON_PREFIX + id)


## Путь PNG для КОНЕЧНОГО ключа (без маппинга) — один формат на весь реестр.
static func path_for(key: StringName) -> String:
	return ART_DIR + String(key) + EXTENSION
