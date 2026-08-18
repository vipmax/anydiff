# План экстремальной оптимизации памяти AnyDiff (до ~120–150 МБ)

В этом документе описан побайтовый анализ текущего потребления оперативной памяти AnyDiff на мега-диффах (1 000 000+ строк) и пошаговый план сжатия памяти с **657 МБ** до **~120–150 МБ**.

---

## 1. Текущий профиль памяти на миллионе строк

На бенчмарке с 2 200+ файлами и 1 029 583 строками диффа:

| Приложение | Real Memory (RSS) | Потоки |
| :--- | :--- | :--- |
| **Zed** (Rust) | **2.22 GB** | 27 threads |
| **AnyDiff** (Swift, текущее состояние) | **657.6 MB** | **5 threads** |
| **AnyDiff Target** (после упаковки) | **~120–150 MB** | **5 threads** |

---

## 2. Побайтовый анализ: куда уходят 657 МБ

Сейчас для каждой строки диффа создаётся структура `DisplayCodeLineInfo`. Посмотрим на её размер в 64-битной архитектуре Swift:

```swift
public struct DisplayCodeLineInfo {
    public var excerptIndex: Int              // 8 байт
    public var multiBufferRow: MultiBufferRow  // 8 байт
    public var bufferRow: BufferRow            // 8 байт
    public var displayLineIndex: Int          // 8 байт
    public var oldLineNumber: Int?            // 16 байт (Optional Int = 8 байт число + 8 байт флаг/выравнивание)
    public var newLineNumber: Int?            // 16 байт
    public var diffKind: DiffLineKind         // 1 байт (+7 байт padding для выравнивания)
    public var text: String                   // 16 байт заголовок + данные в куче
    public var language: String               // 16 байт заголовок + данные в куче
    public var wordDiffRanges: [Range<Int>]   // 8 байт указатель на Array
    public var expandInfo: ExpandInfo?        // 24 байта
}
```

### Итоговые затраты на 1 000 000 строк:
1. **Массив структур `[DisplayLine]`**: $1\,000\,000 \times 160\text{ байт} \approx \mathbf{160\text{ МБ}}$.
2. **Данные строк (`text` и `language`) в куче**: $\approx \mathbf{250\text{ МБ}}$.
3. **Кэши чанков (`excerptChunkCache`, `excerptDiffCache`)**: $\approx \mathbf{200\text{ МБ}}$.
4. **Массивы сопоставления индексов (`codeRowToDisplayLineIndex`)**: $\approx \mathbf{40\text{ МБ}}$.
* **Суммарно**: $\approx \mathbf{650\text{ МБ}}$.

---

## 3. Архитектурные шаги оптимизации

### Шаг 1. Ленивые строки без дублирования (Zero-Copy Text Reference)
* **Проблема**: Текст каждой строки сейчас дублируется: он хранится в `Buffer._lines` и копируется в `DisplayCodeLineInfo.text`.
* **Решение**: Убрать поле `text: String` и `language: String` из структуры строки.
  * Структура строки хранит только `bufferId` (или `excerptIndex`) и `bufferRow: Int32`.
  * Текст запрашивается из `Buffer` **только для видимого диапазона строк** (50 строк на экране).
* **Экономия**: **-250 МБ**.

---

### Шаг 2. Битовая упаковка чисел и флагов (Bit Packing)
* **Проблема**: 64-битные `Int` (8 байт) и `Optional<Int>` (16 байт) избыточны для номеров строк.
* **Решение**:
  * `oldLineNumber` и `newLineNumber`: `UInt32` (где `0` означает `nil`, а строки нумеруются с 1). Это **4 байта вместо 16 байт**.
  * `excerptIndex`: `UInt16` (до 65 535 срезов) — **2 байта**.
  * `bufferRow`: `UInt32` (до 4 млрд строк) — **4 байта**.
  * `diffKind` (2 бита) + `expandDirection` (2 бита) + флаги упаковываются в **1 байт** `UInt8 bitmask`.

```swift
/// Компактная структура строки — ровно 24 байта!
public struct CompactDisplayLine {
    public var oldLineNumber: UInt32     // 4 байта (0 = nil)
    public var newLineNumber: UInt32     // 4 байта (0 = nil)
    public var bufferRow: UInt32         // 4 байта
    public var excerptIndex: UInt16      // 2 байта
    public var flags: UInt8              // 1 байт (diffKind, expandUp, expandDown)
    private var _padding: UInt8 = 0      // 1 байт выравнивание
    public var lineLength: UInt32        // 4 байта (для быстрого скролла и каретки)
    public var wordDiffOffset: UInt32    // 4 байта (индекс в общем плоском пуле)
}
// MemoryLayout<CompactDisplayLine>.size == 24 байта
```
* **Экономия**: $1\,000\,000 \times (160 - 24)\text{ байт} = \mathbf{-136\text{ МБ}}$.

---

### Шаг 3. Виртуализация кэшей чанков
* **Проблема**: `excerptChunkCache` хранит заранее сгенерированные полные массивы строк для каждого ханка.
* **Решение**: Перевести кэш в режим LRU (хранить только последние 100 активных чанков) или генерировать отображение на лету по компактному индексу.
* **Экономия**: **-150 МБ**.

---

## 4. Сравнительная сводка: До и После

| Параметр | Сейчас (v1.0) | После Bit-Packing (v2.0) | Выигрыш |
| :--- | :--- | :--- | :--- |
| **Размер одной строки** | ~160 байт | **24 байта** | **6.6x компактнее** |
| **Память под 1M структур** | 160 МБ | **24 МБ** | **-136 МБ** |
| **Память под текст строк** | 250 МБ | **0 МБ (zero-copy)** | **-250 МБ** |
| **Кэши чанков** | 200 МБ | **~20 МБ (LRU)** | **-180 МБ** |
| **Общий RSS приложения** | **657 МБ** | **~120–150 МБ** | **~4.5x экономия памяти** |
| **По сравнению с Zed (2.2GB)** | В 3.4x легче | **В 15x легче Zed!** | 🏆 |
