# briefing_overlay.gd
# Purpose: Экран брифинга (GDD «First 30 seconds», п.2): две-три строки о миссии и кнопка
#          «В бой». Показывается ТОЛЬКО при запуске приложения и при возврате с выбора
#          миссии — рестарт после поражения/победы мгновенный, без брифинга
#          (GDD «Win, fail, restart»).
#          Оверлей не перехватывает тапы вне кнопок: root и dim — MOUSE_FILTER_IGNORE,
#          поэтому тап мимо кнопки не делает ничего (LevelController._unhandled_input удалён
#          в M11/T2; старт забега — только кнопка «В бой»).
#          M5.3b: брифинг стал миссионным — set_mission(id)/show_overlay_for(id) берут заголовок
#          и текст из MissionData (data/missions.json). Для m1_airfield заголовок и строки
#          остаются СЦЕННЫМИ: их фиксируют smoke-тесты, а данные миссии 1 в UI не дублируются
#          (data/missions.json не источник текста брифинга в первом забеге).
#          Кнопка «Миссии» открывает экран выбора миссии (MissionsButton → mission_select.tscn).
#          M6.2b: кнопка «Ангар» (HangarButton) рядом с «Миссии» открывает экран ангара
#          (самолёт + ливрея) — так же сигналом hangar_requested, тем же латчем касания.
#          M6.3b: кнопка «Бесконечный» (EndlessButton) — третий вход из брифинга, сигнал
#          endless_requested (LevelController → start_endless). Гейт — SaveGame.is_endless_unlocked():
#          закрытая кнопка disabled и приглушена (alpha 0.6), программный эмит по закрытому
#          профилю гасится в _request_endless(). Текстовой подсказки условия на брифинге нет
#          (M11/T6, решение D7: «Откроется после прохождения кампании» удалена вместе с узлом
#          EndlessHint — текст читался как условие кампании). Состояние перечитывается ТОЛЬКО
#          в refresh_endless_state() (показ брифинга, возврат с выбора миссии/ангара, явный
#          вызов QA) — SaveGame читает файл и в _process ему нельзя. Профиль между открытием
#          кнопки и стартом не меняется, поэтому кэш _endless_enabled честный.
#          M8a: кнопка «Настройки» (SettingsButton) — 64×64 в свободной полосе под рядом
#          «Миссии»/«Ангар»/«Бесконечный» (460…524 × 88…152), шестерёнка «⚙» 28 px, сигнал
#          settings_requested. Размер 64, а не 48: AGENTS требует тач-таргет ≥ 64×64 —
#          это единственное отклонение от запроса M8a (шестерёнка вместо подписи сохранена).
#          Кнопка не пересекается ни с рядом кнопок (до y 80), ни с заголовком (с y 230),
#          ни со строками брифинга и «В бой» — раскладка M3-B/M5.3b не сдвинулась.
#          Ввод: touch приходит как InputEventScreenTouch (эмуляция мыши из тача выключена) и
#          ловится в gui_input; Button.pressed — запасной путь мыши. Латч одного касания
#          снимается ОТПУСКАНИЕМ пальца (страховка — окно TAP_DEBOUNCE_MS), поэтому брифинг
#          не может «замереть» после нажатия (было: латч снимался только в show_overlay()).
# Dependencies: assets/ui_theme.tres (Noto Sans + TitleLabel/Bold), палитра ArtStyle —
#               цвета зашиты в scenes/briefing_overlay.tscn; MissionData (title/briefing),
#               GameConfig.REFERENCE_SIZE (ширина поля для переноса строк),
#               SaveGame.is_endless_unlocked (гейт бесконечного режима).
# Author: UI/UX Agent (M5.3b, M6.2b, M6.3b, M8a), Mechanics Developer Agent (M3-B)

class_name BriefingOverlay
extends Control

## Игрок нажал «В бой». LevelController начинает забег (start_level).
signal start_requested
## M5.3b: игрок нажал «Миссии» — LevelController показывает экран выбора миссии.
signal missions_requested
## M6.2b: игрок нажал «Ангар» — LevelController показывает экран ангара (выбор самолёта/ливреи).
signal hangar_requested
## M6.3b: игрок нажал «Бесконечный» — LevelController запускает endlessly-забег (start_endless).
## Эмитится ТОЛЬКО при открытом режиме: закрытая кнопка disabled и запрос гасит гейт.
signal endless_requested
## M8a: игрок нажал «⚙» — LevelController показывает экран настроек.
signal settings_requested

## Миссия, чей заголовок/текст сейчас показан, по умолчанию — первая.
const DEFAULT_MISSION_ID := "m1_airfield"
## Сколько body-строк вмещает брифинг (Line1…Line3). В GDD брифинг — 2–3 строки.
const MAX_BODY_LINES := 3
## Боковые поля body-строк: 540 − 2×24 = 492 px (совпадает с проверкой smoke-теста).
## Длинные строки миссий 2–3 переносятся по словам, чтобы не липнуть к краям поля.
const BODY_SIDE_MARGIN := 24.0
## Короткие слова («Ju», «Bf», «№») не остаются в конце строки при переносе: иначе
## «…открывают путь Ju / 88 — сбей его…» читается как опечатка.
const SHORT_WORD_LIMIT := 2

@onready var title_label: Label = $Title
@onready var line1: Label = $Line1
@onready var line2: Label = $Line2
@onready var line3: Label = $Line3
@onready var start_button: Button = $StartButton
## M5.3b: «Миссии» — возврат к выбору миссии (верхний левый угол, 160×64).
@onready var missions_button: Button = $MissionsButton
## M6.2b: «Ангар» — выбор самолёта и ливреи (рядом с «Миссии», 160×64).
@onready var hangar_button: Button = $HangarButton
## M6.3b: «Бесконечный» — третий вход из брифинга (352…512 × 16…80, 160×64).
@onready var endless_button: Button = $EndlessButton
## M8a: «⚙» — вход в настройки (460…524 × 88…152, 64×64 — тач-минимум).
@onready var settings_button: Button = $SettingsButton

## Латч одного физического касания (общий на весь оверлей: два пальца одновременно дают
## один запрос). Android присылает только InputEventScreenTouch (эмуляция мыши из тача в
## проекте выключена), на десктопе при emulate_touch_from_mouse приходят и touch-, и
## mouse-события. Латч снимается ОТПУСКАНИЕМ пальца и не дольше TAP_DEBOUNCE_MS: раньше он
## снимался только в show_overlay(), и после нажатия кнопки брифинг мог «замереть» для тапов.
const TAP_DEBOUNCE_MS := 250
## Время последнего touch-события (нажатие ИЛИ отпускание) — окно дебаунса mouse-пути.
var _last_touch_msec: int = -TAP_DEBOUNCE_MS
## Запрос уже сделан нажатием текущего касания; снимается отпусканием.
var _tap_claimed: bool = false
## Когда запрос был занят — страховка, если отпускание не дошло до узла.
var _tap_claimed_msec: int = -TAP_DEBOUNCE_MS
## M6.3b: кэш гейта бесконечного режима (SaveGame.is_endless_unlocked). Пишется только
## refresh_endless_state(): файл профиля читается по событию, не каждый кадр.
var _endless_enabled: bool = false
## Сценные тексты миссии 1 (снимок ДО любых set_mission): к ним возвращает пустой id/m1.
var _defaults: Dictionary = {}
## id показанной миссии (QA/LevelController).
var _mission_id: String = DEFAULT_MISSION_ID


func _ready() -> void:
	# ALWAYS: брифинг обязан реагировать на кнопку, даже если дерево случайно на паузе.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	start_button.gui_input.connect(_on_start_button_gui_input)
	# Запасной путь для мыши/эмуляции: Button.pressed (нажатие+отпускание).
	start_button.pressed.connect(_on_start_button_pressed)
	missions_button.gui_input.connect(_on_missions_button_gui_input)
	missions_button.pressed.connect(_on_missions_button_pressed)
	hangar_button.gui_input.connect(_on_hangar_button_gui_input)
	hangar_button.pressed.connect(_on_hangar_button_pressed)
	# M6.3b: «Бесконечный» — тот же ввод, что у «Миссии»/«Ангар» (touch + pressed, латч).
	endless_button.gui_input.connect(_on_endless_button_gui_input)
	endless_button.pressed.connect(_on_endless_button_pressed)
	# M8a: «⚙» — вход в настройки, тот же латч касания (не гасит другие кнопки брифинга).
	settings_button.gui_input.connect(_on_settings_button_gui_input)
	settings_button.pressed.connect(_on_settings_button_pressed)
	_capture_defaults()
	_apply_mission(_mission_id)
	refresh_endless_state()
	hide_overlay()


func show_overlay() -> void:
	# Новый показ — чистое состояние ввода: даже если предыдущее касание «потерялось»
	# (палец ушёл за пределы кнопки), первый тап по брифингу сработает.
	_release_tap()
	_last_touch_msec = -TAP_DEBOUNCE_MS
	# M6.3b: гейт режима перечитывается при каждом показе брифинга (после прохождения
	# кампании кнопка открывается без перезапуска приложения).
	refresh_endless_state()
	visible = true


func hide_overlay() -> void:
	visible = false


## M5.3b: показать брифинг конкретной миссии (текст и заголовок — из MissionData).
func show_overlay_for(id: String) -> void:
	set_mission(id)
	show_overlay()


## M5.3b: сменить миссию брифинга. Пустой id и m1_airfield возвращают сценный текст
## (smoke-тесты фиксируют «Оборона аэродрома» и три строки первого забега).
func set_mission(id: String) -> void:
	_apply_mission(id)


## id миссии, чей текст сейчас в оверлее (QA/LevelController).
func get_mission_id() -> String:
	return _mission_id


# ─── Ввод ───────────────────────────────────────────────────────────────────
## Основной путь Android: Button слушает mouse-события, а emulate_mouse_from_touch в проекте
## ВЫКЛЮЧЕН (иначе двойные события на устройстве), поэтому touch обрабатываем сами.
func _on_start_button_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	start_button.accept_event()  # касание кнопки не уходит глубже в UI/мир
	_note_touch()
	if not touch.pressed:
		_release_tap()  # палец ушёл — латч снят, следующее касание снова сработает
		return
	_request_start()


func _on_missions_button_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	missions_button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	_request_missions()


func _on_hangar_button_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	hangar_button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	_request_hangar()


func _on_endless_button_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	endless_button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	_request_endless()


func _on_settings_button_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	settings_button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	_request_settings()


# Запасные пути мыши/эмуляции: Button.pressed приходит сразу после touch-отпускания того же
# касания — гасим его окном TAP_DEBOUNCE_MS, чтобы одно нажатие не дало два запроса. Второй
# pressed без touch (чистая мышь) тоже гасится этим окном; оно же и отпускает латч.
func _on_start_button_pressed() -> void:
	if _is_touch_duplicate():
		return
	_request_start()


func _on_missions_button_pressed() -> void:
	if _is_touch_duplicate():
		return
	_request_missions()


func _on_hangar_button_pressed() -> void:
	if _is_touch_duplicate():
		return
	_request_hangar()


func _on_endless_button_pressed() -> void:
	if _is_touch_duplicate():
		return
	_request_endless()


func _on_settings_button_pressed() -> void:
	if _is_touch_duplicate():
		return
	_request_settings()


## Отметка touch-события. И нажатие, И отпускание: mouse-дубль (Button.pressed) приходит
## сразу после отпускания и должен быть погашен окном TAP_DEBOUNCE_MS.
func _note_touch() -> void:
	_last_touch_msec = Time.get_ticks_msec()


## Отпускание пальца снимает латч: этим и лечится «замерший» брифинг — раньше латч снимался
## только в show_overlay(), а на Android отпускание не приходило как mouse-release.
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


## QA/тесты: принимает ли оверлей следующее касание (false — латч ещё держится).
func is_tap_available() -> bool:
	return not _tap_claimed or Time.get_ticks_msec() - _tap_claimed_msec >= TAP_DEBOUNCE_MS


## Пришёл ли mouse-дубль того же физического касания (эмуляция мыши из тача).
func _is_touch_duplicate() -> bool:
	return Time.get_ticks_msec() - _last_touch_msec < TAP_DEBOUNCE_MS


## Единственная точка эмита: латч гасит второй путь ввода (touch + pressed) за одно касание.
func _request_start() -> void:
	if not _claim_tap():
		return
	start_requested.emit()


func _request_missions() -> void:
	if not _claim_tap():
		return
	missions_requested.emit()


func _request_hangar() -> void:
	if not _claim_tap():
		return
	hangar_requested.emit()


## M6.3b: единственная точка эмита «Бесконечный». Гейт стоит ЗДЕСЬ, а не только на
## disabled-кнопке: программный эмит по закрытому профилю режим не запускает.
func _request_endless() -> void:
	if not _endless_enabled or not _claim_tap():
		return
	endless_requested.emit()


## M8a: единственная точка эмита «⚙». Настройки доступны всегда (гейта нет).
func _request_settings() -> void:
	if not _claim_tap():
		return
	settings_requested.emit()


# ─── Гейт бесконечного режима (M6.3b) ───────────────────────────────────────
## Перечитать гейт из профиля и привести кнопку в актуальное состояние.
## Единственное место, где брифинг трогает SaveGame (не в _process: чтение файла).
func refresh_endless_state() -> void:
	if not is_node_ready():
		return
	_endless_enabled = SaveGame.is_endless_unlocked()
	endless_button.disabled = not _endless_enabled
	# Приглушение: у disabled-кнопки свой цвет шрифта, но и сама плашка не должна выглядеть
	# доступной — alpha 0.6 отличает «замок» от обычной второстепенной кнопки.
	endless_button.modulate = Color(1.0, 1.0, 1.0, 1.0 if _endless_enabled else 0.6)


## QA/LevelController: открыт ли бесконечный режим (кэш последнего refresh_endless_state).
func is_endless_enabled() -> bool:
	return _endless_enabled


# ─── Тексты миссии ──────────────────────────────────────────────────────────
## Снимок сценного состояния (миссия 1). Берётся в _ready до первого set_mission.
func _capture_defaults() -> void:
	_defaults = {
		"title": String(title_label.text),
		"lines": [String(line1.text), String(line2.text), String(line3.text)],
		"visible": [line1.visible, line2.visible, line3.visible],
	}


func _apply_mission(id: String) -> void:
	_mission_id = id if not id.is_empty() else DEFAULT_MISSION_ID
	if _defaults.is_empty():
		return  # до _ready: сценный текст ещё не снят, применим его в _ready
	if _mission_id == DEFAULT_MISSION_ID:
		_restore_defaults()
		return
	var mission_title := MissionData.get_title(_mission_id)
	var briefing_text := MissionData.get_briefing(_mission_id)
	if mission_title.is_empty() and briefing_text.is_empty():
		# Битые/неизвестные данные не должны оставлять пустой экран — показываем миссию 1.
		_restore_defaults()
		return
	title_label.text = mission_title if not mission_title.is_empty() \
		else String(_defaults.get("title", ""))
	_set_body(briefing_text)


func _restore_defaults() -> void:
	title_label.text = String(_defaults.get("title", ""))
	var lines: Array = _defaults.get("lines", [])
	var visibility: Array = _defaults.get("visible", [])
	for index in MAX_BODY_LINES:
		var label := _body_label(index)
		if label == null:
			continue
		label.text = String(lines[index]) if index < lines.size() else ""
		label.visible = bool(visibility[index]) if index < visibility.size() else true


## Разложить текст брифинга по Line1…Line3: абзацы из данных — через \n, длинные строки
## переносятся по словам под ширину поля (иначе «Пять волн Bf 109 и Ju 87 …» — 727 px
## при лимите 492 и вылезала бы за края 540). Больше трёх строк в данных не ждём:
## остаток склеивается в последнюю строку.
func _set_body(text: String) -> void:
	var lines := _wrap_body(text)
	for index in MAX_BODY_LINES:
		var label := _body_label(index)
		if label == null:
			continue
		var has_line := index < lines.size()
		label.text = lines[index] if has_line else ""
		label.visible = has_line


func _wrap_body(text: String) -> Array[String]:
	var result: Array[String] = []
	var font := line1.get_theme_font(&"font")
	var font_size := line1.get_theme_font_size(&"font_size")
	var max_width := GameConfig.REFERENCE_SIZE.x - 2.0 * BODY_SIDE_MARGIN
	for raw_line: String in text.split("\n"):
		var paragraph := raw_line.strip_edges()
		if paragraph.is_empty():
			continue
		if font == null:
			result.append(paragraph)
			continue
		var current := ""
		for word: String in paragraph.split(" ", false):
			var candidate := word if current.is_empty() else current + " " + word
			var candidate_width := font.get_string_size(
				candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			if current.is_empty() or candidate_width <= max_width:
				current = candidate
				continue
			# Перенос: короткое слово в конце строки не оставляем — уносим его на новую
			# строку вместе с текущим (см. SHORT_WORD_LIMIT).
			var parts := current.split(" ", false)
			if parts.size() > 1 and String(parts[parts.size() - 1]).length() <= SHORT_WORD_LIMIT:
				var carry := String(parts[parts.size() - 1])
				parts.remove_at(parts.size() - 1)
				result.append(" ".join(parts))
				current = carry + " " + word
			else:
				result.append(current)
				current = word
		if not current.is_empty():
			result.append(current)
	if result.is_empty():
		result.append("")
	while result.size() > MAX_BODY_LINES:
		var tail: String = result.pop_back()
		result[MAX_BODY_LINES - 1] = result[MAX_BODY_LINES - 1] + " " + tail
	return result


func _body_label(index: int) -> Label:
	match index:
		0:
			return line1
		1:
			return line2
		2:
			return line3
		_:
			return null
