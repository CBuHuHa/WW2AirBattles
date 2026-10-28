# audio_manager.gd
# Purpose: M3-D аудио-слой по GDD «Audio»: один зацикленный военный трек + 8 SFX
#          (автострельба, попадание по врагу/боссу, попадание по игроку, взрыв врага,
#          бомба, подбор, тревога босса, клик UI). Ассеты — плейсхолдеры из
#          tools/generate_audio.py (assets/audio/README.md), код от их содержимого не зависит.
# Dependencies: LevelController (контракт сигналов), assets/audio/*.wav,
#               SaveGame (M8a — настройка «Звук» из [settings] сейва v2).
# Author: Game Feel Developer Agent
#
# ─── ГЛУШЕНИЕ (M8a, GDD «Настройки») ────────────────────────────────────────
# set_muted(true) не останавливает потоки: громкость музыки и голосов уходит в
# MUTED_VOLUME_DB (−80 dB ≈ тишина). Так stream_paused остаётся ТОЛЬКО за паузой дерева
# (см. _notification ниже) — иначе `paused` и «звук выключен» затирали бы друг друга и
# музыка включалась бы на паузе. SFX при этом продолжают «играть» в пул (счётчики
# get_sfx_count/get_last_sfx не меняются) — QA-контракт M3-D остаётся прежним.
# Начальное состояние берётся из профиля: _ready → set_muted(not SaveGame.get_setting("sound")).
#
# ─── РОЛЬ И РЕЖИМ ПРОЦЕССА ──────────────────────────────────────────────────
# Узел Audio — ребёнок Level (LevelController ALWAYS), но САМ явно PAUSABLE:
# музыка и SFX замирают вместе с миром на паузе и на экранах исхода и продолжаются
# после resume. Плееры-дети (Music + 8 голосов) стоят в ALWAYS, а пауза реализована
# явным stream_paused (см. _notification): так состояние воспроизведения полностью
# под нашим контролем и не зависит от того, как движок паркует узлы на паузе.
# Геймплей аудио не трогает: все обработчики — no-op при отсутствии потока/ключа.
#
# ─── ПУБЛИЧНЫЙ DEBUG API (QA) ───────────────────────────────────────────────
#   SFX_KEYS                 список ключей (Array[StringName])
#   get_sfx_count(key)       сколько раз ключ реально запускался (растёт на каждом play)
#   get_last_sfx()           последний реально запущенный ключ (&"" — ещё не было)
#   is_music_playing()       музыка играет (AudioStreamPlayer.playing)
#   get_music_stream()       зацикленный AudioStream (WAV, LOOP_FORWARD)
#   get_music_loop_mode()    AudioStreamWAV.loop_mode музыки
#   get_voice_count()        размер пула голосов (8)
#   set_muted(bool)/is_muted()  M8a: глушение настройкой «Звук» (громкость, не stop)
#   get_music_volume_db()    текущая громкость музыки (−17 обычная, −80 заглушено)
#
# ─── МАППИНГ (GDD «Audio») ──────────────────────────────────────────────────
#   player_shot_fired        → player_shot      (±5% питч)
#   enemy_damaged            → enemy_hit        (±5%)
#   boss_spawned → boss.health_changed(hp>0) → enemy_hit (±5%)   [попадания по боссу]
#   player_damaged           → player_hit       (±5%)
#   enemy_destroyed          → enemy_explosion  (±5%)
#   player_died              → enemy_explosion  (питч 0.7)
#   bomb_detonated           → bomb             (±5%)
#   boss_bomb_detonated      → enemy_explosion  (питч 0.8 ±5%)
#   pickup_collected         → pickup
#   boss_spawned             → boss_alarm
#   boss_phase_changed       → boss_alarm       (питч 1.15)
#   pause_requested / bomb_pressed / briefing.start_requested → ui_click (троттлинг 0.1 с)

class_name AudioManager
extends Node

# ─── Контракт ключей и файлов ───────────────────────────────────────────────
## Ключ = имя файла: res://assets/audio/<key>.wav. SFX_KEYS — публичный список для QA.
const SFX_KEYS: Array[StringName] = [
	&"player_shot",
	&"enemy_hit",
	&"player_hit",
	&"enemy_explosion",
	&"bomb",
	&"pickup",
	&"boss_alarm",
	&"ui_click",
]
const AUDIO_DIR := "res://assets/audio/"
const MUSIC_PATH := AUDIO_DIR + "music_loop.wav"

# ─── Тюнинг громкости/пула ──────────────────────────────────────────────────
## Музыка заметно тише SFX: GDD «Audio» — трек не должен перекрывать боевые звуки.
const MUSIC_VOLUME_DB := -17.0
## База пула SFX; ключевые поправки ниже (выстрел 8/с — тише, бомба — громче).
const SFX_VOLUME_DB := -7.0
const VOICE_COUNT := 8
## Поправки к базе по ключам: клипы нормализованы до −3 dBFS, здесь — микс.
const VOLUME_OFFSETS := {
	&"player_shot": -4.0,
	&"enemy_hit": -2.0,
	&"player_hit": 1.0,
	&"enemy_explosion": 0.0,
	&"bomb": 1.0,
	&"pickup": 1.0,
	&"boss_alarm": -5.0,
	&"ui_click": -2.0,
}
## Питч-вариации ±5%: серия одинаковых выстрелов/попаданий не звучит механически.
const PITCH_JITTER := 0.05
const DEATH_PITCH := 0.7
const BOSS_BOMB_PITCH := 0.8
const BOSS_PHASE_PITCH := 1.15
## UI-клик не чаще 0.1 с (тап по кнопке может прийти и touch-, и mouse-событием).
const UI_CLICK_THROTTLE_MS := 100
## M8a: громкость выключенного звука. −80 dB на мастер-выходе — тишина без stop()/pause:
## состояние воспроизведения не трогается, «включить обратно» — просто вернуть громкость.
const MUTED_VOLUME_DB := -80.0

var _streams: Dictionary = {}          # StringName → AudioStreamWAV
var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0
var _music: AudioStreamPlayer = null
var _counts: Dictionary = {}           # StringName → int (реальные play)
var _last_sfx: StringName = &""
var _last_ui_click_msec: int = -UI_CLICK_THROTTLE_MS
var _level: LevelController = null
## M8a: звук выключен настройкой (SaveGame [settings] sound=false).
var _muted: bool = false


func _ready() -> void:
	# ЯВНО PAUSABLE (наследование от ALWAYS-Level дало бы звук на паузе).
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_load_streams()
	_build_music()
	_build_voices()
	# M8a: стартовое состояние — из профиля (по умолчанию true → звук включён).
	set_muted(not SaveGame.get_setting("sound"))
	_connect_level_signals()


## Пауза дерева: AudioManager PAUSABLE получает NOTIFICATION_PAUSED, а плееры-дети
## (Music/Sfx*) стоят в ALWAYS — поэтому замирание звука делается явным stream_paused,
## а не паузой узла. Поведение то же, что у паузы дерева: позиция не растёт, после
## resume воспроизведение продолжается с того же места; зато на выходе процесса
## состоянием потоков управляем мы, а не внутренний механизм паузы движка.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PAUSED:
			_set_streams_paused(true)
		NOTIFICATION_UNPAUSED:
			_set_streams_paused(false)


func _set_streams_paused(paused_now: bool) -> void:
	if _music != null:
		_music.stream_paused = paused_now
	for voice in _voices:
		voice.stream_paused = paused_now


# ─── Глушение настройкой «Звук» (M8a) ───────────────────────────────────────
## Выключить/включить звук целиком (музыка + все SFX-голоса). Реализовано ГРОМКОСТЬЮ, а не
## stop()/stream_paused: пауза дерева остаётся единственным владельцем stream_paused
## (см. _notification), а включение обратно не перезапускает трек с начала.
func set_muted(muted: bool) -> void:
	if _muted == muted:
		return
	_muted = muted
	if _music != null:
		_music.volume_db = _music_volume_db()
	for voice in _voices:
		voice.volume_db = _voice_base_db()


func is_muted() -> bool:
	return _muted


## Громкость музыки с учётом глушения (QA: при выключенном звуке −80).
func get_music_volume_db() -> float:
	return _music.volume_db if _music != null else MUTED_VOLUME_DB


func _music_volume_db() -> float:
	return MUTED_VOLUME_DB if _muted else MUSIC_VOLUME_DB


## База громкости голоса: при включённом звуке — SFX_VOLUME_DB (поправка по ключу
## добавляется в _play), при выключенном — тишина.
func _voice_base_db() -> float:
	return MUTED_VOLUME_DB if _muted else SFX_VOLUME_DB


# ─── Построение ─────────────────────────────────────────────────────────────
## Загрузка WAV. Отсутствующий файл — не ошибка: ключ просто не играет (no-op).
func _load_streams() -> void:
	for key in SFX_KEYS:
		var path := AUDIO_DIR + String(key) + ".wav"
		if not ResourceLoader.exists(path):
			continue
		var stream := load(path) as AudioStream
		if stream != null:
			_streams[key] = stream


## Музыка: AudioStreamPlayer + КОПИЯ потока с LOOP_FORWARD (общий ресурс не мутируем).
## loop_begin/loop_end — в сэмплах, поэтому считаются из размера данных и формата.
func _build_music() -> void:
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	_music.volume_db = MUSIC_VOLUME_DB
	# ALWAYS + явный stream_paused: паузой потоков управляем мы сами (см. _notification).
	_music.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_music)
	if not ResourceLoader.exists(MUSIC_PATH):
		return
	var imported := load(MUSIC_PATH) as AudioStreamWAV
	if imported == null:
		return
	var looped := imported.duplicate() as AudioStreamWAV
	var samples := _sample_count(looped)
	if samples <= 0:
		# Не 8/16-bit (QOA/ADPCM): длительность всё равно известна — берём её.
		samples = int(round(imported.get_length() * imported.mix_rate))
	if samples <= 0:
		# Совсем неизвестный формат: играем как есть, без зацикливания.
		_music.stream = looped
	else:
		looped.loop_mode = AudioStreamWAV.LOOP_FORWARD
		looped.loop_begin = 0
		looped.loop_end = samples
		_music.stream = looped
	# Музыка играет с запуска приложения — в том числе на брифинге (GDD «Audio»).
	_music.play()


## Пул фиксированного размера: не больше 8 одновременных голосов.
func _build_voices() -> void:
	for index in VOICE_COUNT:
		var voice := AudioStreamPlayer.new()
		voice.name = "Sfx%d" % index
		voice.volume_db = SFX_VOLUME_DB
		# См. _notification(): пауза реализована stream_paused, а не паузой узла.
		voice.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(voice)
		_voices.append(voice)


## Сэмплов в потоке (на канал). 0 — формат, для которого счёт не определён.
func _sample_count(stream: AudioStreamWAV) -> int:
	var bytes_per_sample := 0
	match stream.format:
		AudioStreamWAV.FORMAT_8_BITS:
			bytes_per_sample = 1
		AudioStreamWAV.FORMAT_16_BITS:
			bytes_per_sample = 2
		_:
			return 0
	var channels := 2 if stream.stereo else 1
	return stream.data.size() / (bytes_per_sample * channels)


# ─── Подписки на контракт LevelController ────────────────────────────────────
## Единственная точка подписок. LevelController ALWAYS, AudioManager PAUSABLE:
## сигналы на паузе не эмитятся (мир заморожен), ввод/оверлеи — эмитятся.
func _connect_level_signals() -> void:
	_level = get_parent() as LevelController
	if _level == null:
		return  # автономный инстанс (QA) — просто молчим, без ERROR
	_level.player_shot_fired.connect(_on_player_shot_fired)
	_level.enemy_damaged.connect(_on_enemy_damaged)
	_level.enemy_destroyed.connect(_on_enemy_destroyed)
	_level.player_damaged.connect(_on_player_damaged)
	_level.player_died.connect(_on_player_died)
	_level.bomb_detonated.connect(_on_bomb_detonated)
	_level.boss_bomb_detonated.connect(_on_boss_bomb_detonated)
	_level.pickup_collected.connect(_on_pickup_collected)
	_level.boss_spawned.connect(_on_boss_spawned)
	_level.boss_phase_changed.connect(_on_boss_phase_changed)
	# UI: пауза, бомба, «В бой».
	var pause_button := _level.get_node_or_null(^"UI/PauseButton") as PauseButton
	if pause_button != null:
		pause_button.pause_requested.connect(_on_ui_pause_requested)
	var bomb_button := _level.get_node_or_null(^"UI/BombButton") as BombButton
	if bomb_button != null:
		bomb_button.bomb_pressed.connect(_on_ui_bomb_pressed)
	var briefing := _level.get_node_or_null(^"UI/BriefingOverlay") as BriefingOverlay
	if briefing != null:
		briefing.start_requested.connect(_on_ui_start_requested)


# ─── Обработчики контракта ──────────────────────────────────────────────────
func _on_player_shot_fired(_origin: Vector2, _velocity: Vector2, _damage: float) -> void:
	_play(&"player_shot", 1.0, PITCH_JITTER)


func _on_enemy_damaged(_enemy: EnemyBase, _hp: int, _at: Vector2) -> void:
	_play(&"enemy_hit", 1.0, PITCH_JITTER)


func _on_enemy_destroyed(_kind: StringName, _at: Vector2) -> void:
	_play(&"enemy_explosion", 1.0, PITCH_JITTER)


func _on_player_damaged(_hp: int, _at: Vector2) -> void:
	_play(&"player_hit", 1.0, PITCH_JITTER)


## Гибель Ла-5 — тот же взрыв ниже по тону (GDD «Audio»: отдельного клипа нет).
func _on_player_died(_at: Vector2) -> void:
	_play(&"enemy_explosion", DEATH_PITCH, PITCH_JITTER)


func _on_bomb_detonated(_at: Vector2, _radius: float) -> void:
	_play(&"bomb", 1.0, PITCH_JITTER)


func _on_boss_bomb_detonated(_at: Vector2, _radius: float) -> void:
	_play(&"enemy_explosion", BOSS_BOMB_PITCH, PITCH_JITTER)


func _on_pickup_collected(_kind: int, _at: Vector2) -> void:
	_play(&"pickup")


## Босс вошёл: тревога + подписка на его HP (попадания по боссу = enemy_hit).
## Ссылка на босса не хранится: соединение умирает вместе с узлом, когда его сбивают.
func _on_boss_spawned(boss: EnemyBase) -> void:
	_play(&"boss_alarm")
	if boss == null or not is_instance_valid(boss):
		return
	if not boss.health_changed.is_connected(_on_boss_health_changed):
		boss.health_changed.connect(_on_boss_health_changed)


## hp == 0 — смертельный удар: там играет enemy_destroyed/большой взрыв, тикать нечем.
func _on_boss_health_changed(hp: int) -> void:
	if hp <= 0:
		return
	_play(&"enemy_hit", 1.0, PITCH_JITTER)


func _on_boss_phase_changed(_phase: int) -> void:
	_play(&"boss_alarm", BOSS_PHASE_PITCH)


func _on_ui_pause_requested() -> void:
	_play(&"ui_click")


func _on_ui_bomb_pressed() -> void:
	_play(&"ui_click")


func _on_ui_start_requested() -> void:
	_play(&"ui_click")


## M6.1b: клик выбора перка. Отдельного ассета в GDD «Audio» нет — играем существующий
## ui_click (тот же троттлинг 0.1 с). LevelController зовёт после снятия паузы дерева.
func play_ui_click() -> void:
	_play(&"ui_click")


# ─── Воспроизведение ────────────────────────────────────────────────────────
## Запуск SFX. Нет ключа/потока/голосов — тихий no-op (headless, урезанный набор ассетов).
func _play(key: StringName, pitch: float = 1.0, jitter: float = 0.0) -> void:
	var stream := _streams.get(key, null) as AudioStream
	if stream == null:
		return
	if key == &"ui_click":
		var now := Time.get_ticks_msec()
		if now - _last_ui_click_msec < UI_CLICK_THROTTLE_MS:
			return
		_last_ui_click_msec = now
	var voice := _pick_voice()
	if voice == null:
		return
	voice.stream = stream
	# M8a: при выключенном звуке голос всё равно «играет» (счётчики QA живут), но в тишине.
	voice.volume_db = MUTED_VOLUME_DB if _muted \
		else SFX_VOLUME_DB + float(VOLUME_OFFSETS.get(key, 0.0))
	voice.pitch_scale = pitch * (1.0 + randf_range(-jitter, jitter))
	voice.play()
	_counts[key] = int(_counts.get(key, 0)) + 1
	_last_sfx = key


## Свободный голос по кругу; если все заняты — переиспользуем следующий (не более 8).
func _pick_voice() -> AudioStreamPlayer:
	if _voices.is_empty():
		return null
	for offset in _voices.size():
		var index := (_next_voice + offset) % _voices.size()
		if not _voices[index].playing:
			_next_voice = (index + 1) % _voices.size()
			return _voices[index]
	var stolen := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	return stolen


# ─── Завершение ─────────────────────────────────────────────────────────────
## Best-effort очистка на выходе процесса: замораживаем потоки, гасим их и даём аудиопотоку
## время снять playback-объекты. Без этой паузы Dummy-драйвер в headless иногда не успевает
## отпустить playback музыки, и Godot печатает WARNING об утечке ObjectDB на выходе
## (гонка на выходе процесса, стабильно ловилась на `--quit-after 900`; 100 мс при
## завершении процесса игрок не замечает, зато прогоны QA чистые).
func _exit_tree() -> void:
	_set_streams_paused(true)
	if _music != null:
		_music.stop()
	for voice in _voices:
		voice.stop()
	OS.delay_msec(100)


# ─── Debug API для QA ───────────────────────────────────────────────────────
func get_sfx_count(key: StringName) -> int:
	return int(_counts.get(key, 0))


func get_last_sfx() -> StringName:
	return _last_sfx


func is_music_playing() -> bool:
	return _music != null and _music.playing


func get_music_stream() -> AudioStream:
	return _music.stream if _music != null else null


func get_music_loop_mode() -> int:
	var stream := get_music_stream() as AudioStreamWAV
	return stream.loop_mode if stream != null else AudioStreamWAV.LOOP_DISABLED


func get_voice_count() -> int:
	return _voices.size()
