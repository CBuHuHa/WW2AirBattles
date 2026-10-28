# game_config.gd
# Purpose: Общие константы проекта — база разрешения, границы игрового поля, слои физики, группы узлов.
# Dependencies: нет (только константы и чистые функции).
# Author: Mechanics Developer Agent

class_name GameConfig
extends RefCounted

## База разрешения из GDD «Art direction»: 540×960, stretch canvas_items.
const REFERENCE_SIZE := Vector2(540.0, 960.0)

## Отступ клампа позиции игрока от края экрана.
## QA-правка M2: было 20 px, но визуал Ла-5 — 48×48 (полуширина 24), и крылья обрезались о край.
## 26 px = полуширина 24 + 2 px запаса на кремовый контур.
const PLAYFIELD_MARGIN := 26.0

## Слои физики. Значения = битовые маски; имена продублированы в project.godot → [layer_names].
const LAYER_PLAYER := 1 << 0        # слой 1 «player»
const LAYER_PLAYER_BULLET := 1 << 1 # слой 2 «player_bullet»
const LAYER_ENEMY := 1 << 2         # слой 3 «enemy»
const LAYER_ENEMY_BULLET := 1 << 3  # слой 4 «enemy_bullet»

## Группы узлов — точки расширения M2.
## Обычные враги (Bf 109, в M2 — Ju 87 / Fw 190): бомба убивает их мгновенно.
const GROUP_ENEMIES := &"enemies"
## Босс He 111 (M2) живёт в отдельной группе, чтобы бомба не убивала его через GROUP_ENEMIES.
const GROUP_BOSS := &"boss"


## Прямоугольник игрового поля в координатах канвы (= экран при stretch canvas_items).
static func playfield_rect() -> Rect2:
	return Rect2(Vector2.ZERO, REFERENCE_SIZE)


## Кламп точки в границы экрана с отступом PLAYFIELD_MARGIN.
static func clamp_to_playfield(point: Vector2) -> Vector2:
	var rect := playfield_rect()
	return Vector2(
		clampf(point.x, rect.position.x + PLAYFIELD_MARGIN, rect.end.x - PLAYFIELD_MARGIN),
		clampf(point.y, rect.position.y + PLAYFIELD_MARGIN, rect.end.y - PLAYFIELD_MARGIN)
	)


## Находится ли точка за пределами поля с запасом (для очистки пуль и врагов).
static func is_outside_playfield(point: Vector2, padding: float) -> bool:
	return (
		point.x < -padding
		or point.x > REFERENCE_SIZE.x + padding
		or point.y < -padding
		or point.y > REFERENCE_SIZE.y + padding
	)
