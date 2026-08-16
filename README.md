# AnyDiff ⚡️

Сверхбыстрый нативный macOS MultiBuffer Diff редактор для Code Review на Swift, созданный по архитектуре Zed (`~/dev/tmp/zed/crates/multi_buffer`).

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

---

## 🚀 Ключевые возможности

- **MultiBuffer Architecture**: объединение срезов (excerpts) из разных файлов в единый виртуальный непрерывный документ со сквозным скроллом и быстрым маппингом координат `MultiBufferRow <-> (File, Line)`.
- **Кастомный CoreText движок**: рендеринг без накладных расходов `NSTextView` с полной виртуализацией вьюпорта (120 FPS ProMotion).
- **Двойной гаттер**: старый и новый номер строки с цветной индикацией (`+` добавлен, `-` удален, `~` изменен).
- **Пословный дифф (Intra-line Word Diff)**: посимвольная и пословная подсветка измененных токенов через Myers/LCS.
- **Живое редактирование**:
  - Ввод текста, Enter, Tab, Backspace, Delete прямо в срезах.
  - Мышиное и клавиатурное выделение, мультикурсор.
  - Undo/Redo (`Cmd+Z`, `Cmd+Shift+Z`) на основе истории транзакций `MultiBufferUndoManager`.
- **Инлайн код-ревью**: добавление комментариев ревью по клику на `+` в гаттере с ветками обсуждений.
- **Интеграция с Git**:
  - Автоматическая загрузка диффа из текущей директории при старте.
  - Горячая клавиша `Cmd + R` для мгновенного обновления диффа при изменениях в кодовой базе.
  - Открытие любого локального Git-репозитория или вставка `.diff` / `.patch`.
- **Темы оформления**: Zed Dark, Tokyo Night, GitHub Dark с быстрой токенизированной подсветкой синтаксиса (Swift, Rust, TypeScript, Python, C++, Go, JSON).

---

## 🛠 Установка и запуск

### Требования
- macOS 14.0 (Sonoma) или новее
- Xcode 15+ / Swift 5.9+

### Сборка и запуск
```bash
# Клонировать репозиторий
git clone https://github.com/anydiff/anydiff-swift2.git
cd anydiff-swift2

# Запустить приложение для текущей папки
swift run AnyDiff

# Либо запустить для любого другого репозитория
swift run AnyDiff /path/to/another/repo
```

### Запуск тестов
```bash
swift test
```

---

## 📂 Архитектура

```
AnyDiff/
├── Sources/
│   ├── AnyDiffCore/             # MultiBuffer, Diff Engine, DisplayMap, Syntax
│   │   ├── MultiBuffer/         # Buffer, Excerpt, CoordinateMapping
│   │   ├── Diff/                # GitDiffParser, WordDiffEngine, ReviewModel
│   │   ├── Editing/             # MultiBufferUndoManager, TextEditTransaction
│   │   ├── Display/             # DisplayMap, DisplayLine, LineLayoutCache
│   │   └── Syntax/              # SyntaxHighlighter, Theme
│   ├── AnyDiffUI/               # AppKit Custom CoreText Editor & SwiftUI Views
│   │   ├── Editor/              # CustomMultiBufferEditorView, Gutter, InlineComments
│   │   └── Views/               # MainWindowView, Sidebar, Toolbar, StatusBar
│   └── AnyDiff/                 # Точка входа приложения (NSApplication, Menu)
└── Tests/                       # Unit-тесты для MultiBuffer, Parser, WordDiff
```

---

## 📄 Лицензия

MIT License. Свободное использование и модификация.