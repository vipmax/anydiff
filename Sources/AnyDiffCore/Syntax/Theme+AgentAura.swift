import AppKit

extension Theme {
    /// Returns 4 harmonious, visually distinct sRGB colors derived from this theme's palette
    /// for rendering the animated multi-color aura around the working agent avatar.
    public var agentAuraColors: [NSColor] {
        let candidates: [NSColor] = [
            accentColor,
            keyword,
            type,
            string,
            function,
            number,
            property,
            `operator`,
            diffAddedGutter,
            diffDeletedGutter,
            diffModifiedGutter
        ]

        let targetCount = 4
        var selected: [NSColor] = []
        selected.reserveCapacity(targetCount)

        // Pass 1: saturated, well-separated colors from the theme's syntax & UI palette
        appendDistinctColors(
            from: candidates,
            into: &selected,
            limit: targetCount,
            minSaturation: 0.16,
            minDistance: 0.24
        )

        // Pass 2: relax separation for cohesive/monochrome themes (e.g. Matrix, Vesper)
        if selected.count < targetCount {
            appendDistinctColors(
                from: candidates,
                into: &selected,
                limit: targetCount,
                minSaturation: 0.10,
                minDistance: 0.08
            )
        }

        // Pass 3: guarantee 4 colors even on minimal palettes
        if selected.count < targetCount {
            for candidate in [accentColor, keyword, type, string] where selected.count < targetCount {
                if let srgb = candidate.usingColorSpace(.sRGB) {
                    selected.append(srgb)
                }
            }
        }

        return selected.isEmpty ? [.systemBlue, .systemPurple, .systemPink, .systemTeal] : selected
    }

    private func appendDistinctColors(
        from candidates: [NSColor],
        into selected: inout [NSColor],
        limit: Int,
        minSaturation: CGFloat,
        minDistance: CGFloat
    ) {
        let minDistanceSq = minDistance * minDistance
        for candidate in candidates {
            guard selected.count < limit else { break }
            guard let srgb = candidate.usingColorSpace(.sRGB) else { continue }
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            guard saturation >= minSaturation, brightness >= 0.12 else { continue }

            let isDistinct = selected.allSatisfy { existing in
                let dr = srgb.redComponent - existing.redComponent
                let dg = srgb.greenComponent - existing.greenComponent
                let db = srgb.blueComponent - existing.blueComponent
                return (dr * dr + dg * dg + db * db) >= minDistanceSq
            }
            if isDistinct {
                selected.append(srgb)
            }
        }
    }
}
