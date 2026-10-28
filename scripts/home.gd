# home.gd
# Purpose: Домашний экран-хаб (M8c1; GDD «First 30 seconds», п.1: «Главный экран — ангар:
#          самолёт по центру, снизу «Кампания», «Бесконечный», «Ангар», «Настройки»;
#          «Бесконечный» заблокирован до первого прохождения», плюс GDD «Оболочка»).
#          Полноэкранный оверлей поверх фона: заголовок игры «WW2 Air Battles» (M10, bug 4:
#          «Оборона аэродрома» — заголовок миссии 1 и остаётся только на брифинге; подзаголовка
#          нет по решению владельца), превью выбранного самолёта (ShipVisual 2× с ливреей-тинтом
#          на плашке цвета неба), имя самолёта, «Звёзды: X/9», «Снабжение: N» и четыре кнопки
#          320×88 (тач-минимум 64 px).
#          M10 (bug 2): подсказки «Откроется после прохождения кампании» на Home БОЛЬШЕ НЕТ —
#          владелец: текст стоял под «Кампанией», читался как условие кампании и путал.
#          Сообщение об открытии режима теперь на экране победы в момент открытия гейта
#          (WinOverlay.set_unlock_notice, см. level_controller._log_unlocks).
#          Экран НИЧЕГО не запускает сам: он только эмитит сигналы, а решения (какой экран
#          открыть, стартовать ли endless, куда возвращаться) принимает LevelController —
#          поэтому Home не знает ни про брифинг, ни про MissionSelect/Hangar/Settings.
#          Профиль читается ТОЛЬКО в refresh() при показе/после действия, не в _process:
#          SaveGame каждый раз читает файл, в кадровом цикле это недопустимо.
#          Ввод — как в hangar.gd: root/Dim MOUSE_FILTER_IGNORE, интерактив STOP; touch
#          ловится через gui_input + Button.pressed с латчем от двойного срабатывания
#          (на десктопе emulate_touch_from_mouse=true даёт и touch-, и mouse-событие).
#          process_mode = ALWAYS: экран открывается из BRIEFING и не должен «зависнуть»,
#          если дерево окажется на паузе.
# Dependencies: SaveGame (снабжение, звёзды, самолёт, ливрея, гейт endless), PlaneData (имя
#               и ключ арта самолёта), ArtStyle (палитра + LIVERY_TINTS), ShipVisual (превью),
#               assets/ui_theme.tres (Noto Sans + TitleLabel). Обратных зависимостей нет.
# Author: UI/UX Agent (M8c1)
#
# QA/тесты (публичный API):
#   refresh()                       перечитать профиль и перерисовать превью/строки/гейт
#   is_endless_enabled()            открыт ли бесконечный режим (кэш последнего refresh)
#   get_stars_text()                «Звёзды: X/9»
#   get_supply_text()               «Снабжение: N»
#   get_plane_name()                имя самолёта в строке превью
#   get_visible_button_count()      сколько кнопок реально видно (4)
#   request_campaign()/request_endless()/request_hangar()/request_settings() -> bool
#                                   один эмит на касание; endless по закрытому гейту — false

class_name Home
extends Control

## «Кампания»: LevelController открывает выбор миссии (MissionSelect).
signal campaign_requested
## «Бесконечный»: LevelController запускает endless-забег. Эмитится ТОЛЬКО при открытом
## режиме — закрытая кнопка disabled, и запрос дополнительно гасит гейт.
signal endless_requested
## «Ангар»: LevelController открывает экран ангара (самолёт/ливрея).
signal hangar_requested
## «Настройки»: LevelController открывает экран настроек.
signal settings_requested

## Сколько суммарных звёзд кампании показываем в строке «Звёзды: X/9»
## (3 миссии × 3 звезды, GDD «Счёт, звёзды, снабжение»).
const MAX_CAMPAIGN_STARS := 9

## Кнопки главного экрана: 320×88 — выше тач-минимума 64 px (AGENTS «Icons and HUD»).
const BUTTON_MIN_SIZE := Vector2(320.0, 88.0)

## Превью самолёта: пиксель-арт не масштабируем дробно (AGENTS «Art pipeline»), 64×64 → 128×128
## внутри панели 492×128 — как в ангаре.
const PREVIEW_SCALE := 2.0

## Подсказка закрытого endless на Home удалена (M10, bug 2): владелец попросил убрать её
## отсюда — текст стоял под «Кампанией» и путал. Сообщение об открытии режима показывает
## экран победы (WinOverlay.set_unlock_notice) в момент открытия гейта.

@onready var title_label: Label = $Title
@onready var preview_panel: PanelContainer = $PreviewPanel
@onready var preview: ShipVisual = $PreviewPanel/Preview
@onready var plane_name_label: Label = $PlaneName
@onready var stars_line: Label = $StarsLine
@onready var supply_line: Label = $SupplyLine
@onready var campaign_button: Button = $Buttons/CampaignButton
@onready var endless_button: Button = $Buttons/EndlessButton
@onready var hangar_button: Button = $Buttons/HangarButton
@onready var settings_button: Button = $Buttons/SettingsButton

## Латчи одного касания на кнопку: на Android приходит только InputEventScreenTouch,
## на десктопе emulate_touch_from_mouse даёт и touch, и mouse-событие. Без латча один
## тап открыл бы два экрана / запустил режим дважды. Снимаются в refresh()/show_overlay().
var _campaign_latched: bool = false
var _endless_latched: bool = false
var _hangar_latched: bool = false
var _settings_latched: bool = false
## Кэш гейта бесконечного режима (SaveGame.is_endless_unlocked). Пишется только refresh():
## файл профиля читается по событию, не каждый кадр.
var _endless_enabled: bool = false


func _ready() -> void:
	# ALWAYS: экран открывается из BRIEFING, но не должен «зависнуть», если дерево на паузе.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Основной путь Android: touch приходит только как InputEventScreenTouch
	# (emulate_mouse_from_touch выключен в project.godot), поэтому кнопки слушаем через gui_input.
	campaign_button.gui_input.connect(_on_campaign_gui_input)
	campaign_button.pressed.connect(request_campaign)
	endless_button.gui_input.connect(_on_endless_gui_input)
	endless_button.pressed.connect(request_endless)
	hangar_button.gui_input.connect(_on_hangar_gui_input)
	hangar_button.pressed.connect(request_hangar)
	settings_button.gui_input.connect(_on_settings_gui_input)
	settings_button.pressed.connect(request_settings)
	preview_panel.resized.connect(_center_preview)
	_center_preview()
	refresh()
	hide_overlay()


# ─── Жизненный цикл ─────────────────────────────────────────────────────────
func show_overlay() -> void:
	refresh()
	visible = true


func hide_overlay() -> void:
	visible = false


## Перечитать профиль (звёзды, снабжение, самолёт, ливрея, гейт endless) и перерисовать экран.
## Единственное место, где UI трогает SaveGame: _process профиль не читает.
func refresh() -> void:
	if not is_node_ready():
		return
	_campaign_latched = false
	_endless_latched = false
	_hangar_latched = false
	_settings_latched = false
	var supply := SaveGame.get_supply()
	var total_stars := SaveGame.total_stars()
	var selected_plane := SaveGame.get_selected_plane()
	var selected_livery := SaveGame.get_selected_livery()

	stars_line.text = format_stars(total_stars)
	supply_line.text = format_supply(supply)
	plane_name_label.text = plane_name_for(selected_plane)
	_refresh_preview(selected_plane, selected_livery)
	_refresh_endless_gate()


# ─── Публичный API (LevelController + QA) ───────────────────────────────────
## Открыт ли бесконечный режим (кэш последнего refresh(); GDD: после прохождения кампании).
func is_endless_enabled() -> bool:
	return _endless_enabled


func get_stars_text() -> String:
	return String(stars_line.text)


func get_supply_text() -> String:
	return String(supply_line.text)


func get_plane_name() -> String:
	return String(plane_name_label.text)


## Сколько кнопок реально видно (QA: 4 при живых данных — все четыре всегда в разметке).
func get_visible_button_count() -> int:
	var count := 0
	for button: Button in [campaign_button, endless_button, hangar_button, settings_button]:
		if button != null and button.visible:
			count += 1
	return count


## «Кампания» — единственная точка эмита campaign_requested (латч на касание).
func request_campaign() -> bool:
	if _campaign_latched:
		return false
	_campaign_latched = true
	campaign_requested.emit()
	return true


## «Бесконечный» — эмит только при открытом гейте: программный запрос по закрытому профилю
## режим не запускает (тот же двойной гейт, что у кнопки брифинга).
func request_endless() -> bool:
	if _endless_latched or not _endless_enabled:
		return false
	_endless_latched = true
	endless_requested.emit()
	return true


func request_hangar() -> bool:
	if _hangar_latched:
		return false
	_hangar_latched = true
	hangar_requested.emit()
	return true


func request_settings() -> bool:
	if _settings_latched:
		return false
	_settings_latched = true
	settings_requested.emit()
	return true


# ─── Форматирование (RU) ────────────────────────────────────────────────────
## «Снабжение: N» — та же строка, что на брифинге/в выборе миссии/ангаре.
static func format_supply(supply: int) -> String:
	return "Снабжение: %d" % maxi(0, supply)


## «Звёзды: X/9» — суммарные звёзды кампании.
static func format_stars(total: int) -> String:
	return "Звёзды: %d/%d" % [clampi(total, 0, MAX_CAMPAIGN_STARS), MAX_CAMPAIGN_STARS]


## Имя самолёта из data/planes.json; пустое/неизвестное — сам id (экран не должен пустовать).
static func plane_name_for(id: String) -> String:
	var plane_name := PlaneData.get_plane_name(id)
	return plane_name if not plane_name.is_empty() else id


# ─── Ввод ───────────────────────────────────────────────────────────────────
func _on_campaign_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	campaign_button.accept_event()  # тап по кнопке не уходит в мир/фон
	if touch.pressed:
		request_campaign()


func _on_endless_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	endless_button.accept_event()
	if touch.pressed:
		request_endless()


func _on_hangar_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	hangar_button.accept_event()
	if touch.pressed:
		request_hangar()


func _on_settings_gui_input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	settings_button.accept_event()
	if touch.pressed:
		request_settings()


# ─── Гейт бесконечного режима ───────────────────────────────────────────────
## Привести кнопку «Бесконечный» и подсказку к актуальному профилю. Вызывается только из
## refresh(): SaveGame читает файл — в _process ему нельзя.
func _refresh_endless_gate() -> void:
	_endless_enabled = SaveGame.is_endless_unlocked()
	endless_button.disabled = not _endless_enabled
	# Приглушение: у disabled-кнопки свой цвет шрифта, но и сама плашка не должна выглядеть
	# доступной — alpha 0.6 отличает «замок» от обычной второстепенной кнопки.
	endless_button.modulate = Color(1.0, 1.0, 1.0, 1.0 if _endless_enabled else 0.6)


# ─── Превью ─────────────────────────────────────────────────────────────────
## Превью выбранного самолёта: ключ арта из PlaneData + тинт ливреи. ShipVisual живёт
## внутри Node2D-панели (контейнеры не раскладывают Node2D), поэтому центр считаем сами.
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
