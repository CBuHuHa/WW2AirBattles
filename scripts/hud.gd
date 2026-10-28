# hud.gd
# Purpose: HUD: иконки HP (ui_hp) + текст HP слева сверху, счёт справа сверху,
#          полоса HP босса сверху по центру (тёмная подложка в кремовом контуре, заливка DANGER).
#          Полировка M3-A: иконки рисуются кодом ArtStyle, шрифт — глобальная тема assets/ui_theme.tres.
#          M6.1b: потолок HP стал переменным («Ремонт» даёт 4), поэтому ряд иконок и текст
#          «HP n/max» строятся по max_hp. Под рядом HP — 3 слота перков (2 оружия + 1 утилита,
#          GDD «UI / HUD»: «иконки перков под HP»).
#          M7b: в занятом слоте рисуется иконка `ui_perk_<id>.png` 24×24 внутри плашки 26×26
#          (ArtAssets, nearest, 1:1) поверх кремовой подложки alpha 0.15 — тёмные иконки
#          (accuracy/sparka) читаются на плашке. Если файла нет, слот остаётся прежним:
#          две буквы карты («СП», «БР», «РС», «ОС», «КУ», «ТК» / «РЕ», «ХЛ», «АС»).
# Dependencies: Player (MAX_HP как дефолт), PerkData (категория карты → слот), ArtStyle
#               (палитра, KEY_UI_HP), ArtAssets (иконки перков M7b), сцены main.tscn.
# Author: Mechanics Developer Agent (M2–M6.1b), UI/UX Agent (M3-A),
#         Technical Artist Agent (M7b: иконки перков)

class_name Hud
extends Control

## Полоса босса: 360×16, контур 2 px, подложка 356×12, заливка 354×10 (внутри контура).
const BOSS_BAR_WIDTH := 360.0
const BOSS_BAR_HEIGHT := 16.0
const BOSS_FILL_MAX_WIDTH := 354.0
const BOSS_FILL_HEIGHT := 10.0

## Ряд иконок HP: x=16, иконка 24×24, шаг 30; текст «HP n/max» начинается справа от ряда.
## Шаг не зависит от max_hp: 4-я иконка («Ремонт») встаёт в тот же ритм, а текст HP
## сдвигается вправо (см. _layout_hp_label) — так ряд не «сжимается» на 4 HP.
const HP_ICON_ORIGIN := Vector2(16.0, 16.0)
const HP_ICON_STEP := 30.0
## Зазор между последней иконкой и текстом HP. При 3 HP текст начинается с x=112
## (сценный offset_left), как в утверждённой раскладке M3-A.
const HP_LABEL_GAP := 12.0
## Правый край строки HP в утверждённой раскладке (main.tscn: offset_right = 220);
## левее начинается ScoreLabel, поэтому ширина строки HP растёт только при 4 HP.
const HP_LABEL_RIGHT := 220.0

## Слоты перков (M6.1b): под рядом HP, 3 слота по 26×26 с шагом 30 — тот же ритм, что у
## иконок HP. Слот 0/1 — оружие, слот 2 — утилита (правила data/perks.json: 2 + 1).
const PERK_SLOT_COUNT := 3
const PERK_SLOT_ORIGIN := Vector2(16.0, 46.0)
const PERK_SLOT_STEP := 30.0
const PERK_SLOT_SIZE := Vector2(26.0, 26.0)
const PERK_SLOT_FONT_SIZE := 16
## Короткие коды карт для слотов HUD (RU, 2 буквы — влезают в 26 px при 16 px).
## Фолбэк M7b: если PNG `ui_perk_<id>` нет, слот рисует этот код — единственная таблица
## «id карты → текст в слоте».
const PERK_CODES := {
	"sparka": "СП",
	"ap": "БР",
	"rockets": "РС",
	"shatter": "ОС",
	"accuracy": "КУ",
	"heavy": "ТК",
	"repair": "РЕ",
	"coolhead": "ХЛ",
	"emergency": "АС",
}

## M7b: иконка перка 24×24 внутри плашки 26×26 (по 1 px поля с каждой стороны).
## Иконки — пиксель-арт 1×, поэтому рисуются 1:1 без масштабирования (фильтр не участвует).
const PERK_ICON_SIZE := Vector2(24.0, 24.0)
## Подложка под иконку: кремовый wash поверх тёмной плашки (контраст тёмных иконок).
const PERK_ICON_BACKDROP_ALPHA := 0.15

@onready var hp_label: Label = $HPLabel
@onready var score_label: Label = $ScoreLabel
@onready var boss_bar: Control = $BossBar
@onready var boss_fill: ColorRect = $BossBar/Fill
## M6.3b: строка «Волна N» бесконечного режима — справа под счётом (220…476 × 46…80).
## В кампании скрыта: там волны конечны и номер игроку не нужен (GDD «UI / HUD»).
@onready var wave_label: Label = $WaveLabel

## Текущее HP для отрисовки иконок. set_hp — единственная точка записи.
var hp: int = Player.MAX_HP
## Потолок HP забега (M6.1b: «Ремонт» → 4). Пишется только set_max_hp().
var max_hp: int = Player.MAX_HP

## Коды в FIXED-слотах: [оружие 1, оружие 2, утилита]. Пустая строка — слот свободен.
## Позиции фиксированы по категориям, поэтому утилита не «переезжает» в оружейный слот,
## когда оружия ещё нет.
var _perk_slots: Array[String] = ["", "", ""]
## M7b: id карт в тех же слотах (параллельно кодам) — по нему берётся иконка `ui_perk_<id>`.
## Пустая строка — слот свободен (иконки нет, код есть только у занятого слота).
var _perk_ids: Array[String] = ["", "", ""]

var _boss_max_hp: float = 1.0


func _ready() -> void:
	# HUD не должен перехватывать тапы: драг работает по всему экрану.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_max_hp(Player.MAX_HP)
	set_hp(Player.MAX_HP)
	set_score(0)
	hide_boss()
	hide_wave()


func _draw() -> void:
	# Иконки HP: заполненные — текущие HP, приглушённые — уже потерянные.
	# Контракт tests: текст HP остаётся строкой «HP %d/%d», иконки — только визуал.
	for i in max_hp:
		var center := HP_ICON_ORIGIN + Vector2(HP_ICON_STEP * float(i), 0.0) \
			+ ArtStyle.size_of(ArtStyle.KEY_UI_HP) * 0.5
		ArtStyle.draw_hp_icon(self, center, i < hp)
	_draw_perk_slots()


## Слоты перков под HP: плашка + кремовый контур (оружие) / жёлтый контур (утилита) + иконка.
## Свободный слот остаётся еле заметной рамкой — игрок видит, сколько карт ещё влезет.
## M7b: занятый слот рисует `ui_perk_<id>.png` 24×24 по центру плашки 26×26; если файла нет —
## прежний двухбуквенный код (HUD не падает и не оставляет пустой слот).
func _draw_perk_slots() -> void:
	var font := get_theme_default_font()
	var font_size := PERK_SLOT_FONT_SIZE
	var icon_offset := (PERK_SLOT_SIZE - PERK_ICON_SIZE) * 0.5
	for index in PERK_SLOT_COUNT:
		var rect := Rect2(PERK_SLOT_ORIGIN + Vector2(PERK_SLOT_STEP * float(index), 0.0),
			PERK_SLOT_SIZE)
		var code := _perk_slots[index]
		var filled := not code.is_empty()
		var accent := ArtStyle.BULLET_ENEMY if index == PERK_SLOT_COUNT - 1 else ArtStyle.CREAM
		draw_rect(rect, Color(0.129412, 0.141176, 0.109804, 0.6 if filled else 0.25))
		var icon := _perk_icon(index)
		if icon != null:
			# Кремовый wash под иконкой: тёмные иконки (accuracy/sparka) держат контраст на
			# тёмной плашке, а светлые (emergency) не «выжигают» слот.
			draw_rect(Rect2(rect.position, PERK_SLOT_SIZE),
				Color(ArtStyle.CREAM, PERK_ICON_BACKDROP_ALPHA))
		draw_rect(rect, Color(accent, 0.75 if filled else 0.18), false, 1.0)
		if icon != null:
			# 1:1 на базовом разрешении 540×960: иконка 24 px в плашке 26 px.
			draw_texture_rect(icon, Rect2(rect.position + icon_offset, PERK_ICON_SIZE), false)
			continue
		if not filled or font == null:
			continue
		# Вертикальное центрирование по метрикам шрифта: базисная линия = центр - (ascent-descent)/2.
		var baseline := rect.position.y \
			+ (PERK_SLOT_SIZE.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		draw_string(font, Vector2(rect.position.x, baseline), code,
			HORIZONTAL_ALIGNMENT_CENTER, PERK_SLOT_SIZE.x, font_size, accent)


## M6.1b: потолок HP («Ремонт» → 4). HP клампится по максимуму, ряд иконок и текст
## «HP n/max» перестраиваются под него (4-я иконка не залезает под текст).
func set_max_hp(max_value: int) -> void:
	max_hp = maxi(1, max_value)
	hp = mini(hp, max_hp)
	_layout_hp_label()
	_refresh_hp_text()
	queue_redraw()


func set_hp(hp_value: int) -> void:
	hp = clampi(hp_value, 0, max_hp)
	_refresh_hp_text()
	queue_redraw()


## Текст HP — единственное место формата «HP n/max» (нужен и set_hp, и set_max_hp).
func _refresh_hp_text() -> void:
	if hp_label == null:
		return
	hp_label.text = "HP %d/%d" % [hp, max_hp]


## Сдвинуть текст HP вправо от ряда иконок и дать ему ровно столько ширины, сколько нужно.
## При 3 HP это сценные 112 px (раскладка M3-A не меняется), при 4 HP — 142 px; правый
## край не заходит на ScoreLabel (x=220) при любой из двух длин.
func _layout_hp_label() -> void:
	if hp_label == null:
		return
	var icon_width := ArtStyle.size_of(ArtStyle.KEY_UI_HP).x
	var left := HP_ICON_ORIGIN.x + HP_ICON_STEP * float(max_hp - 1) + icon_width + HP_LABEL_GAP
	hp_label.offset_left = left
	var text_width := 84.0
	var font := hp_label.get_theme_font(&"font")
	if font != null:
		var font_size := hp_label.get_theme_font_size(&"font_size")
		text_width = font.get_string_size("HP %d/%d" % [max_hp, max_hp],
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 4.0
	hp_label.offset_right = maxf(HP_LABEL_RIGHT, left + text_width)


func set_score(score: int) -> void:
	if score_label != null:
		score_label.text = "Счёт: %d" % score


# ─── Волна (M6.3b, только бесконечный режим) ────────────────────────────────
## Показать номер волны бесконечного забега («Волна 3»). Номер 1-based, < 1 клампится в 1.
func set_wave(number: int) -> void:
	if wave_label == null:
		return
	wave_label.text = "Волна %d" % maxi(1, number)
	wave_label.visible = true


## Скрыть строку волны (кампания, брифинг, окно исхода). Текст не стирается: QA получает
## "" через get_wave_text(), а set_wave() всё равно перезапишет номер.
func hide_wave() -> void:
	if wave_label == null:
		return
	wave_label.visible = false


## QA/тесты: текст строки волны ("" — строка скрыта, как в кампании).
func get_wave_text() -> String:
	if wave_label == null or not wave_label.visible:
		return ""
	return String(wave_label.text)


func is_wave_visible() -> bool:
	return wave_label != null and wave_label.visible


# ─── Слоты перков (M6.1b) ───────────────────────────────────────────────────
## Показать активные карты (порядок — как в PerkSystem, т.е. порядок взятия).
## Слот выбирается по категории: оружие → 0/1, утилита → 2. Неизвестный id или карта
## сверх правил в слоты не попадают (HUD не падает на битых данных).
func set_perks(active: Array[String]) -> void:
	_perk_slots = ["", "", ""]
	_perk_ids = ["", "", ""]
	var weapon_index := 0
	for id in active:
		var code := String(PERK_CODES.get(id, ""))
		if code.is_empty():
			continue
		if PerkData.get_category(id) == PerkData.CATEGORY_UTILITY:
			_perk_slots[PERK_SLOT_COUNT - 1] = code
			_perk_ids[PERK_SLOT_COUNT - 1] = id
		elif weapon_index < PERK_SLOT_COUNT - 1:
			_perk_slots[weapon_index] = code
			_perk_ids[weapon_index] = id
			weapon_index += 1
	queue_redraw()


## QA: сколько слотов занято (0…3). Свободные слоты рисуются рамкой, но не считаются.
func get_perk_slot_count() -> int:
	var filled := 0
	for code in _perk_slots:
		if not code.is_empty():
			filled += 1
	return filled


## QA: код карты в слоте ("" — слот свободен, индекс вне 0…2 — тоже "").
## Контракт M6.1b сохранён: код возвращается независимо от того, что нарисовано (иконка или буквы).
func get_perk_slot_text(index: int) -> String:
	if index < 0 or index >= _perk_slots.size():
		return ""
	return _perk_slots[index]


## QA: id карты в слоте ("" — слот свободен/индекс вне 0…2). По нему берётся иконка.
func get_perk_id(index: int) -> String:
	if index < 0 or index >= _perk_ids.size():
		return ""
	return _perk_ids[index]


## QA: нарисована ли в слоте иконка (true — PNG найден и слот занят; false — рисуется код).
func has_perk_icon(index: int) -> bool:
	return _perk_icon(index) != null


## Текстура иконки слота: `ui_perk_<id>.png` через ArtAssets. null — слот свободен или файла нет
## (вызывающий рисует код карты, как до M7b).
func _perk_icon(index: int) -> Texture2D:
	var id := get_perk_id(index)
	if id.is_empty():
		return null
	var key := ArtAssets.perk_icon_key(id)
	if key == &"":
		return null
	return ArtAssets.texture(key)


# ─── Босс ───────────────────────────────────────────────────────────────────
## M6.1a: HP босса приходит float (дробный урон перков); полоса и дальше живёт в int —
## set_boss_hp() получает уже округлённое значение из health_changed.
func show_boss(boss_max: float, boss_hp: float) -> void:
	_boss_max_hp = maxf(boss_max, 1.0)
	boss_bar.visible = true
	set_boss_hp(int(round(boss_hp)))


func set_boss_hp(boss_hp: int) -> void:
	if boss_bar == null or not boss_bar.visible:
		return
	var ratio := clampf(float(boss_hp) / maxf(_boss_max_hp, 1.0), 0.0, 1.0)
	boss_fill.size = Vector2(BOSS_FILL_MAX_WIDTH * ratio, BOSS_FILL_HEIGHT)


func hide_boss() -> void:
	if boss_bar != null:
		boss_bar.visible = false
