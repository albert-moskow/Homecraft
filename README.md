# HomeCraft Launcher

Лаунчер для проекта HomeCraft: NeoForge 1.21.1, офлайн-ник, моды качаются из этого репозитория.

## Как устроено

- `src/` — исходники на SwiftUI
- `build.sh` — сборка `.app` без Xcode (нужны только Command Line Tools)
- `pack.json` — манифест модпака: список файлов, sha1, размеры
- `mods/` — сами моды (их тянет лаунчер)
- `latest.json` — генерируется автоматически после сборки, лаунчер по нему обновляется
- `.github/workflows/release.yml` — собирает и публикует релиз при пуше в `main`

## Сборка локально

```bash
./build.sh              # → build/HomeCraft.app
open build/HomeCraft.app
```

## Как обновить моды

1. Положить новый jar в `mods/`
2. Перегенерировать `pack.json` (sha1 + размер)
3. Поднять `version` в `pack.json`
4. Закоммитить

Лаунчер у игроков сам докачает только изменённые файлы.

## Куда ставится

```
~/Library/Application Support/HomeCraft/
├── game/      # Minecraft + NeoForge + mods
├── java/      # Temurin 21
├── cache/     # архивы загрузок
└── logs/      # логи игры
```

## Android

На телефоне используется AutoModpack: сервер сам раздаёт модпак при входе. ПК-лаунчер и Android не конфликтуют — разные наборы клиентских модов.
