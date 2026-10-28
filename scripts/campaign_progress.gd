# campaign_progress.gd
# Purpose: Засчёт результата миссии (M5.3a; GDD «Счёт, звёзды, снабжение»): звёзды по трём
#          критериям, рекорд миссии, снабжение и открытие следующих миссий. Единственная
#          точка, где LevelController превращает исход забега в мета-прогресс, — экран выбора
#          миссии (M5.3b) и ангар (M6) будут читать готовые данные, не повторяя формулы.
#          Звёзды: 0 при поражении; иначе 1 (миссия пройдена) + 1 (hp >= 1) +
#          1 (score >= star_score миссии из data/missions.json).
#          Снабжение: score / 40 + 150 × звёзд ТОЛЬКО при победе (GDD, (tune) значения).
#          Открытие миссий: m1 всегда, m2 при 1 звезде, m3 при 3 суммарно — правило живёт
#          в SaveGame.is_mission_unlocked, здесь только фиксируется «что открылось именно
#          этим результатом» (для экрана итогов M5.3b).
#          M6.2a: открытие самолётов ангара (GDD «Самолёты (ангар)»): Як-3 — когда все три
#          миссии имеют ≥1 звезду, Аэрокобра — при 9/9 звёзд кампании. Открытие только на
#          победе и только один раз (флаг профиля); id, открытые именно этим результатом,
#          возвращаются в newly_unlocked_planes для экрана итогов.
# Dependencies: SaveGame (запись звёзд/рекордов/снабжения/самолётов), MissionData.MISSION_IDS
#               (порядок миссий). Узлов и сигналов нет — RefCounted-утилита.
# Author: Mechanics Developer Agent
#
#   CampaignProgress.evaluate(won, hp, score, star_score) -> int       0…3
#   CampaignProgress.finish_mission(id, won, hp, score, star_score) -> Dictionary
#       {stars, best, is_new, total_stars, supply_gained, supply_total, newly_unlocked,
#        newly_unlocked_planes}
#   star_score миссии берётся из данных: MissionData.get_star_score(id).

class_name CampaignProgress
extends RefCounted

## (tune) GDD «Счёт, звёзды, снабжение»: снабжение = score / 40 + 150 × звёзд.
const SUPPLY_SCORE_DIVISOR := 40
const SUPPLY_PER_STAR := 150

## GDD «Самолёты (ангар)»: Як-3 — кампания пройдена (у каждой из трёх миссий ≥1 звезда),
## Аэрокобра — 9/9 звёзд. Порог для Аэрокобры — все звёзды кампании.
const P39_STARS_REQUIRED := 9


## Звёзды за один исход. Поражение — ноль: рекорд/снабжение/звёзды не начисляются вовсе.
## hp — ОСТАВШЕЕСЯ HP на момент победы (3 → третья звезда за «сохранено ≥1 HP»).
static func evaluate(won: bool, hp: int, score: int, star_score: int) -> int:
	if not won:
		return 0
	var stars := 1
	if hp >= 1:
		stars += 1
	if score >= star_score:
		stars += 1
	return stars


## Засчитать исход миссии и вернуть снимок для экрана итогов.
## Победа: звёзды (только максимум), рекорд миссии (только вверх), снабжение по формуле.
## Поражение: НИЧЕГО не пишется — stars=0, supply_gained=0, best остаётся прежним.
## newly_unlocked — id миссий, которые были закрыты до этого результата и открылись после
## (обычно одна: m2_crossing после первой звезды, m3_city — при 3 суммарных).
static func finish_mission(
	mission_id: String, won: bool, hp: int, score: int, star_score: int
) -> Dictionary:
	# Открытие ДО записи: иначе не отличить «открылось сейчас» от «было открыто раньше».
	var unlocked_before := {}
	for id: String in MissionData.MISSION_IDS:
		unlocked_before[id] = SaveGame.is_mission_unlocked(id)

	var stars := evaluate(won, hp, score, star_score)
	var best := SaveGame.get_mission_best(mission_id)
	var is_new := false
	var supply_gained := 0
	# Поражение: только чтение уже существующего профиля (возможная разовая миграция v1 —
	# это не запись результата). Ни звёзд, ни снабжения, ни рекорда миссии не появляется.
	if won:
		SaveGame.record_stars(mission_id, stars)
		var result: Dictionary = SaveGame.record_mission_result(mission_id, score)
		best = int(result.get("best", best))
		is_new = bool(result.get("is_new", false))
		# Отрицательный счёт в снабжение не идёт: score / 40 клампится в 0.
		supply_gained = maxi(0, score) / SUPPLY_SCORE_DIVISOR + SUPPLY_PER_STAR * stars
		SaveGame.add_supply(supply_gained)

	var newly_unlocked: Array[String] = []
	for id: String in MissionData.MISSION_IDS:
		if not bool(unlocked_before.get(id, false)) and SaveGame.is_mission_unlocked(id):
			newly_unlocked.append(id)

	# M6.2a: самолёты ангара. Только победа: поражение не открывает ничего (даже если
	# условия по уже накопленным звёздам выполнены — это не результат этого забега).
	var newly_unlocked_planes: Array[String] = []
	if won:
		newly_unlocked_planes = _unlock_planes()

	return {
		"stars": stars,
		"best": best,
		"is_new": is_new,
		"total_stars": SaveGame.total_stars(),
		"supply_gained": supply_gained,
		"supply_total": SaveGame.get_supply(),
		"newly_unlocked": newly_unlocked,
		"newly_unlocked_planes": newly_unlocked_planes,
	}


## Открыть самолёты, условия которых выполнены СЕЙЧАС. Возвращает только те id, которые
## были закрыты до вызова и открылись им (повторно уже открытые не попадают в список).
static func _unlock_planes() -> Array[String]:
	var opened: Array[String] = []
	if _campaign_complete() and not SaveGame.is_plane_unlocked(SaveGame.PLANE_YAK3):
		if SaveGame.unlock_plane(SaveGame.PLANE_YAK3):
			opened.append(SaveGame.PLANE_YAK3)
	if SaveGame.total_stars() >= P39_STARS_REQUIRED \
			and not SaveGame.is_plane_unlocked(SaveGame.PLANE_P39):
		if SaveGame.unlock_plane(SaveGame.PLANE_P39):
			opened.append(SaveGame.PLANE_P39)
	return opened


## «Полное прохождение кампании» (GDD): у КАЖДОЙ миссии хотя бы одна звезда.
static func _campaign_complete() -> bool:
	for id: String in MissionData.MISSION_IDS:
		if SaveGame.get_stars(id) < 1:
			return false
	return true
