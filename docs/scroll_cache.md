# Editor Scroll Cache Architecture & Performance Design

## 1. Problem Analysis from Instruments Trace

Profiling the virtualized MultiBuffer editor during scrolling (`/tmp/anydiff-scroll-20260826-144740.trace`, 8.4s recording, 4,479 samples in Time Profiler) revealed the main sources of micro-stutter and high CPU load (75% Main Thread utilization):

1. **`LineLayoutCache.getOrCreateCTLine` (35.5% of total app CPU)**:
   - To look up or cache a `CTLine`, `LineLayoutCache.cacheKey(for:)` iterated `attributedString.enumerateAttributes`.
   - For every syntax token, it formatted color components via `color.usingColorSpace(.deviceRGB)` into ASCII float strings (`swift_dtoa_optimal_binary64_p`) and concatenated strings via `+=`.
   - At 120 Hz with 60 visible lines, this resulted in **~57,000 heap string allocations and color conversions per second**.
   - Creating `CTLineCreateWithAttributedString` took only 2 samples (0.1% CPU), while computing the string cache key took 1,566 samples (35.4% CPU).

2. **`drawGutter` (9.0% CPU)**:
   - On every line and every frame, `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)` was recreated (3.5% CPU), along with new `NSDictionary` attribute dictionaries and `NSAttributedString` instances (3.2% CPU).

3. **`drawExcerptHeader` (6.9% CPU)**:
   - File icons were redrawn through `NSImage.draw` and `CoreUI` vector glyph resolution (4.8% CPU), and header fonts were recreated on each frame.

4. **`editorDidScroll` / `captureViewState` (2.0% CPU)**:
   - Triggered twice on every scroll event in `EditorHostView.Coordinator`.

---

## 2. Direct-Mapped Ring Buffer Cache Design

To achieve zero heap allocations and 1-cycle L1 CPU cache access during 120 FPS scrolling, the editor uses a **Direct-Mapped Slot Cache (Ring Buffer)** bounded to 2,048 lines, indexed purely by sequential `displayLineIndex` (0, 1, 2, 3... covering unchanged, deleted red, and added green lines alike).

### Core Structure

```swift
public struct LineCacheSlot: @unchecked Sendable {
    public var lineIndex: Int = -1
    public var ctLine: CTLine?
}
```

```swift
public final class LineRenderCache: @unchecked Sendable {
    public static let slotCount = 2048
    public static let slotMask = 2047 // 2048 - 1 (0b0111_1111_1111)

    @usableFromInline
    var slots = [LineCacheSlot](repeating: LineCacheSlot(), count: slotCount)

    @inlinable
    public func get(lineIndex: Int) -> CTLine? {
        let slot = lineIndex & Self.slotMask
        let entry = slots[slot]
        if entry.lineIndex == lineIndex {
            return entry.ctLine
        }
        return nil
    }

    @inlinable
    public func set(lineIndex: Int, ctLine: CTLine) {
        let slot = lineIndex & Self.slotMask
        slots[slot] = LineCacheSlot(lineIndex: lineIndex, ctLine: ctLine)
    }

    public func clear() {
        slots = [LineCacheSlot](repeating: LineCacheSlot(), count: Self.slotCount)
    }
}
```

---

## 3. Hardware & Memory Principles

### 1. Sequential Display Line Indexing
- Every visual line in `DisplayMap` has a strict sequential index `0...displayLineCount-1` (including red deleted lines, green added lines, headers, and code lines).
- Looking up a line requires no string keys or dictionary hashing: `lineIndex & 2047` computes the exact slot in 1 CPU cycle.

### 2. Invalidation on Edit & Fast Repopulation
- When the user edits text or expands an excerpt, `invalidateLayout()` clears the cache (`lineCache.clear()`).
- The cache then seamlessly repopulates on-demand during subsequent rendering frames.

### 3. Collision Safety & Bounded Memory
- 2,048 `CTLine` references take at most **~1 MB of RAM** total.
- Memory consumption remains strictly bounded at ~1 MB regardless of document size.

---
---

# Архитектура кэша скролла и производительность редактора (RU)

## 1. Анализ узких мест из трейса Instruments

Профилирование виртуализированного MultiBuffer-редактора во время скролла (`/tmp/anydiff-scroll-20260826-144740.trace`, 8.4 секунды записи, 4 479 семплов в Time Profiler) выявило основные причины микролагов и высокой нагрузки на процессор (загрузка Main Thread ~75%):

1. **`LineLayoutCache.getOrCreateCTLine` (35.5% всего CPU приложения)**:
   - Обход атрибутов через `enumerateAttributes`, форматирование RGB-цветов в текст и конкатенация строк вызывали ~57 000 аллокаций в секунду.
2. **`drawGutter` (9.0% CPU)**:
   - Пересоздание шрифта `monospacedDigitSystemFont` и словарей на каждой строке.
3. **`drawExcerptHeader` (6.9% CPU)**:
   - Пересоздание шрифтов и тяжелая отрисовка иконок на каждом кадре.
4. **`editorDidScroll` / `captureViewState` (2.0% CPU)**:
   - Дублирующий вызов на каждом микрособытии скролла.

---

## 2. Архитектура кольцевого кэша с прямым отображением (Direct-Mapped Ring Buffer)

Кэш индексируется напрямую по порядковому номеру строки на экране `displayLineIndex` (0, 1, 2, 3...), который одинаково нумерует и обычные, и красные удаленные, и зеленые добавленные строки.

### Базовая структура

```swift
public struct LineCacheSlot: @unchecked Sendable {
    public var lineIndex: Int = -1
    public var ctLine: CTLine?
}
```

```swift
public final class LineRenderCache: @unchecked Sendable {
    public static let slotCount = 2048
    public static let slotMask = 2047 // 2048 - 1 (в двоичной системе: 0b0111_1111_1111)

    @usableFromInline
    var slots = [LineCacheSlot](repeating: LineCacheSlot(), count: slotCount)

    @inlinable
    public func get(lineIndex: Int) -> CTLine? {
        let slot = lineIndex & Self.slotMask
        let entry = slots[slot]
        if entry.lineIndex == lineIndex {
            return entry.ctLine
        }
        return nil
    }

    @inlinable
    public func set(lineIndex: Int, ctLine: CTLine) {
        let slot = lineIndex & Self.slotMask
        slots[slot] = LineCacheSlot(lineIndex: lineIndex, ctLine: ctLine)
    }

    public func clear() {
        slots = [LineCacheSlot](repeating: LineCacheSlot(), count: Self.slotCount)
    }
}
```

---

## 3. Принцип работы при редактировании и скролле

1. **Сквозной индекс строк**:
   В `DisplayMap` все строки идут строго по порядку: `0, 1, 2, 3...` (и красные удаленные, и зеленые добавленные, и обычные).
2. **Сброс при редактировании**:
   При любом вводе с клавиатуры, удалении символов или раскрытии чанков вызывается `invalidateLayout()`, который мгновенно сбрасывает кэш (`lineCache.clear()`).
3. **Мгновенное заполнение**:
   При последующих кадрах скролла кэш прозрачно наполняется актуальными строками за 1 такт CPU без единой аллокации.
