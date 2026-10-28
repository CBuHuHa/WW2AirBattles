# mission_select.gd
# Purpose: Экран выбора миссии (M5.3b; GDD «First 30 seconds» п.2, «Оболочка» — «3 карточки
#          со звёздами, рекордом и замком», «Счёт, звёзды, снабжение»). Полноэкранный оверлей
#          поверх брифинга: заголовок «Кампания», строка снабжения и три карточки миссий
#          в порядке MissionData.MISSION_IDS (m1 → m2 → m3).
#          Карточка: название (MissionData.get_title), звёзды ★/☆ (SaveGame.get_stars),
#          лучший счёт (SaveGame.get_mission_best) и замок (SaveGame.is_mission_unlocked).
#          Закрытая карточка не запускает миссию: кнопка выбора disabled, а request_mission()
#          повторно проверяет открытие — двойной гейт (UI + логика).
#          Профиль читается ТОЛЬКО в refresh() при показе/обновлении, не в _process.
#          Ввод — как в briefing_overlay: root/Dim MOUSE_FILTER_IGNORE, интерактивные элементы
#          STOP; touch ловится через gui_input + pressed. Латч «одного нажатия» снимается
#          ОТПУСКАНИЕМ пальца (страховка — окно TAP_DEBOUNCE_MS): на Android отпускание не
#          приходит как mouse-release, и латч, снимаемый только в refresh()/show_overlay(),
#          запирал бы экран после первого же выбора.
# Dependencies: assets/ui_theme.tres (Noto Sans + TitleLabel/Bold), MissionData (id/title),
#               SaveGame (звёзды/рекорд/замок/снабжение), ArtStyle (палитра карточек).
# Author: UI/UX Agent

class_name MissionSelect
extends Control

## Игрок выбрал ОТКРЫТУЮ миссию. LevelController ставит её в брифинг (забег начнёт «В бой»).
signal mission_chosen(id: String)
## Игрок нажал «Назад» — вернуть брифинг текущей миссии.
signal closed

## Тач-минимум Android для второстепенных элементов — 64 px (кнопка выбора на карточке).
const CHOOSE_MIN_HEIGHT := 64.0
## Высота карточки: заголовок + звёзды + рекорд + замок + кнопка 64 px. Три карточки
## с шагом 12 укладываются в 628 px между заголовком и «Назад».
const CARD_MIN_HEIGHT := 196.0
const CARD_NAME_FONT_SIZE := 26
const CARD_TEXT_FONT_SIZE := 22
const CARD_STARS_FONT_SIZE := 26
const CHOOSE_FONT_SIZE := 26
## Отступ контента карточки от её рамки.
const CARD_CONTENT_MARGIN := 12.0
## Максимум звёзд на миссию (GDD: 3 звезды на миссию).
const MAX_STARS := 3

@onready var title_label: Label = $Title
@onready var supply_line: Label = $SupplyLine
@onready var cards_box: VBoxContainer = $Cards
@onready var back_button: Button = $BackButton

## id → {panel, name, stars, best, lock, button}: ссылки на узлы карточки для refresh().
var _cards: Dictionary = {}

## Окно дебаунса одного физического касания (мс). Android присылает только
## InputEventScreenTouch (emulate_mouse_from_touch в проекте выключен), поэтому отпускание
## не превращается в mouse-release; на десктопе emulate_touch_from_mouse, наоборот, даёт
## и touch-, и mouse-событие. Латч «одного нажатия» живёт ровно до отпускания (и не дольше
## TAP_DEBOUNCE_MS), поэтому экран не может «зависнуть» после выбора миссии.
const TAP_DEBOUNCE_MS := 250
## Время последнего touch-события (нажатие ИЛИ отпускание) — окно дебаунса mouse-пути.
var _last_touch_msec: int = -TAP_DEBOUNCE_MS
## Запрос уже сделан нажатием текущего касания; снимается отпусканием.
var _tap_claimed: bool = false
## Когда запрос был занят — страховка, если отпускание не дошло до узла.
var _tap_claimed_msec: int = -TAP_DEBOUNCE_MS


func _ready() -> void:
	# ALWAYS: экран открывается из BRIEFING, но не должен «зависнуть», если дерево на паузе.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	back_button.gui_input.connect(_on_back_button_gui_input)
	back_button.pressed.connect(_on_back_button_pressed)
	_build_cards()
	refresh()
	hide_overlay()


# ─── Жизненный цикл ─────────────────────────────────────────────────────────
func show_overlay() -> void:
	# Новый показ — чистое состояние ввода: даже если предыдущее касание «потерялось»
	# (палец ушёл за пределы кнопки), первый тап по экрану сработает.
	_release_tap()
	_last_touch_msec = -TAP_DEBOUNCE_MS
	refresh()
	visible = true


func hide_overlay() -> void:
	visible = false


## Перечитать профиль (звёзды/рекорды/замки/снабжение) и перерисовать карточки.
## Единственное место, где UI трогает SaveGame: _process профиль не читает.
func refresh() -> void:
	if not is_node_ready():
		return
	supply_line.text = "Снабжение: %d" % SaveGame.get_supply()
	for id: String in _cards.keys():
		var state := get_card_state(id)
		var card: Dictionary = _cards[id]
		(card["name"] as Label).text = String(state["title"])
		(card["stars"] as Label).text = format_stars(int(state["stars"]))
		(card["best"] as Label).text = "Рекорд: %d" % int(state["best"])
		var unlocked := bool(state["unlocked"])
		var lock: Label = card["lock"]
		# Строка требования остаётся в разметке всегда (пустая у открытой карточки):
		# так кнопка выбора стоит на одной высоте во всех трёх карточках.
		lock.text = String(state["lock_text"])
		var button: Button = card["button"]
		button.disabled = not unlocked
		button.text = "Выбрать"


# ─── Публичный API (LevelController + QA) ───────────────────────────────────
## Снимок состояния карточки. Читает профиль напрямую (SaveGame кэша не имеет), поэтому
## вызывать по событиям/при refresh(), а не каждый кадр.
##   {id, title, stars, best, unlocked, required, lock_text}
func get_card_state(id: String) -> Dictionary:
	var index := MissionData.MISSION_IDS.find(id)
	var required := 0
	if index >= 0 and index < SaveGame.UNLOCK_STARS.size():
		required = int(SaveGame.UNLOCK_STARS[index])
	var unlocked := SaveGame.is_mission_unlocked(id)
	var mission_title := MissionData.get_title(id)
	return {
		"id": id,
		"title": mission_title if not mission_title.is_empty() else id,
		"stars": SaveGame.get_stars(id),
		"best": SaveGame.get_mission_best(id),
		"unlocked": unlocked,
		"required": required,
		"lock_text": "" if unlocked else "Нужно %d %s" % [required, stars_word(required)],
	}


## Запрос на запуск миссии из карточки. Единственная точка эмита mission_chosen.
## Закрытая/неизвестная миссия — false без эмита (карточка не запускает забег).
func request_mission(id: String) -> bool:
	if id.is_empty() or not MissionData.MISSION_IDS.has(id):
		return false
	if not SaveGame.is_mission_unlocked(id):
		return false
	mission_chosen.emit(id)
	return true


## Сколько карточек реально видно (QA: все три при живых данных MissionData).
func get_visible_card_count() -> int:
	var count := 0
	for card: Dictionary in _cards.values():
		var panel := card.get("panel") as Control
		if panel != null and panel.visible:
			count += 1
	return count


## Текст звёзд карточки: «★★☆» (заполненные + пустые, всегда 3 символа).
static func format_stars(stars: int) -> String:
	var filled := clampi(stars, 0, MAX_STARS)
	return "★".repeat(filled) + "☆".repeat(MAX_STARS - filled)


## Правильная форма слова для «Нужно N …»: 1 звезда, 3 звезды, 5 звёзд.
static func stars_word(count: int) -> String:
	var last_two := count % 100
	var last := count % 10
	if last_two >= 11 and last_two <= 14:
		return "звёзд"
	if last == 1:
		return "звезда"
	if last >= 2 and last <= 4:
		return "звезды"
	return "звёзд"


# ─── Ввод ───────────────────────────────────────────────────────────────────
## Основной путь Android: touch приходит только как InputEventScreenTouch
## (emulate_mouse_from_touch выключен), поэтому кнопки слушаем через gui_input.
func _on_choose_button_gui_input(event: InputEvent, id: String, button: Button) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	if button != null:
		button.accept_event()  # тап по карточке не уходит в брифинг/мир
	_note_touch()
	if not touch.pressed:
		_release_tap()  # палец ушёл — латч снят, следующее касание снова сработает
		return
	_request_once(id)


## Запасной путь для мыши/эмуляции: Button.pressed (нажатие + отпускание).
func _on_choose_button_pressed(id: String) -> void:
	# Отпускание того же касания на десктопе приходит и как touch (наш обработчик), и как
	# Button.pressed: mouse-дубль гасим окном TAP_DEBOUNCE_MS после touch-события.
	if _is_touch_duplicate():
		return
	_request_once(id)


func _on_back_button_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	back_button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	_request_close()


## Запасной путь «Назад» для мыши/эмуляции.
func _on_back_button_pressed() -> void:
	if _is_touch_duplicate():
		return
	_request_close()


## Один запрос за касание: провал (закрытая миссия) не блокирует следующий тап —
## латч снимается отпусканием, а не успехом.
func _request_once(id: String) -> void:
	if not _claim_tap():
		return
	request_mission(id)


func _request_close() -> void:
	if not _claim_tap():
		return
	closed.emit()


## Отметка touch-события. И нажатие, И отпускание: mouse-дубль (Button.pressed) приходит
## сразу после отпускания и должен быть погашен окном TAP_DEBOUNCE_MS.
func _note_touch() -> void:
	_last_touch_msec = Time.get_ticks_msec()


## Отпускание пальца снимает латч: этим и лечится «замерший» экран — раньше латч снимался
## только в refresh()/show_overlay(), а на Android отпускание не приходило как mouse-release.
func _release_tap() -> void:
	_tap_claimed = false


## Занять право на ОДИН запрос за касание. false — второй путь ввода того же касания.
## Латч живёт до отпускания; TAP_DEBOUNCE_MS — страховка, если отпускание не дошло
## (палец ушёл за пределы кнопки, оверлей скрылся): теряется максимум одно касание, не ввод.
func _claim_tap() -> bool:
	var now := Time.get_ticks_msec()
	if _tap_claimed and now - _tap_claimed_msec < TAP_DEBOUNCE_MS:
		return false
	_tap_claimed = true
	_tap_claimed_msec = now
	return true


## QA/тесты: принимает ли экран следующее касание (false — латч ещё держится).
func is_tap_available() -> bool:
	return not _tap_claimed or Time.get_ticks_msec() - _tap_claimed_msec >= TAP_DEBOUNCE_MS


## Пришёл ли mouse-дубль того же физического касания (эмуляция мыши из тача).
func _is_touch_duplicate() -> bool:
	return Time.get_ticks_msec() - _last_touch_msec < TAP_DEBOUNCE_MS


# ─── Построение карточек ────────────────────────────────────────────────────
func _build_cards() -> void:
	_cards.clear()
	for child in cards_box.get_children():
		child.queue_free()
	for id: String in MissionData.MISSION_IDS:
		var card := _build_card(id)
		var panel: PanelContainer = card["panel"]
		cards_box.add_child(panel)
		_cards[id] = card


## Карточка = PanelContainer (стиль карточки) → VBox: [название + звёзды], рекорд,
## строка замка, кнопка выбора 64 px. Всё, кроме кнопки, прозрачно для тапов.
func _build_card(id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "Card_" + id
	panel.custom_minimum_size = Vector2(0.0, CARD_MIN_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _card_style())

	var inner := VBoxContainer.new()
	inner.name = "Inner"
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 6)
	panel.add_child(inner)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	inner.add_child(row)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = MissionData.get_title(id)
	name_label.theme_type_variation = &"TitleLabel"
	name_label.add_theme_font_size_override("font_size", CARD_NAME_FONT_SIZE)
	name_label.add_theme_color_override("font_color", ArtStyle.CREAM)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)

	var stars := Label.new()
	stars.name = "StarsLabel"
	stars.text = format_stars(0)
	stars.add_theme_font_size_override("font_size", CARD_STARS_FONT_SIZE)
	stars.add_theme_color_override("font_color", ArtStyle.BULLET_ENEMY)
	stars.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stars.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stars)

	var best := Label.new()
	best.name = "BestLabel"
	best.text = "Рекорд: 0"
	best.add_theme_font_size_override("font_size", CARD_TEXT_FONT_SIZE)
	best.add_theme_color_override("font_color", Color(ArtStyle.CREAM, 0.9))
	best.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(best)

	var lock := Label.new()
	lock.name = "LockLabel"
	lock.text = ""
	lock.custom_minimum_size = Vector2(0.0, CARD_TEXT_FONT_SIZE + 6.0)
	lock.add_theme_font_size_override("font_size", CARD_TEXT_FONT_SIZE)
	lock.add_theme_color_override("font_color", Color(ArtStyle.DANGER, 0.95))
	lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(lock)

	var button := Button.new()
	button.name = "ChooseButton"
	button.text = "Выбрать"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, CHOOSE_MIN_HEIGHT)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", CHOOSE_FONT_SIZE)
	button.add_theme_color_override("font_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_hover_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_pressed_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_disabled_color", Color(ArtStyle.CREAM, 0.45))
	button.add_theme_stylebox_override("normal", _button_style(ArtStyle.PLAYER, Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("hover", _button_style(
		Color(ArtStyle.PLAYER).lightened(0.12), Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("pressed", _button_style(
		Color(ArtStyle.PLAYER).darkened(0.2), Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("focus", _button_style(
		ArtStyle.PLAYER, Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("disabled", _button_style(
		Color(ArtStyle.ENEMY, 0.55), Color(ArtStyle.CREAM, 0.25)))
	button.gui_input.connect(_on_choose_button_gui_input.bind(id, button))
	button.pressed.connect(_on_choose_button_pressed.bind(id))
	inner.add_child(button)

	return {
		"panel": panel,
		"name": name_label,
		"stars": stars,
		"best": best,
		"lock": lock,
		"button": button,
	}


## Подложка карточки: тёмная плашка + кремовый контур (палитра ArtStyle, «HUD остаётся
## векторным» — карточки рисуются кодом, без SpriteCook).
func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.129412, 0.141176, 0.109804, 0.94)
	style.border_color = Color(ArtStyle.CREAM, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(CARD_CONTENT_MARGIN)
	return style


## Стиль кнопки карточки: как «В бой» в брифинге (оливковая плашка, кремовый контур 2 px).
func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	return style
