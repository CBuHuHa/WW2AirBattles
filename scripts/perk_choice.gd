# perk_choice.gd
# Purpose: Оверлей выбора временного перка (M6.1b; GDD «Временные перки»: «Выбор 1 из 2 карт
#          после волн 2, 3 и 4; игра на паузе, карта применяется сразу»).
#          Полноэкранный оверлей: затемнение, заголовок «Выбери перк», две карточки в ряд —
#          название, категория («Оружие»/«Утилита») и описание из PerkData.
#          Кнопки «назад» нет: выбор обязателен. Тап мимо карточки ничего не делает —
#          LevelController._unhandled_input удалён (M11/T2), ввод есть только у карточек.
#          Ввод — как в mission_select/briefing_overlay: корень и Dim MOUSE_FILTER_IGNORE,
#          интерактив (карточка и кнопка «Взять») STOP, InputEventScreenTouch через gui_input
#          + Button.pressed, латч от двойного срабатывания (touch + mouse-эмуляция).
#          process_mode = ALWAYS: оверлей живёт при get_tree().paused = true (его ставит
#          LevelController на время выбора).
#          M7b: в карточке — иконка перка 48×48 (nearest) из `ui_perk_<id>.png` (ArtAssets).
#          Файла нет → узел скрыт, карточка строится как раньше (название/описание/кнопка).
# Dependencies: PerkData (name/category/description карт), ArtStyle (палитра),
#               ArtAssets (иконки перков M7b), assets/ui_theme.tres (Noto Sans + TitleLabel).
#               Обратных зависимостей нет: выбор сообщает о решении сигналом perk_chosen,
#               применяет его LevelController.
# Author: Mechanics Developer Agent (M6.1b), Technical Artist Agent (M7b)

class_name PerkChoice
extends Control

## Игрок выбрал карту. Эмитится ТОЛЬКО для предложенной карты (см. request_perk).
signal perk_chosen(id: String)

## Тач-минимум Android для основной кнопки карточки — 64 px.
const TAKE_MIN_HEIGHT := 64.0
## Карточка = название + категория + описание + кнопка 64 px; две карточки в ряд
## (≈238 px ширины) укладываются в поле 540 при base-шрифтах 26/20/20.
const CARD_MIN_HEIGHT := 420.0
const CARD_NAME_FONT_SIZE := 26
const CARD_CATEGORY_FONT_SIZE := 20
const CARD_DESCRIPTION_FONT_SIZE := 20
const TAKE_FONT_SIZE := 26
const CARD_CONTENT_MARGIN := 12.0
## M7b: иконка перка в карточке — 48×48 (пиксель-арт 24×24 показан 2× целым множителем,
## поэтому не мылится при nearest; влезает в карточку ≥200 px без сдвига кнопки).
const CARD_ICON_SIZE := 48.0

@onready var title_label: Label = $Title
@onready var hint_label: Label = $Hint
@onready var cards_box: HBoxContainer = $Cards

## Предложенные карты (порядок — как пришёл от PerkSystem.roll_offers).
var _offered: Array[String] = []
## id → {panel, name, category, description, button}: ссылки на узлы для тестов/QA.
var _cards: Dictionary = {}
## Латч одного нажатия: на десктопе emulate_touch_from_mouse даёт и touch-, и mouse-событие.
var _latched: bool = false


func _ready() -> void:
	# ALWAYS: оверлей показывается при get_tree().paused = true и обязан ловить тап.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Корень прозрачен для тапов: мимо карточек ввод уходит в LevelController (и там глохнет).
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide_choice()


# ─── Жизненный цикл ─────────────────────────────────────────────────────────
## Показать предложение «1 из 2». Пустой список — оверлей не открывается (LevelController
## и сам не зовёт show_offers без карт, но контракт должен быть безопасным).
func show_offers(offers: Array[String]) -> void:
	_offered = offers.duplicate()
	_latched = false
	_build_cards()
	visible = not _offered.is_empty()


func hide_choice() -> void:
	visible = false
	_latched = true
	_clear_cards()


# ─── Публичный API (LevelController + QA) ───────────────────────────────────
## Сколько карточек построено (0 — оверлей закрыт; 1 — доступна одна карта).
func get_card_count() -> int:
	return _cards.size()


## Снимок предложения (QA/тесты и LevelController).
func get_offered_ids() -> Array[String]:
	return _offered.duplicate()


## Выбор карты. Единственная точка эмита perk_chosen: id вне предложения возвращает false
## без эмита (отап по чужой/устаревшей карточке не применяет перк).
func request_perk(id: String) -> bool:
	if id.is_empty() or not _offered.has(id):
		return false
	perk_chosen.emit(id)
	return true


## Подпись категории для игрока (RU). Неизвестная категория — пустая строка.
static func category_label(category: String) -> String:
	match category:
		PerkData.CATEGORY_WEAPON:
			return "Оружие"
		PerkData.CATEGORY_UTILITY:
			return "Утилита"
		_:
			return ""


## QA: ключ иконки карточки `ui_perk_<id>` ("" — индекс вне предложения или id без иконки).
func get_card_icon_key(index: int) -> StringName:
	if index < 0 or index >= _offered.size():
		return &""
	return ArtAssets.perk_icon_key(_offered[index])


## QA: нарисована ли иконка в карточке (PNG найден и узел Icon виден).
func has_card_icon(index: int) -> bool:
	if index < 0 or index >= _offered.size():
		return false
	var card: Dictionary = _cards.get(_offered[index], {})
	var icon := card.get("icon") as TextureRect
	return icon != null and icon.visible and icon.texture != null


## QA: узел карточки по индексу предложения (null — карточки нет). Для проверок геометрии/текстов.
func get_card_control(index: int) -> Control:
	if index < 0 or index >= _offered.size():
		return null
	var card: Dictionary = _cards.get(_offered[index], {})
	return card.get("panel") as Control


# ─── Ввод ───────────────────────────────────────────────────────────────────
## Основной путь Android: touch приходит только как InputEventScreenTouch
## (emulate_mouse_from_touch выключен), поэтому карточку и кнопку слушаем через gui_input.
func _on_card_gui_input(event: InputEvent, id: String, panel: Control) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	if panel != null:
		panel.accept_event()  # тап по карточке не уходит в мир/брифинг
	if touch.pressed:
		_request_once(id)


## Запасной путь для мыши/эмуляции: Button.pressed (нажатие + отпускание).
func _on_take_pressed(id: String) -> void:
	_request_once(id)


## Латч ставится только после успешного эмита: тап по «чужой» карте не блокирует выбор.
func _request_once(id: String) -> void:
	if _latched:
		return
	if request_perk(id):
		_latched = true


# ─── Построение карточек ────────────────────────────────────────────────────
func _build_cards() -> void:
	_clear_cards()
	for id: String in _offered:
		var card := _build_card(id)
		cards_box.add_child(card["panel"] as Control)
		_cards[id] = card


## Снять карточки немедленно (remove_child): queue_free оставлял бы старые карточки
## видимыми ещё один кадр — на следующем предложении это выглядело бы как 4 карты.
func _clear_cards() -> void:
	for child in cards_box.get_children():
		cards_box.remove_child(child)
		child.queue_free()
	_cards.clear()


## Карточка = PanelContainer (стиль карточки) → VBox: название, категория, описание
## (растягивается) и кнопка «Взять» 64 px. Тап ловит и сама карточка, и кнопка.
func _build_card(id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "Card_" + id
	panel.custom_minimum_size = Vector2(0.0, CARD_MIN_HEIGHT)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _card_style())
	panel.gui_input.connect(_on_card_gui_input.bind(id, panel))

	var inner := VBoxContainer.new()
	inner.name = "Inner"
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 8)
	panel.add_child(inner)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = PerkData.get_card_name(id)
	name_label.theme_type_variation = &"TitleLabel"
	name_label.add_theme_font_size_override("font_size", CARD_NAME_FONT_SIZE)
	name_label.add_theme_color_override("font_color", ArtStyle.CREAM)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_label)

	var category_label := Label.new()
	category_label.name = "CategoryLabel"
	category_label.text = category_label_for(id)
	category_label.add_theme_font_size_override("font_size", CARD_CATEGORY_FONT_SIZE)
	category_label.add_theme_color_override(
		"font_color", Color(ArtStyle.BULLET_ENEMY, 0.95))
	category_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(category_label)

	var icon_key := ArtAssets.perk_icon_key(id)
	var icon_texture: Texture2D = null
	if icon_key != &"":
		icon_texture = ArtAssets.texture(icon_key)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = icon_texture
	# Без PNG узел скрыт: VBox не резервирует 48 px, карточка остаётся прежней геометрии.
	icon.visible = icon_texture != null
	icon.custom_minimum_size = Vector2(CARD_ICON_SIZE, CARD_ICON_SIZE)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Nearest только на этом узле: 24×24 → 48×48 целым множителем остаётся пиксельно чётким.
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(icon)

	var description_label := Label.new()
	description_label.name = "DescriptionLabel"
	description_label.text = PerkData.get_card_description(id)
	description_label.add_theme_font_size_override("font_size", CARD_DESCRIPTION_FONT_SIZE)
	description_label.add_theme_color_override("font_color", Color(ArtStyle.CREAM, 0.9))
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	description_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	description_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(description_label)

	var button := Button.new()
	button.name = "TakeButton"
	button.text = "Взять"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, TAKE_MIN_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", TAKE_FONT_SIZE)
	button.add_theme_color_override("font_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_hover_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_pressed_color", ArtStyle.CREAM)
	button.add_theme_stylebox_override(
		"normal", _button_style(ArtStyle.PLAYER, Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("hover", _button_style(
		Color(ArtStyle.PLAYER).lightened(0.12), Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("pressed", _button_style(
		Color(ArtStyle.PLAYER).darkened(0.2), Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override(
		"focus", _button_style(ArtStyle.PLAYER, Color(ArtStyle.CREAM, 1.0)))
	button.gui_input.connect(_on_card_gui_input.bind(id, button))
	button.pressed.connect(_on_take_pressed.bind(id))
	inner.add_child(button)

	return {
		"panel": panel,
		"name": name_label,
		"category": category_label,
		"icon": icon,
		"description": description_label,
		"button": button,
	}


## Категория карты для игрока; битые данные не оставляют пустую строку в UI.
func category_label_for(id: String) -> String:
	var label := category_label(PerkData.get_category(id))
	return label if not label.is_empty() else PerkData.get_category(id)


## Подложка карточки: тёмная плашка + кремовый контур (палитра ArtStyle, HUD/оверлеи
## остаются векторными — карточки рисуются кодом, без SpriteCook).
func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.129412, 0.141176, 0.109804, 0.94)
	style.border_color = Color(ArtStyle.CREAM, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(CARD_CONTENT_MARGIN)
	return style


## Стиль кнопки карточки: как «В бой»/«Выбрать» (оливковая плашка, кремовый контур 2 px).
func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	return style
