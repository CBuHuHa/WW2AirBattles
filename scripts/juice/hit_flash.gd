# hit_flash.gd
# Purpose: Вспышка попадания через self_modulate: мгновенный пик Color(3,3,3,1) — аддитивное
#          выбеливание силуэта без шейдера (работает на gl_compatibility), затем cubic-out
#          возврат к нейтральному Color(1,1,1,1).
# Dependencies: нет.
# Author: Game Feel Developer Agent
#
# ПОЧЕМУ ПИК > 1, А НЕ Color.WHITE: self_modulate по умолчанию и есть WHITE, поэтому вспышка
# WHITE→WHITE — no-op (ревью: эффект был невидим, тест маскировал это предокраской узла в серый).
# Значения RGB > 1 складываются с цветом силуэта и дают выбеливание; итоговый цвет
# CanvasItem = parent modulate × self_modulate, кламп делает шейдер рендерера.
#
# НЕКОНФЛИКТНОСТЬ С МИГОМ НЕУЯЗВИМОСТИ: player.gd держит собственную логику на modulate.a
# (корень Player Area2D). HitFlash пишет ТОЛЬКО self_modulate визуального узла —
# итоговый цвет CanvasItem = parent modulate × self_modulate, поэтому альфа-миг игрока
# и вспышка складываются, а не затирают друг друга. На практике вспышку нужно
# вызывать для визуального ребёнка (ShipVisual/Sprite2D), но даже вызов на корне безопасен.

class_name HitFlash
extends RefCounted

## Возврат к нейтральному self_modulate — cubic-out (резкий старт, мягкое завершение).
const RETURN_TRANSITION := Tween.TRANS_CUBIC
const RETURN_EASE := Tween.EASE_OUT
const MIN_DURATION := 0.01
## Пик вспышки: RGB > 1 = выбеливание силуэта (см. шапку файла).
const FLASH_COLOR := Color(3.0, 3.0, 3.0, 1.0)
## Нейтральный self_modulate, к которому узел возвращается после вспышки.
const BASE_COLOR := Color(1.0, 1.0, 1.0, 1.0)

## Активные/отработавшие вспышки по instance_id узла: { id: { "tween": Tween, "ref": WeakRef } }.
## WeakRef не удерживает узел, а запись снимается по tree_exited узла (см. flash): кэш не копит
## instance_id сбитых врагов. Для живого узла запись живёт дальше — так на повторную вспышку
## не вешается второй обработчик tree_exited.
static var _active: Dictionary = {}


## visual — узел с отрисовкой (Sprite2D/ShipVisual/Node2D с _draw); seconds — общее время
## эффекта (возврат к нейтральному цвету). Дефолт 0.05 с — короткий щелчок попадания.
static func flash(visual: Node2D, seconds: float = 0.05) -> void:
	if visual == null or not visual.is_inside_tree():
		return
	var duration := maxf(seconds, MIN_DURATION)
	var id := visual.get_instance_id()

	# Повторная вспышка того же узла прерывает предыдущую; старт всегда от пика.
	# WeakRef защищает от переиспользованного instance_id: чужая/мёртвая запись не считается.
	var hooked := false
	var previous: Variant = _active.get(id)
	if previous is Dictionary:
		var prev_ref := previous.get("ref") as WeakRef
		if prev_ref != null and prev_ref.get_ref() == visual:
			var prev_tween := previous.get("tween") as Tween
			if prev_tween != null and prev_tween.is_valid():
				prev_tween.kill()
			hooked = true

	visual.self_modulate = FLASH_COLOR

	var tween := visual.create_tween()
	tween.set_trans(RETURN_TRANSITION)
	tween.set_ease(RETURN_EASE)
	tween.tween_property(visual, "self_modulate", BASE_COLOR, duration)
	_active[id] = {"tween": tween, "ref": weakref(visual)}
	if not hooked:
		# Узел умирает (сбитый враг освобождается в том же кадре) — запись обязана исчезнуть
		# вместе с ним, иначе статик копил бы id мёртвых узлов.
		visual.tree_exited.connect(_on_visual_exited.bind(id), CONNECT_ONE_SHOT)


## Узел покинул дерево (гибель/рестарт) — запись снимается.
static func _on_visual_exited(id: int) -> void:
	_active.erase(id)


## Только для тестов/QA: число записей кэша (обязано убывать вместе с погибшими узлами).
static func debug_active_records() -> int:
	return _active.size()
