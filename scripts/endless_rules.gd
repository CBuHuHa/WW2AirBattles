# endless_rules.gd
# Purpose: Правила бесконечного режима M6.3a (GDD «Бесконечный режим»): чистые статические
#          формулы роста сложности, состава волн и боссов. Никаких узлов, сигналов и состояния:
#          `WaveManager` (генерация волн), `EnemyBase.apply_difficulty` (множители) и
#          `LevelController` (счёт, перки, рекорд) читают ОДНИ И ТЕ ЖЕ числа отсюда, поэтому
#          баланс правится в одном месте и проверяется тестом без запуска уровня.
#
#          ЕДИНИЦА ИЗМЕРЕНИЯ — номер волны `n`, нумерация с 1 (волна 1 — первая). Индекс
#          массива волн в `WaveManager` 0-based: `n = index + 1`.
#
#          Формулы (GDD «Бесконечный режим», все значения (tune)):
#            врагов в волне      clampi(3 + floor(n/2), 3, 12)
#            скорость врагов     min(1.5, 1 + 0.015 × (n−1))
#            скорость пуль       min(1.8, 1 + 0.025 × (n−1))
#            HP врагов           1.0 до 20-й волны, дальше 1 + 0.06 × (n−20)
#            босс                каждая 10-я волна, тип по кругу He 111 → Ju 88 → Fw 200,
#                                HP ×(1 + 0.15 × круг), круг 0 для волны 10
#            множитель счёта     1.05 ^ (пройдено волн)
#            ремкомплект         каждая 5-я волна
#            перки               каждая 2-я волна
#          Состав волн ДЕТЕРМИНИРОВАН (без рандома): тесты и QA должны получать один и тот же
#          набор бортов на одном и том же номере волны.
# Dependencies: нет (только константы и чистые функции). Обратных зависимостей нет.
# Author: Mechanics Developer Agent

class_name EndlessRules
extends RefCounted

# ─── Плотность волны ────────────────────────────────────────────────────────
## GDD: «врагов 3 + floor(n/2) (потолок 12)».
const BASE_ENEMY_COUNT := 3
const MAX_ENEMY_COUNT := 12
## Прирост плотности: один враг на каждые две волны (floor(n/2) в формуле GDD).
const WAVES_PER_EXTRA_ENEMY := 2

# ─── Скорости и HP ──────────────────────────────────────────────────────────
## GDD: «скорость врагов +1.5% за волну (потолок +50%)».
const SPEED_STEP := 0.015
const SPEED_CAP := 1.5
## GDD: «скорость пуль +2.5% за волну (потолок +80%)».
const BULLET_SPEED_STEP := 0.025
const BULLET_SPEED_CAP := 1.8
## GDD: «HP обычных врагов не растёт до 20-й волны, дальше ×(1 + 0.06×(n−20))».
const HP_GROWTH_FREE_WAVES := 20
const HP_STEP := 0.06

# ─── Боссы ──────────────────────────────────────────────────────────────────
## Босс каждые 10 волн; тип по кругу (GDD: He 111 → Ju 88 → Fw 200).
const BOSS_WAVE_STEP := 10
const BOSS_TYPES: Array[String] = ["he111", "ju88", "fw200"]
## GDD: «HP ×(1 + 0.15 × круг)», круг 0 у первого босса (волна 10).
const BOSS_HP_STEP := 0.15

# ─── Счёт, ремкомплект, перки ───────────────────────────────────────────────
## GDD: «счёт ×1.05 за каждую пройденную волну».
const SCORE_STEP := 1.05
## GDD: «ремкомплект — из последнего элитного врага каждые 5 волн».
const REPAIR_WAVE_STEP := 5
## GDD: «перки — 1 из 2 каждые 2 волны».
const PERK_WAVE_STEP := 2


# ─── Формулы ────────────────────────────────────────────────────────────────
## Сколько врагов в волне `wave_number`. Волны 1 → 3, 2 → 4, 10 → 8, 20+ → 12.
## Номер волны ≤ 0 трактуется как первая (защита от индексов 0-based по ошибке).
static func enemy_count(wave_number: int) -> int:
	var wave := maxi(1, wave_number)
	var extra := wave / WAVES_PER_EXTRA_ENEMY  # floor(wave / 2), целочисленное деление
	return clampi(BASE_ENEMY_COUNT + extra, BASE_ENEMY_COUNT, MAX_ENEMY_COUNT)


## Множитель скорости движения обычных врагов. Волна 1 — 1.0, потолок 1.5 (с 35-й волны).
static func enemy_speed_mult(wave_number: int) -> float:
	var wave := maxi(1, wave_number)
	return minf(SPEED_CAP, 1.0 + SPEED_STEP * float(wave - 1))


## Множитель скорости вражеских пуль. Волна 1 — 1.0, потолок 1.8 (с 33-й волны).
static func bullet_speed_mult(wave_number: int) -> float:
	var wave := maxi(1, wave_number)
	return minf(BULLET_SPEED_CAP, 1.0 + BULLET_SPEED_STEP * float(wave - 1))


## Множитель HP обычных врагов: 1.0 по 20-ю волну включительно, дальше +6% за волну.
static func hp_mult(wave_number: int) -> float:
	var wave := maxi(1, wave_number)
	if wave <= HP_GROWTH_FREE_WAVES:
		return 1.0
	return 1.0 + HP_STEP * float(wave - HP_GROWTH_FREE_WAVES)


## Тип босса по кругу: круг 0 → he111, 1 → ju88, 2 → fw200, 3 → снова he111.
## Отрицательный круг трактуется как 0 (боевой код такой не передаёт).
static func boss_type(cycle: int) -> String:
	return BOSS_TYPES[posmod(maxi(0, cycle), BOSS_TYPES.size())]


## Множитель HP босса: круг 0 — 1.0, дальше +15% за круг (1.15 / 1.3 / 1.45).
static func boss_hp_mult(cycle: int) -> float:
	return 1.0 + BOSS_HP_STEP * float(maxi(0, cycle))


## Множитель счёта после `waves_cleared` пройденных волн: 1.05^n (0 → 1.0).
static func score_multiplier(waves_cleared: int) -> float:
	return pow(SCORE_STEP, float(maxi(0, waves_cleared)))


## Волна с боссом: каждая 10-я. Нумерация с 1, поэтому волна 0 (не существует в забеге)
## боссом НЕ считается — иначе пустой индекс 0 обрывал бы первую волну.
static func is_boss_wave(wave_number: int) -> bool:
	return wave_number > 0 and wave_number % BOSS_WAVE_STEP == 0


## Волна с ремкомплектом: каждая 5-я (5 / 10 / 15 …).
static func is_repair_wave(wave_number: int) -> bool:
	return wave_number > 0 and wave_number % REPAIR_WAVE_STEP == 0


## Волна с предложением перка: каждая 2-я (2 / 4 / 6 …).
static func is_perk_wave(wave_number: int) -> bool:
	return wave_number > 0 and wave_number % PERK_WAVE_STEP == 0


## Состав волны: тип врага на слоте `slot_index` (0-based). Детерминированно, без рандома.
##   волны 1–4   — только Bf 109 (ввод в режим на знакомом враге);
##   волны 5–9   — Bf 109 / Ju 87 (появляется «толстый» враг → ремкомплект волны 5);
##   волны 10–14 — Ju 87 / Fw 190;
##   волны 15+   — Fw 190 / Bf 110 (Bf 110 с 15-й волны, как в GDD «Враги»).
## Чётный слот — первый тип пары, нечётный — второй: волна 5 на слоте 1 даёт Ju 87,
## поэтому на каждой волне ремкомплекта (5 / 10 / 15) «толстый» враг гарантированно есть.
static func enemy_type_for(wave_number: int, slot_index: int) -> String:
	var wave := maxi(1, wave_number)
	var slot := maxi(0, slot_index)
	var even := slot % 2 == 0
	if wave < 5:
		return "bf109"
	if wave < 10:
		return "bf109" if even else "ju87"
	if wave < 15:
		return "ju87" if even else "fw190"
	return "fw190" if even else "bf110"
