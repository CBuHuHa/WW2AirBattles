# death_overlay.gd
# Purpose: Экран поражения. Два вида, одна сцена (scenes/main.tscn → UI/DeathOverlay):
#            • кампания — заголовок «Аэродром потерян» (M10: из данных миссии
#              data/missions.json → result.lose_title, пусто → текст сцены) и три действия;
#            • endless (M6.3b) — заголовок сцены + «Бесконечный: волна N», «Счёт: X»,
#              «Новый рекорд: Y» / «Рекорд: Y» (GDD «Бесконечный режим»: отдельный рекорд
#              «очки + достигнутая волна») и те же три действия.
#          M11/T3 (решения D3/D4): экран получил РЕАЛЬНЫЕ кнопки выхода — «Повторить»,
#          «Кампания», «В ангар» (320×88, тач-минимум 64, y 632…720 / 732…820 / 832…920).
#          Это следствие M11/T2: тап-шорткаты удалены из LevelController (было «тап — рестарт»
#          / «тап — повторить»), поэтому без кнопок игрок застревал бы на экране поражения.
#          Строки-подсказки (узел Hint, CAMPAIGN_HINT/ENDLESS_HINT) удалены полностью: на
#          экране исхода нет ни одного текста, приглашающего тапнуть в свободное место.
#          Оверлей только эмитит replay_requested / campaign_requested / home_requested,
#          решения принимает LevelController (start_level / start_endless →
#          _enter_idle_state + выбор миссии → show_home).
#          Ввод — как в pause_overlay.gd: на Android `Button.pressed` от касания не приходит
#          (project.godot: pointing/emulate_mouse_from_touch=false), поэтому единственный рабочий
#          путь — button.gui_input + InputEventScreenTouch (+accept_event). У КАЖДОЙ кнопки свой
#          латч одного касания, сброс — при каждом показе экрана (show_overlay /
#          show_endless_result / set_action_buttons_visible).
#          Оверлей не потребляет ввод сам (mouse_filter = IGNORE): касание мимо кнопок не меняет
#          состояние.
#          M8b: единственное исключение по вводу — СКРЫТЫЙ слот rewarded-revive (ReviveButton,
#          GDD «Win, fail, restart»: «слотом rewarded-revive (скрыт флагом до v1.1)»).
#          Кнопка существует в сцене (y 552…616), но visible = false и включается ТОЛЬКО
#          LevelController по Ads.is_available() (флаг ads_enabled, сейчас всегда false) — при
#          выключенном флаге она не участвует ни в раскладке, ни в тапе. Тап по ней зовёт
#          Ads.show_rewarded(Ads.REVIVE, …) — заглушка ничего не делает и возвращает false
#          (награды нет), поэтому забег не продолжается.
#          Снабжение/рекорд сюда приходят готовыми из LevelController: экран сам на диск не ходит.
#          ALWAYS: экран показывается уже после get_tree().paused = true (см. _finish_run).
# Dependencies: Label-узлы scenes/main.tscn (Title, ResultLine, ScoreLine, RecordLine),
#               кнопки ReviveButton (скрытая) / ReplayButton / CampaignButton / HomeButton,
#               MissionData (M10 — тексты кампанийного исхода), WinOverlay.format_record,
#               Ads (заглушка rewarded).
# Author: Mechanics Developer Agent (M1), UI/UX Agent (M6.3b: итоги endless; M10: тексты миссий;
#         M11/T3: кнопки исхода и удаление подсказок), Mechanics Developer Agent (M8b: слот revive)

class_name DeathOverlay
extends Control

## M11/T3: игрок нажал «Повторить» — рестарт ТОГО ЖЕ режима (кампания → start_level той же
## миссии, endless → start_endless).
signal replay_requested
## M11/T3: игрок нажал «Кампания» — выход из исхода в выбор миссии.
signal campaign_requested
## M11/T3: игрок нажал «В ангар» — выход на домашний экран (LevelController.show_home).
signal home_requested

## Заголовок кампанийного поражения (RU, player-facing). M10: это ФОЛБЭК — реальная строка
## берётся из данных миссии, а если её нет — из текста сцены (они совпадают).
const CAMPAIGN_TITLE := "Аэродром потерян"
## M8b: текст скрытого слота rewarded-revive (GDD «Монетизация» → rewarded-revive).
const REVIVE_TEXT := "Продолжить за рекламу"
## M11/T3: подписи трёх действий (RU, player-facing). Размер кнопок — 320×88 в сцене.
const REPLAY_TEXT := "Повторить"
const CAMPAIGN_TEXT := "Кампания"
const HOME_TEXT := "В ангар"
## Нижняя граница тач-таргета (AGENTS «Icons and HUD»): в сцене 88 px — с запасом.
const BUTTON_MIN_HEIGHT := 64.0

@onready var title_label: Label = $Title
## Строки итогов endless (в кампании скрыты).
@onready var result_line: Label = $ResultLine
@onready var score_line: Label = $ScoreLine
@onready var record_line: Label = $RecordLine
## M8b: скрытый слот rewarded-revive (может отсутствовать в старых сценах — гвард).
@onready var revive_button: Button = get_node_or_null(^"ReviveButton") as Button
## M11/T3: три действия исхода (могут отсутствовать в старых сценах — гвард).
@onready var replay_button: Button = get_node_or_null(^"ReplayButton") as Button
@onready var campaign_button: Button = get_node_or_null(^"CampaignButton") as Button
@onready var home_button: Button = get_node_or_null(^"HomeButton") as Button

## M6.3b: показывается ли сейчас endless-вид (QA/тесты).
var _endless_view: bool = false
## M10: id миссии, чьи тексты поражения сейчас на экране ("" — тексты сцены).
var _mission_id: String = ""
## M10: заголовок сцены на момент _ready — фолбэк, если в данных миссии пусто.
var _default_title: String = ""
## M8b: латч одного нажатия revive (desktop: emulate_touch_from_mouse даёт touch + mouse).
var _revive_latched: bool = false
## M11/T3: по латчу на КАЖДУЮ кнопку исхода (как в pause_overlay.gd): touch и Button.pressed
## одного тапа не должны дать два запроса. Сброс — при каждом показе экрана.
var _replay_latched: bool = false
var _campaign_latched: bool = false
var _home_latched: bool = false
## Снимок последнего endless-исхода (живёт после hide_overlay — как у WinOverlay).
var endless_score: int = 0
var endless_wave: int = 0
var endless_best: int = 0
var endless_is_new: bool = false


func _ready() -> void:
	# ALWAYS: экран живёт поверх паузы (дерево уже заморожено в момент показа).
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# M10: текст сцены запоминаем ДО первого hide_overlay() — это фолбэк миссии без данных.
	_default_title = String(title_label.text)
	_apply_campaign_view()
	_setup_revive_button()
	_setup_action_buttons()
	hide_overlay()


## M10: тексты поражения по миссии («Переправа потеряна» / «Город потерян»). Пустой id, нет
## данных или пустая строка в данных → текст сцены («Аэродром потерян»).
func set_mission(id: String) -> void:
	_mission_id = id
	_apply_campaign_view()


## QA/тесты: id миссии, чьи тексты сейчас в кампанийном виде ("" — тексты сцены).
func get_mission_id() -> String:
	return _mission_id


## Кампанийное поражение: заголовок миссии + три действия, строки итогов endless скрыты.
## Возвращает экран в кампанийный вид и после endless.
func show_overlay() -> void:
	_apply_campaign_view()
	set_action_buttons_visible(true)
	visible = true


## M6.3b: итоги бесконечного забега. score/wave — результат забега, best/is_new — рекорд
## из SaveGame.record_endless (новичок → «Новый рекорд: Y», иначе «Рекорд: Y»).
func show_endless_result(score: int, wave: int, best: int, is_new: bool) -> void:
	endless_score = maxi(0, score)
	endless_wave = maxi(0, wave)
	endless_best = maxi(0, best)
	endless_is_new = is_new
	# M10: сначала кампанийный вид — он гасит строки итогов; затем заголовок ПРИНУДИТЕЛЬНО
	# возвращается к тексту сцены («Аэродром потерян»). Иначе после забега m3 экран endless
	# говорил бы «Город потерян»: id миссии переживает старт endless.
	_apply_campaign_view()
	title_label.text = _default_title
	_endless_view = true
	result_line.text = "Бесконечный: волна %d" % endless_wave
	score_line.text = "Счёт: %d" % endless_score
	record_line.text = WinOverlay.format_record(endless_best, endless_is_new)
	# Рекорд подсвечивается жёлтым (ArtStyle.BULLET_ENEMY), обычный рекорд — кремовым.
	record_line.add_theme_color_override(&"font_color",
		Color(1.0, 0.819608, 0.4, 1.0) if endless_is_new else Color(0.85098, 0.823529, 0.764706, 0.92))
	result_line.visible = true
	score_line.visible = true
	record_line.visible = true
	set_action_buttons_visible(true)
	visible = true


func hide_overlay() -> void:
	visible = false
	# M8b: слот revive не переживает скрытие: следующий показ снова решает LevelController.
	set_revive_available(false)
	# M11/T3: кнопки исхода не переживают скрытие — их включает следующий показ.
	set_action_buttons_visible(false)


# ─── M11/T3: три действия экрана поражения ──────────────────────────────────
## Показать/скрыть три кнопки исхода. Единственные вызывающие — show_overlay(),
## show_endless_result() и hide_overlay(): скрытая кнопка не участвует ни в раскладке,
## ни в тапе. Каждый показ/скрытие чистит латчи (как PauseOverlay.show_overlay()).
func set_action_buttons_visible(show_buttons: bool) -> void:
	for button: Button in [replay_button, campaign_button, home_button]:
		if button != null:
			button.visible = show_buttons
	_reset_action_latches()


## QA/тесты: сколько кнопок исхода реально видно (0 — оверлей скрыт или сцена без кнопок).
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


# ─── M8b: скрытый слот rewarded-revive ──────────────────────────────────────
## Включить/выключить кнопку «Продолжить за рекламу». Единственный вызывающий —
## LevelController (visible = Ads.is_available()), поэтому сейчас кнопка всегда скрыта.
func set_revive_available(available: bool) -> void:
	if revive_button == null:
		return
	revive_button.visible = available
	_revive_latched = false


func is_revive_visible() -> bool:
	return revive_button != null and revive_button.visible


func get_revive_text() -> String:
	return String(revive_button.text) if revive_button != null else ""


## Тап по слоту (и путь QA/тестов). Заглушка Ads всегда возвращает false: продолжения нет,
## забег остаётся на экране поражения (тап-шорткатов в игре нет — M11/T2).
func tap_revive() -> bool:
	if not is_revive_visible():
		return false
	return Ads.show_rewarded(Ads.REVIVE, Callable())


## QA/тесты: текущий вид — endless (true) или кампания (false).
func is_endless_view() -> bool:
	return _endless_view


## QA/тесты: текст строки волны ("" — строка скрыта в кампанийном виде).
func get_result_text() -> String:
	return String(result_line.text) if result_line.visible else ""


func get_score_text() -> String:
	return String(score_line.text) if score_line.visible else ""


func get_record_text() -> String:
	return String(record_line.text) if record_line.visible else ""


# ─── Внутреннее ─────────────────────────────────────────────────────────────
## M8b: настройка скрытого слота revive. Кнопка в сцене, но по умолчанию скрыта; ввод —
## gui_input (Android touch) + pressed (desktop), с латчем от двойного срабатывания.
func _setup_revive_button() -> void:
	if revive_button == null:
		return
	revive_button.text = REVIVE_TEXT
	revive_button.visible = false
	revive_button.focus_mode = Control.FOCUS_NONE
	revive_button.gui_input.connect(_on_revive_gui_input)
	revive_button.pressed.connect(_on_revive_pressed)


func _on_revive_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	# Тап по кнопке не уходит дальше по дереву: касание по слоту не должно срабатывать
	# чужим действием. Скрытая кнопка событий не получает.
	revive_button.accept_event()
	if touch.pressed:
		_on_revive_pressed()


func _on_revive_pressed() -> void:
	if _revive_latched or not is_revive_visible():
		return
	_revive_latched = true
	tap_revive()


## M11/T3: кнопки исхода в сцене скрыты; ввод — gui_input (Android touch) + pressed (desktop),
## у каждой кнопки свой латч. Подписи ставятся здесь, чтобы текст жил в одном месте.
func _setup_action_buttons() -> void:
	var pairs: Array = [
		[replay_button, REPLAY_TEXT, _on_replay_gui_input, request_replay],
		[campaign_button, CAMPAIGN_TEXT, _on_campaign_gui_input, request_campaign],
		[home_button, HOME_TEXT, _on_home_gui_input, request_home],
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


## Общий путь касания кнопки исхода: press → ровно один запрос (латч ставит сам request_*),
## отпускание только гасит событие, чтобы тап не ушёл в дерево. Латч здесь НЕ занимается —
## двойной захват делал кнопки мёртвыми (баг M11/T1 на экране победы).
func _route_action_touch(event: InputEvent, button: Button, request: Callable) -> void:
	if not (event is InputEventScreenTouch) or button == null:
		return
	var touch := event as InputEventScreenTouch
	button.accept_event()
	if touch.pressed:
		request.call()


## Чистое состояние ввода на показ/скрытие экрана: латчи прошлого исхода не должны оставить
## кнопки «мёртвыми».
func _reset_action_latches() -> void:
	_replay_latched = false
	_campaign_latched = false
	_home_latched = false


## Кампанийный вид: строки итогов скрыты, заголовок — из данных миссии (M10),
## пусто → текст сцены.
func _apply_campaign_view() -> void:
	_endless_view = false
	result_line.visible = false
	score_line.visible = false
	record_line.visible = false
	var lose_title := MissionData.get_result_lose_title(_mission_id)
	title_label.text = lose_title if not lose_title.is_empty() else _default_title
