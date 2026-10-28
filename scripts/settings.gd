# settings.gd
# Purpose: Экран настроек (M8a; GDD «Оболочка»: «Настройки: звук, вибрация, сброс прогресса
#          (с подтверждением), «О игре» + лицензии, версия»).
#          Полноэкранный оверлей поверх брифинга: заголовок «Настройки», две строки-переключателя
#          («Звук», «Вибрация» — вся строка 492×96, тап-минимум 64 px), строка «Сбросить
#          прогресс» в danger-стиле (первый тап — «Подтвердить сброс?», второй — сброс),
#          блок «О игре» (версия, Noto Sans OFL, SpriteCook) и «Назад» 320×88.
#          Значения звука/вибрации читаются и пишутся ТОЛЬКО через SaveGame.get_setting()/
#          set_setting() (секция [settings] сейва v2), по умолчанию — включено.
#          Звук применяется сразу: Settings зовёт AudioManager.set_muted(not enabled), иначе
#          переключатель менял бы только файл, а музыка/SFX играли бы до перезапуска.
#          РЕШЕНИЕ M8a: «Сбросить прогресс» стирает ПРОГРЕСС (звёзды, снабжение, открытые
#          самолёты, ливреи, рекорды) и НЕ трогает настройки звука/вибрации — GDD называет
#          настройки отдельно от прогресса, а игрок, выключивший звук, не ждёт, что он
#          включится обратно. SaveGame.reset() удаляет файл целиком, поэтому значения
#          настроек снимаются ДО удаления и записываются обратно после.
#          Профиль читается только в refresh() (как в hangar/mission_select), не в _process:
#          SaveGame каждый раз читает файл, в кадровом цикле это недопустимо.
#          Ввод — как в hangar/mission_select: root/Dim MOUSE_FILTER_IGNORE, интерактив STOP,
#          touch ловится через gui_input + Button.pressed. Латч «одного нажатия» снимается
#          ОТПУСКАНИЕМ пальца (страховка — окно TAP_DEBOUNCE_MS): раньше он снимался только
#          в refresh()/show_overlay(), а на Android отпускание не приходит как mouse-release —
#          после первого же действия экран мог замереть для тапов.
#          process_mode = ALWAYS: экран открывается из BRIEFING и не должен «зависнуть»,
#          если дерево окажется на паузе.
#          M8b: переключатели дополнительно пишут локальное событие settings_change
#          (Analytics, без PII) — других изменений в поведении настроек нет.
# Dependencies: SaveGame (настройки + сброс профиля), AudioManager (set_muted — звук сразу),
#               Analytics (M8b — событие смены настройки), assets/ui_theme.tres (Noto Sans +
#               TitleLabel), ArtStyle (палитра).
#               Обратных зависимостей нет: LevelController зовёт Settings, не наоборот.
# Author: UI/UX Agent (M8a)
#
# QA/тесты (публичный API):
#   refresh()                      перечитать настройки и перерисовать строки (снимает подтверждение)
#   is_sound_enabled()             текущее значение из профиля
#   is_vibration_enabled()         текущее значение из профиля
#   toggle_sound() -> bool         переключить и записать; возвращает НОВОЕ значение
#   toggle_vibration() -> bool     то же для вибрации
#   get_sound_text()/get_vibration_text()        «Вкл» / «Выкл» в строке
#   request_reset() -> bool        тап по сбросу: false — включил подтверждение, true — стёр профиль
#   is_reset_confirm_visible()     виден ли вопрос «Подтвердить сброс?»
#   get_reset_status_text()/is_reset_status_visible()   «Прогресс сброшен»
#   get_version_text()             «Версия 1.0.0»
#   is_reset_armed()               ждёт ли сброс второго тапа
#   is_tap_available()             жив ли ввод: false — латч касания ещё держится (QA)

class_name Settings
extends Control

## Игрок нажал «Назад» — LevelController возвращает брифинг текущей миссии.
signal closed
## Прогресс стёрт (M8a). LevelController обновляет зависящий от профиля UI: гейт endless
## в брифинге и выбранную миссию (после сброса m2/m3 снова закрыты).
signal progress_reset

## Версия игры в «О игре». Держать в синхроне с export_presets.cfg (version/name="1.0.0"):
## единого ProjectSettings-ключа версии в проекте нет, константа — единственный источник.
const GAME_VERSION := "1.0.0"

## Тач-минимум Android — 64 px. Строка настроек выше (96), но это же значение —
## нижняя граница для кнопки «Назад» и проверка теста.
const ROW_MIN_SIZE := Vector2(492.0, 96.0)
const ROW_CONTENT_MARGIN := 16.0
const ROW_LABEL_FONT_SIZE := 28
const ROW_STATE_FONT_SIZE := 24

## Яркий вариант danger-цвета для вооружённого сброса: ArtStyle.DANGER #B23A2E на тёмной
## плашке даёт контраст ≈2.5:1 (мало даже для крупного текста), поэтому в состоянии
## подтверждения берём осветлённый тон (≈4.4:1). В обычном состоянии красный — только контур.
const DANGER_BRIGHT := Color("d06a57")

## Тексты (RU, player-facing; GDD: все строки в одном месте под будущий перевод).
const TEXT_ON := "Вкл"
const TEXT_OFF := "Выкл"
const TEXT_RESET_ROW := "Сбросить прогресс"
const TEXT_RESET := "Сбросить"
const TEXT_RESET_ARMED := "Ещё раз"
const TEXT_RESET_CONFIRM := "Подтвердить сброс?"
const TEXT_RESET_DONE := "Прогресс сброшен"
const TEXT_ABOUT := "О игре"
const TEXT_VERSION_PREFIX := "Версия"
const TEXT_CREDITS_FONT := "Шрифт: Noto Sans (OFL)"
const TEXT_CREDITS_ART := "Арт: SpriteCook"

const SETTING_SOUND := "sound"
const SETTING_VIBRATION := "vibration"

@onready var sound_row: PanelContainer = $SoundRow
@onready var sound_name: Label = $SoundRow/Inner/Label
@onready var sound_state: Label = $SoundRow/Inner/StateLabel
@onready var vibration_row: PanelContainer = $VibrationRow
@onready var vibration_name: Label = $VibrationRow/Inner/Label
@onready var vibration_state: Label = $VibrationRow/Inner/StateLabel
@onready var reset_row: PanelContainer = $ResetRow
@onready var reset_name: Label = $ResetRow/Inner/Label
@onready var reset_state: Label = $ResetRow/Inner/StateLabel
@onready var reset_confirm: Label = $ResetConfirm
@onready var reset_status: Label = $ResetStatus
@onready var about_title: Label = $AboutTitle
@onready var version_line: Label = $VersionLine
@onready var credits_font: Label = $CreditsFont
@onready var credits_art: Label = $CreditsArt
@onready var back_button: Button = $BackButton

## Латч одного касания. Android присылает только InputEventScreenTouch
## (emulate_mouse_from_touch в проекте выключен), поэтому отпускание не превращается в
## mouse-release; на десктопе emulate_touch_from_mouse, наоборот, даёт и touch-, и mouse.
## Латч живёт ровно до отпускания (и не дольше TAP_DEBOUNCE_MS) — экран не «зависает».
const TAP_DEBOUNCE_MS := 250
## Время последнего touch-события (нажатие ИЛИ отпускание) — окно дебаунса mouse-пути.
var _last_touch_msec: int = -TAP_DEBOUNCE_MS
## Запрос уже сделан нажатием текущего касания; снимается отпусканием.
var _tap_claimed: bool = false
## Когда запрос был занят — страховка, если отпускание не дошло до узла.
var _tap_claimed_msec: int = -TAP_DEBOUNCE_MS
## Сброс вооружён первым тапом и ждёт второго (подтверждения).
var _reset_armed: bool = false


func _ready() -> void:
	# ALWAYS: экран открывается из BRIEFING, но не должен «зависнуть», если дерево на паузе.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	sound_row.gui_input.connect(_on_sound_row_gui_input)
	vibration_row.gui_input.connect(_on_vibration_row_gui_input)
	reset_row.gui_input.connect(_on_reset_row_gui_input)
	back_button.gui_input.connect(_on_back_button_gui_input)
	back_button.pressed.connect(_on_back_button_pressed)
	refresh()
	hide_overlay()


# ─── Жизненный цикл ─────────────────────────────────────────────────────────
func show_overlay() -> void:
	# Новый показ — чистое состояние ввода: даже если предыдущее касание «потерялось»
	# (палец ушёл за пределы строки), первый тап по экрану сработает.
	_release_tap()
	_last_touch_msec = -TAP_DEBOUNCE_MS
	refresh()
	visible = true


func hide_overlay() -> void:
	visible = false


## Перечитать настройки из профиля и перерисовать строки. Единственное место, где UI трогает
## SaveGame (не в _process). Подтверждение сброса и строка «Прогресс сброшен» снимаются:
## после перечитывания профиля они не соответствуют тому, что видит игрок.
func refresh() -> void:
	if not is_node_ready():
		return
	_reset_armed = false
	_refresh_row(sound_row, sound_state, SaveGame.get_setting(SETTING_SOUND))
	_refresh_row(vibration_row, vibration_state, SaveGame.get_setting(SETTING_VIBRATION))
	_refresh_reset_row()
	reset_confirm.visible = false
	reset_confirm.text = TEXT_RESET_CONFIRM
	reset_status.visible = false
	reset_status.text = TEXT_RESET_DONE
	about_title.text = TEXT_ABOUT
	version_line.text = format_version()
	credits_font.text = TEXT_CREDITS_FONT
	credits_art.text = TEXT_CREDITS_ART


# ─── Публичный API (QA/тесты) ───────────────────────────────────────────────
func is_sound_enabled() -> bool:
	return SaveGame.get_setting(SETTING_SOUND)


func is_vibration_enabled() -> bool:
	return SaveGame.get_setting(SETTING_VIBRATION)


## Переключить звук: пишет настройку в профиль и сразу применяет к AudioManager
## (set_muted(not enabled)). Возвращает НОВОЕ значение (true — звук включён).
func toggle_sound() -> bool:
	var enabled := not is_sound_enabled()
	SaveGame.set_setting(SETTING_SOUND, enabled)
	# M8b: смена настройки — локальное событие (без PII, значение bool).
	Analytics.log_event("settings_change", {"key": SETTING_SOUND, "value": enabled})
	_apply_sound(enabled)
	refresh()
	return enabled


## Переключить вибрацию. Применять нечего: LevelController читает настройку в момент
## попадания по игроку (единственное место вибрации в игре).
func toggle_vibration() -> bool:
	var enabled := not is_vibration_enabled()
	SaveGame.set_setting(SETTING_VIBRATION, enabled)
	Analytics.log_event("settings_change", {"key": SETTING_VIBRATION, "value": enabled})
	refresh()
	return enabled


## Единственный вход «сбросить прогресс» (тап по строке и QA).
## Первый вызов только вооружает кнопку (текст «Подтвердить сброс?») — false, профиль цел.
## Второй вызов стирает прогресс — true. Уход с экрана/refresh() снимают вооружение.
func request_reset() -> bool:
	if not _reset_armed:
		_reset_armed = true
		reset_confirm.visible = true
		reset_status.visible = false
		_refresh_reset_row()
		return false
	_perform_reset()
	return true


func is_reset_confirm_visible() -> bool:
	return reset_confirm != null and reset_confirm.visible


func is_reset_armed() -> bool:
	return _reset_armed


func get_reset_status_text() -> String:
	return String(reset_status.text)


func is_reset_status_visible() -> bool:
	return reset_status != null and reset_status.visible


func get_sound_text() -> String:
	return String(sound_state.text)


func get_vibration_text() -> String:
	return String(vibration_state.text)


func get_version_text() -> String:
	return String(version_line.text)


## «Версия 1.0.0» (M8a: версия в «О игре», GDD «Оболочка»).
static func format_version() -> String:
	return "%s %s" % [TEXT_VERSION_PREFIX, GAME_VERSION]


# ─── Ввод ───────────────────────────────────────────────────────────────────
## Основной путь Android: touch приходит только как InputEventScreenTouch
## (emulate_mouse_from_touch выключен), поэтому строки-переключатели слушаем через gui_input.
func _on_sound_row_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	sound_row.accept_event()  # тап по строке не уходит в брифинг/мир
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	if _claim_tap():
		toggle_sound()


func _on_vibration_row_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	vibration_row.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	if _claim_tap():
		toggle_vibration()


func _on_reset_row_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	reset_row.accept_event()
	_note_touch()
	if not touch.pressed:
		_release_tap()
		return
	if _claim_tap():
		request_reset()


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
## (палец ушёл за пределы строки, оверлей скрылся): теряется максимум одно касание, не ввод.
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


# ─── Сброс прогресса ────────────────────────────────────────────────────────
## Стереть прогресс, сохранив настройки звука/вибрации (решение M8a, см. заголовок файла).
## SaveGame.reset() удаляет файл профиля (путь не меняется), поэтому настройки снимаются
## до удаления, а после — записываются обратно: файл пересоздаётся с дефолтами профиля.
func _perform_reset() -> void:
	var sound := SaveGame.get_setting(SETTING_SOUND)
	var vibration := SaveGame.get_setting(SETTING_VIBRATION)
	SaveGame.reset()
	SaveGame.set_setting(SETTING_SOUND, sound)
	SaveGame.set_setting(SETTING_VIBRATION, vibration)
	refresh()
	reset_confirm.visible = false
	reset_status.text = TEXT_RESET_DONE
	reset_status.visible = true
	progress_reset.emit()


# ─── Применение звука ───────────────────────────────────────────────────────
## AudioManager живёт в Level (main.tscn) рядом с CanvasLayer UI, поэтому ищем его подъёмом
## по родителям: Settings → UI → Level → Audio. В изолированном инстансе (тест оверлея
## без уровня) менеджера нет — настройка всё равно пишется, вызов молча пропускается.
func _audio_manager() -> AudioManager:
	var node: Node = self
	while node != null:
		var audio := node.get_node_or_null(^"Audio") as AudioManager
		if audio != null:
			return audio
		node = node.get_parent()
	return null


func _apply_sound(enabled: bool) -> void:
	var audio := _audio_manager()
	if audio == null:
		return
	audio.set_muted(not enabled)


# ─── Отрисовка строк ────────────────────────────────────────────────────────
func _refresh_row(row: PanelContainer, state_label: Label, enabled: bool) -> void:
	if row == null or state_label == null:
		return
	state_label.text = TEXT_ON if enabled else TEXT_OFF
	# «Выкл» — не ошибка, а выключенное состояние: кремовый приглушается, а не краснеет.
	state_label.add_theme_color_override("font_color",
		ArtStyle.CREAM if enabled else Color(ArtStyle.CREAM, 0.55))
	row.add_theme_stylebox_override("panel", _row_style(false, false))


func _refresh_reset_row() -> void:
	if reset_row == null:
		return
	reset_name.text = TEXT_RESET_ROW
	reset_state.text = TEXT_RESET_ARMED if _reset_armed else TEXT_RESET
	reset_state.add_theme_color_override("font_color",
		DANGER_BRIGHT if _reset_armed else Color(ArtStyle.CREAM, 0.8))
	reset_row.add_theme_stylebox_override("panel", _row_style(true, _reset_armed))


# ─── Стили (палитра ArtStyle, без SpriteCook — UI остаётся векторным) ────────
## Строка настроек: тёмная плашка + кремовый контур; danger-строка — красный контур
## (#B23A2E, при вооружении ярче и толще). Контур один по толщине у всех состояний,
## чтобы подпись не «прыгала» на пиксель при подтверждении.
func _row_style(danger: bool, armed: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.129412, 0.141176, 0.109804, 0.94)
	if danger:
		style.border_color = DANGER_BRIGHT if armed else Color(ArtStyle.DANGER, 0.9)
	else:
		style.border_color = Color(ArtStyle.CREAM, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(ROW_CONTENT_MARGIN)
	return style
