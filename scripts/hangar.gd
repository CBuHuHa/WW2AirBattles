# hangar.gd
# Purpose: Экран ангара (M6.2b; GDD «Оболочка»: «Ангар — текущий самолёт, снабжение, звёзды»,
#          «Самолёты (ангар)»: три самолёта, открытие по кампании/9 звёздам, ливреи 300/600/900).
#          Полноэкранный оверлей поверх брифинга: затемнение, заголовок «Ангар», строки
#          «Снабжение: N» и «Звёзды: X/9», панель превью (ShipVisual 2× с ливреей-тинтом),
#          три карточки самолётов (имя, строка статов, состояние + кнопка) и ряд свотчей ливрей
#          (0 — «Без ливреи» + три платные).
#          Экран НИЧЕГО не применяет к забегу: выбор пишется только в сейв (SaveGame), а
#          LevelController.start_level() сам зовёт player.apply_plane()/apply_livery().
#          Профиль читается ТОЛЬКО в refresh() при показе и после действия, не в _process
#          (SaveGame каждый раз читает файл — в кадровом цикле это недопустимо).
#          Ввод — как в mission_select/briefing_overlay: root/Dim MOUSE_FILTER_IGNORE,
#          интерактив STOP; touch ловится через gui_input + Button.pressed. Латч «одного
#          нажатия» снимается ОТПУСКАНИЕМ пальца (страховка — окно TAP_DEBOUNCE_MS).
#          Раньше он снимался только в refresh()/show_overlay(): на Android отпускание не
#          приходит как mouse-release, request_plane()/request_livery() звали refresh()
#          ДО установки латча, и после первого же действия экран замирал навсегда.
#          process_mode = ALWAYS: экран открывается из BRIEFING и не должен «зависнуть»,
#          если дерево окажется на паузе.
# Dependencies: SaveGame (самолёт/ливрея/снабжение/звёзды), PlaneData (имя/статы/ключ арта),
#               ArtStyle (палитра + LIVERY_TINTS), ShipVisual (превью), Player (статы HP),
#               assets/ui_theme.tres (Noto Sans + TitleLabel). Обратных зависимостей нет.
# Author: UI/UX Agent (M6.2b)
#
# QA/тесты (публичный API):
#   refresh()                       перечитать профиль и перерисовать строки/карточки/свотчи
#   get_plane_card_state(id)        {id, name, stats, unlocked, selected, unlock, lock_text}
#   request_plane(id) -> bool       выбрать открытый самолёт (закрытый/неизвестный → false)
#   request_livery(index) -> bool   0 — снять ливрею; 1…3 — купить (если нужно) и выбрать
#   get_livery_state(index)         {index, name, cost, owned, selected, text, disabled}
#   get_visible_plane_count()       сколько карточек реально видно (3 при живых данных)
#   get_supply_text()/get_stars_text()   текст строк снабжения и звёзд
#   get_selected_livery()           индекс выбранной ливреи (0…3)
#   is_tap_available()              жив ли ввод: false — латч касания ещё держится (QA)

class_name Hangar
extends Control

## Игрок нажал «Назад» — LevelController возвращает брифинг текущей миссии.
signal closed

## Сколько суммарных звёзд кампании показываем в строке «Звёзды: X/9»
## (3 миссии × 3 звезды, GDD «Счёт, звёзды, снабжение»).
const MAX_CAMPAIGN_STARS := 9

## Тач-минимум Android для интерактивных элементов — 64 px (кнопка карточки).
const CARD_BUTTON_MIN_SIZE := Vector2(132.0, 64.0)
## Карточка: три текстовые строки (имя/статы/состояние) + кнопка 64 px справа.
## Три карточки по 104 px с шагом 10 укладываются в 288…620 поля 540×960.
const CARD_MIN_HEIGHT := 104.0
const CARD_CONTENT_MARGIN := 8.0
const CARD_CONTENT_SEPARATION := 10.0
const CARD_NAME_FONT_SIZE := 24
const CARD_STATS_FONT_SIZE := 18
const CARD_STATE_FONT_SIZE := 16
const CARD_BUTTON_FONT_SIZE := 18
## Фиксированные высоты строк текстовой колонки: у выбранной карточки нет «лишних» пикселей
## от строки замка, поэтому все три карточки ровно одной высоты (проверено скриншотом).
const CARD_NAME_MIN_HEIGHT := 32.0
const CARD_STATS_MIN_HEIGHT := 24.0
const CARD_STATE_MIN_HEIGHT := 24.0

## Свотч ливреи: цветная полоса + название + состояние; вся плашка — тач-таргет (STOP).
const SWATCH_MIN_HEIGHT := 96.0
const SWATCH_COLOR_HEIGHT := 34.0
const SWATCH_CONTENT_MARGIN := 6.0
const SWATCH_NAME_FONT_SIZE := 15
const SWATCH_STATE_FONT_SIZE := 15

## Превью самолёта: код-силуэт ArtStyle, увеличенный ЦЕЛОчисленно (пиксель-арт не масштабируем
## дробно — AGENTS «Art pipeline»). 48×48 → 96×96 внутри панели 492×128.
const PREVIEW_SCALE := 2.0

## Тексты состояний (RU, player-facing).
const TEXT_SELECTED := "Выбрано"
const TEXT_SELECT := "Выбрать"
const TEXT_LOCKED := "Закрыто"

@onready var title_label: Label = $Title
@onready var supply_line: Label = $SupplyLine
@onready var stars_line: Label = $StarsLine
@onready var preview_panel: PanelContainer = $PreviewPanel
@onready var preview: ShipVisual = $PreviewPanel/Preview
@onready var cards_box: VBoxContainer = $Cards
@onready var livery_title: Label = $LiveryTitle
@onready var livery_row: HBoxContainer = $LiveryRow
@onready var back_button: Button = $BackButton

## id → {panel, name, stats, state, button}: ссылки на узлы карточки для refresh().
var _cards: Dictionary = {}
## индекс ливреи (0…3) → {panel, bar, name, state}: ссылки на узлы свотча.
var _swatches: Dictionary = {}

## Окно дебаунса одного физического касания (мс). Android присылает только
## InputEventScreenTouch (emulate_mouse_from_touch в проекте выключен), поэтому отпускание
## не превращается в mouse-release; на десктопе emulate_touch_from_mouse, наоборот, даёт
## и touch-, и mouse-событие. Латч «одного нажатия» живёт ровно до отпускания (и не дольше
## TAP_DEBOUNCE_MS), поэтому экран не может «зависнуть» после действия.
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
	preview_panel.resized.connect(_center_preview)
	_build_cards()
	_build_swatches()
	_center_preview()
	refresh()
	hide_overlay()


# ─── Жизненный цикл ─────────────────────────────────────────────────────────
func show_overlay() -> void:
	# Новый показ — чистое состояние ввода: даже если предыдущее касание «потерялось»
	# (палец ушёл за пределы узла), первый тап по экрану сработает.
	_release_tap()
	_last_touch_msec = -TAP_DEBOUNCE_MS
	refresh()
	visible = true


func hide_overlay() -> void:
	visible = false


## Перечитать профиль (снабжение, звёзды, самолёт, ливрея) и перерисовать экран.
## Единственное место, где UI трогает SaveGame: _process профиль не читает.
func refresh() -> void:
	if not is_node_ready():
		return
	var supply := SaveGame.get_supply()
	var total_stars := SaveGame.total_stars()
	var selected_plane := SaveGame.get_selected_plane()
	var selected_livery := SaveGame.get_selected_livery()

	supply_line.text = format_supply(supply)
	stars_line.text = format_stars(total_stars)
	_refresh_preview(selected_plane, selected_livery)
	for id: String in _cards.keys():
		_refresh_card(id, _plane_state(id, selected_plane))
	for index: int in _swatches.keys():
		_refresh_swatch(index, _livery_state(index, supply, selected_livery))


# ─── Публичный API (LevelController + QA) ───────────────────────────────────
## Снимок состояния карточки самолёта. Читает профиль напрямую (SaveGame кэша не имеет),
## поэтому вызывать по событиям/при refresh(), а не каждый кадр.
##   {id, name, stats, unlocked, selected, unlock, lock_text}
func get_plane_card_state(id: String) -> Dictionary:
	return _plane_state(id, SaveGame.get_selected_plane())


## Выбор самолёта. Закрытый/неизвестный id — false без записи (карточка не меняет забег).
## Успешный выбор сразу перерисовывает экран: карточка становится «Выбрано».
func request_plane(id: String) -> bool:
	if id.is_empty() or not PlaneData.has_plane(id):
		return false
	if not SaveGame.is_plane_unlocked(id):
		return false
	if not SaveGame.select_plane(id):
		return false
	refresh()
	return true


## Ливрея: 0 — «без ливреи» (всегда), 1…3 — сначала покупка за снабжение (если ещё не куплена),
## затем выбор. Не хватает снабжения / индекс вне 0…3 → false, профиль не меняется.
func request_livery(index: int) -> bool:
	if index < 0 or index >= SaveGame.LIVERY_SLOTS:
		return false
	if not SaveGame.is_livery_owned(index):
		# buy_livery() сам проверяет баланс: false = снабжения не хватает (списания нет).
		if not SaveGame.buy_livery(index):
			return false
	if not SaveGame.select_livery(index):
		return false
	refresh()
	return true


## Снимок свотча ливреи (QA/тесты и refresh()).
##   {index, name, cost, owned, selected, text, disabled}
func get_livery_state(index: int) -> Dictionary:
	return _livery_state(index, SaveGame.get_supply(), SaveGame.get_selected_livery())


## Сколько карточек самолётов реально видно (QA: 3 при живых данных PlaneData).
func get_visible_plane_count() -> int:
	var count := 0
	for card: Dictionary in _cards.values():
		var panel := card.get("panel") as Control
		if panel != null and panel.visible:
			count += 1
	return count


func get_supply_text() -> String:
	return String(supply_line.text)


func get_stars_text() -> String:
	return String(stars_line.text)


func get_selected_livery() -> int:
	return SaveGame.get_selected_livery()


# ─── Форматирование (RU) ────────────────────────────────────────────────────
## «Снабжение: N» — та же строка, что на экране выбора миссии.
static func format_supply(supply: int) -> String:
	return "Снабжение: %d" % maxi(0, supply)


## «Звёзды: X/9» — суммарные звёзды кампании.
static func format_stars(total: int) -> String:
	return "Звёзды: %d/%d" % [clampi(total, 0, MAX_CAMPAIGN_STARS), MAX_CAMPAIGN_STARS]


## Одна строка статов карточки: «8 выстр./с · урон 1.0 · HP 3» (GDD «Самолёты (ангар)»).
## Числа берутся из data/planes.json через PlaneData, HP — общий для всех 3 (Player.MAX_HP).
static func format_stats(id: String) -> String:
	var interval := PlaneData.get_number(id, "fire_interval", Player.FIRE_INTERVAL)
	var damage := PlaneData.get_number(id, "damage", float(Player.BULLET_DAMAGE))
	var rate := 1.0 / maxf(interval, 0.001)
	return "%s выстр./с · урон %s · HP %d" % [
		format_rate(rate), format_damage(damage), Player.MAX_HP]


## «8» / «10» / «6.5» — темп стрельбы без хвостовых нулей у целых значений.
static func format_rate(rate: float) -> String:
	if is_equal_approx(rate, roundf(rate)):
		return "%d" % int(roundf(rate))
	return "%.1f" % rate


## «1.0» / «0.85» / «1.5» — минимум один знак после точки (0.85 не округляется до 0.9).
static func format_damage(damage: float) -> String:
	var text := "%.2f" % damage
	while text.ends_with("0") and not text.ends_with(".0"):
		text = text.substr(0, text.length() - 1)
	return text


## Название ливреи для свотча: 0 — «Без ливреи», 1…3 — «Ливрея N».
static func livery_label(index: int) -> String:
	return "Без ливреи" if index <= 0 else "Ливрея %d" % index


## Текст замка карточки по правилу открытия (PlaneData.unlock): GDD — Як-3 после полного
## прохождения кампании, Аэрокобра после 9/9 звёзд. Точный текст с числами не выдумываем:
## «9/9 звёзд» — прямо из GDD, «пройди кампанию» — из правила campaign.
static func lock_text_for(id: String) -> String:
	var unlock := PlaneData.get_unlock(id)
	if unlock == PlaneData.UNLOCK_CAMPAIGN:
		return "Закрыто: пройди кампанию"
	if unlock == PlaneData.UNLOCK_STARS_9:
		return "Закрыто: 9/9 звёзд"
	return TEXT_LOCKED


# ─── Ввод ───────────────────────────────────────────────────────────────────
## Основной путь Android: touch приходит только как InputEventScreenTouch
## (emulate_mouse_from_touch выключен), поэтому кнопки слушаем через gui_input.
func _on_plane_button_gui_input(event: InputEvent, id: String, button: Button) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	if button != null:
		button.accept_event()  # тап по карточке не уходит в брифинг/мир
	_note_touch()
	if not touch.pressed:
		_release_tap()  # палец ушёл — латч снят, следующее касание снова сработает
		return
	_request_plane_once(id)


## Запасной путь для мыши/эмуляции: Button.pressed (нажатие + отпускание).
func _on_plane_button_pressed(id: String) -> void:
	# Отпускание того же касания на десктопе приходит и как touch (наш обработчик), и как
	# Button.pressed: mouse-дубль гасим окном TAP_DEBOUNCE_MS после touch-события.
	# Второй pressed без touch (чистая мышь) тоже гасится этим окном — оно же и отпускает латч.
	if _is_touch_duplicate():
		return
	_request_plane_once(id)


func _on_swatch_gui_input(event: InputEvent, index: int, panel: Control) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	if panel != null:
		panel.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	_request_livery_once(index)


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
## (палец ушёл за пределы узла, оверлей скрылся): теряется максимум одно касание, не ввод.
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


## Просьба о выборе самолёта из карточки (и путь QA). Провал (закрытая карточка) не
## оставляет латча: касание отпускается и следующий тап проходит.
func _request_plane_once(id: String) -> void:
	if not _claim_tap():
		return
	request_plane(id)


func _request_livery_once(index: int) -> void:
	if not _claim_tap():
		return
	request_livery(index)


func _request_close() -> void:
	if not _claim_tap():
		return
	closed.emit()


# ─── Превью ─────────────────────────────────────────────────────────────────
## Превью выбранного самолёта: ключ арта из PlaneData + тинт ливреи. ShipVisual живёт
## в панели Node2D-ом (контейнеры не раскладывают Node2D), поэтому центр считаем сами.
func _refresh_preview(selected_plane: String, selected_livery: int) -> void:
	if preview == null:
		return
	preview.asset_key = PlaneData.get_asset_key(selected_plane)
	preview.modulate = ArtStyle.livery_tint(selected_livery)
	preview.queue_redraw()


func _center_preview() -> void:
	if preview == null or preview_panel == null:
		return
	preview.position = preview_panel.size * 0.5


# ─── Внутреннее: снимки состояний без повторного чтения профиля ─────────────
func _plane_state(id: String, selected_plane: String) -> Dictionary:
	var plane := PlaneData.get_plane(id)
	if plane.is_empty():
		return {
			"id": id, "name": id, "stats": "", "unlocked": false, "selected": false,
			"unlock": "", "lock_text": TEXT_LOCKED,
		}
	var unlocked := SaveGame.is_plane_unlocked(id)
	var plane_name := PlaneData.get_plane_name(id)
	return {
		"id": id,
		"name": plane_name if not plane_name.is_empty() else id,
		"stats": format_stats(id),
		"unlocked": unlocked,
		"selected": unlocked and selected_plane == id,
		"unlock": PlaneData.get_unlock(id),
		"lock_text": "" if unlocked else lock_text_for(id),
	}


func _livery_state(index: int, supply: int, selected_livery: int) -> Dictionary:
	var valid := index >= 0 and index < SaveGame.LIVERY_SLOTS
	var cost := SaveGame.get_livery_cost(index) if valid else 0
	var owned := valid and SaveGame.is_livery_owned(index)
	var selected := valid and selected_livery == index
	var text := TEXT_SELECT
	var disabled := not valid
	if selected:
		text = TEXT_SELECTED
	elif not owned:
		text = "Купить %d" % cost
		disabled = supply < cost
	return {
		"index": index,
		"name": livery_label(index),
		"cost": cost,
		"owned": owned,
		"selected": selected,
		"text": text,
		"disabled": disabled,
	}


# ─── Карточки самолётов ─────────────────────────────────────────────────────
func _build_cards() -> void:
	_cards.clear()
	for child in cards_box.get_children():
		cards_box.remove_child(child)
		child.queue_free()
	for id: String in PlaneData.PLANE_IDS:
		var card := _build_card(id)
		cards_box.add_child(card["panel"] as Control)
		_cards[id] = card


## Карточка = PanelContainer → HBox: слева три строки (имя, статы, состояние),
## справа кнопка «Выбрать»/«Выбрано»/«Закрыто» 132×64. Строка состояния есть всегда
## (пустая у открытой карточки) — кнопки во всех карточках стоят на одной высоте.
func _build_card(id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "Card_" + id
	panel.custom_minimum_size = Vector2(0.0, CARD_MIN_HEIGHT)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _card_style(false))

	var row := HBoxContainer.new()
	row.name = "Inner"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", CARD_CONTENT_SEPARATION)
	panel.add_child(row)

	var lines := VBoxContainer.new()
	lines.name = "Lines"
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lines.add_theme_constant_override("separation", 2)
	row.add_child(lines)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = PlaneData.get_plane_name(id)
	name_label.theme_type_variation = &"TitleLabel"
	name_label.custom_minimum_size = Vector2(0.0, CARD_NAME_MIN_HEIGHT)
	name_label.add_theme_font_size_override("font_size", CARD_NAME_FONT_SIZE)
	name_label.add_theme_color_override("font_color", ArtStyle.CREAM)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(name_label)

	var stats_label := Label.new()
	stats_label.name = "StatsLabel"
	stats_label.text = format_stats(id)
	stats_label.custom_minimum_size = Vector2(0.0, CARD_STATS_MIN_HEIGHT)
	stats_label.add_theme_font_size_override("font_size", CARD_STATS_FONT_SIZE)
	stats_label.add_theme_color_override("font_color", Color(ArtStyle.CREAM, 0.9))
	stats_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(stats_label)

	var state_label := Label.new()
	state_label.name = "StateLabel"
	state_label.text = ""
	state_label.custom_minimum_size = Vector2(0.0, CARD_STATE_MIN_HEIGHT)
	state_label.add_theme_font_size_override("font_size", CARD_STATE_FONT_SIZE)
	state_label.add_theme_color_override("font_color", Color(ArtStyle.DANGER, 0.95))
	state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lines.add_child(state_label)

	var button := Button.new()
	button.name = "ChooseButton"
	button.text = TEXT_SELECT
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = CARD_BUTTON_MIN_SIZE
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", CARD_BUTTON_FONT_SIZE)
	button.add_theme_color_override("font_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_hover_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_pressed_color", ArtStyle.CREAM)
	button.add_theme_color_override("font_disabled_color", Color(ArtStyle.CREAM, 0.45))
	button.add_theme_stylebox_override("normal", _button_style(
		ArtStyle.PLAYER, Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("hover", _button_style(
		Color(ArtStyle.PLAYER).lightened(0.12), Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("pressed", _button_style(
		Color(ArtStyle.PLAYER).darkened(0.2), Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("focus", _button_style(
		ArtStyle.PLAYER, Color(ArtStyle.CREAM, 1.0)))
	button.add_theme_stylebox_override("disabled", _button_style(
		Color(ArtStyle.ENEMY, 0.55), Color(ArtStyle.CREAM, 0.25)))
	button.gui_input.connect(_on_plane_button_gui_input.bind(id, button))
	button.pressed.connect(_on_plane_button_pressed.bind(id))
	row.add_child(button)

	return {
		"panel": panel,
		"name": name_label,
		"stats": stats_label,
		"state": state_label,
		"button": button,
	}


func _refresh_card(id: String, state: Dictionary) -> void:
	var card: Dictionary = _cards.get(id, {})
	if card.is_empty():
		return
	(card["name"] as Label).text = String(state["name"])
	(card["stats"] as Label).text = String(state["stats"])
	(card["state"] as Label).text = String(state["lock_text"])
	var selected := bool(state["selected"])
	var unlocked := bool(state["unlocked"])
	var button: Button = card["button"]
	button.disabled = selected or not unlocked
	button.text = TEXT_SELECTED if selected else (TEXT_SELECT if unlocked else TEXT_LOCKED)
	# Акцент выбранного — жёлтый контур (ArtStyle.BULLET_ENEMY) и толще: видно на бегу.
	var panel: PanelContainer = card["panel"]
	panel.add_theme_stylebox_override("panel", _card_style(selected))


# ─── Свотчи ливрей ──────────────────────────────────────────────────────────
func _build_swatches() -> void:
	_swatches.clear()
	for child in livery_row.get_children():
		livery_row.remove_child(child)
		child.queue_free()
	for index in SaveGame.LIVERY_SLOTS:
		var swatch := _build_swatch(index)
		livery_row.add_child(swatch["panel"] as Control)
		_swatches[index] = swatch


## Свотч = PanelContainer (тач-таргет STOP) → VBox: цветная полоса, название, состояние.
## Плашка, а не Button: состояние («Купить 300»/«Выбрать»/«Выбрано») и цвет — одна картинка,
## а блочная кнопка на 117 px ширины не вмещает текст без переноса.
func _build_swatch(index: int) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "Swatch_%d" % index
	panel.custom_minimum_size = Vector2(0.0, SWATCH_MIN_HEIGHT)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _swatch_style(false, false))
	panel.gui_input.connect(_on_swatch_gui_input.bind(index, panel))

	var inner := VBoxContainer.new()
	inner.name = "Inner"
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_theme_constant_override("separation", 4)
	panel.add_child(inner)

	var bar := ColorRect.new()
	bar.name = "ColorBar"
	bar.custom_minimum_size = Vector2(0.0, SWATCH_COLOR_HEIGHT)
	bar.color = _swatch_color(index)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(bar)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = livery_label(index)
	name_label.add_theme_font_size_override("font_size", SWATCH_NAME_FONT_SIZE)
	name_label.add_theme_color_override("font_color", Color(ArtStyle.CREAM, 0.92))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(name_label)

	var state_label := Label.new()
	state_label.name = "StateLabel"
	state_label.text = TEXT_SELECT
	state_label.add_theme_font_size_override("font_size", SWATCH_STATE_FONT_SIZE)
	state_label.add_theme_color_override("font_color", ArtStyle.CREAM)
	state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(state_label)

	return {"panel": panel, "bar": bar, "name": name_label, "state": state_label}


func _refresh_swatch(index: int, state: Dictionary) -> void:
	var swatch: Dictionary = _swatches.get(index, {})
	if swatch.is_empty():
		return
	(swatch["bar"] as ColorRect).color = _swatch_color(index)
	(swatch["name"] as Label).text = String(state["name"])
	var selected := bool(state["selected"])
	var disabled := bool(state["disabled"])
	var state_label: Label = swatch["state"]
	state_label.text = String(state["text"])
	state_label.add_theme_color_override("font_color",
		Color(ArtStyle.DANGER, 0.95) if disabled else ArtStyle.CREAM)
	var panel: PanelContainer = swatch["panel"]
	panel.add_theme_stylebox_override("panel", _swatch_style(selected, disabled))


## Цвет полосы свотча: тинт ливреи; у «без ливреи» белый тинт заменяем приглушённым кремовым,
## иначе на тёмной плашке полоса выглядит как «пустое место».
func _swatch_color(index: int) -> Color:
	if index <= 0:
		return Color(ArtStyle.CREAM, 0.18)
	return ArtStyle.livery_tint(index)


# ─── Стили (палитра ArtStyle, без SpriteCook — UI остаётся векторным) ────────
## Подложка карточки: тёмная плашка + кремовый контур; у выбранной — жёлтый акцент.
## Толщина контура ОДНА (2 px) у всех карточек: рамка не должна менять высоту строки
## (3 px у выбранной карточки сдвигали её соседей на пиксели и «ломали» сетку).
func _card_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.129412, 0.141176, 0.109804, 0.94)
	style.border_color = ArtStyle.BULLET_ENEMY if selected else Color(ArtStyle.CREAM, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(CARD_CONTENT_MARGIN)
	return style


## Плашка свотча: акцент — выбранная, красный контур — не хватает снабжения.
func _swatch_style(selected: bool, disabled: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.129412, 0.141176, 0.109804, 0.94)
	if selected:
		style.border_color = ArtStyle.BULLET_ENEMY
	elif disabled:
		style.border_color = Color(ArtStyle.DANGER, 0.55)
	else:
		style.border_color = Color(ArtStyle.CREAM, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(SWATCH_CONTENT_MARGIN)
	return style


## Стиль кнопки карточки: как «Выбрать» в выборе миссии (оливковая плашка, кремовый контур 2 px).
func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	return style
