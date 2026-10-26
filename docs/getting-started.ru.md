# Быстрый старт со Stayo

SDK подключается к одному проекту Stayo по HTTPS-адресу проекта и **публичному
ключу проекта**. Пароль базы, ключ подписи JWT, service-role и ключ внешнего API
приложению не нужны.

> **Статус выпуска:** пакеты SDK `0.1.0` собраны локально, тестовая сборка
> установлена на тестовом VPS. Публикация пакетов, реальные OAuth-входы и проверки
> устройств ещё не завершены. Перед установкой из реестра проверьте
> [отчёт о приёмке](release-status.md#verification). Примеры ниже показывают
> подготовленный интерфейс версии `0.1.0`.

## 1. Возьмите параметры подключения

Откройте проект в кабинете Stayo и раздел **«Подключение»**. Скопируйте адрес
проекта и публичный ключ. Публичный ключ указывает проект, но сам по себе не
открывает доступ к строкам и файлам. Доступ задают сессия пользователя и политики
RLS.

Ключи внешних сервисов храните в разделе проекта **«Секреты»**. Серверная
функция получает секрет своего проекта и обращается к внешнему сервису. Не
встраивайте такой ключ в Web-, iOS-, macOS- или Android-приложение. Подробнее:
[Секреты и серверные функции](secrets-and-functions.md).

Если кабинет не смог подтвердить результат записи, сначала обновите раздел:
сервер мог сохранить изменение, даже если ответ не дошёл. Проверьте дату
изменения и применённую версию функции, затем выполните безопасный тестовый
вызов без вывода ключа. При временной недоступности среды дождитесь завершения
фоновой операции перед новой записью. Автоматического повтора таких запросов нет.

Вход в клиентский кабинет — `/login`. Адрес `/admin` предназначен для
оператора сервера; bootstrap token не нужен пользователю проекта.

Вкладка **«Резервные копии»** позволяет создать зашифрованную копию и восстановить
выбранную проверенную копию. Восстановление заменяет текущие данные, секреты и
функции, требует имени проекта и пароля кабинета. Дождитесь завершения операции;
сохранённый черновик функции не публикуется автоматически при восстановлении.
Подробнее: [порядок резервного копирования и восстановления](cabinet-backups.md).

## 2. Установите SDK

Команды для публичных реестров используйте после подтверждения публикации
пакета. Пока пакет не опубликован, внутри этого репозитория подключайте исходник.

| Платформа | Публичный пакет после выпуска | Исходник для локальной разработки |
| --- | --- | --- |
| Web / Node.js | `npm install @stayo/sdk@0.1.0` | `npm install /path/to/stayo-sdk-0.1.0.tgz` |
| iOS / macOS | [stayo-swift](https://github.com/RomanKarasevDev/stayo-swift), точная версия `0.1.0` | Добавьте `sdk/stayo-swift` как локальный пакет |
| Android | `implementation("live.stayo:stayo-android:0.1.0")` | Используйте локальный Maven-репозиторий из [Android README](reference/android.md) |

Удалённая зависимость SwiftPM требует отдельный tagged-репозиторий. Папка
монорепозитория не подходит в качестве SwiftPM URL-зависимости. Точные команды
локальной сборки есть в README каждой библиотеки.

## 3. Создайте таблицу с доступом по владельцу

Один раз выполните SQL в консоли проекта. Таблица приватная: пользователь может
читать и менять только свои строки.

```sql
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now()
);

alter table public.notes enable row level security;
grant select, insert, update, delete on public.notes to authenticated;

create policy notes_select_own on public.notes
  for select to authenticated using ((select auth.uid()) = owner_id);
create policy notes_insert_own on public.notes
  for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy notes_update_own on public.notes
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy notes_delete_own on public.notes
  for delete to authenticated using ((select auth.uid()) = owner_id);
```

Чтобы получать Realtime-события для этой таблицы, добавьте её в публикацию
Realtime, если она ещё не добавлена:

```sql
alter publication supabase_realtime add table public.notes;
```

Сейчас Realtime передаёт `INSERT` и `UPDATE`. После переподключения заново
запросите актуальные строки: поток событий не хранит историю. Подробности — в
[руководстве по Realtime](realtime.md).

## 4. Подключитесь и прочитайте строки

Если включено подтверждение почты, приложение запрашивает код из письма.
[Сценарии подтверждения и восстановления](auth-and-oauth.md#confirm-an-email-or-recover-a-password-with-its-code)
содержат примеры Web, Swift и Kotlin. До подтверждения регистрация не создаёт
сессию; для смены забытого пароля сначала проверяется код восстановления.

### Web и Node.js

```ts
import { createClient } from '@stayo/sdk'

const stayo = createClient({
  url: import.meta.env.VITE_STAYO_URL,
  publicKey: import.meta.env.VITE_STAYO_PUBLIC_KEY,
})

await stayo.auth.signInWithPassword({ email, password })
const user = await stayo.auth.getUser()
const { data: notes } = await stayo.from('notes')
  .select('id,title,created_at')
  .eq('owner_id', user.id)
  .order('created_at', { ascending: false })
  .range(0, 19)
  .execute()
```

Для SSR создавайте новый клиент на каждый запрос и передавайте ему хранилище
сессии этого запроса. Не используйте одного вошедшего пользователя в другом
запросе. Подробности — в [README JavaScript SDK](reference/javascript.md#ssr).

### iOS и macOS

```swift
import Foundation
import Stayo

struct Note: Codable, Sendable {
    let id: String
    let title: String
    let created_at: String
}

let stayo = try StayoClient(
    url: URL(string: projectURL)!,
    publicKey: publicProjectKey
)
try await stayo.auth.signIn(email: email, password: password)
let result = try await stayo.database.from("notes")
    .select("id,title,created_at")
    .order("created_at")
    .range(0, 19)
    .execute(as: [Note].self)
let notes = result.value
```

По умолчанию сессия хранится в Apple Keychain. Чтобы разделить учётные записи
в одном приложении, задайте каждой своё пространство имён. См. [README Swift
SDK](../../sdk/stayo-swift/README.md).

### Android

```kotlin
import live.stayo.sdk.StayoClient

val stayo = StayoClient(projectURL, publicProjectKey, applicationContext)
stayo.auth.signInWithPassword(email, password)
val result = stayo.from("notes")
    .select("id,title,created_at")
    .order("created_at")
    .range(0, 19)
    .execute()
val notes = result.data
```

В Android-приложении используйте конструктор с `Context`: он сохраняет только
шифротекст в закрытой папке приложения и хранит ключ в Android Keystore. Эта
папка исключена из резервного копирования Android. См. [README Android
SDK](../../sdk/stayo-android/README.md).

## 5. Следующие шаги

- [Вход по почте, Google и Apple](auth-and-oauth.md)
- [Загрузка приватных файлов с RLS по владельцу](storage.md)
- [Вызов серверной функции с сессией пользователя](secrets-and-functions.md)
- [Подписка на изменения и восстановление после обрыва](realtime.md)
- [Ошибки и диагностика](troubleshooting.md)

Доступ к таблицам и Storage контролируют политики проекта. Проверьте два
пользователя: каждый должен видеть только свои строки и объекты.

Проект допускает два одновременных вызова Functions. Обрабатывайте HTTP `429` и
код SDK `FUNCTION_CONCURRENCY_LIMIT`. Вызов с возможными побочными эффектами
не повторяется автоматически. SDK не передаёт приложению текст ошибок провайдера.

Отмена прекращает ожидание в приложении. Если сервер ещё не отправил заголовки
ответа, обработчик может занимать слот до завершения или лимита 60 секунд.
После отмены обоих вызовов новые запросы временно могут получать тот же `429`.
Уже выполненные действия внешнего сервиса отмена не откатывает.
