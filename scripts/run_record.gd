# run_record.gd
# Purpose: Локальный рекорд забега (GDD «Challenge and progression»: «Локальный лучший
#          результат хранится на устройстве», «Win, fail, restart»: экран победы со счётом,
#          временем и локальным рекордом). Хранится РОВНО один int — никакой мета-прогрессии,
#          разблокировок, магазина или статистики.
#          Формат: ConfigFile (INI) в user://ww2_air_battles.cfg:
#              [record]
#              best_score=<int>
#          M5.3a: тот же файл использует сейв v2 (SaveGame: [meta]/[profile]/[settings]/
#          [records]). RunRecord пишет ТОЛЬКО [record] best_score, но перед записью
#          загружает существующий файл — чужие секции сохраняются. M1–M3 рекорд вели в
#          одиночку, поэтому чтение по-прежнему переживает отсутствие остальных секций.
#          M6.2a: в [profile] появился строковый `selected_plane`, поэтому пред-скрин
#          принимает и строку в кавычках (иначе весь файл считался бы битым и submit()
#          стирал бы профиль).
#          Перед разбором содержимое проверяется строго: байтовый пре-скрин (размер, NUL,
#          управляющие) + структура INI и нормализация (комментарии выбрасываются). Битый
#          файл даёт 0 БЕЗ ERROR в логе движка — см. _read_validated_text()/_sanitize_config().
# Dependencies: — (Godot ConfigFile; ничего из игровых систем).
# Author: Mechanics Developer Agent
#
# API (всё статическое — класс-утилита, инстансы не нужны):
#   RunRecord.get_best_score() -> int          0, если файла нет / он битый / значение
#                                              невалидно или отрицательно.
#   RunRecord.submit(score) -> Dictionary      {"best": int, "is_new": bool}
#                                              новый рекорд ТОЛЬКО при score > best;
#                                              равный счёт новым рекордом не считается.
#   RunRecord.set_save_path(path)              QA/тесты: подменить файл (уникальный user://).
#   RunRecord.reset_save_path()                вернуть DEFAULT_PATH.
#   RunRecord.get_save_path() -> String        текущий путь (QA/диагностика).
#
# Ошибки записи/чтения НЕ роняют игру и НЕ пишут push_error/warning: user:// может быть
# недоступен (read-only устройство, переполнение), а тесты не должны засоряться логом.
# Потеря рекорда в таком случае — приемлемый дефект, падение забега — нет.

class_name RunRecord
extends RefCounted

const DEFAULT_PATH := "user://ww2_air_battles.cfg"
const SECTION := "record"
const KEY_BEST := "best_score"

## Потолок размера файла: рекорд — это заголовок и один int. 64 KB с большим запасом
## покрывают ручные правки с комментариями, но не дают скормить парсеру случайно
## подсунутый крупный файл.
const MAX_CONFIG_BYTES := 64 * 1024

## Максимум цифр в целой части числового литерала (18 < 2^63-1). Более длинное число
## VariantParser сам не осилит и напечатает ERROR о переполнении int64 — такой «рекорд»
## отсекаем ещё до парсера.
const MAX_INT_DIGITS := 18

## Текущий путь сохранения. Меняется только через set_save_path()/reset_save_path().
static var _path: String = DEFAULT_PATH


## QA/тесты: сохранять рекорд в отдельный файл (например, уникальный user:// для прогона).
## Пустая строка трактуется как «вернуть путь по умолчанию» — случайный set_save_path("")
## не должен писать в корень user://.
static func set_save_path(path: String) -> void:
	_path = path if not path.is_empty() else DEFAULT_PATH


## Вернуть путь по умолчанию (изоляция состояния между тестами).
static func reset_save_path() -> void:
	_path = DEFAULT_PATH


static func get_save_path() -> String:
	return _path


## Лучший результат с устройства. Любая проблема (нет файла, битый INI, отсутствующий ключ,
## не тот тип, отрицательное значение) → 0: рекорд не может быть «минус очки».
static func get_best_score() -> int:
	# Строгий пре-скрин + нормализация: комментарии выбрасываются, остаются только
	# [section] и key=value. ConfigFile.load() перечитывал бы файл с диска, а сам парсер
	# в 4.7.2 не считает «#» комментарием и склеивает такую строку с соседним ключом
	# (config_file.cpp → VariantParser::parse_tag_assign_eof), из-за чего рекорд «пропадал»
	# бы. Поэтому отдаём парсеру уже проверенный и очищенный текст через ConfigFile.parse():
	# тот же INI-разбор, без второго чтения файла и без шанса на ERROR в логе.
	var sanitized := _sanitize_config(_read_validated_text(_path))
	if sanitized.is_empty():
		return 0
	var config := ConfigFile.new()
	if config.parse(sanitized) != OK:
		return 0
	if not config.has_section_key(SECTION, KEY_BEST):
		return 0
	var value: Variant = config.get_value(SECTION, KEY_BEST, 0)
	var best := 0
	match typeof(value):
		TYPE_INT:
			best = int(value)
		TYPE_FLOAT:
			# ConfigFile может вернуть float, если файл правили вручную (best_score=100.0).
			var as_float := float(value)
			if not is_finite(as_float):
				return 0
			best = int(as_float)
		_:
			# Строка/bool/null/массив — мусор, а не рекорд.
			return 0
	return maxi(0, best)


## Прочитать файл и отсеять всё, что не является «текстовым INI», ещё на уровне БАЙТОВ.
## GET_LINE()/get_as_text() для этого не годятся: они молча выкидывают NUL (проверено на
## 4.7.2 — файл "\0\0\0" читается как пустая строка), из-за чего NUL-мусор вида
## "\0\1=ab" и доходил до ConfigFile. Поэтому читаем raw-буфер и валидируем байты сами.
## Возвращает "" при любой проблеме: нет файла, пустой/слишком большой файл, NUL,
## управляющие символы (кроме \t \n \r), ошибка чтения.
static func _read_validated_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var length := int(file.get_length())
	if length <= 0 or length > MAX_CONFIG_BYTES:
		file.close()
		return ""
	var bytes := file.get_buffer(length)
	file.close()
	if bytes.size() != length:
		return ""
	for i in length:
		var byte := bytes[i]
		# NUL и DEL — признак не текста; C0-управляющие (0x00–0x1F) пропускаем только
		# как табуляцию/перевод строки/возврат каретки.
		if byte == 0x00 or byte == 0x7F:
			return ""
		if byte < 0x20 and byte != 0x09 and byte != 0x0A and byte != 0x0D:
			return ""
	return bytes.get_string_from_utf8()


## Структурная проверка INI + нормализация: пустые строки и комментарии (; / #)
## отбрасываются, каждая содержательная строка — либо [section], либо key=value. Пустые
## имена/ключи/значения, мусор без «=», скобки или пробелы внутри имён → "" (отказ, 0).
## Возвращает безопасный текст для ConfigFile.parse(); "" — если структура невалидна
## или содержательных строк нет вовсе (пустой файл / только комментарии).
static func _sanitize_config(text: String) -> String:
	var lines := PackedStringArray()
	# "\r" нормализуем в "\n": CRLF превращается в пустую строку, которую пропускаем.
	for raw_line in text.replace("\r", "\n").split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("["):
			if not line.ends_with("]"):
				return ""
			if not _is_plain_name(line.substr(1, line.length() - 2)):
				return ""
			lines.append(line)
			continue
		var eq := line.find("=")
		if eq < 0:
			return ""
		var key := line.substr(0, eq).strip_edges()
		if not _is_plain_name(key):
			return ""
		var value := _strip_value_comment(line.substr(eq + 1).strip_edges())
		if not _is_parseable_value(value):
			return ""
		lines.append(key + "=" + value)
	if lines.is_empty():
		return ""
	return "\n".join(lines) + "\n"


## Имя секции/ключа: непустое, только [A-Za-z0-9_.-]. Это уже, чем допускает ConfigFile,
## но файл принадлежит RunRecord (одна секция, один ключ), а кавычки/пробелы в имени
## заставляют парсер печатать «Unterminated string»/терять секцию.
static func _is_plain_name(name: String) -> bool:
	if name.is_empty():
		return false
	for i in name.length():
		var code := name.unicode_at(i)
		var is_alnum := (code >= 0x30 and code <= 0x39) \
			or (code >= 0x41 and code <= 0x5A) \
			or (code >= 0x61 and code <= 0x7A)
		if not (is_alnum or code == 0x5F or code == 0x2E or code == 0x2D):
			return false
	return true


## Отрезать хвостовой комментарий значения: "13 ; note" и "13 # note" — это 13.
static func _strip_value_comment(value: String) -> String:
	var cut := value.find(";")
	var hash_cut := value.find("#")
	if hash_cut >= 0 and (cut < 0 or hash_cut < cut):
		cut = hash_cut
	if cut >= 0:
		return value.substr(0, cut).strip_edges()
	return value


## Значение должно быть тем, что VariantParser гарантированно разберёт одной лексемой:
## целое/дробное число, bool или строка в кавычках. Массивы, словари, identifier'ы и
## «1=2»/«1 2» отвергаем: рекорд — только int, а лишние формы лишь открывают дорогу
## ERROR-логу (в 4.7.2 голый identifier "abc" — это именно «Unexpected identifier»).
## M6.2a: строка в кавычках разрешена, потому что общий файл v2 хранит `selected_plane`
## (строковый id самолёта). Без этого RunRecord отвергал бы весь файл и submit() затирал
## профиль — совместимость «submit не стирает [profile]» сломалась бы.
static func _is_parseable_value(value: String) -> bool:
	if value == "true" or value == "false":
		return true
	if value.length() >= 2 and value.begins_with("\"") and value.ends_with("\""):
		# Строка без экранированной кавычки внутри: парсер не должен упираться в хвост.
		return value.substr(1, value.length() - 2).find("\"") < 0
	return _is_plain_number(value)


## Число: опциональный «-», 1..18 цифр, опциональная дробная часть через точку.
## Плюс, экспонента, hex, «5.» и «.5» не поддерживаются: RunRecord пишет только int.
static func _is_plain_number(value: String) -> bool:
	var i := 0
	if value.begins_with("-"):
		i = 1
	var int_start := i
	while i < value.length() and _is_digit_at(value, i):
		i += 1
	var int_digits := i - int_start
	if int_digits == 0 or int_digits > MAX_INT_DIGITS:
		return false
	if i == value.length():
		return true
	if value.unicode_at(i) != 0x2E:  # '.'
		return false
	i += 1
	var frac_start := i
	while i < value.length() and _is_digit_at(value, i):
		i += 1
	return i - frac_start > 0 and i == value.length()


static func _is_digit_at(text: String, index: int) -> bool:
	var code := text.unicode_at(index)
	return code >= 0x30 and code <= 0x39


## Засчитать результат забега. Возвращает {"best": актуальный лучший, "is_new": был ли
## это новый рекорд}. Сохранение выполняется ТОЛЬКО при новом рекорде — лишних записей
## на диск (и износа flash-памяти на Android) на каждом поражении нет.
static func submit(score: int) -> Dictionary:
	var best := get_best_score()
	var candidate := maxi(0, score)  # отрицательный счёт клампится в 0
	var is_new := candidate > best
	if is_new:
		best = candidate
		_save(best)
	return {"best": best, "is_new": is_new}


## Точечная запись одного ключа. Возвращаемое значение save() намеренно игнорируется:
## ошибка записи не должна ни ронять игру, ни сорить в логах тестов.
## M5.3a: файл общий с SaveGame v2 ([meta]/[profile]/[settings]/[records]), поэтому перед
## set_value существующий ConfigFile ЗАГРУЖАЕТСЯ: иначе запись рекорда затирала бы профиль
## (снабжение, звёзды, настройки). Свежий/битый файл даёт пустой конфиг — прежнее поведение
## «ровно одна секция [record]» сохраняется.
static func _save(best: int) -> void:
	var config := _load_existing()
	config.set_value(SECTION, KEY_BEST, maxi(0, best))
	config.save(_path)


## Прочитать существующий файл, сохранив ВСЕ секции. Пустой/битый/недоступный файл →
## пустой ConfigFile: запись тогда создаёт файл с нуля, как раньше.
static func _load_existing() -> ConfigFile:
	var sanitized := _sanitize_config(_read_validated_text(_path))
	if sanitized.is_empty():
		return ConfigFile.new()
	var probe := ConfigFile.new()
	if probe.parse(sanitized) != OK:
		return ConfigFile.new()
	return probe
