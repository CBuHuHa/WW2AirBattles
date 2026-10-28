# background.gd
# Purpose: фон-земля ВИДА СВЕРХУ для трёх локаций кампании (GDD «Art direction» и
#          «Assets»: ключи bg_airfield / bg_crossing / bg_city). Самолёт летит НАД
#          объектом, поэтому весь экран 540×960 — земля: поля, ВПП и ангары;
#          река с мостом и переправой; кварталы города с улицами и крышами.
#          Неба, горизонта и перспективного аэродрома внизу больше нет.
#          Три слоя параллакса ползут ВНИЗ (база медленнее, объекты и крыши
#          быстрее), поверх земли — 9 полупрозрачных облаков (дымка/тени).
#          Всё рисуется кодом в палитре ArtStyle, текстур нет: PNG bg_* из M7d
#          заменят эти слои, не трогая остальной код.
# Dependencies: GameConfig (поле 540×960), ArtStyle (палитра).
# Author: Technical Artist Agent (фон сверху, решение владельца 2026-10-28)
#
# ПРОИЗВОДИТЕЛЬНОСТЬ: геометрия каждой темы собирается ОДИН РАЗ в _build_*
# (_ready и set_theme_for_mission). В _draw нет ни создания узлов, ни сборки
# PackedVector2Array: только draw_rect / draw_colored_polygon / draw_circle по
# готовым массивам, сдвиг слоя — draw_set_transform. Плитка = высота экрана,
# поэтому на кадр видно не больше двух экземпляров, а невидимые отсекаются.
# ~250 примитивов в одном CanvasItem, без текстур и материалов.
# ПАУЗА: process_mode = PAUSABLE — на паузе и экранах исхода земля замирает,
# на брифинге (дерево не на паузе) продолжает жить.
# СЛОИ: Background стоит в main.tscn ДО World, поэтому рисуется под самолётами,
# пулями и эффектами; HUD в CanvasLayer всегда сверху.

class_name BattlefieldBackground
extends Node2D

# ─── Темы локаций: ключи GDD «Assets» (переименовывать нельзя) ───────────────
const THEME_AIRFIELD := &"bg_airfield"
const THEME_CROSSING := &"bg_crossing"
const THEME_CITY := &"bg_city"
## Миссия (id из data/missions.json) → тема. Неизвестный/пустой id → аэродром:
## миссия 1 открыта всегда, поэтому дефолт безопасен.
const MISSION_THEMES := {
	"m1_airfield": THEME_AIRFIELD,
	"m2_crossing": THEME_CROSSING,
	"m3_city": THEME_CITY,
}

# ─── Плитка земли и параллакс ────────────────────────────────────────────────
## Плитка одного слоя = высота экрана: крупные объекты (мост, деревня, квартал)
## повторяются один раз за экран, а не дважды, и повтор не бросается в глаза.
## Все примитивы лежат внутри [0, TILE_HEIGHT) — соседние плитки стыкуются
## непрерывно, поэтому шва нет ни при каком смещении.
const TILE_HEIGHT := 960.0
## 2 × 960 = 1920 ≥ 960 + плитка: экран покрыт при любом смещении.
const TILE_INSTANCES := 2
const LAYER_COUNT := 3
## Индексы слоёв (они же порядок отрисовки: земля → дороги → объекты).
const LAYER_GROUND := 0
const LAYER_ROUTE := 1
const LAYER_OBJECTS := 2
## Скорости вниз, px/с: земля медленнее всего, «поднятые» объекты и крыши —
## быстрее (параллакс глубины). Разница намеренно небольшая: слои читаются как
## один пейзаж, а не как независимые картинки.
const LAYER_SPEEDS := [16.0, 30.0, 46.0]

# ─── Облака: два слоя параллакса ─────────────────────────────────────────────
## Позиции стабильны (декор), прокручиваются вниз с разной скоростью и зациклены.
const CLOUD_BACK := [
	{"pos": Vector2(88.0, 102.0), "scale": 1.35, "alpha": 0.10},
	{"pos": Vector2(372.0, 214.0), "scale": 0.95, "alpha": 0.09},
	{"pos": Vector2(190.0, 398.0), "scale": 1.10, "alpha": 0.08},
	{"pos": Vector2(470.0, 552.0), "scale": 0.80, "alpha": 0.08},
	{"pos": Vector2(56.0, 690.0), "scale": 1.05, "alpha": 0.07},
]
const CLOUD_FRONT := [
	{"pos": Vector2(430.0, 148.0), "scale": 0.85, "alpha": 0.15},
	{"pos": Vector2(132.0, 312.0), "scale": 0.65, "alpha": 0.14},
	{"pos": Vector2(330.0, 486.0), "scale": 0.75, "alpha": 0.13},
	{"pos": Vector2(498.0, 726.0), "scale": 0.60, "alpha": 0.12},
]
## Смещения четырёх кругов облака относительно центра (в единицах масштаба).
const CLOUD_PUFFS := [
	Vector2(0.0, 0.0),
	Vector2(30.0, 6.0),
	Vector2(-30.0, 8.0),
	Vector2(6.0, -12.0),
]
const CLOUD_PUFF_RADII := [26.0, 20.0, 18.0, 18.0]
const CLOUD_BACK_SPEED := 6.0
const CLOUD_FRONT_SPEED := 13.0
## Запас за экраном для бесшовного цикла (облако не «выскакивает» на кромке).
const CLOUD_WRAP_PADDING := 120.0

var _playfield: Vector2 = GameConfig.REFERENCE_SIZE
var _theme_id: StringName = THEME_AIRFIELD
## Сплошная заливка земли темы: она же «цвет боевой зоны» для QA-читаемости.
var _terrain_color: Color = Color.BLACK
## Образцы палитры темы для QA (terrain/field/route/detail/accent).
var _palette: Dictionary = {}
var _time: float = 0.0
## Смещения слоёв земли вниз, каждое в [0, TILE_HEIGHT).
var _layer_offsets: PackedFloat32Array = PackedFloat32Array()
var _cloud_back_offset: float = 0.0
var _cloud_front_offset: float = 0.0

# Предвычисленная геометрия: три слоя, в каждом — прямоугольники, полигоны и
# круги со своими цветами. Ни одна из этих структур не меняется в _draw.
var _rects: Array = [[], [], []]
var _rect_colors: Array = [[], [], []]
var _polys: Array = [[], [], []]
var _poly_colors: Array = [[], [], []]
var _circle_centers: Array = [[], [], []]
var _circle_radii: Array = [[], [], []]
var _circle_colors: Array = [[], [], []]
## Максимальная alpha слоя (QA-читаемость: детали не «забивают» землю).
var _layer_max_alpha: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	# На паузе/в исходе фон замирает вместе с миром; на брифинге дерево не на паузе.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_playfield = GameConfig.REFERENCE_SIZE
	_layer_offsets.resize(LAYER_COUNT)
	_layer_max_alpha.resize(LAYER_COUNT)
	_build_theme(THEME_AIRFIELD)
	queue_redraw()


func _process(delta: float) -> void:
	_time += delta
	for layer in LAYER_COUNT:
		_layer_offsets[layer] = fmod(
			_layer_offsets[layer] + float(LAYER_SPEEDS[layer]) * delta, TILE_HEIGHT)
	var cloud_wrap := _playfield.y + CLOUD_WRAP_PADDING * 2.0
	_cloud_back_offset = fmod(_cloud_back_offset + CLOUD_BACK_SPEED * delta, cloud_wrap)
	_cloud_front_offset = fmod(_cloud_front_offset + CLOUD_FRONT_SPEED * delta, cloud_wrap)
	queue_redraw()


# ─── Тема локации ────────────────────────────────────────────────────────────
## M7d: тема земли по миссии. Единственный вход для LevelController (_start_run);
## повторный вызов с той же темой ничего не перестраивает.
func set_theme_for_mission(mission_id: String) -> void:
	var theme: StringName = MISSION_THEMES.get(mission_id, THEME_AIRFIELD)
	if theme == _theme_id:
		return
	_build_theme(theme)
	queue_redraw()


func get_theme_id() -> StringName:
	return _theme_id


## Образцы палитры текущей темы (все цвета выведены из ArtStyle). Для QA:
## «terrain» — заливка земли, по ней считается читаемость боевой зоны.
func get_theme_palette() -> Dictionary:
	return _palette.duplicate()


func _build_theme(theme: StringName) -> void:
	_theme_id = theme
	_clear_geometry()
	match theme:
		THEME_CROSSING:
			_build_crossing()
		THEME_CITY:
			_build_city()
		_:
			_build_airfield()


func _clear_geometry() -> void:
	_terrain_color = Color.BLACK
	_palette = {}
	if _layer_max_alpha.size() != LAYER_COUNT:
		_layer_max_alpha.resize(LAYER_COUNT)
	_layer_max_alpha.fill(0.0)
	_rects = [[], [], []]
	_rect_colors = [[], [], []]
	_polys = [[], [], []]
	_poly_colors = [[], [], []]
	_circle_centers = [[], [], []]
	_circle_radii = [[], [], []]
	_circle_colors = [[], [], []]


# ─── Сборка примитивов (только на смене темы) ────────────────────────────────
func _add_rect(layer: int, rect: Rect2, color: Color) -> void:
	var rects: Array = _rects[layer]
	rects.append(rect)
	var colors: Array = _rect_colors[layer]
	colors.append(color)
	_note_alpha(layer, color.a)


func _add_poly(layer: int, points: PackedVector2Array, color: Color) -> void:
	var polys: Array = _polys[layer]
	polys.append(points)
	var colors: Array = _poly_colors[layer]
	colors.append(color)
	_note_alpha(layer, color.a)


func _add_circle(layer: int, center: Vector2, radius: float, color: Color) -> void:
	var centers: PackedVector2Array = _circle_centers[layer]
	centers.append(center)
	_circle_centers[layer] = centers
	var radii: PackedFloat32Array = _circle_radii[layer]
	radii.append(radius)
	_circle_radii[layer] = radii
	var colors: Array = _circle_colors[layer]
	colors.append(color)
	_note_alpha(layer, color.a)


func _note_alpha(layer: int, alpha: float) -> void:
	if layer < 0 or layer >= _layer_max_alpha.size():
		return
	if alpha > _layer_max_alpha[layer]:
		_layer_max_alpha[layer] = alpha


## Полоса (река) с синусоидальными берегами. Период синуса = TILE_HEIGHT,
## поэтому при зацикливании плитки берега стыкуются без шва.
func _wavy_band(center_x: float, amplitude: float, width: float, steps: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.resize((steps + 1) * 2)
	var half := width * 0.5
	for i in steps + 1:
		var y := TILE_HEIGHT * float(i) / float(steps)
		var x := center_x + amplitude * sin(TAU * float(i) / float(steps))
		points[i] = Vector2(x - half, y)
		points[(steps + 1) * 2 - 1 - i] = Vector2(x + half, y)
	return points


## Тень «поднятого» объекта (крыша/ангар/мост): тот же прямоугольник, сдвинутый
## вниз-вправо. Без неё слой объектов читается как пятно, ползущее по полю.
func _add_shadow(layer: int, rect: Rect2, shade: Color) -> void:
	_add_rect(layer, Rect2(rect.position + Vector2(6.0, 6.0), rect.size), shade)


# ─── Тема 1: аэродром (m1_airfield) ─────────────────────────────────────────
## Сверху: поля с пятнами и межой, бетонная ВПП с разметкой, идущая через всё
## поле, ангары по обе стороны от неё, грузовики с бочками, грунтовки, деревья.
## ВПП сдвинута от центра — боевая колонна остаётся полем.
func _build_airfield() -> void:
	var grass := ArtStyle.PLAYER.lightened(0.34)
	_terrain_color = grass
	_palette = {
		"terrain": grass,
		"field": ArtStyle.PLAYER.lightened(0.50),
		"route": ArtStyle.CREAM.darkened(0.42),
		"detail": ArtStyle.ENEMY.darkened(0.10),
		"accent": ArtStyle.CREAM,
	}
	var field: Color = _palette["field"]
	var route: Color = _palette["route"]
	var detail: Color = _palette["detail"]
	var accent: Color = _palette["accent"]
	var shade := ArtStyle.PLAYER.darkened(0.16)

	# ── Слой 0: пятна полей (медленнее всего; первая половина плитки) ───────
	_add_rect(LAYER_GROUND, Rect2(24.0, 36.0, 196.0, 138.0), Color(field, 0.22))
	_add_rect(LAYER_GROUND, Rect2(300.0, 150.0, 216.0, 150.0), Color(field, 0.17))
	_add_rect(LAYER_GROUND, Rect2(214.0, 56.0, 170.0, 112.0), Color(shade, 0.12))
	_add_rect(LAYER_GROUND, Rect2(18.0, 392.0, 244.0, 66.0), Color(field, 0.12))
	# Вторая половина плитки — другой рисунок полей, повтор не заметен.
	_add_rect(LAYER_GROUND, Rect2(70.0, 548.0, 178.0, 132.0), Color(field, 0.15))
	_add_rect(LAYER_GROUND, Rect2(352.0, 600.0, 190.0, 140.0), Color(shade, 0.11))
	_add_rect(LAYER_GROUND, Rect2(24.0, 748.0, 220.0, 120.0), Color(field, 0.18))
	_add_rect(LAYER_GROUND, Rect2(300.0, 836.0, 210.0, 100.0), Color(field, 0.13))

	# ── Слой 1: ВПП, разметка, грунтовки, межи ──────────────────────────────
	_add_rect(LAYER_ROUTE, Rect2(352.0, 0.0, 108.0, TILE_HEIGHT), Color(route, 0.58))
	_add_rect(LAYER_ROUTE, Rect2(352.0, 0.0, 3.0, TILE_HEIGHT), Color(accent, 0.18))
	_add_rect(LAYER_ROUTE, Rect2(457.0, 0.0, 3.0, TILE_HEIGHT), Color(accent, 0.18))
	for i in 16:
		_add_rect(LAYER_ROUTE, Rect2(400.0, 10.0 + float(i) * 60.0, 12.0, 26.0),
			Color(accent, 0.20))
	_add_rect(LAYER_ROUTE, Rect2(120.0, 0.0, 18.0, TILE_HEIGHT), Color(route, 0.32))
	# Грунтовки заканчиваются у кромки ВПП — дорога не «едет» по бетону.
	_add_rect(LAYER_ROUTE, Rect2(0.0, 196.0, 348.0, 20.0), Color(route, 0.40))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 452.0, 348.0, 14.0), Color(route, 0.30))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 692.0, 348.0, 18.0), Color(route, 0.36))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 900.0, 348.0, 12.0), Color(route, 0.28))
	# Межи: горизонтальные полосы дают главное ощущение полёта вперёд.
	_add_rect(LAYER_ROUTE, Rect2(0.0, 96.0, 348.0, 4.0), Color(shade, 0.28))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 330.0, 348.0, 5.0), Color(shade, 0.24))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 250.0, 348.0, 3.0), Color(field, 0.22))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 574.0, 348.0, 4.0), Color(shade, 0.26))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 796.0, 348.0, 3.0), Color(field, 0.20))

	# ── Слой 2: ангары, техника, деревья, стога (быстрее всех) ──────────────
	for hangar: Rect2 in [Rect2(462.0, 150.0, 56.0, 42.0), Rect2(462.0, 324.0, 56.0, 42.0),
			Rect2(188.0, 384.0, 64.0, 44.0)]:
		_add_shadow(LAYER_OBJECTS, hangar, Color(shade, 0.16))
		_add_rect(LAYER_OBJECTS, hangar, Color(detail, 0.46))
		_add_rect(LAYER_OBJECTS, Rect2(hangar.position + Vector2(6.0, 6.0),
			Vector2(hangar.size.x - 12.0, 6.0)), Color(accent, 0.13))
	# Вторая половина: ангар слева от ВПП и пара мелких построек.
	for hangar: Rect2 in [Rect2(196.0, 700.0, 60.0, 40.0), Rect2(476.0, 806.0, 52.0, 38.0)]:
		_add_shadow(LAYER_OBJECTS, hangar, Color(shade, 0.16))
		_add_rect(LAYER_OBJECTS, hangar, Color(detail, 0.44))
		_add_rect(LAYER_OBJECTS, Rect2(hangar.position + Vector2(6.0, 6.0),
			Vector2(hangar.size.x - 12.0, 5.0)), Color(accent, 0.12))

	# Грузовики: кузов + кабина, стоят на грунтовках.
	_add_rect(LAYER_OBJECTS, Rect2(150.0, 200.0, 22.0, 10.0), Color(detail, 0.55))
	_add_rect(LAYER_OBJECTS, Rect2(143.0, 200.0, 8.0, 10.0), Color(detail, 0.62))
	_add_rect(LAYER_OBJECTS, Rect2(300.0, 696.0, 24.0, 9.0), Color(detail, 0.50))
	_add_rect(LAYER_OBJECTS, Rect2(324.0, 696.0, 7.0, 9.0), Color(detail, 0.58))

	# Бочки с топливом у ангаров (единственный тёплый акцент темы).
	for i in 3:
		_add_circle(LAYER_OBJECTS, Vector2(490.0 + float(i) * 8.0, 206.0 + float(i) * 4.0),
			3.5, Color(ArtStyle.DANGER.darkened(0.30), 0.45))
	for i in 2:
		_add_circle(LAYER_OBJECTS, Vector2(208.0 + float(i) * 9.0, 754.0 + float(i) * 5.0),
			3.5, Color(ArtStyle.DANGER.darkened(0.30), 0.40))

	# Деревья и стога: только у кромок, центр поля остаётся чистым.
	for tree: Vector2 in [Vector2(34.0, 84.0), Vector2(48.0, 100.0), Vector2(20.0, 296.0),
			Vector2(36.0, 312.0), Vector2(510.0, 60.0), Vector2(516.0, 240.0),
			Vector2(44.0, 456.0), Vector2(30.0, 640.0), Vector2(512.0, 560.0),
			Vector2(46.0, 850.0), Vector2(58.0, 866.0)]:
		_add_circle(LAYER_OBJECTS, tree, 7.0, Color(shade, 0.42))
	for tree: Vector2 in [Vector2(34.0, 84.0), Vector2(20.0, 296.0), Vector2(516.0, 240.0),
			Vector2(30.0, 640.0)]:
		_add_circle(LAYER_OBJECTS, tree + Vector2(-1.0, -1.0), 3.5,
			Color(ArtStyle.PLAYER.lightened(0.30), 0.25))
	_add_circle(LAYER_OBJECTS, Vector2(250.0, 120.0), 5.0,
		Color(ArtStyle.CREAM.darkened(0.28), 0.35))
	_add_circle(LAYER_OBJECTS, Vector2(264.0, 128.0), 4.0,
		Color(ArtStyle.CREAM.darkened(0.28), 0.32))
	_add_circle(LAYER_OBJECTS, Vector2(300.0, 560.0), 5.0,
		Color(ArtStyle.CREAM.darkened(0.28), 0.33))


# ─── Тема 2: переправа (m2_crossing) ────────────────────────────────────────
## Сверху: река с синусоидальными берегами идёт через всё поле, мост на дороге в
## первой половине, паромная переправа с лодками — во второй, деревня на берегах.
func _build_crossing() -> void:
	var meadow := ArtStyle.PLAYER.lightened(0.24)
	var water := ArtStyle.SKY.darkened(0.32)
	_terrain_color = meadow
	_palette = {
		"terrain": meadow,
		"field": ArtStyle.PLAYER.lightened(0.42),
		"route": water,
		"detail": ArtStyle.ENEMY.lightened(0.08),
		"accent": ArtStyle.CREAM,
	}
	var field: Color = _palette["field"]
	var detail: Color = _palette["detail"]
	var accent: Color = _palette["accent"]
	var shade := ArtStyle.PLAYER.darkened(0.18)
	var road := ArtStyle.CREAM.darkened(0.42)

	# ── Слой 0: луга и пятна полей ──────────────────────────────────────────
	_add_rect(LAYER_GROUND, Rect2(18.0, 72.0, 152.0, 120.0), Color(field, 0.20))
	_add_rect(LAYER_GROUND, Rect2(396.0, 40.0, 132.0, 150.0), Color(field, 0.18))
	_add_rect(LAYER_GROUND, Rect2(352.0, 250.0, 172.0, 142.0), Color(field, 0.16))
	_add_rect(LAYER_GROUND, Rect2(58.0, 200.0, 120.0, 90.0), Color(shade, 0.10))
	_add_rect(LAYER_GROUND, Rect2(30.0, 520.0, 160.0, 130.0), Color(field, 0.19))
	_add_rect(LAYER_GROUND, Rect2(390.0, 600.0, 140.0, 140.0), Color(field, 0.15))
	_add_rect(LAYER_GROUND, Rect2(200.0, 740.0, 180.0, 120.0), Color(field, 0.13))
	_add_rect(LAYER_GROUND, Rect2(60.0, 820.0, 150.0, 110.0), Color(field, 0.11))
	_add_rect(LAYER_GROUND, Rect2(404.0, 860.0, 116.0, 70.0), Color(shade, 0.10))

	# ── Слой 1: река (берег → вода → глубина), дороги, межи ────────────────
	_add_poly(LAYER_ROUTE, _wavy_band(300.0, 30.0, 172.0, 28),
		Color(ArtStyle.CREAM.darkened(0.34), 0.30))
	_add_poly(LAYER_ROUTE, _wavy_band(300.0, 30.0, 148.0, 28), Color(water, 0.55))
	_add_poly(LAYER_ROUTE, _wavy_band(300.0, 30.0, 64.0, 28), Color(water.darkened(0.18), 0.35))
	# Дорога с мостом (первая половина) и дорога с паромом (вторая).
	_add_rect(LAYER_ROUTE, Rect2(0.0, 110.0, 540.0, 18.0), Color(road, 0.38))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 404.0, 240.0, 16.0), Color(road, 0.30))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 700.0, 540.0, 16.0), Color(road, 0.36))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 892.0, 220.0, 14.0), Color(road, 0.28))
	# Межи обрываются у берегов — через воду они не идут.
	_add_rect(LAYER_ROUTE, Rect2(0.0, 182.0, 150.0, 3.0), Color(shade, 0.20))
	_add_rect(LAYER_ROUTE, Rect2(420.0, 182.0, 120.0, 3.0), Color(shade, 0.20))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 340.0, 150.0, 4.0), Color(shade, 0.24))
	_add_rect(LAYER_ROUTE, Rect2(420.0, 340.0, 120.0, 4.0), Color(shade, 0.24))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 560.0, 150.0, 4.0), Color(shade, 0.22))
	_add_rect(LAYER_ROUTE, Rect2(420.0, 560.0, 120.0, 4.0), Color(shade, 0.22))
	_add_rect(LAYER_ROUTE, Rect2(0.0, 840.0, 150.0, 3.0), Color(shade, 0.20))
	_add_rect(LAYER_ROUTE, Rect2(420.0, 840.0, 120.0, 3.0), Color(shade, 0.20))

	# ── Слой 2: мост, паром, деревня, деревья (быстрее всех) ───────────────
	# Мост через воду на линии верхней грунтовки.
	_add_rect(LAYER_OBJECTS, Rect2(230.0, 112.0, 200.0, 36.0), Color(detail, 0.55))
	_add_rect(LAYER_OBJECTS, Rect2(230.0, 112.0, 200.0, 3.0), Color(accent, 0.26))
	_add_rect(LAYER_OBJECTS, Rect2(230.0, 145.0, 200.0, 3.0), Color(accent, 0.26))
	for i in 5:
		_add_rect(LAYER_OBJECTS, Rect2(244.0 + float(i) * 38.0, 118.0, 4.0, 24.0),
			Color(accent, 0.12))
	# Паром во второй половине: три лодки поперёк воды + трос.
	_add_rect(LAYER_OBJECTS, Rect2(190.0, 706.0, 170.0, 2.0), Color(accent, 0.20))
	for i in 3:
		_add_rect(LAYER_OBJECTS, Rect2(196.0 + float(i) * 56.0, 700.0, 30.0, 13.0),
			Color(detail, 0.55))
		_add_rect(LAYER_OBJECTS, Rect2(199.0 + float(i) * 56.0, 702.0, 24.0, 4.0),
			Color(accent, 0.16))
	# Деревня на берегах (крыши + конёк).
	_add_rect(LAYER_OBJECTS, Rect2(54.0, 150.0, 34.0, 22.0), Color(detail, 0.42))
	_add_rect(LAYER_OBJECTS, Rect2(58.0, 154.0, 26.0, 4.0), Color(accent, 0.12))
	_add_rect(LAYER_OBJECTS, Rect2(96.0, 158.0, 26.0, 18.0), Color(detail, 0.40))
	_add_rect(LAYER_OBJECTS, Rect2(434.0, 336.0, 34.0, 22.0), Color(detail, 0.42))
	_add_rect(LAYER_OBJECTS, Rect2(438.0, 340.0, 26.0, 4.0), Color(accent, 0.12))
	_add_rect(LAYER_OBJECTS, Rect2(476.0, 344.0, 24.0, 16.0), Color(detail, 0.40))
	_add_rect(LAYER_OBJECTS, Rect2(436.0, 366.0, 28.0, 16.0), Color(detail, 0.38))
	_add_rect(LAYER_OBJECTS, Rect2(60.0, 640.0, 36.0, 24.0), Color(detail, 0.42))
	_add_rect(LAYER_OBJECTS, Rect2(64.0, 644.0, 28.0, 4.0), Color(accent, 0.12))
	_add_rect(LAYER_OBJECTS, Rect2(102.0, 650.0, 24.0, 16.0), Color(detail, 0.38))
	_add_rect(LAYER_OBJECTS, Rect2(440.0, 790.0, 32.0, 20.0), Color(detail, 0.40))
	_add_rect(LAYER_OBJECTS, Rect2(64.0, 856.0, 30.0, 20.0), Color(detail, 0.38))
	# Деревья у берегов и в полях.
	for tree: Vector2 in [Vector2(150.0, 60.0), Vector2(162.0, 74.0), Vector2(120.0, 380.0),
			Vector2(430.0, 200.0), Vector2(64.0, 520.0), Vector2(420.0, 640.0),
			Vector2(120.0, 760.0), Vector2(470.0, 900.0)]:
		_add_circle(LAYER_OBJECTS, tree, 7.0, Color(shade, 0.42))


# ─── Тема 3: город (m3_city) ────────────────────────────────────────────────
## Сверху: кварталы между улицами, крыши разного размера с тенями, дворы,
## скверы с деревьями, следы воронок и выгоревшая крыша.
func _build_city() -> void:
	# Земля города светлее крыш: серые силуэты врагов читаются и над кварталом.
	var earth := ArtStyle.CREAM.darkened(0.24).lerp(ArtStyle.ENEMY, 0.22)
	_terrain_color = earth
	_palette = {
		"terrain": earth,
		"field": ArtStyle.CREAM.darkened(0.28),
		"route": ArtStyle.ENEMY.darkened(0.35),
		"detail": ArtStyle.ENEMY.darkened(0.06),
		"accent": ArtStyle.DANGER.darkened(0.30),
	}
	var yard: Color = _palette["field"]
	var street: Color = _palette["route"]
	var roof: Color = _palette["detail"]
	var accent: Color = _palette["accent"]
	var shade := ArtStyle.ENEMY.darkened(0.45)

	# ── Слой 0: кварталы (однородные по высоте полосы — поперечные улицы идут
	# по ним без «разъезда» домов и проезжей части) и пятна гари ─────────────
	_add_rect(LAYER_GROUND, Rect2(0.0, 0.0, 108.0, TILE_HEIGHT), Color(yard, 0.13))
	_add_rect(LAYER_GROUND, Rect2(150.0, 0.0, 180.0, TILE_HEIGHT), Color(yard, 0.11))
	_add_rect(LAYER_GROUND, Rect2(372.0, 0.0, 168.0, TILE_HEIGHT), Color(yard, 0.13))
	for burn: Rect2 in [Rect2(20.0, 60.0, 70.0, 60.0), Rect2(200.0, 240.0, 90.0, 70.0),
			Rect2(430.0, 160.0, 80.0, 80.0), Rect2(60.0, 600.0, 78.0, 58.0),
			Rect2(250.0, 760.0, 86.0, 64.0)]:
		_add_rect(LAYER_GROUND, burn, Color(shade, 0.09))

	# ── Слой 1: улицы, скверы, разметка ─────────────────────────────────────
	_add_rect(LAYER_ROUTE, Rect2(108.0, 0.0, 42.0, TILE_HEIGHT), Color(street, 0.52))
	_add_rect(LAYER_ROUTE, Rect2(330.0, 0.0, 42.0, TILE_HEIGHT), Color(street, 0.52))
	_add_rect(LAYER_ROUTE, Rect2(104.0, 0.0, 5.0, TILE_HEIGHT), Color(ArtStyle.CREAM, 0.12))
	_add_rect(LAYER_ROUTE, Rect2(149.0, 0.0, 5.0, TILE_HEIGHT), Color(ArtStyle.CREAM, 0.12))
	_add_rect(LAYER_ROUTE, Rect2(326.0, 0.0, 5.0, TILE_HEIGHT), Color(ArtStyle.CREAM, 0.12))
	_add_rect(LAYER_ROUTE, Rect2(371.0, 0.0, 5.0, TILE_HEIGHT), Color(ArtStyle.CREAM, 0.12))
	for cross_y: float in [110.0, 362.0, 590.0, 842.0]:
		_add_rect(LAYER_ROUTE, Rect2(0.0, cross_y, 540.0, 38.0), Color(street, 0.46))
	for i in 12:
		_add_rect(LAYER_ROUTE, Rect2(127.0, 8.0 + float(i) * 80.0, 4.0, 18.0),
			Color(ArtStyle.CREAM, 0.12))
		_add_rect(LAYER_ROUTE, Rect2(349.0, 8.0 + float(i) * 80.0, 4.0, 18.0),
			Color(ArtStyle.CREAM, 0.12))
	# Скверы во дворах (плоская зелень — не объект, поэтому в слое улиц).
	_add_rect(LAYER_ROUTE, Rect2(160.0, 236.0, 92.0, 66.0),
		Color(ArtStyle.PLAYER.lightened(0.14), 0.40))
	_add_rect(LAYER_ROUTE, Rect2(176.0, 700.0, 84.0, 58.0),
		Color(ArtStyle.PLAYER.lightened(0.14), 0.36))

	# ── Слой 2: крыши с тенями, коньки, воронки, деревья ────────────────────
	# Первая половина плитки.
	_add_house(Rect2(16.0, 40.0, 62.0, 48.0), 0.46, roof, shade, true)
	_add_house(Rect2(16.0, 196.0, 76.0, 58.0), 0.42, roof, shade, false)
	_add_house(Rect2(20.0, 330.0, 68.0, 44.0), 0.44, roof, shade, false)
	_add_house(Rect2(160.0, 28.0, 70.0, 56.0), 0.45, roof, shade, true)
	_add_house(Rect2(244.0, 44.0, 66.0, 50.0), 0.40, roof, shade, false)
	_add_house(Rect2(170.0, 150.0, 86.0, 60.0), 0.44, roof, shade, true)
	_add_house(Rect2(268.0, 220.0, 44.0, 54.0), 0.42, roof, shade, false)
	_add_house(Rect2(166.0, 300.0, 74.0, 48.0), 0.40, roof, shade, false)
	_add_house(Rect2(250.0, 400.0, 60.0, 52.0), 0.43, roof, shade, true)
	_add_house(Rect2(388.0, 60.0, 74.0, 52.0), 0.44, roof, shade, true)
	_add_house(Rect2(474.0, 72.0, 50.0, 44.0), 0.40, roof, shade, false)
	_add_house(Rect2(392.0, 210.0, 80.0, 58.0), 0.45, roof, shade, true)
	_add_house(Rect2(482.0, 250.0, 44.0, 50.0), 0.41, roof, shade, false)
	_add_house(Rect2(392.0, 340.0, 70.0, 52.0), 0.42, roof, shade, false)
	# Вторая половина плитки — другой рисунок кварталов.
	_add_house(Rect2(14.0, 540.0, 74.0, 50.0), 0.43, roof, shade, true)
	_add_house(Rect2(24.0, 660.0, 62.0, 44.0), 0.40, roof, shade, false)
	_add_house(Rect2(12.0, 800.0, 80.0, 56.0), 0.45, roof, shade, true)
	_add_house(Rect2(164.0, 520.0, 66.0, 52.0), 0.42, roof, shade, false)
	_add_house(Rect2(240.0, 548.0, 74.0, 46.0), 0.44, roof, shade, true)
	_add_house(Rect2(166.0, 640.0, 88.0, 58.0), 0.40, roof, shade, false)
	_add_house(Rect2(270.0, 780.0, 46.0, 52.0), 0.43, roof, shade, false)
	_add_house(Rect2(170.0, 880.0, 76.0, 50.0), 0.41, roof, shade, false)
	_add_house(Rect2(390.0, 520.0, 68.0, 54.0), 0.45, roof, shade, true)
	_add_house(Rect2(470.0, 560.0, 56.0, 44.0), 0.40, roof, shade, false)
	_add_house(Rect2(386.0, 660.0, 84.0, 60.0), 0.42, roof, shade, true)
	_add_house(Rect2(486.0, 700.0, 40.0, 48.0), 0.44, roof, shade, false)
	_add_house(Rect2(392.0, 820.0, 72.0, 54.0), 0.41, roof, shade, false)
	# Выгоревшая крыша — единственный тёплый акцент города.
	_add_rect(LAYER_OBJECTS, Rect2(258.0, 408.0, 44.0, 36.0), Color(accent, 0.18))

	# Воронки и деревья скверов — мелкие детали, alpha держим низкой.
	for crater: Vector2 in [Vector2(64.0, 300.0), Vector2(300.0, 120.0),
			Vector2(80.0, 760.0), Vector2(440.0, 560.0)]:
		_add_circle(LAYER_OBJECTS, crater, 9.0, Color(shade, 0.16))
	for tree: Vector2 in [Vector2(172.0, 246.0), Vector2(196.0, 262.0), Vector2(226.0, 244.0),
			Vector2(240.0, 276.0), Vector2(188.0, 712.0), Vector2(214.0, 730.0),
			Vector2(242.0, 716.0)]:
		_add_circle(LAYER_OBJECTS, tree, 5.0, Color(ArtStyle.PLAYER.darkened(0.30), 0.40))


## Крыша квартала: тень + скат + (по флагу) светлый конёк. Плоскостная геометрия
## сверху: крыша не «падает» на землю, поэтому её alpha ниже, чем у дорог.
func _add_house(rect: Rect2, alpha: float, roof: Color, shade: Color, ridge: bool) -> void:
	_add_shadow(LAYER_OBJECTS, rect, Color(shade, 0.14))
	_add_rect(LAYER_OBJECTS, rect, Color(roof, alpha))
	if ridge:
		_add_rect(LAYER_OBJECTS, Rect2(rect.position + Vector2(6.0, 6.0),
			Vector2(rect.size.x - 12.0, 5.0)), Color(ArtStyle.CREAM, 0.12))


# ─── Отрисовка ───────────────────────────────────────────────────────────────
func _draw() -> void:
	# Земля: сплошная заливка на весь экран — «дыр» в поле быть не может.
	draw_rect(Rect2(Vector2.ZERO, _playfield), _terrain_color)
	for layer in LAYER_COUNT:
		var shift := fmod(_layer_offsets[layer], TILE_HEIGHT)
		var origin_y := shift - TILE_HEIGHT
		for instance in TILE_INSTANCES:
			var offset_y := origin_y + TILE_HEIGHT * float(instance)
			# Экземпляр целиком за экраном — не рисуем (экономия команд).
			if offset_y > _playfield.y or offset_y + TILE_HEIGHT <= 0.0:
				continue
			draw_set_transform(Vector2(0.0, offset_y))
			_draw_layer(layer)
	draw_set_transform(Vector2.ZERO)
	_draw_clouds(CLOUD_BACK, _cloud_back_offset)
	_draw_clouds(CLOUD_FRONT, _cloud_front_offset)


## Примитивы одного слоя по уже собранным массивам (никаких аллокаций).
func _draw_layer(layer: int) -> void:
	var rects: Array = _rects[layer]
	var rect_colors: Array = _rect_colors[layer]
	for i in rects.size():
		draw_rect(rects[i], rect_colors[i])
	var polys: Array = _polys[layer]
	var poly_colors: Array = _poly_colors[layer]
	for i in polys.size():
		draw_colored_polygon(polys[i], poly_colors[i])
	var centers: PackedVector2Array = _circle_centers[layer]
	var radii: PackedFloat32Array = _circle_radii[layer]
	var circle_colors: Array = _circle_colors[layer]
	for i in centers.size():
		draw_circle(centers[i], radii[i], circle_colors[i])


func _draw_clouds(layer: Array, offset: float) -> void:
	var wrap := _playfield.y + CLOUD_WRAP_PADDING * 2.0
	for cloud: Dictionary in layer:
		var base: Vector2 = cloud["pos"]
		var y := fmod(base.y + offset + CLOUD_WRAP_PADDING, wrap) - CLOUD_WRAP_PADDING
		var center := Vector2(base.x, y)
		if center.y < -CLOUD_WRAP_PADDING or center.y > _playfield.y + CLOUD_WRAP_PADDING:
			continue
		_draw_cloud(center, float(cloud["scale"]), float(cloud["alpha"]))


func _draw_cloud(center: Vector2, scale_factor: float, alpha: float) -> void:
	var color := Color(ArtStyle.CLOUD, alpha)
	for i in CLOUD_PUFFS.size():
		var offset: Vector2 = CLOUD_PUFFS[i] * scale_factor
		var radius: float = CLOUD_PUFF_RADII[i] * scale_factor
		draw_circle(center + offset, radius, color)


# ─── Debug API для QA ────────────────────────────────────────────────────────
## Смещение самого медленного слоя земли (база) в [0, TILE_HEIGHT).
func get_back_offset() -> float:
	return get_layer_offset(LAYER_GROUND)


## Смещение самого быстрого слоя земли (объекты/крыши) в [0, TILE_HEIGHT).
func get_front_offset() -> float:
	return get_layer_offset(LAYER_OBJECTS)


func get_layer_count() -> int:
	return LAYER_COUNT


func get_layer_speed(layer: int) -> float:
	if layer < 0 or layer >= LAYER_SPEEDS.size():
		return 0.0
	return float(LAYER_SPEEDS[layer])


func get_layer_offset(layer: int) -> float:
	if layer < 0 or layer >= _layer_offsets.size():
		return 0.0
	return _layer_offsets[layer]


## Максимальная alpha примитивов слоя: по ней smoke проверяет, что детали не
## превращают землю в пёстрое пятно под самолётом.
func get_layer_max_alpha(layer: int) -> float:
	if layer < 0 or layer >= _layer_max_alpha.size():
		return 0.0
	return _layer_max_alpha[layer]


## QA: подвести слой к кромке цикла и проверить бесшовный wrap.
func set_layer_offset(layer: int, value: float) -> void:
	if layer < 0 or layer >= _layer_offsets.size():
		return
	_layer_offsets[layer] = value


func get_animation_time() -> float:
	return _time


func get_cloud_count() -> int:
	return CLOUD_BACK.size() + CLOUD_FRONT.size()


## Заливка земли темы — по ней smoke считает читаемость боевой зоны.
func get_terrain_color() -> Color:
	return _terrain_color
