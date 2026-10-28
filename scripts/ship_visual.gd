# ship_visual.gd
# Purpose: Визуал самолёта по ключу ассета GDD. M7b: если для ключа есть PNG в assets/art
#          (ArtAssets, с временным маппингом Bf 110 / боссов), рисуется пиксель-арт в
#          прямоугольник ArtStyle.draw_size_of(ключ) с фильтром nearest; иначе — прежний код-силуэт
#          ArtStyle.draw_ship(). Хитбоксы, сцены и SIZES не меняются: текстура масштабируется
#          в увеличенный прямоугольник отрисовки (SIZES × ArtStyle.DRAW_SCALE, M11/T5), а хитбокс
#          по-прежнему считается от SIZES (EnemyBase), поэтому +25 % картинки не меняет баланс.
#          Спрайты из листа SpriteCook нарисованы «носом вверх», поэтому face_down поворачивает
#          текстуру по вертикали (flip_v) — враги, как и у код-силуэтов, летят носом на игрока.
# Dependencies: ArtStyle (размеры/силуэты), ArtAssets (кэш текстур).
# Author: Mechanics Developer Agent (M1), Technical Artist Agent (M7b)

class_name ShipVisual
extends Node2D

## Ключ ассета GDD «Assets» (player_la5, enemy_bf109, enemy_ju87, enemy_fw190, boss_he111).
@export var asset_key: StringName = ArtStyle.KEY_PLAYER_LA5:
	set(value):
		asset_key = value
		_refresh_texture()
		if is_inside_tree():
			queue_redraw()

## Нос вниз — для врагов, летящих на игрока.
@export var face_down: bool = false:
	set(value):
		face_down = value
		if is_inside_tree():
			queue_redraw()

## M7b: рисовать пиксель-арт, если файл есть. false — принудительный код-силуэт (фолбэк для
## QA/сравнения картинок; ArtStyle остаётся рабочим до конца арт-пасса).
@export var use_sprite_art: bool = true:
	set(value):
		use_sprite_art = value
		_refresh_texture()
		if is_inside_tree():
			queue_redraw()

## Текущая текстура (null — рисуем силуэт). Разрешается при смене ключа/флага и в _ready().
var _texture: Texture2D = null
## Конечный ключ файла (после временного маппинга) — для QA; &"" без текстуры.
var _texture_key: StringName = &""


func _ready() -> void:
	# Nearest только на этом узле (не глобально): пиксель-арт не должен размываться при
	# масштабе 64→40/44/48, а векторный HUD и шрифты живут по своим настройкам.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_refresh_texture()
	queue_redraw()


func _draw() -> void:
	if _texture != null:
		var size := ArtStyle.draw_size_of(asset_key)
		# M11/T5: картинка на 25 % крупнее прямоугольника из таблицы Assets (SIZES) — хитбокс
		# остаётся прежним, поэтому визуал чуть «выступает» за радиус столкновения.
		# Спрайты нарисованы носом вверх, а враги летят на игрока — для них кадр отражается
		# по вертикали (draw_texture_rect в 4.x не умеет flip_v, поэтому отражение задаётся
		# трансформом вокруг центра силуэта).
		if face_down:
			draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, -1.0))
		draw_texture_rect(_texture, Rect2(-size * 0.5, size), false)
		if face_down:
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	ArtStyle.draw_ship(self, asset_key, face_down)


## QA/тесты: рисуется ли сейчас текстура (а не код-силуэт).
func is_using_texture() -> bool:
	return _texture != null


## QA/тесты: конечный ключ загруженного PNG (&"" — текстуры нет, работает ArtStyle).
func get_texture_key() -> StringName:
	return _texture_key


## Пересобрать текстуру под текущие asset_key/use_sprite_art. Вызывается сеттерами (в т.ч.
## до входа в дерево — ArtAssets кэширует, поэтому повторные вызовы бесплатны).
func _refresh_texture() -> void:
	if not use_sprite_art:
		_texture = null
		_texture_key = &""
		return
	_texture = ArtAssets.texture(asset_key)
	_texture_key = ArtAssets.render_key(asset_key) if _texture != null else &""
