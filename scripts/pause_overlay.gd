# pause_overlay.gd
# Purpose: Оверлей паузы (M3, кнопки — M8c1; GDD «Оболочка»: «Пауза: продолжить, заново,
#          выйти в ангар»).
#          Три кнопки 320×88 (тач-минимум 64 px): «Продолжить», «Заново», «В ангар».
#          Оверлей НЕ решает, что делать: он только эмитит resume_requested /
#          restart_requested / home_requested, а забег переключает LevelController
#          (pause_game/resume_game/start_level/start_endless/show_home).
#          M11/T2: тап ВНЕ кнопок больше ничего не делает — корень и затемнение прозрачны для
#          тапов, а LevelController._unhandled_input удалён, поэтому снять паузу можно только
#          кнопкой «Продолжить» (y 576…664). Кнопки стоят ниже центра поля, точка (270,480)
#          свободна — касание там не меняет состояние (контракт smoke-теста).
#          Ввод — как в hangar/home: touch ловится через gui_input + Button.pressed с латчем
#          (на десктопе emulate_touch_from_mouse даёт и touch-, и mouse-событие).
#          PROCESS_MODE_ALWAYS: кнопки обязаны работать при get_tree().paused = true.
#          M11/T3 (решение D4): строка-подсказка «Тап, чтобы продолжить» (узел Hint) удалена —
#          паузу снимает только кнопка «Продолжить».
# Dependencies: assets/ui_theme.tres (Noto Sans + TitleLabel), палитра ArtStyle — стили
#               зашиты в scenes/main.tscn. Обратных зависимостей нет.
# Author: Mechanics Developer Agent (M3), UI/UX Agent (M8c1 — кнопки)

class_name PauseOverlay
extends Control

## «Продолжить»: LevelController снимает паузу (resume_game).
signal resume_requested
## «Заново»: рестарт ТЕКУЩЕГО режима (кампания — start_level, endless — start_endless).
signal restart_requested
## «В ангар»: выход из забега на домашний экран (LevelController.show_home).
signal home_requested

## Нижняя граница тач-таргета (AGENTS «Icons and HUD»): кнопки в сцене 88 px.
const BUTTON_MIN_HEIGHT := 64.0

@onready var resume_button: Button = $ResumeButton
@onready var restart_button: Button = $RestartButton
@onready var home_button: Button = $HomeButton

## Латчи одного касания на кнопку: touch + Button.pressed за один тап не должны дать два
## запроса. Снимаются в show_overlay() — на новом открытии паузы кнопки снова активны.
var _resume_latched: bool = false
var _restart_latched: bool = false
var _home_latched: bool = false


func _ready() -> void:
	# ALWAYS: пауза замораживает дерево, а кнопки оверлея обязаны нажиматься.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resume_button.gui_input.connect(_on_resume_gui_input)
	resume_button.pressed.connect(request_resume)
	restart_button.gui_input.connect(_on_restart_gui_input)
	restart_button.pressed.connect(request_restart)
	home_button.gui_input.connect(_on_home_gui_input)
	home_button.pressed.connect(request_home)
	hide_overlay()


func show_overlay() -> void:
	_resume_latched = false
	_restart_latched = false
	_home_latched = false
	visible = true


func hide_overlay() -> void:
	visible = false


# ─── Публичный API (LevelController + QA) ───────────────────────────────────
func request_resume() -> bool:
	if _resume_latched:
		return false
	_resume_latched = true
	resume_requested.emit()
	return true


func request_restart() -> bool:
	if _restart_latched:
		return false
	_restart_latched = true
	restart_requested.emit()
	return true


func request_home() -> bool:
	if _home_latched:
		return false
	_home_latched = true
	home_requested.emit()
	return true


# ─── Ввод ───────────────────────────────────────────────────────────────────
func _on_resume_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	resume_button.accept_event()  # тап по кнопке не уходит дальше по дереву
	if touch.pressed:
		request_resume()


func _on_restart_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	restart_button.accept_event()
	if touch.pressed:
		request_restart()


func _on_home_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	home_button.accept_event()
	if touch.pressed:
		request_home()
