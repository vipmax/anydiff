//
//  main.swift
//  AnyDiff — High Performance MultiBuffer Git Diff Viewer & Review Tool

//  Created for macOS with native FSEvents Watch Mode & Zero-Copy SIMD parsing.
//  Copyright © 2026 AnyDiff. All rights reserved.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if let icon = delegate.loadAppIcon() {
    app.applicationIconImage = icon
}
app.run()
