# AnyDiff

Сверхбыстрый нативный macOS MultiBuffer Diff редактор для продуктивного Code Review на Swift, созданный по архитектуре Zed (`multi_buffer`).

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)
![Build](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)
![Tests](https://img.shields.io/badge/tests-9%2F9%20passing-brightgreen?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

---

## Ключевые возможности

- **MultiBuffer Architecture**: объединение срезов (excerpts/hunks) из разных файлов в единый виртуальный непрерывный документ со сквозным скроллом и быстрым двусторонним маппингом координат `MultiBufferRow <-> (File, Line)`.
- **Динамический пересчет диффа на лету (LineDiffEngine)**:
  - Встроенный чистый Myers diff алгоритм пересчитывает дифф за 0.05-0.1 мс на каждое нажатие клавиши.
  - Мгновенная адаптация номеров строк в гаттере, смещение блоков и динамическое обновление счетчиков `+N -M`.
- **Sticky File Headers (Прилипающие заголовки)**:
  - При скролле длинных файлов плашка с названием файла, статусом и бейджами изменений (`+N -M`) закрепляется в самом верху редактора с легкой тенью.
  - Плавное выталкивание (Push-away physics): при подходе следующего файла предыдущий заголовок мягко уходит вверх.
  - Интерактивный `Collapse / Expand` прямо на sticky-плашке.
- **Безопасное редактирование диффа**:
  - Зеленые добавленные (`.added`) и контекстные (`.unchanged`) строки полноценно редактируются на лету.
  - Красные удаленные строки (`.deleted`) защищены от случайной модификации (Read-Only) с системным звуковым предупреждением.
  - Сохранение измененных буферов напрямую в файлы на диск (`Cmd + S`).
- **Кастомный CoreText движок рендеринга**:
  - Полная виртуализация вьюпорта: рендерятся только видимые на экране строки (120 FPS ProMotion).
  - Никаких тормозов `NSTextView` на диффах в тысячи строк.
- **Двойной гаттер**: старый и новый номер строки с цветной индикацией (`+` добавлен, `-` удален).
- **Пословный дифф (Intra-line Word Diff)**: посимвольная и пословная подсветка измененных токенов через Myers/LCS с адаптацией при редактировании.
- **Живое редактирование**:
  - Ввод текста, Enter, Tab, Backspace, Delete прямо в срезах.
  - Мышиное и клавиатурное выделение текста.
  - Undo/Redo (`Cmd + Z`, `Cmd + Shift + Z`) на основе истории транзакций `MultiBufferUndoManager`.
- **Сворачивание и развертывание контекста**:
  - Кликом по заголовку файла сворачиваются/разворачиваются все ханки файла целиком.
  - Плашки `Fold Gap` позволяют разворачивать скрытый контекст на 10 строк вверх или вниз.
- **Инлайн код-ревью**: добавление комментариев ревью по клику на `+` в гаттере с ветками обсуждений.
- **Интеграция с Git**:
  - Автоматическая загрузка диффа из текущей директории при старте.
  - Горячая клавиша `Cmd + R` для мгновенного обновления диффа при изменениях в репозитории.
  - Открытие любого локального Git-репозитория или вставка произвольного `.diff` / `.patch`.
- **Минималистичный UI без визуального мусора**:
  - 100% высоты окна отдано под редактор кода.
  - Кнопки выбора папки, обновления и палитры тем встроены в шапку окна левее сплит-разделителя.
  - Название текущей открытой папки выводится в заголовке окна.
  - Автоматически исчезающие (auto-hide fade) оверлейные скроллбары.
- **Темы оформления**:
  - `Zed Slate Gray` (темно-серый фирменный стиль `#28292d` в тон сайдбару),
  - `Zed Dark`,
  - `Tokyo Night`,
  - `GitHub Dark`.
  - Быстрая токенизированная подсветка синтаксиса (Swift, Rust, TypeScript, Python, C++, Go, JSON).

---

## Горячие клавиши

| Сочетание клавиш | Действие |
| :--- | :--- |
| **Cmd + O** | Открыть папку Git-репозитория |
| **Cmd + R** | Обновить дифф из текущего репозитория |
| **Cmd + S** | Сохранить все измененные буферы на диск |
| **Cmd + Shift + V** | Вставить произвольный Git-дифф из буфера обмена |
| **Cmd + Z** | Отменить последнее действие (Undo) |
| **Cmd + Shift + Z** | Повторить отмененное действие (Redo) |
| **Cmd + A** | Выделить весь текст в текущем буфере |
| **Cmd + C** | Скопировать выделенный фрагмент |
| **Cmd + V** | Вставить текст |
| **Option + Click** | Развернуть скрытый контекст (Fold Gap) |

---

## Архитектура проекта

```text
AnyDiff
├── Sources/
│   ├── AnyDiffCore/          # Ядро редактора (не зависит от AppKit/UI)
│   │   ├── Diff/             # GitDiffParser, LineDiffEngine, WordDiffEngine, DiffHunk
│   │   ├── MultiBuffer/      # MultiBuffer, Buffer, Excerpt, UndoManager, EditTransaction
│   │   ├── Display/          # DisplayMap, DisplayLine, Coordinate Translation
│   │   ├── Syntax/           # SyntaxHighlighter, Color Themes (Tokens)
│   │   └── Review/           # ReviewManager, ReviewComment
│   ├── AnyDiffUI/            # Слой представления (SwiftUI + кастомный AppKit CoreText)
│   │   ├── Editor/           # CustomMultiBufferEditorView, CoreText LineCache, Virtual Scroll
│   │   └── Views/            # MainWindowView, SidebarFileListView, Modals
│   └── AnyDiff/              # Точка входа (main.swift, AppDelegate, NSApplication)
└── Tests/
    └── AnyDiffCoreTests/     # Юнит-тесты (Myers Diff, MultiBuffer, WordDiff, Координаты)
```

---

## Сборка и запуск

### Требования
- macOS 14.0+ (Sonoma или новее)
- Swift 6.0+ / Xcode 16.0+

### Запуск через терминал
```bash
# Клонирование репозитория
git clone https://github.com/your-username/anydiff.git
cd anydiff

# Запуск тестов
swift test

# Сборка и запуск приложения
swift run
```

---

## Лицензия

Распространяется под лицензией MIT.