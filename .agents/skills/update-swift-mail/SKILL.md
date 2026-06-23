---
name: update-swift-mail
description: Update the local SwiftMail SPM fork from upstream/main, then re-apply MyEmail's local patches on top via rebase. Trigger when the user runs `/update-swift-mail` or asks to refresh/update/sync the SwiftMail dependency.
---

# update-swift-mail

Обновляет локальный fork **SwiftMail** (`../SwiftMail`) из `upstream/main` и накатывает локальные патчи MyEmail (`MyEmail fork:` коммиты + любые adapter-коммиты под изменения NIOIMAPCore API) поверх свежей базы.

## Контекст (см. `~/.Codex/projects/.../memory/`)

- `../SwiftMail` — local-path SPM dep, branch **`myemail-fork`**.
- Origin **и** upstream указывают на `https://github.com/Cocoanetics/SwiftMail.git` — это нормально.
- Обновления делаются **в git**, не через `swift package update`.
- Локальные патчи живут как git-коммиты на `myemail-fork`, **не** как `.patch` файлы.

## Процедура

Все команды выполняются из репозитория SwiftMail. Работаем последовательно — каждый шаг зависит от предыдущего.

### 1. Pre-flight checks

```bash
cd ../SwiftMail
git status --short            # WT должен быть clean
git rev-parse --abbrev-ref HEAD   # должен быть myemail-fork
```

Если есть uncommitted changes — **остановись** и сообщи пользователю. Не делай `stash`/`reset` без явного согласия.

Если ветка не `myemail-fork` — **остановись** и спроси.

### 2. Снимок локальных патчей (для отчёта)

```bash
git log --oneline myemail-fork --not upstream/main
```

Запомни список — после rebase сравним с тем же выводом и убедимся, что все патчи пережили обновление.

Также сделай безопасный backup:

```bash
git branch -f myemail-fork-backup-$(date +%Y%m%d-%H%M%S) myemail-fork
```

### 3. Fetch upstream

```bash
git fetch upstream --prune
git fetch origin --prune
```

### 4. Rebase

```bash
git rebase upstream/main
```

**Если конфликт** — НЕ продолжай автоматически. Покажи пользователю:
- список конфликтующих файлов (`git status`),
- список патчей до конфликтного,
- предложи варианты: разрешить руками + `git rebase --continue`, или `git rebase --abort`.

Не используй `--strategy=ours/theirs`, не передавай `-X` флагов — это критичный код, конфликт = сигнал что upstream изменил API под нашими патчами.

**ВНИМАНИЕ: `--ours` / `--theirs` при rebase инвертированы.** При `git rebase upstream/main`:
- `--ours` = HEAD ветки, на которую rebase'имся (т.е. **upstream/main**),
- `--theirs` = коммит, который применяется (т.е. **наш патч**).

Это **противоположно** интуиции из `git merge`. Если хочешь сохранить наш патч в Package.swift — `--theirs`. Если хочешь принять upstream — `--ours`.

**Особый случай: Package.swift**. Один из наших патчей **обязательно** содержит override `swift-nio-imap` на `path: "../swift-nio-imap"` (для CRLF-split fix `e466da1`, без него ломается длинный IMAP). Этот override должен пережить любой rebase. Если по ошибке принят upstream-вариант (`odrobnik/swift-nio-imap@exact:`) — добавь отдельный коммит сверху, восстанавливающий local-path override (см. коммит `MyEmail fork: override swift-nio-imap with local path for CRLF-split fix` как референс).

### 5. Post-rebase verification

```bash
git log --oneline myemail-fork --not upstream/main
git log --oneline -5
```

Сверь со снапшотом из шага 2:
- Должно быть **столько же** локальных коммитов (или больше, если упомянуты merge-фиксы).
- Subject lines `MyEmail fork: ...` должны совпадать.

### 6. Push (только с явного согласия пользователя)

```bash
# Force-push нужен из-за rebase. НЕ делать без подтверждения.
git push --force-with-lease origin myemail-fork
```

Спроси пользователя перед push'ом. Локального rebase достаточно для пересборки MyEmail — push нужен только если фиксируем результат.

### 7. Что **НЕ** делать

- ❌ `swift package update` — это поломает local-path resolution.
- ❌ `xcodebuild` автоматически — пользователь собирает сам (`feedback_no_build.md`).
- ❌ Менять `Package.swift` MyEmail — local-path dependency остаётся как есть.
- ❌ Удалять backup-ветку — пусть лежит, чистка вручную.
- ❌ `git pull` без указания ремоута/ветки — он подтянет origin/myemail-fork и съест наш rebase.

## Финальный отчёт пользователю

Краткий summary:
- Сколько коммитов upstream подтянуто (`git log upstream/main --not myemail-fork@{1} --oneline | wc -l` — до rebase).
- Список локальных патчей (subject lines).
- Имя backup-ветки.
- Был ли конфликт и как разрешён.
- Нужен ли `swift-nio-imap` revert по правилу `project_swiftnioimap_revert_to_url.md` (`git tag --contains <pinned-sha>` в `../swift-nio-imap`).
- Reminder пользователю: пересобрать MyEmail вручную (`Cmd-B` в Xcode или `xcodebuild`).
