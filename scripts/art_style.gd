# art_style.gd
# Purpose: Единственный источник правды по плейсхолдер-графике: палитра GDD, стабильные ключи ассетов,
#          размеры из таблицы Assets и векторная отрисовка силуэтов кодом (ассетов в проекте нет).
# Dependencies: GameConfig (разрешение).
# Author: Mechanics Developer Agent
#
# ПРАВИЛО АРХИТЕКТУРЫ: игровая логика ссылается на KEY_* и size_of(KEY_*), но не на конкретную отрисовку.
# Когда появятся текстуры (GDD «Assets»), достаточно заменить вызов draw_ship()/draw_bullet() на Sprite2D
# с тем же ключом и размером — логика, хитбоксы и сцены останутся без изменений.

class_name ArtStyle
extends RefCounted

# ─── Палитра GDD «Art direction» ──────────────────────────────────────────────
const SKY := Color("8fa6b2")         # небо
const CLOUD := Color("d9d2c3")       # облака / кремовый
const CREAM := Color("d9d2c3")       # кремовый контур игрока
const PLAYER := Color("4a5d3a")      # игрок (оливковый)
const ENEMY := Color("4f4f4f")       # враги (серый)
const BULLET_ENEMY := Color("ffd166") # вражеские пули (ярко-жёлтый)
const DANGER := Color("b23a2e")      # опасность / HP-полоса (в M1 не используется)
const PLAYER_BULLET := Color("ffffff") # белые трассеры игрока

# ─── Ливреи ангара (M6.2b; GDD «Самолёты (ангар)»: «Ливреи — перекраски корпуса») ───────────
## Тинт корпуса по индексу ливреи (SaveGame.get_selected_livery/0…3). 0 — без ливреи:
## белый = силуэт в родной палитре. 1…3 — платные перекраски (300/600/900); цвета приглушены,
## чтобы кремовый контур #D9D2C3 читался на небе #8FA6B2 и альфа-миг неуязвимости не спорил.
## Единственный источник правды: Player.apply_livery() и превью ангара берут цвета отсюда.
const LIVERY_TINTS := [
	Color(1.0, 1.0, 1.0),  # 0 — без ливреи
	Color("6b7f5a"),       # 1 — оливковая
	Color("8a6b3a"),       # 2 — песочная
	Color("3b4a57"),       # 3 — серо-синяя
]


## Тинт ливреи по индексу. Вне диапазона 0…3 → белый (без перекраски), а не случайный цвет.
static func livery_tint(index: int) -> Color:
	if index < 0 or index >= LIVERY_TINTS.size():
		return Color(1.0, 1.0, 1.0)
	return LIVERY_TINTS[index]

# ─── Стабильные ключи ассетов GDD «Assets» (менять нельзя) ────────────────────
const KEY_PLAYER_LA5 := &"player_la5"
## M6.2b: ключи Як-3 и Аэрокобры (planes.json M6.2a). Арт — M7: до него они рисуются
## силуэтом игрока в палитре PLAYER/CREAM (см. draw_ship), а не серым фолбэком врага.
const KEY_PLAYER_YAK3 := &"player_yak3"
const KEY_PLAYER_P39 := &"player_p39"
const KEY_ENEMY_BF109 := &"enemy_bf109"
const KEY_ENEMY_JU87 := &"enemy_ju87"
const KEY_ENEMY_FW190 := &"enemy_fw190"
const KEY_ENEMY_BF110 := &"enemy_bf110"
const KEY_BOSS_HE111 := &"boss_he111"
const KEY_BOSS_JU88 := &"boss_ju88"
const KEY_BOSS_FW200 := &"boss_fw200"
const KEY_BULLET_PLAYER := &"bullet_player"
const KEY_BULLET_ENEMY := &"bullet_enemy"
const KEY_PICKUP_REPAIR := &"pickup_repair"
const KEY_UI_BOMB := &"ui_bomb"
const KEY_UI_HP := &"ui_hp"
const KEY_UI_PAUSE := &"ui_pause"

## Размеры из таблицы Assets GDD. Единственный источник правды для визуала и производных хитбоксов.
const SIZES := {
	KEY_PLAYER_LA5: Vector2(48.0, 48.0),
	KEY_PLAYER_YAK3: Vector2(48.0, 48.0),
	KEY_PLAYER_P39: Vector2(48.0, 48.0),
	KEY_ENEMY_BF109: Vector2(40.0, 40.0),
	KEY_ENEMY_JU87: Vector2(48.0, 48.0),
	KEY_ENEMY_FW190: Vector2(44.0, 44.0),
	KEY_ENEMY_BF110: Vector2(64.0, 64.0),
	KEY_BOSS_HE111: Vector2(160.0, 96.0),
	KEY_BOSS_JU88: Vector2(160.0, 112.0),
	KEY_BOSS_FW200: Vector2(192.0, 128.0),
	KEY_BULLET_PLAYER: Vector2(4.0, 12.0),
	KEY_BULLET_ENEMY: Vector2(8.0, 8.0),
	KEY_PICKUP_REPAIR: Vector2(24.0, 24.0),
	KEY_UI_BOMB: Vector2(48.0, 48.0),
	KEY_UI_HP: Vector2(24.0, 24.0),
	KEY_UI_PAUSE: Vector2(32.0, 32.0),
}

const BULLET_DRAW_RADIUS := 4.0


## Размер ассета по ключу (с безопасным фолбэком, чтобы новый ключ не ломал отрисовку).
## Это же число — источник хитбоксов (EnemyBase: r = size_of(key).x × HIT_RADIUS_RATIO),
## поэтому менять SIZES ради «крупнее на экране» нельзя: для картинки есть draw_size_of().
static func size_of(asset_key: StringName) -> Vector2:
	var stored: Variant = SIZES.get(asset_key)
	if stored is Vector2:
		return stored
	return Vector2(48.0, 48.0)


## M11 (решение владельца D1): +25 % ТОЛЬКО к отрисовке моделек самолётов. SIZES и хитбоксы
## остаются прежними (баланс не меняется), поэтому масштаб живёт отдельным множителем, а не
## правкой таблицы размеров. 1.25 — дробный коэффициент: пиксель-арт при nearest получает
## неровный пиксель (1–2 px); принято владельцем «для начала».
const DRAW_SCALE := 1.25


## Размер ОТРИСОВКИ ассета по ключу: size_of(key) × DRAW_SCALE. Хитбоксы и SIZES не меняются.
## Ожидаемо: игрок 60, Bf 109 50, Ju 87 60, Fw 190 55, Bf 110 80,
## He 111 200×120, Ju 88 200×140, Fw 200 240×160.
static func draw_size_of(asset_key: StringName) -> Vector2:
	return size_of(asset_key) * DRAW_SCALE


## Отрисовка силуэта самолёта. face_down = нос вниз (враги летят на игрока).
## Рисуется в увеличенном прямоугольнике draw_size_of(), чтобы код-силуэт совпадал с PNG-артом
## (ShipVisual) — иначе при use_sprite_art=false модель «прыгала» бы на 20 %.
static func draw_ship(canvas: CanvasItem, asset_key: StringName, face_down: bool = false) -> void:
	var size := draw_size_of(asset_key)
	match asset_key:
		KEY_PLAYER_LA5:
			_draw_la5(canvas, size)
		# M6.2b: Як-3 и Аэрокобра — те же игровые силуэты (оливковый корпус + кремовый
		# контур), пока арт M7 не дал им отдельные формы. Серый фолбэк читался как враг —
		# и в ангаре, и в забеге. Перекраска ливреи идёт отдельно (Player.apply_livery).
		KEY_PLAYER_YAK3:
			_draw_la5(canvas, size)
		KEY_PLAYER_P39:
			_draw_la5(canvas, size)
		KEY_ENEMY_BF109:
			_draw_bf109(canvas, size, face_down)
		KEY_ENEMY_JU87:
			_draw_ju87(canvas, size)
		KEY_ENEMY_FW190:
			_draw_fw190(canvas, size)
		KEY_ENEMY_BF110:
			_draw_bf110(canvas, size)
		KEY_BOSS_HE111:
			_draw_he111(canvas, size)
		KEY_BOSS_JU88:
			_draw_ju88(canvas, size)
		KEY_BOSS_FW200:
			_draw_fw200(canvas, size)
		_:
			_draw_fallback_ship(canvas, size, ENEMY)


## Иконка подбора (pickup_repair, 24×24). Второго вида подбора нет: бомба не выпадает
## (GDD «Бомба»), поэтому иконка бомбы живёт только на кнопке HUD (ui_bomb, draw_bomb_icon).
static func draw_pickup_icon(canvas: CanvasItem, center: Vector2) -> void:
	var box := size_of(KEY_PICKUP_REPAIR)
	# Подложка — читаемый круг на любом фоне.
	canvas.draw_circle(center, box.x * 0.5, Color(CREAM, 0.85))
	canvas.draw_arc(center, box.x * 0.5, 0.0, TAU, 24, Color(PLAYER, 0.9), 1.5, true)
	# Ремкомплект: крест из двух кремовых/оливковых полос.
	var arm := box * 0.28
	var thick := box * 0.18
	canvas.draw_rect(Rect2(center - Vector2(arm.x, thick.y * 0.5), Vector2(arm.x * 2.0, thick.y)), PLAYER)
	canvas.draw_rect(Rect2(center - Vector2(thick.x * 0.5, arm.y), Vector2(thick.x, arm.y * 2.0)), PLAYER)


## Отрисовка пули в локальных координатах (центр = 0,0).
static func draw_bullet(canvas: CanvasItem, is_enemy: bool) -> void:
	if is_enemy:
		# Вражеская пуля: ярко-жёлтый круг 8×8 (GDD «Читаемость»).
		canvas.draw_circle(Vector2.ZERO, BULLET_DRAW_RADIUS, BULLET_ENEMY)
		canvas.draw_circle(Vector2.ZERO, BULLET_DRAW_RADIUS * 0.5, BULLET_ENEMY.lightened(0.45))
	else:
		# Снаряд игрока: белый трассер 4×12.
		var tracer := size_of(KEY_BULLET_PLAYER)
		canvas.draw_rect(Rect2(-tracer * 0.5, tracer), PLAYER_BULLET)


## Отрисовка ракеты «РС-82» в локальных координатах (центр = 0,0, летит вверх).
## Простой вектор-плейсхолдер до арта M7: кремовый корпус, тёмный носик, красный факел.
static func draw_rocket(canvas: CanvasItem) -> void:
	var body := Vector2(6.0, 14.0)
	canvas.draw_rect(Rect2(-body * 0.5, body), CREAM)
	# Носик — треугольник над корпусом (ракета смотрит вверх).
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(-body.x * 0.5, -body.y * 0.5),
		Vector2(body.x * 0.5, -body.y * 0.5),
		Vector2(0.0, -body.y * 0.5 - 4.0),
	]), CREAM.darkened(0.25))
	# Стабилизаторы.
	canvas.draw_rect(Rect2(Vector2(-body.x * 0.5 - 2.0, body.y * 0.5 - 3.0), Vector2(2.0, 3.0)),
		CREAM.darkened(0.15))
	canvas.draw_rect(Rect2(Vector2(body.x * 0.5, body.y * 0.5 - 3.0), Vector2(2.0, 3.0)),
		CREAM.darkened(0.15))
	# Факел: короткий клин под корпусом.
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(-body.x * 0.35, body.y * 0.5),
		Vector2(body.x * 0.35, body.y * 0.5),
		Vector2(0.0, body.y * 0.5 + 5.0),
	]), BULLET_ENEMY)


## Иконка HP (ui_hp, 24×24) в точке center. filled=true — HP есть: сердце DANGER
## с кремовым контуром (GDD «Читаемость»); filled=false — потерянный HP: приглушённая
## (полупрозрачная) версия той же формы, чтобы ряд из трёх иконок не «прыгал» по композиции.
static func draw_hp_icon(canvas: CanvasItem, center: Vector2, filled: bool) -> void:
	var r := size_of(KEY_UI_HP).x * 0.5
	var contour := Color(CREAM, 0.92) if filled else Color(CREAM, 0.30)
	var body := DANGER if filled else Color(ENEMY, 0.42)
	# Сердце = два круга + треугольник вершиной вниз. Внешний слой — контур, внутренний — заливка:
	# на 24×24 это даёт ~2 px кремовой обводки без шейдеров и второго прохода polyline.
	canvas.draw_circle(center + Vector2(-r * 0.40, -r * 0.28), r * 0.56, contour)
	canvas.draw_circle(center + Vector2(r * 0.40, -r * 0.28), r * 0.56, contour)
	canvas.draw_colored_polygon(
		PackedVector2Array([
			center + Vector2(-r * 0.94, -r * 0.30),
			center + Vector2(r * 0.94, -r * 0.30),
			center + Vector2(0.0, r * 0.92),
		]),
		contour
	)
	canvas.draw_circle(center + Vector2(-r * 0.39, -r * 0.26), r * 0.39, body)
	canvas.draw_circle(center + Vector2(r * 0.39, -r * 0.26), r * 0.39, body)
	canvas.draw_colored_polygon(
		PackedVector2Array([
			center + Vector2(-r * 0.74, -r * 0.28),
			center + Vector2(r * 0.74, -r * 0.28),
			center + Vector2(0.0, r * 0.68),
		]),
		body
	)


## Иконка бомбы (ui_bomb, 48×48) в точке center. enabled=false — кнопка без зарядов.
static func draw_bomb_icon(canvas: CanvasItem, center: Vector2, box_size: Vector2, enabled: bool) -> void:
	var k: float = box_size.x / 48.0
	var col := CREAM
	if not enabled:
		col.a = 0.35
	# Корпус: прямоугольник + скруглённый нос (бомба смотрит вниз).
	canvas.draw_rect(Rect2(center + Vector2(-8.0, -12.0) * k, Vector2(16.0, 18.0) * k), col)
	canvas.draw_circle(center + Vector2(0.0, 4.0) * k, 8.0 * k, col)
	# Стабилизатор.
	canvas.draw_colored_polygon(
		PackedVector2Array([
			center + Vector2(-12.0, -22.0) * k,
			center + Vector2(12.0, -22.0) * k,
			center + Vector2(5.0, -12.0) * k,
			center + Vector2(-5.0, -12.0) * k,
		]),
		col
	)
	# Взрыватель.
	canvas.draw_rect(Rect2(center + Vector2(-1.5, -27.0) * k, Vector2(3.0, 6.0) * k), col)


# ─── Внутренняя отрисовка ─────────────────────────────────────────────────────

## Ла-5: оливковый силуэт с кремовым контуром (GDD «Читаемость»), нос вверх.
static func _draw_la5(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 48.0
	var points := _scale_points(_la5_outline(), k)
	canvas.draw_colored_polygon(points, PLAYER)
	canvas.draw_polyline(_closed(points), CREAM, maxf(1.5, 2.0 * k.x), true)
	# Кабина — кремовая точка, чтобы силуэт читался на фоне неба.
	canvas.draw_circle(Vector2(0.0, -4.0) * k, 2.6 * k.x, CREAM)


## Bf 109: серый силуэт, нос вниз (летит на игрока), без кремового контура.
static func _draw_bf109(canvas: CanvasItem, size: Vector2, face_down: bool) -> void:
	var k := size / 40.0
	var points := _scale_points(_bf109_outline(), k)
	if not face_down:
		points = _flip_y(points)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.0, 1.5 * k.x), true)
	# Кабина чуть светлее корпуса — серый силуэт остаётся плоским, но читаемым.
	var cockpit := Vector2(0.0, 4.0) * k
	canvas.draw_circle(cockpit, 2.2 * k.x, ENEMY.lightened(0.3))


## Ju 87: серый силуэт с характерным «обратным» крылом, нос вниз.
static func _draw_ju87(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 48.0
	var points := _scale_points(_ju87_outline(), k)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.0, 1.5 * k.x), true)
	# Фонарь кабины — светлее корпуса.
	canvas.draw_circle(Vector2(0.0, -2.0) * k, 2.4 * k.x, ENEMY.lightened(0.3))
	# Неубирающиеся стойки шасси — опознавательная деталь «Штуки».
	var gear := maxf(1.0, 1.5 * k.x)
	canvas.draw_line(Vector2(-13.0, 4.0) * k, Vector2(-13.0, 13.0) * k, ENEMY.darkened(0.2), gear)
	canvas.draw_line(Vector2(13.0, 4.0) * k, Vector2(13.0, 13.0) * k, ENEMY.darkened(0.2), gear)


## Fw 190 (элита): серый силуэт + красный акцент (GDD «Читаемость»: элита — с красным акцентом).
static func _draw_fw190(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 44.0
	var points := _scale_points(_fw190_outline(), k)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.0, 1.5 * k.x), true)
	# Красные законцовки крыла + кольцо капота — единственный цветовой маркер элиты.
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(-22.0, -6.0) * k, Vector2(-17.0, -6.0) * k,
		Vector2(-17.0, -3.0) * k, Vector2(-22.0, -3.0) * k,
	]), DANGER)
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(22.0, -6.0) * k, Vector2(17.0, -6.0) * k,
		Vector2(17.0, -3.0) * k, Vector2(22.0, -3.0) * k,
	]), DANGER)
	canvas.draw_arc(Vector2(0.0, 11.0) * k, 5.0 * k.x, 0.0, TAU, 16, DANGER,
		maxf(1.5, 2.0 * k.x), true)


## He 111 (босс): широкий двухмоторный силуэт, нос вниз.
static func _draw_he111(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 160.0
	var points := _scale_points(_he111_outline(), k)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.5, 2.0 * k.x), true)
	for side: float in [-1.0, 1.0]:
		canvas.draw_rect(Rect2(Vector2(side * 40.0 - 9.0, -12.0) * k, Vector2(18.0, 30.0) * k),
			ENEMY.darkened(0.15))
		# Красный акцент на капоте — читаемая «опасность» босса.
		canvas.draw_rect(Rect2(Vector2(side * 40.0 - 7.0, 12.0) * k, Vector2(14.0, 5.0) * k), DANGER)
	# Остекление кабины.
	canvas.draw_rect(Rect2(Vector2(-9.0, 18.0) * k, Vector2(18.0, 10.0) * k), CREAM.darkened(0.1))


## Bf 110 (M5.2): двухмоторный тяжёлый истребитель, два киля, нос вниз.
static func _draw_bf110(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 64.0
	var points := _scale_points(_bf110_outline(), k)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.0, 1.5 * k.x), true)
	# Два киля — опознавательная деталь Bf 110 (в очертании они уже есть; контур усиливает).
	for side: float in [-1.0, 1.0]:
		canvas.draw_colored_polygon(PackedVector2Array([
			Vector2(side * 9.0, -29.0) * k, Vector2(side * 12.0, -21.0) * k,
			Vector2(side * 7.0, -21.0) * k, Vector2(side * 6.0, -29.0) * k,
		]), ENEMY.darkened(0.25))
	# Две мотогондолы на крыле.
	for side: float in [-1.0, 1.0]:
		canvas.draw_rect(Rect2(Vector2(side * 20.0 - 4.5, -3.0) * k, Vector2(9.0, 17.0) * k),
			ENEMY.darkened(0.15))
	# Кабина — светлее корпуса.
	canvas.draw_circle(Vector2(0.0, 8.0) * k, 2.6 * k.x, ENEMY.lightened(0.3))


## Ju 88 (босс M5.2): двухмоторный бомбардировщик, широкое крыло, остеклённый нос.
static func _draw_ju88(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 160.0
	var points := _scale_points(_ju88_outline(), k)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.5, 2.0 * k.x), true)
	# Мотогондолы + красный акцент на капотах (читаемая «опасность» босса).
	for side: float in [-1.0, 1.0]:
		canvas.draw_rect(Rect2(Vector2(side * 30.0 - 7.0, 2.0) * k, Vector2(14.0, 20.0) * k),
			ENEMY.darkened(0.15))
		canvas.draw_rect(Rect2(Vector2(side * 30.0 - 5.0, 17.0) * k, Vector2(10.0, 4.0) * k), DANGER)
	# Остеклённый нос и фонарь кабины.
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, 54.0) * k, Vector2(8.0, 40.0) * k,
		Vector2(6.0, 24.0) * k, Vector2(-6.0, 24.0) * k, Vector2(-8.0, 40.0) * k,
	]), CREAM.darkened(0.1))
	canvas.draw_rect(Rect2(Vector2(-7.0, 12.0) * k, Vector2(14.0, 9.0) * k), CREAM.darkened(0.1))


## Fw 200 (босс M5.2): четырёхмоторный, длинный фюзеляж, четыре гондолы.
static func _draw_fw200(canvas: CanvasItem, size: Vector2) -> void:
	var k := size / 192.0
	var points := _scale_points(_fw200_outline(), k)
	canvas.draw_colored_polygon(points, ENEMY)
	canvas.draw_polyline(_closed(points), ENEMY.darkened(0.35), maxf(1.5, 2.0 * k.x), true)
	# Четыре гондолы (внутренняя и внешняя пара) + красные акценты капотов.
	for side: float in [-1.0, 1.0]:
		for offset: float in [34.0, 62.0]:
			canvas.draw_rect(
				Rect2(Vector2(side * offset - 6.0, -12.0) * k, Vector2(12.0, 24.0) * k),
				ENEMY.darkened(0.15))
			canvas.draw_rect(
				Rect2(Vector2(side * offset - 4.0, 7.0) * k, Vector2(8.0, 4.0) * k), DANGER)
	# Длинный фюзеляж: остекление кабины ближе к носу.
	canvas.draw_rect(Rect2(Vector2(-8.0, 34.0) * k, Vector2(16.0, 12.0) * k), CREAM.darkened(0.1))


## Фолбэк для будущих типов врагов, пока для них нет силуэта.
static func _draw_fallback_ship(canvas: CanvasItem, size: Vector2, color: Color) -> void:
	var half := size * 0.5
	canvas.draw_colored_polygon(
		PackedVector2Array([
			Vector2(0.0, -half.y),
			Vector2(half.x, 0.0),
			Vector2(0.0, half.y),
			Vector2(-half.x, 0.0),
		]),
		color
	)


## Контур Ла-5 в пространстве 48×48 (центр в 0,0, нос в -Y).
static func _la5_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, -24.0), Vector2(3.0, -17.0), Vector2(4.5, -8.0),
		Vector2(23.0, -3.0), Vector2(24.0, 3.0), Vector2(6.0, 7.0),
		Vector2(5.0, 15.0), Vector2(11.0, 21.0), Vector2(11.0, 24.0),
		Vector2(4.0, 22.0), Vector2(0.0, 23.0), Vector2(-4.0, 22.0),
		Vector2(-11.0, 24.0), Vector2(-11.0, 21.0), Vector2(-5.0, 15.0),
		Vector2(-6.0, 7.0), Vector2(-24.0, 3.0), Vector2(-23.0, -3.0),
		Vector2(-4.5, -8.0), Vector2(-3.0, -17.0),
	])


## Контур Bf 109 в пространстве 40×40 (центр в 0,0, нос в +Y — сверху вниз).
static func _bf109_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 20.0), Vector2(2.5, 14.0), Vector2(3.6, 6.0),
		Vector2(19.0, 1.0), Vector2(20.0, -3.0), Vector2(5.0, -6.0),
		Vector2(4.0, -13.0), Vector2(9.0, -17.0), Vector2(9.0, -20.0),
		Vector2(0.0, -19.0), Vector2(-9.0, -20.0), Vector2(-9.0, -17.0),
		Vector2(-4.0, -13.0), Vector2(-5.0, -6.0), Vector2(-20.0, -3.0),
		Vector2(-19.0, 1.0), Vector2(-3.6, 6.0), Vector2(-2.5, 14.0),
	])


## Контур Ju 87 в пространстве 48×48 (нос в +Y, «обратное» крыло).
static func _ju87_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 24.0), Vector2(3.0, 16.0), Vector2(6.0, 8.0),
		Vector2(23.0, 6.0), Vector2(24.0, 2.0), Vector2(7.0, -2.0),
		Vector2(5.0, -10.0), Vector2(15.0, -17.0), Vector2(14.0, -24.0),
		Vector2(0.0, -22.0), Vector2(-14.0, -24.0), Vector2(-15.0, -17.0),
		Vector2(-5.0, -10.0), Vector2(-7.0, -2.0), Vector2(-24.0, 2.0),
		Vector2(-23.0, 6.0), Vector2(-6.0, 8.0), Vector2(-3.0, 16.0),
	])


## Контур Fw 190 в пространстве 44×44 (нос в +Y, широкий капот).
static func _fw190_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 22.0), Vector2(4.0, 14.0), Vector2(5.0, 6.0),
		Vector2(21.0, 2.0), Vector2(22.0, -2.0), Vector2(6.0, -6.0),
		Vector2(5.0, -13.0), Vector2(10.0, -18.0), Vector2(10.0, -21.0),
		Vector2(0.0, -20.0), Vector2(-10.0, -21.0), Vector2(-10.0, -18.0),
		Vector2(-5.0, -13.0), Vector2(-6.0, -6.0), Vector2(-22.0, -2.0),
		Vector2(-21.0, 2.0), Vector2(-5.0, 6.0), Vector2(-4.0, 14.0),
	])


## Контур He 111 в пространстве 160×96 (нос в +Y, двухмоторный бомбардировщик).
static func _he111_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 48.0), Vector2(5.0, 32.0), Vector2(7.0, 16.0),
		Vector2(80.0, 8.0), Vector2(80.0, -4.0), Vector2(20.0, -10.0),
		Vector2(18.0, -28.0), Vector2(46.0, -40.0), Vector2(44.0, -46.0),
		Vector2(-44.0, -46.0), Vector2(-46.0, -40.0), Vector2(-18.0, -28.0),
		Vector2(-20.0, -10.0), Vector2(-80.0, -4.0), Vector2(-80.0, 8.0),
		Vector2(-7.0, 16.0), Vector2(-5.0, 32.0),
	])


## Контур Bf 110 в пространстве 64×64 (нос в +Y, тяжёлый двухмоторный истребитель,
## хвост с двумя килями).
static func _bf110_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 32.0), Vector2(3.5, 26.0), Vector2(5.0, 14.0),
		Vector2(28.0, 9.0), Vector2(31.0, 4.0), Vector2(29.0, 0.0),
		Vector2(9.0, -4.0), Vector2(7.0, -18.0), Vector2(12.0, -24.0),
		Vector2(9.0, -30.0), Vector2(2.0, -28.0), Vector2(0.0, -30.0),
		Vector2(-2.0, -28.0), Vector2(-9.0, -30.0), Vector2(-12.0, -24.0),
		Vector2(-7.0, -18.0), Vector2(-9.0, -4.0), Vector2(-29.0, 0.0),
		Vector2(-31.0, 4.0), Vector2(-28.0, 9.0), Vector2(-5.0, 14.0),
		Vector2(-3.5, 26.0),
	])


## Контур Ju 88 в пространстве 160×112 (нос в +Y, широкое крыло, остеклённый нос).
static func _ju88_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 56.0), Vector2(6.0, 42.0), Vector2(9.0, 22.0),
		Vector2(78.0, 16.0), Vector2(80.0, 6.0), Vector2(13.0, 1.0),
		Vector2(11.0, -16.0), Vector2(26.0, -26.0), Vector2(46.0, -44.0),
		Vector2(42.0, -54.0), Vector2(-42.0, -54.0), Vector2(-46.0, -44.0),
		Vector2(-26.0, -26.0), Vector2(-11.0, -16.0), Vector2(-13.0, 1.0),
		Vector2(-80.0, 6.0), Vector2(-78.0, 16.0), Vector2(-9.0, 22.0),
		Vector2(-6.0, 42.0),
	])


## Контур Fw 200 в пространстве 192×128 (нос в +Y, длинный фюзеляж, четыре гондолы).
static func _fw200_outline() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.0, 64.0), Vector2(5.0, 50.0), Vector2(7.0, 20.0),
		Vector2(94.0, 12.0), Vector2(96.0, 2.0), Vector2(10.0, -6.0),
		Vector2(9.0, -30.0), Vector2(30.0, -40.0), Vector2(54.0, -56.0),
		Vector2(50.0, -64.0), Vector2(-50.0, -64.0), Vector2(-54.0, -56.0),
		Vector2(-30.0, -40.0), Vector2(-9.0, -30.0), Vector2(-10.0, -6.0),
		Vector2(-96.0, 2.0), Vector2(-94.0, 12.0), Vector2(-7.0, 20.0),
		Vector2(-5.0, 50.0),
	])


static func _scale_points(points: PackedVector2Array, factor: Vector2) -> PackedVector2Array:
	var scaled := PackedVector2Array()
	scaled.resize(points.size())
	for i in points.size():
		scaled[i] = points[i] * factor
	return scaled


static func _flip_y(points: PackedVector2Array) -> PackedVector2Array:
	var flipped := PackedVector2Array()
	flipped.resize(points.size())
	for i in points.size():
		flipped[i] = Vector2(points[i].x, -points[i].y)
	return flipped


## Замкнутый контур для draw_polyline.
static func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var closed := points.duplicate()
	if closed.size() > 0:
		closed.append(closed[0])
	return closed
