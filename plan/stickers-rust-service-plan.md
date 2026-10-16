# План реализации стикеров в PenikXMPP на базе Rust-микросервиса (v2)

## 1. Архитектурный обзор

Система стикеров объединяет легковесный автономный Rust-микросервис для хранения, каталогизации и импорта стикерпаков, расширение XMPP-станз сообщений с обратной совместимостью (XEP-0066 OOB) и Compose UI в Android-клиенте с аппаратным рендерингом нативных форматов.

```mermaid
flowchart TD
    subgraph Telegram["Telegram Cloud"]
        TGBot["Telegram Bot API\n(getStickerSet / getFile)"]
    end

    subgraph Backend["Rust Микросервис (penik-stickers-rs)"]
        API["Axum HTTP Server\n(:8085 /api/v1/stickers)"]
        Auth["Auth Middleware\n(Bearer HMAC-SHA256 Token)"]
        RateLimit["Rate Limiter (Tower Governor)\n(3 req/min на JID)"]
        DB[(SQLite WAL\npacks, stickers, user_packs)]
        Storage[("Файловое хранилище\n/data/stickers/{pack_id}/\n(файлы + предсобранный bundle.zip)")]
        Packager["FFmpeg Converter & Bundler\n(Конвертация WebM -> Animated WebP + сборка bundle.zip)"]
    end

    subgraph XMPP["Сервер Snikket / Prosody"]
        C2S["XMPP Stream (:5222 / :5223)\nmod_funxmpp"]
        TokenGen["Генерация Auth Token\n(HMAC по Shared Secret)"]
    end

    subgraph Client["Penik Android Client"]
        StickerPicker["Compose Sticker Keyboard\n(Сетка, табы, недавние)"]
        StickerCache["Локальный кэш бандлов\n(cache/stickers/{pack_id}/)"]
        ChatRenderer["Рендерер стикеров в чате\n(WebP / Animated WebP: Coil, TGS: Lottie)"]
        StickerModel["XMPP Парсер/Генератор\n(<sticker xmlns='penik:stickers:0'/>)"]
    end

    Client -->|1. Запрос токена / XMPP| C2S
    C2S --> TokenGen
    Client -->|2. Авторизованный HTTP API (Bearer)| Auth
    Auth --> RateLimit
    RateLimit --> API
    API -->|Проверка telegram_name| DB
    API -->|Загрузка новых файлов| TGBot
    TGBot --> Storage
    Storage --> Packager
    Packager -->|Готовый bundle.zip на диск| Storage
    Storage -->|Скачивание bundle.zip целиком| StickerCache

    StickerPicker -->|3. Отправка стикера| StickerModel
    StickerModel -->|4. XMPP Message со <sticker>| C2S
    C2S -->|5. Доставка сообщения| Client
    Client -->|6. Нативный рендеринг из кэша/URL| ChatRenderer
```

---

## 2. Ключевые архитектурные решения

### 2.1. Серверная однократная конвертация WebM в Animated WebP через FFmpeg
- **Проблема с VP9 Alpha:** Стандартный Android `MediaCodec` и ExoPlayer из коробки **не декодируют альфа-канал** (прозрачность) в контейнере WebM/VP9. Прозрачность в WebM хранится во вспомогательном видеопотоке (`alpha_mode: 1` / `BlockAddID: 1`). Аппаратный декодер смартфона просто игнорирует этот слой и рисует стикер на глухом черном прямоугольнике.
- **Особенность декодера FFmpeg (КРИТИЧНО):** Дефолтный нативный декодер VP9 в ffmpeg также игнорирует слой прозрачности и отбрасывает альфу. Чтобы ffmpeg прочитал альфа-канал из WebM, **обязательно** указывать внешний декодер `libvpx-vp9` строго перед ключом `-i`.
- **Оптимизация разрешения, FPS и веса:**
  - Оставлять исходные `512x512` при `30 FPS` для Animated WebP недопустимо — 3-секундная анимация раздувается до 1.5–2 МБ, а пак из 50 штук весит ~80 МБ. В чате стикеры рендерятся в размере 180–200 dp, поэтому разрешение `256x256` (Lanczos) при `20 FPS` дает идеальную четкость на экранах смартфонов при весе всего 200–350 КБ на стикер (пак ~12–15 МБ).
  - Наряду с анимацией, при импорте генерируется статичный 1-кадровый превью-файл `thumb.webp` (`128x128`).
- **Команда транскодинга (Rust микросервис):**
  ```bash
  # 1. Анимированный WebP с прозрачностью (256x256, 20 fps, q=65)
  ffmpeg -y -c:v libvpx-vp9 -i input.webm \
    -vcodec libwebp -filter:v "fps=20,scale=256:256:flags=lanczos" \
    -lossless 0 -compression_level 6 -q:v 65 -loop 0 output.webp

  # 2. Легковесный статичный кадр для сетки клавиатуры (128x128, q=70)
  ffmpeg -y -c:v libvpx-vp9 -i input.webm -vframes 1 \
    -vcodec libwebp -filter:v "scale=128:128:flags=lanczos" \
    -lossless 0 -compression_level 6 -q:v 70 thumb.webp
  ```
- **На Android-клиенте:**
  - В чате (`PenikChatRoom`) анимированный WebP рендерится стандартным **Coil (`AsyncImage`)** через нативный `ImageDecoder` / `coil-gif` (`AnimatedImageDecoder`) с аппаратным ускорением и нативной прозрачностью.
  - В клавиатуре стикеров (`LazyVerticalGrid`) отображаются **статичные превью `thumb.webp`**, исключая одновременное декодирование 16+ тяжелых анимаций в память и предотвращая OOM и фризы скролла.
  - Векторный TGS рендерится через `lottie-compose`.
  - Полностью исключены внешние видеоплееры (ExoPlayer/Media3), NDK-библиотеки и кастомные OpenGL-шейдеры.

---

### 2.2. Защита и авторизация REST API (XMPP Token Exchange)
- **Устранение уязвимостей Query-параметров:**
  - Передача `?jid={user_jid}` в query-параметрах категорически **запрещена**. Никаких параметров JID в URL нет.
  - Любой неавторизованный запрос к модифицирующим эндпоинтам (`POST/DELETE /install`, `POST /import/telegram`) моментально возвращает `401 Unauthorized`.
- **Механизм выпуска токена через XMPP IQ:**
  - Секретный ключ `shared_secret` известен **только серверу Prosody/Snikket и Rust-микросервису**. Клиент Android **никогда не имеет доступа к секрету**.
  - При старте сессии или раз в 24 часа Android-клиент запрашивает временный токен у своего XMPP-сервера через IQ:
    ```xml
    <iq type='get' id='stk_auth_1'>
      <stickers-auth xmlns='penik:stickers:auth:0'/>
    </iq>
    ```
  - Модуль Prosody (`mod_stickers_auth.lua` или `mod_funxmpp`), зная аутентифицированный JID пользователя из активного C2S-потока, генерирует HMAC-SHA256 токен:
    `raw_data = user_jid + ":" + expires_at`
    `sig = hmac_sha256(raw_data, shared_secret)`
    `token = base64(raw_data + ":" + sig)`
  - Prosody возвращает токен клиенту:
    ```xml
    <iq type='result' id='stk_auth_1'>
      <stickers-auth xmlns='penik:stickers:auth:0' token='ZXhhbXBsZUB...=' expires='1776345600'/>
    </iq>
    ```
- **Валидация в Rust-микросервисе:**
  - Клиент передает заголовок `Authorization: Bearer <token>`.
  - Axum middleware валидирует криптографическую подпись HMAC по `shared_secret`, проверяет `expires_at > now()`, безопасно извлекает доверенный `user_jid` и помещает его в `Extension<AuthUser>`.
  - Rate Limiter (`tower_governor`) на `/import/telegram` жестко лимитирует импорт до 3 вызовов в минуту на доверенный `user_jid`.

---

### 2.3. Однократная генерация `bundle.zip` и дедупликация
- **Проблема:** Сборка ZIP-архива «на лету» при каждом клиентском скачивании нерационально тратит память и такты процессора.
- **Решение:**
  - При импорте пака архив `bundle.zip` генерируется **ровно один раз** и сохраняется на диск: `/data/stickers/{pack_id}/bundle.zip`.
  - Эндпоинт `GET /api/v1/stickers/pack/{id}/bundle.zip` отдаёт готовый файл с диска со стандартными заголовками `ETag`, `Last-Modified` и поддержкой `304 Not Modified`. Раздачу можно без изменений вынести на reverse-proxy (Caddy / Nginx).
  - В таблице `sticker_packs` колонка `telegram_name TEXT UNIQUE`: повторный запрос на импорт пака с тем же именем моментально возвращает существующую запись из базы без лишних обращений к Telegram Bot API.

---

### 2.4. Приватность и XMPP-станзы
- В Penik сквозное шифрование OMEMO по умолчанию отключено (follower-only режим, весь чат открытый). Поэтому передача метаданных стикера в корневом теге `<sticker xmlns='penik:stickers:0'/>` и fallback-ссылки в `<x xmlns='jabber:x:oob'>` полностью легитимна.
- Если в будущем OMEMO активируется для конкретного диалога, генератор станз клиента упакует тег `<sticker>` внутрь шифруемого содержимого (payload), чтобы скрыть идентификатор стикера и URL от промежуточных узлов.

---

## 3. Спецификация Rust-микросервиса (`server/MicroServices/penik-stickers-rs`)

### 3.1. Стек и зависимости
- Язык: Rust (2021 edition).
- Асинхронный рантайм: `tokio`.
- HTTP-сервер: `axum` + `tower` + `tower-http` (файловый стриминг, сжатие gzip/brotli, CORS).
- Rate Limiting: `tower_governor`.
- База данных: `sqlx` со встроенным SQLite (WAL-режим, пул соединений).
- HTTP-клиент: `reqwest` (TLS native-tls / rustls).
- Архивация: `zip` (однократная упаковка при импорте).
- Безопасность: `hmac` + `sha2`.
- Системный транскодер: `ffmpeg` (асинхронный вызов CLI через `tokio::process::Command` для однократной конвертации WebM в Animated WebP с сохранением альфа-канала).

### 3.2. Схема базы данных (SQLite)
```sql
CREATE TABLE IF NOT EXISTS sticker_packs (
    id TEXT PRIMARY KEY,
    telegram_name TEXT UNIQUE,
    title TEXT NOT NULL,
    author_jid TEXT NOT NULL DEFAULT '',
    cover_sticker_id TEXT NOT NULL DEFAULT '',
    format TEXT NOT NULL DEFAULT 'static', -- 'static' (webp), 'animated' (tgs), 'animated_webp' (webm converted to webp)
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_packs_tg_name ON sticker_packs(telegram_name);

CREATE TABLE IF NOT EXISTS stickers (
    id TEXT PRIMARY KEY,
    pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
    emoji TEXT NOT NULL DEFAULT '',
    file_name TEXT NOT NULL,
    width INTEGER NOT NULL DEFAULT 512,
    height INTEGER NOT NULL DEFAULT 512,
    sort_order INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_stickers_pack ON stickers(pack_id, sort_order);

CREATE TABLE IF NOT EXISTS user_sticker_packs (
    user_jid TEXT NOT NULL,
    pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
    sort_order INTEGER NOT NULL DEFAULT 0,
    installed_at INTEGER NOT NULL,
    PRIMARY KEY (user_jid, pack_id)
);
CREATE INDEX IF NOT EXISTS idx_user_packs ON user_sticker_packs(user_jid, sort_order);
```

### 3.3. REST API Эндпоинты

| Метод | Путь | Авторизация | Описание |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/v1/stickers/my` | Bearer Token | Список установленных паков пользователя (из `user_jid` токена). |
| `GET` | `/api/v1/stickers/pack/{id}` | Опционально | Полные метаданные пака и список всех стикеров. |
| `POST` | `/api/v1/stickers/pack/{id}/install` | Bearer Token | Добавить пак в личную коллекцию пользователя. |
| `DELETE` | `/api/v1/stickers/pack/{id}/install` | Bearer Token | Удалить пак из личной коллекции. |
| `POST` | `/api/v1/stickers/import/telegram` | Bearer Token + RateLimit | Импорт пака по ссылке `t.me/addstickers/{name}`. |
| `GET` | `/api/v1/stickers/pack/{id}/bundle.zip` | Публично (кэш) | Скачивание предсобранного ZIP-архива всего пака. |
| `GET` | `/api/v1/stickers/file/{pack_id}/{file}` | Публично (кэш) | Раздача отдельного стикера (`.webp`, `.tgs`). |

---

## 4. XMPP Протокол (Формат передачи)

```xml
<message to='contact@snikket.penik.ru' type='chat' id='stk_918237'>
  <body>[Стикер: 🔥]</body>
  <sticker xmlns='penik:stickers:0'
           pack_id='tg_meme_cats'
           sticker_id='cat_fire'
           emoji='🔥'
           width='512'
           height='512'
           format='animated_webp'
           url='https://snikket.penik.ru/api/v1/stickers/file/tg_meme_cats/cat_fire.webp'/>
  <!-- XEP-0066 Out of Band Data для сторонних клиентов -->
  <x xmlns='jabber:x:oob'>
    <url>https://snikket.penik.ru/api/v1/stickers/file/tg_meme_cats/cat_fire.webp</url>
  </x>
</message>
```

- В FunXMPP элементы `sticker`, `pack_id`, `sticker_id`, `emoji`, `width`, `height`, `format`, `url` кодируются как компактные строковые литералы либо токенизируются в версии 2.

---

## 5. Android Клиент (Jetpack Compose & Storage)

### 5.1. Хранилище и кэш (`StickerManager.kt`)
1. **Директория хранения:** `context.filesDir/stickers/{pack_id}/`.
2. **Фоновая установка:**
   - Клиент вызывает `POST /api/v1/stickers/pack/{id}/install`.
   - В фоне через `WorkManager` скачивается `bundle.zip` и распаковывается в `filesDir/stickers/{pack_id}/`.
   - Метаданные пака сохраняются локально (JSON / Room).
3. **Открытие чата:** Стикер мгновенно отдаётся из локального файла. Если пак не установлен локально у получателя, файл стримится по HTTP URL с сохранением во временный LRU-кэш.

### 5.2. Рендеринг стикеров в чате (`PenikChatRoom.kt`)
- `PenikStickerBubble`:
  - Прозрачный фон без декоративных рамок текстового пузыря.
  - Фиксированный размер: 180–220 dp с сохранением aspect ratio.
  - В зависимости от `format`:
    - `static` / `animated_webp`: Coil `AsyncImage` с поддержкой анимации через `ImageDecoderDecoder` (Android 9+) / `coil-gif`. Обеспечивает нативную прозрачность, аппаратный рендеринг и гладкий скролл без подвисаний.
    - `animated`: `com.airbnb.android.lottie:lottie-compose` (TGS/Lottie).
  - Индикатор доставки (одиночная/двойная галочка) на полупрозрачной подложке в нижнем правом углу.

### 5.3. Клавиатура стикеров (`PenikStickerPicker.kt`)
- Вкладки установленных паков с иконками обложек (горизонтальный скролл).
- Вкладка «Недавние» (история последних 30 отправленных стикеров).
- Сетка стикеров (4 колонки): рендеринг легковесных статичных миниатюр `thumb.webp` (`128x128`) через Coil вместо тяжелых анимированных потоков, что гарантирует 60 FPS при скролле и нулевой риск OOM.
- Предпросмотр анимации при долгом нажатии на ячейку стикера.
- Диалог добавления пака: ввод ссылки Telegram `t.me/addstickers/...` с индикатором прогресса загрузки.

---

## 6. Пошаговые этапы реализации

### Этап 1: Rust-микросервис (`server/MicroServices/penik-stickers-rs`)
1. Инициализировать проект `cargo new --bin server/MicroServices/penik-stickers-rs`.
2. Настроить Axum, SQLite миграции (`packs`, `stickers`, `user_packs`), HMAC middleware.
3. Реализовать клиент Telegram Bot API (`getStickerSet`, скачивание файлов через `getFile`).
4. Реализовать вызов `ffmpeg` для однократной конвертации `.webm` видеостикеров в `Animated WebP` с сохранением альфа-канала.
5. Реализовать сборку `bundle.zip` при импорте и сохранение на диск.
6. Реализовать отдачу статических файлов с ETag и кэшированием.
7. Написать юнит-тесты на проверку HMAC-авторизации, идемпотентности импорта по `telegram_name` и генерации zip.

### Этап 2: Интеграция с XMPP-протоколом
1. Создать XML-модель стикера и интеграцию в `MessageParser.java` / `MessageGenerator.java`.
2. Реализовать провайдер временных HMAC-токенов в Prosody (`mod_funxmpp` или отдельный хук) либо локальный генератор на клиенте при наличии общего секрета.
3. Протестировать парсинг и генерацию станз со стикерами в `FunProtocolTest.java`.

### Этап 3: Менеджер кэширования и загрузки (Android)
1. Реализовать `StickerManager.kt` (HTTP клиент к сервису стикеров, скачивание и распаковка `bundle.zip`).
2. Настроить локальное сохранение метаданных и истории недавних стикеров.

### Этап 4: Jetpack Compose UI
1. Реализовать `PenikStickerPicker.kt` (табы паков, сетка, кнопка импорта).
2. Реализовать `PenikStickerBubble.kt` для рендеринга в `PenikChatRoom.kt` через Coil `AsyncImage` (WebP / Animated WebP с прозрачностью) и `lottie-compose` (TGS).
3. Добавить кнопку переключения на стикеры в поле ввода сообщения.

### Этап 5: Сборка, Docker и верификация
1. Подготовить `server/MicroServices/penik-stickers-rs/Dockerfile` с установленным `ffmpeg` для продакшн-образа.
2. Провести E2E-тестирование: импорт пака из Telegram (включая видеостикеры с альфой) -> скачивание бандла на Android -> отправка стикера в чат -> отображение у собеседника на прозрачном фоне.
3. Обновить `PROJECT_MAP.md`.
