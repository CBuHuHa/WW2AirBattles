# enemy_ju87.gd
# Purpose: Ju 87 «Штука» — средний враг. Спускается сквозь поле и бьёт веером из 3 пуль;
#          после прохода за нижний край тихо удаляется (despawn, без очков).
# Dependencies: EnemyBase, ArtStyle.
# Author: Mechanics Developer Agent

class_name EnemyJu87
extends EnemyBase

# ─── Тюнинг (GDD «Волны и враги» → Ju 87) ────────────────────────────────────
const JU87_HP := 8                            # GDD: 8 HP (было 12 × 0.7 ≈ 8.4)
const JU87_SCORE := 150                        # GDD: 150 очков (tune)
const JU87_SPEED := 120.0                      # GDD: 120 px/s (tune)
const JU87_FIRE_INTERVAL := 2.0                # GDD: веер из 3 пуль каждые 2 с (tune)
const JU87_BULLET_SPEED := 280.0               # GDD: 260–420 px/s
const JU87_FAN_ANGLES := [-24.0, 0.0, 24.0]    # (tune) веер из 3 пуль, отклонение от вертикали


func _init() -> void:
	asset_key = ArtStyle.KEY_ENEMY_JU87
	max_hp = JU87_HP
	hp = JU87_HP
	score_value = JU87_SCORE
	fire_interval = JU87_FIRE_INTERVAL
	bullet_speed = JU87_BULLET_SPEED
	bullet_damage = 1
	face_down = true


## Ровный спуск: Ju 87 не патрулирует, а проходит поле насквозь (уход за экран — деспавн).
## M6.3a: скорость множится на speed_mult (EndlessRules.enemy_speed_mult).
func _move(delta: float) -> void:
	position.y += JU87_SPEED * speed_mult * delta


## Веер из 3 пуль вниз и по диагоналям (прицел не нужен — зона покрытия).
func _fire_at_target() -> void:
	var origin := _muzzle_position()
	for angle_deg: float in JU87_FAN_ANGLES:
		fire_direction(origin, Vector2.DOWN.rotated(deg_to_rad(angle_deg)), bullet_speed, bullet_damage)
