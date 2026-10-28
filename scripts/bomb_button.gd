# bomb_button.gd
# Purpose: Кнопка бомбы справа снизу. Зона тапа 96×96 (ТЗ M1), touch-only: обрабатывает
#          только InputEventScreenTouch и потребляет событие, чтобы палец на кнопке не вёл самолёт.
#          M7c: иконка из PNG `ui_bomb` (ArtAssets) 48×48 по центру круга; без файла — прежний
#          код-силуэт ArtStyle.draw_bomb_icon. Геометрия, touch-зона, mouse_filter и сигнал
#          от арта не зависят.
# Dependencies: ArtStyle (палитра, ключ ui_bomb, размеры), ArtAssets (кэш текстур), GameConfig.
# Author: Mechanics Developer Agent, Technical Artist Agent (M7c: иконка из PNG)

class_name BombButton
extends Control

signal bomb_pressed

## ТЗ M1: зона тапа ≥ 96×96 px.
const TOUCH_SIZE := Vector2(96.0, 96.0)
const BUTTON_RADIUS := 46.0
const ICON_KEY := ArtStyle.KEY_UI_BOMB
## M7c: прозрачность иконки без зарядов (у код-силуэта было alpha 0.35 у заливки).
const DISABLED_ALPHA := 0.35

## Счётчик зарядов: маленький бейдж в правом нижнем углу круга, шрифт глобальной темы.
## QA M3-B: OFFSET был (21,21) — внешний край бейджа (r=13) подходил к кольцу кнопки (r=46)
## на 3 px и «×1/×0» сливался с контуром. (18,18) даёт зазор ≈7.5 px при том же бейдже.
const COUNTER_FONT_SIZE := 16
const COUNTER_RADIUS := 13.0
const COUNTER_OFFSET := Vector2(18.0, 18.0)

var _charges: int = 0
## Текущая текстура иконки (null — рисуем код-силуэт ArtStyle).
var _texture: Texture2D = null
## Конечный ключ файла (для QA); &"" без текстуры.
var _texture_key: StringName = &""

## M7c: рисовать PNG, если файл есть (как ShipVisual.use_sprite_art). false — код-силуэт
## ArtStyle: фолбэк остаётся рабочим до конца арт-пасса и проверяется тестом.
@export var use_sprite_art: bool = true:
	set(value):
		use_sprite_art = value
		_refresh_texture()
		if is_inside_tree():
			queue_redraw()


func _ready() -> void:
	custom_minimum_size = TOUCH_SIZE
	# Фильтр узла НЕ трогаем: здесь же рисуется текст счётчика «×N», а nearest размыл бы
	# его глифы при 2× stretch на устройстве. Иконка 64→48 идёт с обычным фильтром.
	_refresh_texture()
	set_charges(_charges)
	queue_redraw()


## 0 — кнопка неактивна. Пополнений нет: 1 заряд на забег (GDD «Бомба»), второй заряд
## не появится ни от подбора, ни от врагов.
func set_charges(charges: int) -> void:
	_charges = maxi(charges, 0)
	# QA-правка M2: при 0 зарядов кнопка обязана пропускать тапы (IGNORE), иначе её мёртвая
	# зона в правом нижнем углу перекрывает драг самолёта.
	mouse_filter = Control.MOUSE_FILTER_STOP if _charges > 0 else Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func get_charges() -> int:
	return _charges


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	accept_event()  # кнопка забирает касание: перетаскивание самолёта с неё не начинается
	if touch.pressed and _charges > 0:
		bomb_pressed.emit()


func _draw() -> void:
	var center := size * 0.5
	var armed := _charges > 0
	var background := Color(ArtStyle.PLAYER, 1.0) if armed else Color(ArtStyle.ENEMY, 1.0)
	background.a = 0.88 if armed else 0.55
	var outline := Color(ArtStyle.CREAM, 0.9 if armed else 0.35)

	draw_circle(center, BUTTON_RADIUS, background)
	draw_arc(center, BUTTON_RADIUS, 0.0, TAU, 48, outline, 2.0, true)
	if _texture != null:
		# Иконка из PNG: 64×64 → 48×48 (прямоугольник GDD), приглушение — прозрачностью,
		# чтобы неактивная кнопка читалась так же, как прежний код-силуэт.
		var icon_box := ArtStyle.size_of(ICON_KEY)
		draw_texture_rect(_texture, Rect2(center - icon_box * 0.5, icon_box), false,
			Color(1.0, 1.0, 1.0, 1.0 if armed else DISABLED_ALPHA))
	else:
		ArtStyle.draw_bomb_icon(self, center, ArtStyle.size_of(ICON_KEY), armed)
	_draw_charge_counter(center, armed)


## QA/тесты: рисуется ли сейчас текстура (а не код-силуэт ArtStyle).
func is_using_texture() -> bool:
	return _texture != null


## QA/тесты: конечный ключ загруженного PNG (&"" — текстуры нет).
func get_texture_key() -> StringName:
	return _texture_key


## Пересобрать текстуру под текущий use_sprite_art (ArtAssets кэширует, повтор бесплатен).
func _refresh_texture() -> void:
	if not use_sprite_art:
		_texture = null
		_texture_key = &""
		return
	_texture = ArtAssets.texture(ICON_KEY)
	_texture_key = ArtAssets.render_key(ICON_KEY) if _texture != null else &""


## Счётчик зарядов «×N»: маленький бейдж внутри круга. При 0 зарядов — приглушённый,
## как и вся кнопка. Только визуал: touch-зона, mouse_filter и сигнал не меняются.
func _draw_charge_counter(center: Vector2, armed: bool) -> void:
	var badge_center := center + COUNTER_OFFSET
	var badge_fill := Color(ArtStyle.ENEMY, 0.92) if armed else Color(ArtStyle.ENEMY, 0.30)
	var badge_outline := Color(ArtStyle.CREAM, 0.9) if armed else Color(ArtStyle.CREAM, 0.30)
	var text_color := Color(ArtStyle.CREAM, 1.0) if armed else Color(ArtStyle.CREAM, 0.35)
	draw_circle(badge_center, COUNTER_RADIUS, badge_fill)
	draw_arc(badge_center, COUNTER_RADIUS, 0.0, TAU, 24, badge_outline, 1.5, true)

	var font := get_theme_font(&"font")
	if font == null:
		return
	var text := "×%d" % _charges
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, COUNTER_FONT_SIZE)
	# draw_string ставит точку на базовую линию: центрируем по (ascent − descent)/2.
	var baseline := badge_center + Vector2(
		-text_size.x * 0.5,
		(font.get_ascent(COUNTER_FONT_SIZE) - font.get_descent(COUNTER_FONT_SIZE)) * 0.5
	)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, COUNTER_FONT_SIZE, text_color)

