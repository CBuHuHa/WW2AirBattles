# juice_lab.gd
# Purpose: Демо-сцена M4 «Juice Lab» — 6 крупных тач-зон проверяют тряску, hit-stop,
#          белую вспышку и плейсхолдерные взрывы БЕЗ встраивания в геймплей (интеграция M4 —
#          отдельный шаг LevelController'ом). Ввод строго ScreenTouch.
# Dependencies: ScreenShake, HitStop, HitFlash, Explosions, ArtStyle, GameConfig.
# Author: Game Feel Developer Agent

extends Node2D

@onready var _world: Node2D = $World
@onready var _grid: GridContainer = $UI/Grid

var _shake: ScreenShake
var _hit_stop: HitStop
var _probe: Node2D


func _ready() -> void:
	# project.godot НЕ меняем (правило параллельной работы): тач-эмуляция для мыши
	# включается кодом сцены — на Androidе она не влияет, в редакторе даёт тап мышью.
	Input.set_emulate_touch_from_mouse(true)

	_install_shake_wrapper()
	_hit_stop = HitStop.new()
	_hit_stop.name = "HitStop"
	add_child(_hit_stop)

	_probe = _Probe.new()
	_probe.name = "Probe"
	_world.add_child(_probe)
	_probe.position = GameConfig.REFERENCE_SIZE * 0.5

	_wire_zones()


## World переподчиняется под ScreenShake: обёртка смещает СВОЙ position —
## порядок add_child выдержан, global_position до add_child не читается.
func _install_shake_wrapper() -> void:
	_shake = ScreenShake.new()
	_shake.name = "ScreenShake"
	add_child(_shake)
	_world.reparent(_shake)


func _wire_zones() -> void:
	_zone("BtnShakePlayerHit").pressed.connect(_demo_shake_player_hit)
	_zone("BtnShakeBomb").pressed.connect(_demo_shake_bomb)
	_zone("BtnShakeBoss").pressed.connect(_demo_shake_boss)
	_zone("BtnFlash").pressed.connect(_demo_flash)
	_zone("BtnExpSmall").pressed.connect(_demo_explosion_small)
	_zone("BtnExpBoss").pressed.connect(_demo_explosion_boss)


func _zone(button_name: String) -> Button:
	return _grid.get_node(button_name) as Button


# ─── Демо-действия зон ───────────────────────────────────────────────────────

## GDD «Game feel»: 4 px / 0.15 с — попадание по игроку.
func _demo_shake_player_hit() -> void:
	_shake.shake(ScreenShake.SHAKE_PLAYER_HIT.x, ScreenShake.SHAKE_PLAYER_HIT.y)


## GDD «Game feel»: 6 px / 0.25 с — бомба; GDD: hit-stop 2–3 кадра.
func _demo_shake_bomb() -> void:
	_shake.shake(ScreenShake.SHAKE_BOMB.x, ScreenShake.SHAKE_BOMB.y)
	_hit_stop.freeze(2)


## GDD «Game feel»: 8 px / 0.4 с — смерть босса.
func _demo_shake_boss() -> void:
	_shake.shake(ScreenShake.SHAKE_BOSS_DEATH.x, ScreenShake.SHAKE_BOSS_DEATH.y)


func _demo_flash() -> void:
	HitFlash.flash(_probe)


func _demo_explosion_small() -> void:
	Explosions.spawn(_world, _probe.global_position, false)


func _demo_explosion_boss() -> void:
	Explosions.spawn(_world, _probe.global_position, true)


# ─── Внутренние узлы демо ────────────────────────────────────────────────────

## Плоский вектор Ла-5 из общего арт-пайплайна (ArtStyle) — тот же силуэт, что в игре.
class _Probe extends Node2D:
	func _draw() -> void:
		ArtStyle.draw_ship(self, ArtStyle.KEY_PLAYER_LA5)
