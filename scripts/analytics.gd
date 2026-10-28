# analytics.gd
# Purpose: Локальная аналитика (M8b; GDD «Монетизация (заложена, не включена)» →
#          «Аналитика: локальные события (старт, миссия, волна смерти, перк, босс, endless,
#          анлок) в debug-лог; внешний SDK — v1.1»).
#          Только запись в ЛОКАЛЬНЫЙ файл: никаких сетевых вызовов, SDK, device id, аккаунтов
#          и PII. Формат — JSONL (одно событие на строку):
#              {"ts": <msec с запуска процесса>, "event": "...", <поля события>}
#          Файл по умолчанию user://analytics.log, режим append (FileAccess.READ_WRITE + seek
#          в конец). Ошибки файла (нет user://, read-only, переполнение) НЕ роняют игру и НЕ
#          пишут push_error: потеря аналитики — приемлемая цена, падение забега — нет.
#          В памяти держится буфер последних MAX_EVENTS событий (QA/тесты + будущий экран
#          «диагностика»); буфер не растёт бесконечно.
#          set_enabled(false) полностью выключает сбор: ни файла, ни буфера.
# Dependencies: нет (RefCounted-утилита; FileAccess/JSON — движок). Обратных зависимостей нет:
#               LevelController/Settings зовут Analytics.log_event(), не наоборот.
# Author: Mechanics Developer Agent (M8b)
#
# API (всё статическое; инстансы не нужны):
#   log_event(name, data = {})   записать событие (пустое имя игнорируется)
#   get_events() -> Array[Dictionary]   копия буфера (последние MAX_EVENTS)
#   clear()                      очистить буфер (файл не трогается)
#   set_enabled(enabled)/is_enabled()   выключенная аналитика не пишет и не копит
#   set_sink_path(path)/reset_sink_path()/get_sink_path()   QA: изоляция в user://qa_*.log
#
# Выключена по умолчанию? На устройстве/в редакторе — включена (GDD: локальный лог нужен и
# в релизе). В headless (CI, QA-прогоны) — выключена: иначе каждый тест, создающий main.tscn,
# дописывал бы реальный user://analytics.log. Тесты, которым аналитика нужна, зовут
# set_enabled(true) (или set_enabled(false), если нужна тишина) — это переопределяет дефолт.

class_name Analytics
extends RefCounted

## Сколько последних событий держим в памяти. Больше не нужно: это диагностика, а не БД.
const MAX_EVENTS := 200
## Путь по умолчанию (GDD «Аналитика»: локальный лог). QA подменяет его на user://qa_*.log.
const DEFAULT_SINK_PATH := "user://analytics.log"
## Потолок файла: 512 KB (тысячи событий). Дальше лог пересоздаётся с нуля — иначе файл на
## телефоне растёт без границы, а аналитика v1 никуда не отправляется и не чистится.
const MAX_LOG_BYTES := 512 * 1024

## Выключенная аналитика не пишет ни в файл, ни в буфер.
static var _enabled: bool = true
## Решён ли дефолт (ленивый: DisplayServer точно жив, когда приходит первое событие).
static var _default_resolved: bool = false
static var _sink_path: String = DEFAULT_SINK_PATH
static var _events: Array[Dictionary] = []


# ─── Включение/выключение ───────────────────────────────────────────────────
## Явный вызов переопределяет дефолт «включено на устройстве / выключено в headless».
static func set_enabled(enabled: bool) -> void:
	_default_resolved = true
	_enabled = enabled


static func is_enabled() -> bool:
	_resolve_default()
	return _enabled


## Дефолт по платформе: headless (CI, `godot --headless`) аналитику не пишет — иначе тесты,
## создающие main.tscn, засоряли бы реальный user://analytics.log.
static func _resolve_default() -> void:
	if _default_resolved:
		return
	_default_resolved = true
	_enabled = DisplayServer.get_name() != "headless"


# ─── Путь приёмника (QA/тесты) ──────────────────────────────────────────────
## Подменить файл лога. Пустая строка — вернуться к пути по умолчанию (не «писать в никуда»).
static func set_sink_path(path: String) -> void:
	var trimmed := path.strip_edges()
	_sink_path = DEFAULT_SINK_PATH if trimmed.is_empty() else trimmed


static func reset_sink_path() -> void:
	_sink_path = DEFAULT_SINK_PATH


static func get_sink_path() -> String:
	return _sink_path


# ─── События ────────────────────────────────────────────────────────────────
## Записать событие. data — только плоские поля (число/bool/строка): вложенные структуры
## заменяются строкой, чтобы лог оставался однострочным JSONL.
## Ошибки записи глушатся: аналитика не имеет права ломать забег.
static func log_event(name: String, data: Dictionary = {}) -> void:
	_resolve_default()
	if not _enabled:
		return
	var event_name := name.strip_edges()
	if event_name.is_empty():
		return
	var event := {
		"ts": Time.get_ticks_msec(),
		"event": event_name,
	}
	for key in data:
		event[str(key)] = _plain_value(data[key])
	_remember(event)
	_append(event)


## Копия буфера (последние MAX_EVENTS событий). Копия намеренная: вызывающий не должен
## менять внутреннее состояние аналитики.
static func get_events() -> Array[Dictionary]:
	return _events.duplicate(true)


## Очистить буфер. Файл не трогается: уже записанные строки — история, а не кэш.
static func clear() -> void:
	_events.clear()


# ─── Внутреннее ─────────────────────────────────────────────────────────────
static func _remember(event: Dictionary) -> void:
	_events.append(event)
	# Держим ПОСЛЕДНИЕ события: при переполнении выкидываем самые старые.
	while _events.size() > MAX_EVENTS:
		_events.remove_at(0)


## Дописать событие в файл. Недоступный/переполненный user:// — молча выходим.
## READ_WRITE НЕ создаёт файл (open вернёт null), поэтому первый append идёт через WRITE:
## иначе лог молча не появлялся бы до тех пор, пока кто-то другой не создаст файл.
static func _append(event: Dictionary) -> void:
	var path := _sink_path
	if path.is_empty():
		return
	var line := JSON.stringify(event)
	if line.is_empty():
		return
	_trim_if_oversized(path)
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE
	var file := FileAccess.open(path, mode)
	if file == null:
		return
	file.seek_end()
	file.store_line(line)
	file.close()


## Потолок файла: перед append смотрим длину и при переполнении пересоздаём файл (WRITE
## обнуляет). Так лог не растёт бесконечно на устройстве без сервера аналитики.
static func _trim_if_oversized(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var probe := FileAccess.open(path, FileAccess.READ)
	if probe == null:
		return
	var length := int(probe.get_length())
	probe.close()
	if length <= MAX_LOG_BYTES:
		return
	var truncate := FileAccess.open(path, FileAccess.WRITE)
	if truncate != null:
		truncate.close()


## Привести значение к плоскому виду: JSON понимает числа/строки/bool; StringName → String,
## Vector2/массивы и прочее → строка. NaN/INF отбрасываются: JSON.stringify на них ломается.
static func _plain_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			var as_float := float(value)
			return as_float if is_finite(as_float) else 0.0
		TYPE_STRING_NAME:
			return String(value)
		_:
			return str(value)
