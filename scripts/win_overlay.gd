# win_overlay.gd
# Purpose: Экран победы (GDD «Win, fail, restart»): «Аэродром спасён», счёт, время забега,
#          локальный рекорд (GDD «Challenge and progression») и — с M5.3b — звёзды и
#          начисленное снабжение (GDD «Счёт, звёзды, снабжение», «Оболочка» → «Итоги»).
#          Рекорд/звёзды/снабжение уже посчитаны CampaignProgress: оверлей только показывает
#          готовые значения, сам на диск не ходит.
#          M7c: рядом с StarsLine — ряд из 3 иконок `ui_star` (TextureRect 24×24, nearest):
#          заполненные с полной альфой, пустые с alpha 0.25.
#          M11 (T4, решение D2): звёзды показываются ОДИН раз. При наличии PNG `ui_star`
#          StarsLine пишет только подпись «Звёзды:» (без глифов ★/☆), а ряд иконок стоит сразу
#          справа (зазор 8 px), и вся группа «подпись + 3 иконки» центрирована по полосе
#          StarsLine (±2 px): полоса сжимается до ширины текста и сдвигается влево на половину
#          ширины группы. PNG нет → прежний текст «Звёзды: ★★☆» и ряд скрыт (фолбэк).
#          M8b: скрытый слот rewarded ×2 снабжение (DoubleSupplyButton, GDD «Монетизация»:
#          «rewarded ×2 снабжение после миссии»). Кнопка есть в сцене, но visible = false и
#          включается только LevelController по Ads.is_available() (флаг ads_enabled, сейчас
#          всегда false): при выключенном флаге она не участвует ни в раскладке, ни в тапе.
#          M10 (bug 1): три действия исхода — «Повторить» (ReplayButton), «Кампания»
#          (CampaignButton) и «В ангар» (HomeButton), 320×88. Оверлей только эмитит
#          replay_requested / campaign_requested / home_requested, а решения принимает
#          LevelController (start_level / _enter_idle_state + выбор миссии / show_home).
#          Кнопки видны ТОЛЬКО при показанном оверлее (hide_overlay() их прячет), корень и Dim
#          прозрачны для тапов, кнопки ловят своё касание через accept_event().
#          M11/T2: тап-шорткатов нет — «тап мимо кнопок = рестарт» больше не существует
#          (LevelController._unhandled_input удалён), исход покидается только этими кнопками.
#          Ввод — как в pause_overlay.gd: на Android `Button.pressed` от касания не приходит
#          (project.godot: pointing/emulate_mouse_from_touch=false), поэтому единственный рабочий
#          путь — button.gui_input + InputEventScreenTouch (+accept_event). У КАЖДОЙ кнопки свой
#          латч (_replay_latched/_campaign_latched/_home_latched): press → ровно один сигнал,
#          отпускание → латч снят. Button.pressed остаётся desktop-путём и гасится окном
#          TAP_DEBOUNCE_MS. M11 (T1): раньше общий латч занимался дважды (_route_action_touch
#          звал _claim_tap(), а затем request_* звал его ещё раз) — кнопки были мёртвыми на
#          100 %; теперь латчирует только сам request_*, и они сбрасываются при каждом показе.
#          Title — из данных миссии (M10, data/missions.json → result.win_title), пусто → текст
#          сцены. M11/T3 (решение D4): строка-подсказка (узел Hint, «Тап — рестарт») удалена
#          вместе с тап-шорткатами T2 — экран покидается только тремя кнопками исхода.
#          M10 (bug 2): строка UnlockLine «Бесконечный режим открыт» над заголовком — только в
#          тот забег, когда открылся гейт endless (≥1 звезда в каждой миссии). Подсказку
#          «Откроется после прохождения кампании» с домашнего экрана убрали: она стояла под
#          «Кампанией» и путала. Видимость решает LevelController (set_unlock_notice), сам
#          оверлей профиль не читает.
#          PROCESS_MODE_ALWAYS: оверлей показывается уже при get_tree().paused = true, кнопки
#          обязаны нажиматься на паузе (как PauseOverlay/DeathOverlay).
# Dependencies: scene main.tscn (Title / ScoreLine / TimeLine / RecordLine / StarsLine /
#               StarIcons / SupplyLine, скрытый DoubleSupplyButton, ReplayButton /
#               CampaignButton / HomeButton), MissionData (тексты миссии), ArtAssets (ui_star),
#               Ads (заглушка rewarded). SaveGame/CampaignProgress не требуются: значения
#               приходят готовыми из LevelController.
# Author: Mechanics Developer Agent (M3-C), UI/UX Agent (M5.3b: звёзды и снабжение),
#         Technical Artist Agent (M7c: иконки ui_star), Mechanics Developer Agent (M8b: слот ×2),
#         UI/UX Agent (M10: кнопки исхода и тексты по миссии)

class_name WinOverlay
extends Control

## M10: игрок нажал «Повторить» — рестарт ТОЙ ЖЕ миссии (LevelController.start_level).
signal replay_requested
## M10: игрок нажал «Кампания» — выход из исхода в выбор миссии.
signal campaign_requested
## M10: игрок нажал «В ангар» — выход на домашний экран (LevelController.show_home).
signal home_requested

## Максимум звёзд миссии (GDD: 3 звезды на миссию).
const MAX_STARS := 3
## M7c: ключ иконки звезды и её размер (GDD «Assets»: ui_star 24×24).
const STAR_ICON_KEY := &"ui_star"
const STAR_ICON_SIZE := Vector2(24.0, 24.0)
## Зазор между иконками в ряду.
const STAR_ICON_SEPARATION := 4
## M11 (T4): зазор между подписью «Звёзды:» и рядом пиксельных иконок (D2).
const STAR_ICON_TEXT_GAP := 8.0
## M11 (T4): подпись строки звёзд. Без PNG ui_star к ней добавляется «★★☆» (фолбэк).
const STARS_LABEL_TEXT := "Звёзды:"
## alpha пустой звезды (заполненная — 1.0).
const STAR_EMPTY_ALPHA := 0.25
## M8b: текст скрытого слота rewarded ×2 снабжение (GDD «Монетизация»).
const DOUBLE_SUPPLY_TEXT := "Снабжение ×2 за рекламу"
## M10: подписи кнопок исхода (RU, player-facing). Размер кнопок — 320×88 в сцене
## (тач-минимум Android 64 px выполняется с запасом).
const REPLAY_TEXT := "Повторить"
const CAMPAIGN_TEXT := "Кампания"
const HOME_TEXT := "В ангар"
## M10 (bug 2): текст строки об открытии бесконечного режима (RU, player-facing).
const ENDLESS_UNLOCK_TEXT := "Бесконечный режим открыт"
## Окно дебаунса одного касания (как в settings.gd/hangar.gd): на десктопе
## emulate_touch_from_mouse даёт и touch-, и mouse-событие на один тап.
const TAP_DEBOUNCE_MS := 250

@onready var title: Label = $Title
## M10 (bug 2): «Бесконечный режим открыт» над заголовком (может отсутствовать в старых сценах).
@onready var unlock_line: Label = get_node_or_null(^"UnlockLine") as Label
@onready var score_line: Label = $ScoreLine
@onready var time_line: Label = $TimeLine
## M3-C: «Новый рекорд: N» в момент рекорда, иначе «Рекорд: N».
@onready var record_line: Label = $RecordLine
## M5.3b: «Звёзды: ★★☆» — звёзды именно этого исхода (0 при вызове без аргументов).
@onready var stars_line: Label = $StarsLine
## M7c: ряд иконок ui_star рядом со StarsLine (может отсутствовать в старых сценах).
@onready var star_icons: HBoxContainer = get_node_or_null(^"StarIcons") as HBoxContainer
## M5.3b: «Снабжение: +N» — начислено этим исходом (0 при вызове без аргументов).
@onready var supply_line: Label = $SupplyLine
## M8b: скрытый слот rewarded ×2 снабжение (может отсутствовать в старых сценах — гвард).
@onready var double_supply_button: Button = get_node_or_null(^"DoubleSupplyButton") as Button
## M10: кнопки исхода (могут отсутствовать в старых сценах — гвард).
@onready var replay_button: Button = get_node_or_null(^"ReplayButton") as Button
@onready var campaign_button: Button = get_node_or_null(^"CampaignButton") as Button
@onready var home_button: Button = get_node_or_null(^"HomeButton") as Button

## Последние переданные значения рекорда (QA/тесты; переживают hide_overlay()).
var best_score: int = 0
var is_new_record: bool = false
## M5.3b: последние переданные звёзды/снабжение (QA/тесты; переживают hide_overlay()).
var stars: int = 0
var supply_gained: int = 0
## M7c: узлы-иконки и конечный ключ загруженной текстуры (&"" — ряда нет).
var _star_icon_nodes: Array[TextureRect] = []
var _star_texture_key: StringName = &""
## M11 (T4): полоса StarsLine, как она задана в сцене (источник центрирования группы).
## Снимается один раз до первого сдвига — иначе повторный _layout_star_icons() сдвигал бы
## уже сдвинутую полосу и раскладка «уползала» бы влево.
var _stars_band: Rect2 = Rect2()
var _stars_band_captured: bool = false
## M10: id миссии, чьи тексты сейчас на экране ("" — тексты сцены до первого set_mission).
var _mission_id: String = ""
## M10: заголовок сцены на момент _ready — фолбэк, если в данных миссии пусто.
var _default_title: String = ""
## M11 (T1): по латчу на КАЖДУЮ кнопку исхода (как в pause_overlay.gd): touch и Button.pressed
## одного тапа не должны дать два запроса. Латч ставит сам request_*(), снимает отпускание
## (_release_tap) и каждый показ экрана (_reset_taps).
var _replay_latched: bool = false
var _campaign_latched: bool = false
var _home_latched: bool = false
## M8b: отдельный латч скрытого слота ×2 — он не участвует во вводе кнопок исхода.
var _double_supply_latched: bool = false
## M10: отметка последнего touch-события. Только для desktop-пути Button.pressed
## (_is_touch_duplicate): mouse-дубль того же тапа не должен дать второй запрос.
var _last_touch_msec: int = -TAP_DEBOUNCE_MS


func _ready() -> void:
	# ALWAYS: оверлей показывается при get_tree().paused = true — кнопки обязаны нажиматься.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# M10: текст сцены запоминаем ДО первого hide_overlay(): это фолбэк для миссии без данных.
	_default_title = String(title.text) if title != null else ""
	_setup_unlock_line()
	# M11 (T4): до первого показа строка — только подпись без глифов; текстовый фолбэк
	# «Звёзды: ★★☆» включит show_result(), если PNG ui_star не найдётся.
	stars_line.text = STARS_LABEL_TEXT
	refresh_star_icons()
	_setup_double_supply_button()
	_setup_action_buttons()
	hide_overlay()
	resized.connect(_layout_star_icons)


# ─── M10: тексты экрана победы по миссии ────────────────────────────────────
## Заголовок из данных миссии (data/missions.json → result.win_title). Пустой id, нет данных
## или пустая строка в данных → текст сцены («Аэродром спасён»).
## M11/T3 (решение D4): строка-подсказка «Тап — рестарт» удалена — на экране победы остались
## только заголовок, строки итогов и кнопки исхода.
func set_mission(id: String) -> void:
	_mission_id = id
	if title == null:
		return
	if _default_title.is_empty():
		_default_title = String(title.text)
	var win_title := MissionData.get_result_win_title(id)
	title.text = win_title if not win_title.is_empty() else _default_title


## QA/тесты: id миссии, чьи тексты сейчас на экране ("" — тексты сцены).
func get_mission_id() -> String:
	return _mission_id


# ─── M10 (bug 2): сообщение об открытии бесконечного режима ─────────────────
## Показать/скрыть строку «Бесконечный режим открыт». Единственный вызывающий —
## LevelController: он показывает её ровно в тот забег, когда гейт endless открылся впервые
## (≥1 звезда в каждой миссии). Оверлей профиль не читает и сам решение не принимает.
func set_unlock_notice(show_notice: bool) -> void:
	if unlock_line == null:
		return
	unlock_line.text = ENDLESS_UNLOCK_TEXT
	unlock_line.visible = show_notice


func is_unlock_notice_visible() -> bool:
	return unlock_line != null and unlock_line.visible


func get_unlock_text() -> String:
	return String(unlock_line.text) if unlock_line != null else ""


## Текст строки живёт в одном месте (ENDLESS_UNLOCK_TEXT), сцена — только раскладка.
func _setup_unlock_line() -> void:
	if unlock_line == null:
		return
	unlock_line.text = ENDLESS_UNLOCK_TEXT
	unlock_line.visible = false
	unlock_line.mouse_filter = Control.MOUSE_FILTER_IGNORE


## Показать исход. Все дополнительные аргументы опциональны: старые вызовы
## show_result(score, elapsed) и show_result(score, elapsed, best, is_new) остаются
## валидными — тогда звёзды «☆☆☆» и снабжение «+0».
func show_result(
	score: int,
	elapsed: float,
	best_score: int = 0,
	is_new_record: bool = false,
	stars: int = 0,
	supply: int = 0
) -> void:
	# M11 (T1): каждый показ экрана — чистое состояние ввода (как PauseOverlay.show_overlay()):
	# латчи прошлого исхода не должны оставить кнопки «мёртвыми».
	_reset_taps()
	self.best_score = maxi(0, best_score)
	self.is_new_record = is_new_record
	self.stars = clampi(stars, 0, MAX_STARS)
	self.supply_gained = maxi(0, supply)
	score_line.text = "Счёт: %d" % score
	time_line.text = "Время: %s" % format_time(elapsed)
	record_line.text = format_record(self.best_score, self.is_new_record)
	# M11 (T4, D2): при наличии PNG строка — только подпись «Звёзды:», звёзды показывает ряд
	# пиксельных иконок; без PNG остаётся прежний текстовый фолбэк «Звёзды: ★★☆».
	stars_line.text = STARS_LABEL_TEXT if _has_star_row() \
		else ("Звёзды: %s" % format_stars(self.stars))
	supply_line.text = "Снабжение: +%d" % self.supply_gained
	_update_star_icons()
	set_action_buttons_visible(true)
	visible = true


## Скрыть оверлей, НЕ теряя рекорд: текст RecordLine остаётся, следующий show_result()
## перезапишет его актуальными значениями.
func hide_overlay() -> void:
	visible = false
	# M10 (bug 2): строка об открытии режима не переживает скрытие — её включает только
	# следующий вызов set_unlock_notice() от LevelController.
	set_unlock_notice(false)
	# M10: кнопки исхода не переживают скрытие — их включает следующий show_result().
	set_action_buttons_visible(false)
	# M8b: слот ×2 не переживает скрытие: следующий показ снова решает LevelController.
	set_double_supply_available(false)


# ─── M10: кнопки исхода ─────────────────────────────────────────────────────
## Показать/скрыть три кнопки исхода. Единственные вызывающие — show_result() и
## hide_overlay(): скрытая кнопка не участвует ни в раскладке, ни в тапе.
func set_action_buttons_visible(show_buttons: bool) -> void:
	for button: Button in [replay_button, campaign_button, home_button]:
		if button != null:
			button.visible = show_buttons
	# M11 (T1): показ и скрытие одинаково чистят ввод: скрытая кнопка не участвует в тапе,
	# а новый показ не наследует латч прошлого исхода (как PauseOverlay.show_overlay()).
	_reset_taps()


## QA/тесты: сколько кнопок исхода реально видно (0 — оверлей скрыт).
func get_visible_action_button_count() -> int:
	var count := 0
	for button: Button in [replay_button, campaign_button, home_button]:
		if button != null and button.visible:
			count += 1
	return count


## «Повторить» (и путь QA/тестов): один запрос на касание. false — латч этой кнопки держится
## (второй путь ввода того же тапа или повторный press до отпускания).
func request_replay() -> bool:
	if _replay_latched:
		return false
	_replay_latched = true
	replay_requested.emit()
	return true


## «Кампания» (и путь QA/тестов).
func request_campaign() -> bool:
	if _campaign_latched:
		return false
	_campaign_latched = true
	campaign_requested.emit()
	return true


## «В ангар» (и путь QA/тестов).
func request_home() -> bool:
	if _home_latched:
		return false
	_home_latched = true
	home_requested.emit()
	return true


## QA/тесты: свободен ли ввод (false — держится латч хотя бы одной кнопки исхода или слота ×2).
func is_tap_available() -> bool:
	return not (_replay_latched or _campaign_latched or _home_latched
		or _double_supply_latched)


# ─── M8b: скрытый слот rewarded ×2 снабжение ────────────────────────────────
## Включить/выключить кнопку «Снабжение ×2 за рекламу». Единственный вызывающий —
## LevelController (visible = Ads.is_available()), поэтому сейчас кнопка всегда скрыта.
func set_double_supply_available(available: bool) -> void:
	if double_supply_button == null:
		return
	double_supply_button.visible = available
	_release_tap()


func is_double_supply_visible() -> bool:
	return double_supply_button != null and double_supply_button.visible


func get_double_supply_text() -> String:
	return String(double_supply_button.text) if double_supply_button != null else ""


## Тап по слоту (и путь QA/тестов). Заглушка Ads всегда возвращает false: снабжение не
## удваивается, экран победы остаётся на месте — выйти можно только кнопками исхода
## (тап-шорткатов нет, M11/T2).
func tap_double_supply() -> bool:
	if not is_double_supply_visible():
		return false
	return Ads.show_rewarded(Ads.DOUBLE_SUPPLY, Callable())


# ─── M7c: ряд иконок ui_star ────────────────────────────────────────────────
## Пересобрать ряд иконок: текстура из ArtAssets, фильтр nearest, alpha по текущим звёздам.
## Вызывается из _ready() и из QA/тестов; файла нет — ряд скрыт, StarsLine остаётся один.
func refresh_star_icons() -> void:
	_star_icon_nodes.clear()
	if star_icons == null:
		_star_texture_key = &""
		return
	var icon_texture := ArtAssets.texture(STAR_ICON_KEY)
	_star_texture_key = STAR_ICON_KEY if icon_texture != null else &""
	for child in star_icons.get_children():
		var icon := child as TextureRect
		if icon == null:
			continue
		icon.texture = icon_texture
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.custom_minimum_size = STAR_ICON_SIZE
		_star_icon_nodes.append(icon)
	star_icons.visible = icon_texture != null and not _star_icon_nodes.is_empty()
	_update_star_icons()


## QA/тесты: сколько иконок в ряду (0 — узла StarIcons нет).
func get_star_icon_count() -> int:
	return _star_icon_nodes.size()


## QA/тесты: сколько иконок залито полной альфой (считается по modulate.a, как на экране).
func get_star_filled_count() -> int:
	var filled := 0
	for icon: TextureRect in _star_icon_nodes:
		if icon.modulate.a > STAR_EMPTY_ALPHA + 0.01:
			filled += 1
	return filled


## QA/тесты: конечный ключ текстуры ряда (&"" — PNG нет, ряд скрыт).
func get_star_texture_key() -> StringName:
	return _star_texture_key


## QA/тесты: виден ли ряд (скрыт, если файла ui_star нет).
func is_star_row_visible() -> bool:
	return star_icons != null and star_icons.visible


## M8b: настройка скрытого слота ×2. Кнопка в сцене, но по умолчанию скрыта; ввод —
## gui_input (Android touch) + pressed (desktop), с латчем одного касания.
func _setup_double_supply_button() -> void:
	if double_supply_button == null:
		return
	double_supply_button.text = DOUBLE_SUPPLY_TEXT
	double_supply_button.visible = false
	double_supply_button.focus_mode = Control.FOCUS_NONE
	double_supply_button.gui_input.connect(_on_double_supply_gui_input)
	double_supply_button.pressed.connect(_on_double_supply_pressed)


func _on_double_supply_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	# Тап по кнопке не уходит дальше по дереву: берём касание себе, чтобы слот не срабатывал
	# чужим действием. Скрытая кнопка событий не получает.
	double_supply_button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	if _claim_double_supply_tap():
		_on_double_supply_pressed()


func _on_double_supply_pressed() -> void:
	if not is_double_supply_visible():
		return
	tap_double_supply()


# ─── M10: настройка кнопок исхода ───────────────────────────────────────────
## Кнопки в сцене скрыты; ввод — gui_input (Android touch) + pressed (desktop), у каждой
## кнопки свой латч (M11/T1). Подписи ставятся здесь, чтобы текст жил в одном месте.
func _setup_action_buttons() -> void:
	var pairs: Array = [
		[replay_button, REPLAY_TEXT, _on_replay_gui_input, _on_replay_pressed],
		[campaign_button, CAMPAIGN_TEXT, _on_campaign_gui_input, _on_campaign_pressed],
		[home_button, HOME_TEXT, _on_home_gui_input, _on_home_pressed],
	]
	for pair: Array in pairs:
		var button: Button = pair[0] as Button
		if button == null:
			continue
		button.text = String(pair[1])
		button.visible = false
		button.focus_mode = Control.FOCUS_NONE
		button.gui_input.connect(pair[2] as Callable)
		button.pressed.connect(pair[3] as Callable)


func _on_replay_gui_input(event: InputEvent) -> void:
	_route_action_touch(event, replay_button, request_replay)


func _on_campaign_gui_input(event: InputEvent) -> void:
	_route_action_touch(event, campaign_button, request_campaign)


func _on_home_gui_input(event: InputEvent) -> void:
	_route_action_touch(event, home_button, request_home)


## Общий путь касания кнопки исхода: тап по кнопке не уходит дальше по дереву, отпускание
## снимает латч, нажатие — один запрос. Латч здесь НЕ занимается: его ставит сам request_*()
## (M11/T1 — раньше двойной захват делал кнопки мёртвыми).
func _route_action_touch(event: InputEvent, button: Button, request: Callable) -> void:
	if not (event is InputEventScreenTouch) or button == null:
		return
	var touch := event as InputEventScreenTouch
	button.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	request.call()


## Запасные пути для мыши/эмуляции (Button.pressed): mouse-дубль того же тапа гасится окном
## TAP_DEBOUNCE_MS, иначе одно касание дало бы два запроса.
func _on_replay_pressed() -> void:
	if _is_touch_duplicate():
		return
	request_replay()


func _on_campaign_pressed() -> void:
	if _is_touch_duplicate():
		return
	request_campaign()


func _on_home_pressed() -> void:
	if _is_touch_duplicate():
		return
	request_home()


## Отметка touch-события (нажатие И отпускание): mouse-дубль приходит сразу после отпускания.
func _note_touch() -> void:
	_last_touch_msec = Time.get_ticks_msec()


## Отпускание пальца снимает латчи — экран не «замерзает» для следующих тапов.
func _release_tap() -> void:
	_replay_latched = false
	_campaign_latched = false
	_home_latched = false
	_double_supply_latched = false


## Чистое состояние ввода на показ экрана: латчи + отметка touch. Вызывается из show_result()
## и set_action_buttons_visible() — иначе латч прошлого исхода оставил бы кнопку «мёртвой».
func _reset_taps() -> void:
	_release_tap()
	_last_touch_msec = -TAP_DEBOUNCE_MS


## Занять латч скрытого слота ×2 (один запрос за касание, как у кнопок исхода).
func _claim_double_supply_tap() -> bool:
	if _double_supply_latched:
		return false
	_double_supply_latched = true
	return true


## Пришёл ли mouse-дубль того же физического касания (эмуляция мыши из тача).
func _is_touch_duplicate() -> bool:
	return Time.get_ticks_msec() - _last_touch_msec < TAP_DEBOUNCE_MS


## Залить первые `self.stars` иконок, остальные приглушить, и поставить ряд в полосу StarsLine.
func _update_star_icons() -> void:
	if _star_icon_nodes.is_empty():
		return
	for index in _star_icon_nodes.size():
		_star_icon_nodes[index].modulate.a = 1.0 if index < stars else STAR_EMPTY_ALPHA
	_layout_star_icons()


## M11 (T4): есть ли рабочий ряд пиксельных иконок (PNG загружен и узлы собраны). От этого
## зависит текст StarsLine: «Звёзды:» без глифов или прежний текстовый фолбэк со звёздами.
func _has_star_row() -> bool:
	return star_icons != null and not _star_icon_nodes.is_empty() \
		and star_icons.visible


## M11 (T4, D2): группа «подпись + ряд иконок» центрируется по полосе StarsLine целиком —
## подпись сдвигается влево на половину ширины ряда с зазором, ряд встаёт сразу за текстом.
## Полоса запоминается один раз (до первого сдвига), иначе повторная раскладка «уползала» бы.
func _layout_star_icons() -> void:
	if star_icons == null or stars_line == null or _star_icon_nodes.is_empty():
		return
	var count := _star_icon_nodes.size()
	var row_width := STAR_ICON_SIZE.x * float(count) \
		+ float(STAR_ICON_SEPARATION) * float(count - 1)
	# Раскладка ещё не посчитана (узлы без размера) — повторим на следующем кадре.
	if not _stars_band_captured:
		if stars_line.size.x <= 1.0:
			_layout_star_icons.call_deferred()
			return
		_stars_band = stars_line.get_rect()
		_stars_band_captured = true
	var band := _stars_band
	var font := stars_line.get_theme_font(&"font")
	var font_size := stars_line.get_theme_font_size(&"font_size")
	var text_width := font.get_string_size(
		String(stars_line.text), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var group_width := text_width + STAR_ICON_TEXT_GAP + row_width
	var group_left := band.position.x + (band.size.x - group_width) * 0.5
	stars_line.position = Vector2(group_left, band.position.y)
	# Ширину подписи сжимаем до фактического текста: полоса 540 px, сдвинутая на половину
	# ряда, вылезала бы за край поля (M11, T4) — так остаётся внутри и текст, и ряд.
	stars_line.size = Vector2(text_width, band.size.y)
	star_icons.position = Vector2(
		group_left + text_width + STAR_ICON_TEXT_GAP,
		band.position.y + (band.size.y - STAR_ICON_SIZE.y) * 0.5
	)
	star_icons.size = Vector2(row_width, STAR_ICON_SIZE.y)


## «Новый рекорд: %d» при рекорде, иначе «Рекорд: %d». Публичный static — единый источник
## текста для QA/тестов и будущих экранов.
static func format_record(best: int, is_new: bool) -> String:
	var safe_best := maxi(0, best)
	if is_new:
		return "Новый рекорд: %d" % safe_best
	return "Рекорд: %d" % safe_best


## «★★☆» — заполненные + пустые звёзды, всегда MAX_STARS символов.
## U+2605/U+2606 отсутствуют в NotoSans-Regular.ttf, поэтому рендерятся системным
## fallback-шрифтом (FontFile.allow_system_fallback = true).
static func format_stars(stars: int) -> String:
	var filled := clampi(stars, 0, MAX_STARS)
	return "★".repeat(filled) + "☆".repeat(MAX_STARS - filled)


## Секунды → «M:SS». Время показывается, но на счёт не влияет (GDD).
static func format_time(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	var minutes := total / 60
	var rest := total % 60
	return "%d:%02d" % [minutes, rest]
