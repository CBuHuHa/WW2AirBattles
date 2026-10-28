# Data safety и возрастной рейтинг — Play Console (M8c2)

Версия: 1.0.0 (versionCode 1) · пакет `com.ww2airbattles.defense`
Дата: 2026-10-28 · Источник фактов: `scripts/analytics.gd`, `scripts/ads.gd`,
`scripts/iap.gd`, `scripts/save_game.gd`, `project.godot`, Android-манифест сборки.

Ниже — готовые ответы для разделов Play Console «Data safety» (Безопасность данных) и
«Content rating» (Возрастной рейтинг). Все утверждения проверяемы по коду: сетевых
вызовов нет, в манифесте нет разрешения `INTERNET` (проверено `aapt2 dump permissions`
по собранному APK).

## 1. Data safety — краткие ответы

| Вопрос Play | Ответ |
| --- | --- |
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | Не применимо (данные не передаются) |
| Do you provide a way for users to request that their data be deleted? | Не применимо; данные удаляются очисткой данных приложения / удалением приложения |
| Does your app use advertising ID? | **No** |
| Does your app have any third-party SDKs that collect data? | **No** |

## 2. Data safety — раздел за разделом

- **Data collection**: приложение не собирает данные. Локальный журнал
  `user://analytics.log` и профиль `user://ww2_air_battles.cfg` обрабатываются **только на
  устройстве** и не передаются за его пределы, поэтому Play не считает их «collected»:
  собираемыми считаются данные, покидающие устройство.
- **Data sharing**: нет. Передачи третьим лицам, обработчикам и рекламным сетям нет.
- **Data types** (ни один не отмечается):
  - Location — нет;
  - Personal info (имя, e-mail, телефон, адрес, ID документов) — нет;
  - Financial info — нет (платежей нет, IAP выключен);
  - Health and fitness — нет;
  - Messages — нет;
  - Photos and videos, Audio files, Files and docs — нет;
  - Calendar, Contacts — нет;
  - App activity (interactions, in-app search history, installed apps) — нет;
  - Web browsing — нет;
  - App info and performance (crash logs, diagnostics) — нет; локальный журнал событий
    остаётся на устройстве и не загружается;
  - Device or other IDs — нет (Advertising ID, IMEI, MAC, SSAID не читаются).
- **Purpose / optionality / encryption**: не применимо — данных нет.
- **Data deletion request URL**: не требуется; можно указать `store/privacy_policy.md`
  (URL политики) и раздел «Удаление данных» в ней.

## 3. Остальные обязательные ответы Play Console

| Раздел | Ответ |
| --- | --- |
| App access (вход в приложение) | Все функции доступны без входа; аккаунтов нет → «All functionality is available without special access» |
| Ads | «No, my app does not contain ads» |
| In-app purchases | «No» (магазин выключен флагом `shop_enabled=false`) |
| Target audience | 6+ (см. рейтинг ниже); не предназначено специально для детей |
| News app / COVID-19 / government app | Нет |
| Financial features | Нет |
| Health | Нет |
| Permissions | В манифесте нет ни одного `uses-permission` (нет сети, камеры, геолокации, контактов, уведомлений) |

## 4. Возрастной рейтинг (IARC / Content rating)

Тема — Вторая мировая война, воздушный бой. Игрок управляет самолётом, сбивает самолёты
противника; люди, кровь, расчленение и нацистская символика отсутствуют, боевые действия
показаны силуэтами самолётов и схематичными взрывами.

Предлагаемые ответы в опроснике IARC:

- **Violence**: «Mild» — насилие направлено на технику (самолёты), без крови и страданий.
  Реалистичное насилие над людьми — «Нет».
- **Blood / gore**: нет.
- **Sexuality, nudity, language (брань), drugs, alcohol, tobacco, gambling**: нет.
- **Scary elements**: нет.
- **Simulated gambling / real money gambling**: нет.
- **Purchases**: нет (IAP выключены).
- **User interaction / UGC / location sharing**: нет (нет сети, аккаунтов, чата).
- **Data sharing**: нет.

Ожидаемый результат IARC: **6+** (в терминах Play — допустимо для 6 лет и старше),
PEGI 7, ESRB E10+ при формулировке «mild violence against vehicles/aircraft».
Итоговую категорию присваивает IARC автоматически — цифры выше ориентир, а не гарантия.

Отдельно: историческая тематика без нацистской символики. В игре нейтральные
опознавательные знаки (код-силуэты и пиксель-арт SpriteCook), свастики, рун и портретов
политических деятелей нет — это осознанное требование GDD «Art direction → Историчность».

## 5. Что изменится, если включить рекламу (Ads) или покупки (IAP)

Сейчас оба адаптера — заглушки, флаги `ads_enabled`/`shop_enabled` в профиле `false`.
Перед выпуском версии с включёнными слотами потребуется:

1. **Data safety**: отметить «Yes» на сбор данных; добавить типы
   «Device or other IDs» (Advertising ID) и «App activity» (показы/клики рекламы),
   для IAP — «Purchase history»; указать передачу третьим лицам (рекламная сеть) и
   шифрование при передаче.
2. **Ads declaration**: переключить на «My app contains ads» (только rewarded, без
   баннеров и интерстишлов — GDD «Монетизация»).
3. **In-app purchases**: «Yes», с товарами-скинами (`Iap.SKIN_IDS`).
4. **Разрешения**: добавить `INTERNET` и `AD_ID` (для рекламы), что само по себе
   меняет ответ «Permissions» в этом документе.
5. **Согласие и приватность**: обновить `store/privacy_policy.md` (появятся сторонние
   SDK, идентификаторы, право на отказ от персонализации), для ЕЭЗ/Великобритании —
   consent-форма рекламной сети.
6. **Возрастной рейтинг**: перепроверить опросник IARC (появляется «sharing data» и
   «digital purchases»; на категорию для 6+ это обычно не влияет).
7. **Платежи**: тестовые товары в Play Console и `Iap.purchase()` с реальным SDK —
   сейчас покупка всегда возвращает `false`, награды не выдаются.
