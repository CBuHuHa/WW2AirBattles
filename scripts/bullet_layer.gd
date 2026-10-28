# bullet_layer.gd
# Purpose: Контейнер снарядов. Единая точка создания, очистки и подсчёта пуль.
#          Умеет мгновенно убирать вражеские пули (взрыв бомбы), все пули (рестарт)
#          и вражеские пули в радиусе (M6.1a «Аварийный сброс»).
#          M6.1a: урон float, плюс параметры перков (урон по боссу, осколки, ракета).
#          M6.2a: радиус хитбокса пули игрока — параметр fire_player/spawn (GDD «Самолёты»:
#          4 px у Ла-5/Як-3, 6 px у Аэрокобры); по умолчанию — 5 px (прежние вызовы, враги).
# Dependencies: Bullet, GameConfig.
# Author: Mechanics Developer Agent

class_name BulletLayer
extends Node2D

const BULLET_SCENE: PackedScene = preload("res://scenes/bullet.tscn")


## Создать снаряд. Вызывается через fire_player/fire_enemy/spawn_rocket
## (сигнатуры 3–4 аргумента совпадают с прежними сигналами стрельбы).
func spawn(
	kind: Bullet.Kind,
	origin: Vector2,
	velocity: Vector2,
	damage: float,
	boss_damage_mult: float = 1.0,
	splash_radius: float = 0.0,
	splash_ratio: float = 0.0,
	is_rocket: bool = false,
	hit_radius: float = Bullet.DEFAULT_HIT_RADIUS
) -> Bullet:
	var bullet: Bullet = BULLET_SCENE.instantiate()
	bullet.setup(kind, origin, velocity, damage, boss_damage_mult, splash_radius,
		splash_ratio, is_rocket, hit_radius)
	add_child(bullet)
	return bullet


## Сигнатура подходит для Player.shot_fired (3 аргумента); остальные — перки M6.1a и
## радиус пули самолёта M6.2a.
func fire_player(
	origin: Vector2,
	velocity: Vector2,
	damage: float,
	boss_damage_mult: float = 1.0,
	splash_radius: float = 0.0,
	splash_ratio: float = 0.0,
	bullet_hit_radius: float = Bullet.DEFAULT_HIT_RADIUS
) -> void:
	spawn(Bullet.Kind.PLAYER, origin, velocity, damage, boss_damage_mult, splash_radius,
		splash_ratio, false, bullet_hit_radius)


## «РС-82»: ракета с полным уроном в радиусе взрыва (GDD: 4 урона, радиус 40 px).
## boss_damage_mult — «Тяжёлый калибр»: +30% по боссу относится ко всему урону игрока.
## Возвращает созданный снаряд (нужно QA/тестам для проверки полей).
func spawn_rocket(
	origin: Vector2,
	velocity: Vector2,
	damage: float,
	radius: float,
	boss_damage_mult: float = 1.0
) -> Bullet:
	return spawn(Bullet.Kind.PLAYER, origin, velocity, damage, boss_damage_mult, radius, 1.0, true)


## Сигнатура подходит для EnemyBase.shot_fired.
func fire_enemy(origin: Vector2, velocity: Vector2, damage: int) -> void:
	spawn(Bullet.Kind.ENEMY, origin, velocity, float(damage))


## Очистить все вражеские пули на экране (GDD «Бомба»). Возвращает число убранных пуль.
func clear_enemy_bullets() -> int:
	var cleared := 0
	for child in get_children():
		var bullet := child as Bullet
		if bullet != null and bullet.kind == Bullet.Kind.ENEMY:
			bullet.despawn()
			cleared += 1
	return cleared


## Очистить вражеские пули в радиусе (M6.1a «Аварийный сброс»: 120 px вокруг игрока).
## Возвращает число убранных пуль. Триггер — M6.1b (в обработчике урона игрока).
func clear_enemy_bullets_in_radius(center: Vector2, radius: float) -> int:
	if radius <= 0.0:
		return 0
	var cleared := 0
	for child in get_children():
		var bullet := child as Bullet
		if bullet == null or bullet.kind != Bullet.Kind.ENEMY:
			continue
		if bullet.global_position.distance_to(center) <= radius:
			bullet.despawn()
			cleared += 1
	return cleared


## Очистить все снаряды игрока (окно исхода: автострельба не должна добивать врагов
## после того, как исход забега уже решён). Возвращает число убранных снарядов.
func clear_player_bullets() -> int:
	var cleared := 0
	for child in get_children():
		var bullet := child as Bullet
		if bullet != null and bullet.kind == Bullet.Kind.PLAYER:
			bullet.despawn()
			cleared += 1
	return cleared


## Очистить все пули (рестарт уровня).
func clear_all() -> void:
	for child in get_children():
		var bullet := child as Bullet
		if bullet != null:
			bullet.despawn()


## Количество живых пуль (нужно тестам/QA, в геймплее не используется).
func count_bullets(enemy_only: bool = false) -> int:
	var total := 0
	for child in get_children():
		var bullet := child as Bullet
		if bullet == null or bullet.is_queued_for_deletion():
			continue
		if enemy_only and bullet.kind != Bullet.Kind.ENEMY:
			continue
		total += 1
	return total
