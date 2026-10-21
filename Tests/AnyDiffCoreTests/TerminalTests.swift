import XCTest
import SwiftUI
@testable import AnyDiffCore
@testable import AnyDiffUI

final class TerminalTests: XCTestCase {

    // MARK: - TerminalColor & Attributes Tests

    func testTerminalColors() {
        let def = TerminalColor.default
        let defRgb = def.rgb()
        XCTAssertEqual(defRgb.red, 0.9, accuracy: 0.01)

        let red = TerminalColor.standard(1)
        let redRgb = red.rgb()
        XCTAssertEqual(redRgb.red, 0.8, accuracy: 0.01)

        let brightGreen = TerminalColor.standard(10)
        let bgRgb = brightGreen.rgb()
        XCTAssertEqual(bgRgb.green, 1.0, accuracy: 0.01)

        let p256 = TerminalColor.palette256(196) // Red in 256 palette
        let p256Rgb = p256.rgb()
        XCTAssertGreaterThan(p256Rgb.red, 0.5)

        let trueColor = TerminalColor.trueColor(red: 100, green: 150, blue: 200)
        let tcRgb = trueColor.rgb()
        XCTAssertEqual(tcRgb.red, 100.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(tcRgb.green, 150.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(tcRgb.blue, 200.0 / 255.0, accuracy: 0.001)
    }

    func testTerminalCellAttributes() {
        var attrs: TerminalCellAttributes = [.bold, .italic]
        XCTAssertTrue(attrs.contains(.bold))
        XCTAssertTrue(attrs.contains(.italic))
        XCTAssertFalse(attrs.contains(.underline))

        attrs.insert(.underline)
        XCTAssertTrue(attrs.contains(.underline))

        attrs.remove(.bold)
        XCTAssertFalse(attrs.contains(.bold))
    }

    // MARK: - TerminalScreen Tests

    func testScreenInitialization() {
        let screen = TerminalScreen(cols: 40, rows: 10)
        XCTAssertEqual(screen.cols, 40)
        XCTAssertEqual(screen.rows, 10)
        XCTAssertEqual(screen.cursorX, 0)
        XCTAssertEqual(screen.cursorY, 0)
        XCTAssertEqual(screen.lines.count, 10)
        XCTAssertEqual(screen.lines[0].cells.count, 40)
    }

    func testScreenPutCharacterAndCursor() {
        let screen = TerminalScreen(cols: 10, rows: 5)
        screen.putCharacter("A")
        screen.putCharacter("B")
        screen.putCharacter("C")

        XCTAssertEqual(screen.cursorX, 3)
        XCTAssertEqual(screen.cursorY, 0)
        XCTAssertEqual(screen.lines[0].cells[0].character, "A")
        XCTAssertEqual(screen.lines[0].cells[1].character, "B")
        XCTAssertEqual(screen.lines[0].cells[2].character, "C")

        screen.carriageReturn()
        XCTAssertEqual(screen.cursorX, 0)
        screen.lineFeed()
        XCTAssertEqual(screen.cursorY, 1)

        screen.tab()
        XCTAssertEqual(screen.cursorX, 8)

        screen.backspace()
        XCTAssertEqual(screen.cursorX, 7)
    }

    func testScreenWrapAndScroll() {
        let screen = TerminalScreen(cols: 5, rows: 2)
        // Write 6 characters to force wrap
        for c in "HELLO!" {
            screen.putCharacter(c)
        }
        // "HELLO" is on row 0, "!" wrapped to row 1
        XCTAssertEqual(screen.lines[0].plainText(), "HELLO")
        XCTAssertEqual(screen.lines[1].plainText(), "!")

        // Line feed on bottom row scrolls up
        screen.lineFeed()
        XCTAssertEqual(screen.scrollback.count, 1)
        XCTAssertEqual(screen.scrollback[0].plainText(), "HELLO")
        XCTAssertEqual(screen.lines[0].plainText(), "!")
    }

    func testScreenEraseOperations() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        for c in "0123456789" {
            screen.putCharacter(c)
        }
        XCTAssertEqual(screen.lines[0].plainText(), "0123456789")

        // Erase from cursor (pos 5) to end of line
        screen.setCursorPosition(col: 5, row: 0)
        screen.eraseInLine(mode: 0)
        XCTAssertEqual(screen.lines[0].plainText(), "01234")

        // Erase entire line
        screen.eraseInLine(mode: 2)
        XCTAssertEqual(screen.lines[0].plainText(), "")
    }

    func testAlternateScreenBuffer() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        screen.putCharacter("M")
        screen.putCharacter("A")
        screen.putCharacter("I")
        screen.putCharacter("N")
        XCTAssertEqual(screen.lines[0].plainText(), "MAIN")

        // Switch to alternate buffer
        screen.switchAlternateScreen(enable: true)
        XCTAssertTrue(screen.isAlternateBufferActive)
        XCTAssertEqual(screen.lines[0].plainText(), "")

        screen.putCharacter("A")
        screen.putCharacter("L")
        screen.putCharacter("T")
        XCTAssertEqual(screen.lines[0].plainText(), "ALT")

        // Switch back to primary
        screen.switchAlternateScreen(enable: false)
        XCTAssertFalse(screen.isAlternateBufferActive)
        XCTAssertEqual(screen.lines[0].plainText(), "MAIN")
    }

    func testAlternateScreenResizeAndEraseRegression() {
        let screen = TerminalScreen(cols: 80, rows: 24)
        let parser = TerminalEscapeParser(screen: screen)

        // Simulate interactive program entering alternate screen buffer
        parser.feed("\u{1B}[?1049h".data(using: .utf8)!)
        XCTAssertTrue(screen.isAlternateBufferActive)

        // View resizes grid while in alternate screen buffer
        screen.resize(cols: 120, rows: 35)
        XCTAssertEqual(screen.cols, 120)
        XCTAssertEqual(screen.rows, 35)

        // Interactive program exits alternate screen buffer
        parser.feed("\u{1B}[?1049l".data(using: .utf8)!)
        XCTAssertFalse(screen.isAlternateBufferActive)
        XCTAssertEqual(screen.cols, 120)
        XCTAssertEqual(screen.rows, 35)
        XCTAssertEqual(screen.lines.count, 35)
        XCTAssertEqual(screen.lines[0].cells.count, 120)

        // Now program or shell issues erase in display / erase in line
        // (Previously crashed with Index out of range: lines[cursorY].cells[x])
        parser.feed("\u{1B}[J".data(using: .utf8)!)
        parser.feed("\u{1B}[2J".data(using: .utf8)!)
        parser.feed("\u{1B}[K".data(using: .utf8)!)

        XCTAssertEqual(screen.lines[0].cells.count, 120)
    }

    func testScreenResize() {
        let screen = TerminalScreen(cols: 20, rows: 5)
        for c in "Hello, World!" {
            screen.putCharacter(c)
        }
        XCTAssertEqual(screen.lines[0].plainText(), "Hello, World!")

        screen.resize(cols: 30, rows: 8)
        XCTAssertEqual(screen.cols, 30)
        XCTAssertEqual(screen.rows, 8)
        XCTAssertEqual(screen.lines.count, 8)
        XCTAssertEqual(screen.lines[0].cells.count, 30)
        XCTAssertEqual(screen.lines[0].plainText(), "Hello, World!")
    }

    // MARK: - TerminalEscapeParser Tests

    func testEscapeParserPlainOutput() {
        let screen = TerminalScreen(cols: 20, rows: 5)
        let parser = TerminalEscapeParser(screen: screen)

        let data = "Hello, AnyDiff!\r\nSecond Line".data(using: .utf8)!
        parser.feed(data)

        XCTAssertEqual(screen.lines[0].plainText(), "Hello, AnyDiff!")
        XCTAssertEqual(screen.lines[1].plainText(), "Second Line")
    }

    func testEscapeParserSgrColorsAndStyles() {
        let screen = TerminalScreen(cols: 20, rows: 5)
        let parser = TerminalEscapeParser(screen: screen)

        // \e[1;31m Red Bold \e[0m Reset
        let ansi = "\u{1B}[1;31mRed\u{1B}[0mPlain"
        parser.feed(ansi.data(using: .utf8)!)

        XCTAssertEqual(screen.lines[0].cells[0].character, "R")
        XCTAssertEqual(screen.lines[0].cells[0].fg, .standard(1))
        XCTAssertTrue(screen.lines[0].cells[0].attributes.contains(.bold))

        XCTAssertEqual(screen.lines[0].cells[3].character, "P")
        XCTAssertEqual(screen.lines[0].cells[3].fg, .default)
        XCTAssertFalse(screen.lines[0].cells[3].attributes.contains(.bold))
    }

    func testEscapeParserTrueColor() {
        let screen = TerminalScreen(cols: 20, rows: 5)
        let parser = TerminalEscapeParser(screen: screen)

        // \e[38;2;12;34;56m
        let ansi = "\u{1B}[38;2;12;34;56mTC"
        parser.feed(ansi.data(using: .utf8)!)

        XCTAssertEqual(screen.lines[0].cells[0].fg, .trueColor(red: 12, green: 34, blue: 56))
    }

    func testEscapeParserCursorMovement() {
        let screen = TerminalScreen(cols: 20, rows: 10)
        let parser = TerminalEscapeParser(screen: screen)

        // Move to row 4, col 6 (\e[4;6H)
        let ansi = "\u{1B}[4;6HX"
        parser.feed(ansi.data(using: .utf8)!)

        XCTAssertEqual(screen.cursorY, 3)
        XCTAssertEqual(screen.cursorX, 6) // Placed X at (5, 3), cursor advanced to col 6
        XCTAssertEqual(screen.lines[3].cells[5].character, "X")
    }

    func testEscapeParserDsrCursorPositionReport() {
        let screen = TerminalScreen(cols: 20, rows: 10)
        let parser = TerminalEscapeParser(screen: screen)

        screen.setCursorPosition(col: 7, row: 4)

        var responseData: Data?
        parser.onResponseRequired = { data in
            responseData = data
        }

        // Query cursor position: \e[6n
        parser.feed("\u{1B}[6n".data(using: .utf8)!)

        XCTAssertNotNil(responseData)
        let responseStr = String(data: responseData!, encoding: .utf8)
        XCTAssertEqual(responseStr, "\u{1B}[5;8R") // 1-based row=5, col=8
    }

    func testEscapeParserOscTitle() {
        let screen = TerminalScreen(cols: 20, rows: 10)
        let parser = TerminalEscapeParser(screen: screen)

        var capturedTitle: String?
        parser.onTitleChanged = { title in
            capturedTitle = title
        }

        let osc = "\u{1B}]0;MyCustomTerminal\u{07}"
        parser.feed(osc.data(using: .utf8)!)

        XCTAssertEqual(capturedTitle, "MyCustomTerminal")
    }

    func testScreenReverseIndexAndScrollDown() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        screen.setCursorPosition(col: 0, row: 1)
        screen.putCharacter("B")
        screen.setCursorPosition(col: 0, row: 2)
        screen.putCharacter("C")

        // Cursor at row 1: reverse index moves cursor to row 0
        screen.setCursorPosition(col: 0, row: 1)
        screen.reverseIndex()
        XCTAssertEqual(screen.cursorY, 0)

        // Cursor at row 0 (scrollTop): reverse index scrolls down by 1 line
        screen.reverseIndex()
        XCTAssertEqual(screen.cursorY, 0)
        XCTAssertEqual(screen.lines[2].plainText(), "B") // "C" was scrolled off bottom, "B" moved down
    }

    func testScreenSetScrollRegionResetsCursor() {
        let screen = TerminalScreen(cols: 10, rows: 5)
        screen.setCursorPosition(col: 5, row: 4)
        screen.setScrollRegion(top: 1, bottom: 3)

        XCTAssertEqual(screen.scrollTop, 1)
        XCTAssertEqual(screen.scrollBottom, 3)
        XCTAssertEqual(screen.cursorX, 0)
        XCTAssertEqual(screen.cursorY, 0)

        screen.setCursorPosition(col: 8, row: 2)
        screen.resetScrollRegion()
        XCTAssertEqual(screen.cursorX, 0)
        XCTAssertEqual(screen.cursorY, 0)
    }

    func testEscapeParserReverseIndex() {
        let screen = TerminalScreen(cols: 10, rows: 3)
        let parser = TerminalEscapeParser(screen: screen)

        // Write line 0
        parser.feed("LINE0".data(using: .utf8)!)
        XCTAssertEqual(screen.lines[0].plainText(), "LINE0")

        // Cursor at row 0: ESC M triggers reverseIndex and scrolls down
        parser.feed("\u{1B}M".data(using: .utf8)!)
        XCTAssertEqual(screen.lines[1].plainText(), "LINE0")
        XCTAssertEqual(screen.lines[0].plainText(), "")
    }

    // MARK: - TerminalProcess PTY Integration Test

    func testTerminalProcessLaunchAndOutput() {
        let proc = TerminalProcess(workingDirectory: "/tmp")
        let expectation = expectation(description: "PTY process output received")

        var receivedOutput = ""
        proc.onOutput = { data in
            if let str = String(data: data, encoding: .utf8) {
                receivedOutput += str
                if receivedOutput.contains("ANYDIFF_PTY_OK") {
                    expectation.fulfill()
                }
            }
        }

        XCTAssertNoThrow(try proc.start(cols: 80, rows: 24))
        XCTAssertTrue(proc.isRunning)
        XCTAssertGreaterThan(proc.pid, 0)

        // Write an echo command into shell
        proc.write(string: "echo ANYDIFF_PTY_OK\r")

        wait(for: [expectation], timeout: 5.0)

        proc.terminate()
        XCTAssertFalse(proc.isRunning)
    }

    func testTerminalProcessResize() {
        let proc = TerminalProcess(workingDirectory: "/tmp")
        XCTAssertNoThrow(try proc.start(cols: 80, rows: 24))
        XCTAssertTrue(proc.isRunning)

        // Resize PTY to 120 cols x 40 rows
        proc.resize(cols: 120, rows: 40)

        var win = winsize()
        let res = ioctl(proc.masterFd, TIOCGWINSZ, &win)
        XCTAssertEqual(res, 0)
        XCTAssertEqual(win.ws_col, 120)
        XCTAssertEqual(win.ws_row, 40)

        proc.terminate()
    }

    @MainActor
    func testTerminalScreenResizeReadingContent() async throws {
        let session = TerminalSession(workingDirectory: "/tmp", cols: 80, rows: 24)
        session.start()
        XCTAssertTrue(session.isRunning)

        // Give shell 300ms to initialize prompt
        try await Task.sleep(nanoseconds: 300_000_000)

        // 1. Query initial terminal size via tput
        session.sendInput("echo SZ1:$(tput cols)x$(tput lines)\r")

        // Wait until screen contains the output
        var foundSz1 = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let currentText = session.screen.fullText(includeScrollback: true)
            if currentText.contains("SZ1:80x24") {
                foundSz1 = true
                break
            }
        }
        XCTAssertTrue(foundSz1, "Screen should contain SZ1:80x24 before resize. Actual screen:\n\(session.screen.fullText(includeScrollback: true))")

        // 2. Perform resize to 50 cols, 12 rows
        session.resize(cols: 50, rows: 12)
        XCTAssertEqual(session.screen.cols, 50)
        XCTAssertEqual(session.screen.rows, 12)
        XCTAssertEqual(session.screen.lines.count, 12)
        XCTAssertEqual(session.screen.lines[0].cells.count, 50)

        // Give process 200ms to process SIGWINCH
        try await Task.sleep(nanoseconds: 200_000_000)

        // 3. Query new terminal size via tput
        session.sendInput("echo SZ2:$(tput cols)x$(tput lines)\r")

        var foundSz2 = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let currentText = session.screen.fullText(includeScrollback: true)
            if currentText.contains("SZ2:50x12") {
                foundSz2 = true
                break
            }
        }
        XCTAssertTrue(foundSz2, "Screen should contain SZ2:50x12 after resize. Actual screen:\n\(session.screen.fullText(includeScrollback: true))")

        session.terminateProcess()
    }

    @MainActor
    func testTerminalInteractiveScreenCursorAndWrapAfterResize() async throws {
        let session = TerminalSession(workingDirectory: "/tmp", cols: 80, rows: 24)
        session.start()
        XCTAssertTrue(session.isRunning)

        try await Task.sleep(nanoseconds: 300_000_000)

        // Print a marked line of exactly 70 characters
        let line70 = String(repeating: "A", count: 70)
        session.sendInput("echo MARK1_\(line70)\r")

        var foundMark1 = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let text = session.screen.fullText(includeScrollback: true)
            if text.contains("MARK1_" + line70) {
                foundMark1 = true
                break
            }
        }
        XCTAssertTrue(foundMark1, "Screen should contain 70-char marker before resize")

        // Resize down to 35 cols
        session.resize(cols: 35, rows: 15)
        XCTAssertEqual(session.screen.cols, 35)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Print a line of 20 characters that fits in 35 cols (6 + 20 = 26 cols <= 35)
        let line20 = String(repeating: "B", count: 20)
        session.sendInput("echo MARK2_\(line20)\r")

        var foundMark2 = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let text = session.screen.fullText(includeScrollback: true)
            if text.contains("MARK2_" + line20) {
                foundMark2 = true
                break
            }
        }
        if !foundMark2 {
            print("=== ACTUAL SCREEN BEFORE ASSERT ===\n\(session.screen.fullText(includeScrollback: true))\n===================================")
        }
        XCTAssertTrue(foundMark2, "Screen should contain 20-char marker within 35-col boundary after resize")

        // Verify that screen cells are bounded by new 35 cols limit
        for line in session.screen.lines {
            XCTAssertLessThanOrEqual(line.cells.count, 35)
        }

        session.terminateProcess()
    }

    // MARK: - Mouse Tracking & Encoder Tests

    func testMouseTrackingEscapeSequences() {
        let screen = TerminalScreen(cols: 80, rows: 24)
        let parser = TerminalEscapeParser(screen: screen)

        // Initial default: no tracking, x10 format
        XCTAssertEqual(screen.mouseTrackingMode, .none)
        XCTAssertEqual(screen.mouseFormat, .x10)

        // Enable normal mouse tracking: \e[?1000h
        parser.feed(Data("\u{1b}[?1000h".utf8))
        XCTAssertEqual(screen.mouseTrackingMode, .normal)

        // Enable SGR extended mode: \e[?1006h
        parser.feed(Data("\u{1b}[?1006h".utf8))
        XCTAssertEqual(screen.mouseFormat, .sgr)

        // Enable button-event (drag) tracking: \e[?1002h
        parser.feed(Data("\u{1b}[?1002h".utf8))
        XCTAssertEqual(screen.mouseTrackingMode, .buttonEvent)

        // Enable any-event tracking: \e[?1003h
        parser.feed(Data("\u{1b}[?1003h".utf8))
        XCTAssertEqual(screen.mouseTrackingMode, .anyEvent)

        // Disable mouse tracking: \e[?1000l
        parser.feed(Data("\u{1b}[?1000l".utf8))
        XCTAssertEqual(screen.mouseTrackingMode, .none)

        // Disable SGR mode: \e[?1006l
        parser.feed(Data("\u{1b}[?1006l".utf8))
        XCTAssertEqual(screen.mouseFormat, .x10)
    }

    func testMouseEncoderSGR() {
        // Press left button at (col: 11, row: 6) 1-based
        let pressLeftData = TerminalMouseEncoder.encode(
            button: .left,
            type: .press,
            col: 11,
            row: 6,
            format: .sgr
        )
        XCTAssertEqual(pressLeftData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<0;11;6M")

        // Release left button at (col: 11, row: 6)
        let releaseLeftData = TerminalMouseEncoder.encode(
            button: .left,
            type: .release,
            col: 11,
            row: 6,
            format: .sgr
        )
        XCTAssertEqual(releaseLeftData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<0;11;6m")

        // Middle button press: button code 1 -> \e[<1;...
        let pressMiddleData = TerminalMouseEncoder.encode(
            button: .middle,
            type: .press,
            col: 1,
            row: 1,
            format: .sgr
        )
        XCTAssertEqual(pressMiddleData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<1;1;1M")

        // Right button press: button code 2 -> \e[<2;...
        let pressRightData = TerminalMouseEncoder.encode(
            button: .right,
            type: .press,
            col: 20,
            row: 10,
            format: .sgr
        )
        XCTAssertEqual(pressRightData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<2;20;10M")

        // Drag left button: code 0 + 32 = 32
        let dragLeftData = TerminalMouseEncoder.encode(
            button: .left,
            type: .drag,
            col: 16,
            row: 13,
            format: .sgr
        )
        XCTAssertEqual(dragLeftData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<32;16;13M")

        // Wheel Up: button code 64
        let wheelUpData = TerminalMouseEncoder.encode(
            button: .wheelUp,
            type: .press,
            col: 6,
            row: 9,
            format: .sgr
        )
        XCTAssertEqual(wheelUpData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<64;6;9M")

        // Wheel Down: button code 65
        let wheelDownData = TerminalMouseEncoder.encode(
            button: .wheelDown,
            type: .press,
            col: 6,
            row: 9,
            format: .sgr
        )
        XCTAssertEqual(wheelDownData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<65;6;9M")

        // Modifiers: Shift (+4), Option/Alt (+8), Control (+16)
        let pressWithShiftData = TerminalMouseEncoder.encode(
            button: .left,
            type: .press,
            modifiers: [.shift],
            col: 1,
            row: 1,
            format: .sgr
        )
        XCTAssertEqual(pressWithShiftData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<4;1;1M")

        let pressWithOptCtrlData = TerminalMouseEncoder.encode(
            button: .left,
            type: .press,
            modifiers: [.option, .control],
            col: 1,
            row: 1,
            format: .sgr
        )
        XCTAssertEqual(pressWithOptCtrlData.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[<24;1;1M")
    }

    func testMouseEncoderX10() {
        // Press left at (1, 1) -> col=1, row=1 -> '!' (33), '!' (33)
        // Button 0 + 32 = 32 (' ')
        let pressX10Data = TerminalMouseEncoder.encode(
            button: .left,
            type: .press,
            col: 1,
            row: 1,
            format: .x10
        )
        XCTAssertEqual(pressX10Data.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[M !!")

        // Wheel Up (64 + 32 = 96 = '`') at col: 2, row: 3 -> 2+32=34 ('"'), 3+32=35 ('#')
        let wheelX10Data = TerminalMouseEncoder.encode(
            button: .wheelUp,
            type: .press,
            col: 2,
            row: 3,
            format: .x10
        )
        XCTAssertEqual(wheelX10Data.flatMap { String(data: $0, encoding: .utf8) }, "\u{1b}[M`\"#")
    }

    func testHtopStreamParsing() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/htop_stream.bin")) else {
            return
        }
        let screen = TerminalScreen(cols: 112, rows: 24)
        let parser = TerminalEscapeParser(screen: screen)
        parser.feed(data)

        let headerLine = screen.lines[10].plainText().trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(headerLine.contains("PID"), "Line 10 should contain PID header, got: '\(headerLine)'")
        XCTAssertTrue(headerLine.contains("Command"), "Line 10 should contain Command, got: '\(headerLine)'")

        let procLine = screen.lines[11].plainText().trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(procLine.contains("kernel_task"), "Line 11 should contain kernel_task, got: '\(procLine)'")
    }

    @MainActor
    func testTerminalPanelViewRendering() {
        let session = TerminalSession(workingDirectory: "/tmp")
        let view = TerminalPanelView(session: session, theme: .vesper, fontSize: 12, onBack: {})
            .padding(.top, 52)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hosting.layoutSubtreeIfNeeded()

        print("Dumping subviews of TerminalPanelView with padding:")
        func printSubs(_ v: NSView, indent: String = "") {
            let windowFrame = v.window?.contentView != nil ? v.convert(v.bounds, to: nil) : v.frame
            print("\(indent)\(type(of: v)) isFlipped=\(v.isFlipped) frame=\(v.frame) inWindow=\(windowFrame)")
            for s in v.subviews {
                printSubs(s, indent: indent + "  ")
            }
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        printSubs(hosting)
    }

    @MainActor
    func testTerminalDragSelectionAutoScroll() {
        let session = TerminalSession(workingDirectory: "/tmp")
        let termView = TerminalNSView(session: session, theme: .vesper)
        termView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = termView
        termView.layout()

        // Feed 50 lines to populate scrollback
        for i in 1...50 {
            session.screen.putCharacter("L")
            session.screen.putCharacter(Character("\(i % 10)"))
            session.screen.lineFeed()
            session.screen.carriageReturn()
        }
        XCTAssertGreaterThan(session.screen.scrollback.count, 20, "Scrollback should have lines")

        // Mouse down inside the view (bottom-ish area)
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 30, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        termView.mouseDown(with: downEvent)

        // Mouse drag ABOVE the top of the view
        // In window coordinates, top is y=200, so y=260 is 60pt above the view
        let dragEventAbove = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 30, y: 260),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        termView.mouseDragged(with: dragEventAbove)

        // Allow timer to fire multiple times
        let exp = expectation(description: "Autoscroll timer ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        // Mouse up to finish drag
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 30, y: 260),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0.0
        )!
        termView.mouseUp(with: upEvent)
    }

    @MainActor
    func testSelectionSingleLineBackwardsCopy() {
        let session = TerminalSession(workingDirectory: "/tmp")
        let termView = TerminalNSView(session: session, theme: .vesper)
        termView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = termView
        termView.layout()

        // Feed a line of text: "HELLO_WORLD"
        for c in "HELLO_WORLD" {
            session.screen.putCharacter(c)
        }

        // Mouse down at column ~10 (around x = 80 in window coords: y = 200 - 10 = 190)
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 80, y: 190),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        termView.mouseDown(with: downEvent)

        // Mouse drag backwards to column ~0 (x = 10)
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 10, y: 190),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        termView.mouseDragged(with: dragEvent)

        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 10, y: 190),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0.0
        )!
        termView.mouseUp(with: upEvent)

        // Copy selection via Cmd+C keyDown
        let copyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!
        termView.keyDown(with: copyEvent)

        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertFalse(copied.isEmpty, "Backwards selection copy should not be empty")
        XCTAssertTrue(copied.contains("HELLO") || copied.contains("WORLD"), "Should copy text from backwards drag, got: \(copied)")
    }

    @MainActor
    func testReverseVideoAttributeAndDrawing() {
        let session = TerminalSession(workingDirectory: "/tmp")
        let parser = TerminalEscapeParser(screen: session.screen)
        // Feed reverse video sequence (like zsh bracketed paste: ESC[7m ... ESC[27m)
        let data = "\u{1b}[7mPASTED\u{1b}[27mNORMAL".data(using: .utf8)!
        parser.feed(data)

        XCTAssertTrue(session.screen.lines[0].cells[0].attributes.contains(.reverse), "P should have reverse attribute")
        XCTAssertTrue(session.screen.lines[0].cells[5].attributes.contains(.reverse), "D should have reverse attribute")
        XCTAssertFalse(session.screen.lines[0].cells[6].attributes.contains(.reverse), "N should not have reverse attribute")

        let termView = TerminalNSView(session: session, theme: .vesper)
        termView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        // Ensure draw() executes without issue with reverse video cells
        termView.draw(termView.bounds)
    }

    @MainActor
    func testRussianLayoutShortcuts() {
        let session = TerminalSession(workingDirectory: "/tmp")
        let termView = TerminalNSView(session: session, theme: .vesper)
        termView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = termView

        var receivedData = Data()
        session.onInputSent = { data in
            receivedData.append(data)
        }

        // Test 1: Cmd+V with Russian layout (keyCode 9 = 'v', but characters = "м")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("PASTED_FROM_RU", forType: .string)

        let cmdVEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "м",
            charactersIgnoringModifiers: "м",
            isARepeat: false,
            keyCode: 9 // physical 'v'
        )!
        termView.keyDown(with: cmdVEvent)

        let sentString = String(data: receivedData, encoding: .utf8) ?? ""
        XCTAssertTrue(sentString.contains("PASTED_FROM_RU"), "Cmd+V should paste under Russian layout, got: \(sentString)")

        // Test 2: Ctrl+C with Russian layout (keyCode 8 = 'c', characters = "с")
        receivedData.removeAll()
        let ctrlCEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "с",
            charactersIgnoringModifiers: "с",
            isARepeat: false,
            keyCode: 8 // physical 'c'
        )!
        termView.keyDown(with: ctrlCEvent)

        XCTAssertEqual(receivedData, Data([0x03]), "Ctrl+C under Russian layout should send SIGINT 0x03")

        // Test 3: Ctrl+D with Russian layout (keyCode 2 = 'd', characters = "в")
        receivedData.removeAll()
        let ctrlDEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "в",
            charactersIgnoringModifiers: "в",
            isARepeat: false,
            keyCode: 2 // physical 'd'
        )!
        termView.keyDown(with: ctrlDEvent)

        XCTAssertEqual(receivedData, Data([0x04]), "Ctrl+D under Russian layout should send EOF 0x04")
    }

    // MARK: - TerminalMultiBuffer & Command Block Tests

    func testTerminalMultiBufferBlockCreationAndANSIOutput() {
        let multiBuffer = TerminalMultiBuffer()
        XCTAssertEqual(multiBuffer.blocks.count, 0)

        let block = multiBuffer.createBlock(
            command: "cargo test",
            workingDirectory: "/tmp/project",
            gitBranch: "main"
        )
        XCTAssertEqual(block.command, "cargo test")
        XCTAssertEqual(block.status, .running)
        XCTAssertEqual(multiBuffer.blocks.count, 1)
        XCTAssertEqual(multiBuffer.activeBlockId, block.id)

        // Stream output with ANSI green and red colors
        let rawOutput = "Compiling project v0.1\n\u{1B}[32mtest passed\u{1B}[0m\n\u{1B}[31mtest failed\u{1B}[0m\n"
        multiBuffer.appendOutput(to: block.id, text: rawOutput)

        XCTAssertEqual(block.lines.count, 3)
        XCTAssertEqual(block.lines[0].rawText, "Compiling project v0.1")
        XCTAssertEqual(block.lines[1].rawText, "test passed")
        XCTAssertEqual(block.lines[1].spans.count, 1)
        XCTAssertEqual(block.lines[1].spans[0].fg, .standard(2)) // Green = standard(2)

        XCTAssertEqual(block.lines[2].rawText, "test failed")
        XCTAssertEqual(block.lines[2].spans[0].fg, .standard(1)) // Red = standard(1)

        // Complete block
        multiBuffer.completeBlock(id: block.id, exitCode: 0)
        XCTAssertEqual(block.status, .success)
        XCTAssertEqual(block.exitCode, 0)
        XCTAssertNotNil(block.endTime)
        XCTAssertNil(multiBuffer.activeBlockId)
    }

    func testTerminalMultiBufferCarriageReturnOverwrite() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "curl download", workingDirectory: "/tmp")

        // First progress update
        multiBuffer.appendOutput(to: block.id, text: "Downloading: [==   ] 20%\r")
        XCTAssertEqual(block.lines.count, 1)
        XCTAssertEqual(block.lines.last?.rawText, "Downloading: [==   ] 20%")

        // Second progress update with \r overwriting the line on-the-fly
        multiBuffer.appendOutput(to: block.id, text: "Downloading: [==== ] 80%\r")
        XCTAssertEqual(block.lines.count, 1, "Carriage return without newline should update line in place")
        XCTAssertEqual(block.lines.last?.rawText, "Downloading: [==== ] 80%")

        // Final completion with newline
        multiBuffer.appendOutput(to: block.id, text: "Downloading: [=====] 100%\nDone!\n")
        XCTAssertEqual(block.lines.count, 3)
        XCTAssertEqual(block.lines[1].rawText, "Downloading: [=====] 100%")
        XCTAssertEqual(block.lines[2].rawText, "Done!")
    }

    func testTerminalMultiBufferCollapseAndClear() {
        let multiBuffer = TerminalMultiBuffer()
        let b1 = multiBuffer.createBlock(command: "ls -la", workingDirectory: "/tmp")
        multiBuffer.appendOutput(to: b1.id, text: "file1\nfile2\n")
        multiBuffer.completeBlock(id: b1.id, exitCode: 0)

        XCTAssertFalse(b1.isCollapsed)
        multiBuffer.toggleCollapse(id: b1.id)
        XCTAssertTrue(b1.isCollapsed)
        multiBuffer.toggleCollapse(id: b1.id)
        XCTAssertFalse(b1.isCollapsed)

        multiBuffer.clear()
        XCTAssertEqual(multiBuffer.blocks.count, 0)
        XCTAssertNil(multiBuffer.activeBlockId)
    }

    @MainActor
    func testBlockTerminalSessionLsLah() {
        let session = BlockTerminalSession(workingDirectory: FileManager.default.currentDirectoryPath)
        let exp = expectation(description: "ls -lah completes")

        session.execute(command: "ls -lah")
        guard let block = session.multiBuffer.blocks.first else {
            XCTFail("No block created")
            return
        }

        func checkOutput(attempts: Int) {
            if block.lines.count > 5 || block.status != .running || attempts <= 0 {
                XCTAssertGreaterThan(block.lines.count, 5, "Expected more than 5 lines for ls -lah")
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkOutput(attempts: attempts - 1)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            checkOutput(attempts: 20)
        }

        wait(for: [exp], timeout: 5.0)
    }

    @MainActor
    func testBlockTerminalSessionNativeCd() {
        let initialDir = FileManager.default.currentDirectoryPath
        let session = BlockTerminalSession(workingDirectory: initialDir)
        let exp = expectation(description: "cd completes")

        session.execute(command: "cd /tmp")

        func checkCd(attempts: Int) {
            guard let block = session.multiBuffer.blocks.first else {
                XCTFail("No block created for cd")
                return
            }
            if block.status != .running || attempts <= 0 {
                XCTAssertTrue(
                    session.currentDirectory == "/private/tmp" || session.currentDirectory == "/tmp",
                    "Expected directory to change to /private/tmp or /tmp, got: \(session.currentDirectory)"
                )
                XCTAssertEqual(block.status, .success)
                XCTAssertEqual(block.exitCode, 0)
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkCd(attempts: attempts - 1)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            checkCd(attempts: 20)
        }

        wait(for: [exp], timeout: 5.0)
    }

    @MainActor
    func testBlockTerminalSessionEnvironmentPersistence() {
        let session = BlockTerminalSession(workingDirectory: FileManager.default.currentDirectoryPath)
        let exp = expectation(description: "export and echo complete")

        session.execute(command: "export TTEST=123")

        func checkEcho(attempts: Int) {
            guard attempts > 0 else {
                XCTFail("Timeout waiting for echo block")
                exp.fulfill()
                return
            }

            if session.multiBuffer.blocks.count >= 2 {
                let echoBlock = session.multiBuffer.blocks[1]
                if echoBlock.status != .running {
                    let fullText = echoBlock.lines.map(\.rawText).joined(separator: "\n")
                    XCTAssertTrue(fullText.contains("123"), "Expected echo block to contain 123, got: \(fullText)")
                    XCTAssertEqual(echoBlock.exitCode, 0)
                    exp.fulfill()
                    return
                }
            } else if session.multiBuffer.blocks.count == 1 {
                let exportBlock = session.multiBuffer.blocks[0]
                if exportBlock.status != .running && !session.isProcessRunning {
                    session.execute(command: "echo $TTEST")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                checkEcho(attempts: attempts - 1)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            checkEcho(attempts: 30)
        }

        wait(for: [exp], timeout: 5.0)
    }

    @MainActor
    func testBlockTerminalNSViewLayoutAndCollapse() {
        let multiBuffer = TerminalMultiBuffer()
        let block1 = multiBuffer.createBlock(command: "git status", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block1.id, text: "On branch main\nNothing to commit\n")
        multiBuffer.completeBlock(id: block1.id, exitCode: 0)

        let block2 = multiBuffer.createBlock(command: "ls -la", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block2.id, text: "file1.txt\nfile2.txt\nfile3.txt\n")
        multiBuffer.completeBlock(id: block2.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.rebuildLayout()

        XCTAssertEqual(canvas.blockLayouts.count, 2)
        let initialH = canvas.totalDocumentHeight
        XCTAssertGreaterThan(initialH, 100)

        // Collapse block 1
        multiBuffer.toggleCollapse(id: block1.id)
        canvas.rebuildLayout()

        XCTAssertTrue(canvas.blockLayouts[0].isCollapsed)
        XCTAssertLessThan(canvas.totalDocumentHeight, initialH)

        // Expand block 1 again
        multiBuffer.toggleCollapse(id: block1.id)
        canvas.rebuildLayout()
        XCTAssertFalse(canvas.blockLayouts[0].isCollapsed)
        XCTAssertEqual(canvas.totalDocumentHeight, initialH)
    }

    @MainActor
    func testBlockTerminalNSViewSelectionAndExtraction() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "echo hello", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block.id, text: "hello world\nsecond line\n")
        multiBuffer.completeBlock(id: block.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.rebuildLayout()

        // Select all
        canvas.selectAll(nil)
        XCTAssertTrue(canvas.hasSelection)
        guard let sel = canvas.normalizedSelection else {
            XCTFail("Expected normalized selection")
            return
        }
        XCTAssertEqual(sel.start.blockIndex, 0)
        XCTAssertEqual(sel.start.lineIndex, 0)
        XCTAssertEqual(sel.start.columnIndex, 0)
    }

    @MainActor
    func testBlockTerminalNSViewRenderingIntoBitmap() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "swift build", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block.id, text: "Building target AnyDiff...\nBuild complete!\n")
        multiBuffer.completeBlock(id: block.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.rebuildLayout()

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            XCTFail("Failed to allocate bitmapImageRep")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        XCTAssertEqual(rep.size.width, 600)
        XCTAssertEqual(rep.size.height, 400)
    }

    @MainActor
    func testBlockTerminalCommandHeaderSelectionAndCopy() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "git commit -m \"feat: terminal\"", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block.id, text: "[feat/terminal 123456] feat: terminal\n 1 file changed\n")
        multiBuffer.completeBlock(id: block.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.rebuildLayout()

        // 1. Select just the word "commit" in the command header (lineIndex: -1)
        canvas.selectionAnchor = TerminalDocumentPoint(blockIndex: 0, lineIndex: -1, columnIndex: 4)
        canvas.cursorPoint = TerminalDocumentPoint(blockIndex: 0, lineIndex: -1, columnIndex: 10)
        XCTAssertTrue(canvas.hasSelection)

        guard let sel = canvas.normalizedSelection else {
            XCTFail("Expected normalized selection")
            return
        }
        let extractedCmd = canvas.extractText(in: sel)
        XCTAssertEqual(extractedCmd, "commit")

        // 2. Perform copy
        canvas.copy(nil)
        let clipboard = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(clipboard, "commit")

        // 3. Select from command line into output
        canvas.selectionAnchor = TerminalDocumentPoint(blockIndex: 0, lineIndex: -1, columnIndex: 0)
        canvas.cursorPoint = TerminalDocumentPoint(blockIndex: 0, lineIndex: 0, columnIndex: 22)
        guard let multiSel = canvas.normalizedSelection else {
            XCTFail("Expected multi-line selection")
            return
        }
        let multiText = canvas.extractText(in: multiSel)
        XCTAssertTrue(multiText.contains("git commit -m \"feat: terminal\""))
        XCTAssertTrue(multiText.contains("[feat/terminal 123456]"))
    }

    @MainActor
    func testBlockTerminalDragClampingNeverFreezes() {
        let multiBuffer = TerminalMultiBuffer()
        let block1 = multiBuffer.createBlock(command: "echo first", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block1.id, text: "output 1\n")
        multiBuffer.completeBlock(id: block1.id, exitCode: 0)

        let block2 = multiBuffer.createBlock(command: "echo second", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block2.id, text: "output 2\n")
        multiBuffer.completeBlock(id: block2.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.rebuildLayout()

        // Drag above top (negative Y) clamps to start
        let topPoint = canvas.documentPoint(at: CGPoint(x: 50, y: -100), clampForDrag: true)
        XCTAssertNotNil(topPoint)
        XCTAssertEqual(topPoint?.blockIndex, 0)
        XCTAssertEqual(topPoint?.lineIndex, -1)
        XCTAssertEqual(topPoint?.columnIndex, 0)

        // Drag below bottom clamps to end of last block
        let bottomPoint = canvas.documentPoint(at: CGPoint(x: 50, y: 5000), clampForDrag: true)
        XCTAssertNotNil(bottomPoint)
        XCTAssertEqual(bottomPoint?.blockIndex, 1)

        // Drag into gap between blocks clamps to valid coordinate
        let b1ContentMaxY = canvas.blockLayouts[0].contentMaxY
        let gapPoint = canvas.documentPoint(at: CGPoint(x: 50, y: b1ContentMaxY + 2.0), clampForDrag: true)
        XCTAssertNotNil(gapPoint)
    }

    @MainActor
    func testBlockTerminalContextMenu() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "ls -la", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block.id, text: "total 0\n")
        multiBuffer.completeBlock(id: block.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.rebuildLayout()

        let dummyEvent = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 100, y: 350),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!

        let menu = canvas.menu(for: dummyEvent)
        XCTAssertNotNil(menu)
        let itemTitles = menu?.items.map(\.title) ?? []
        XCTAssertTrue(itemTitles.contains("Copy"))
        XCTAssertTrue(itemTitles.contains("Copy Command"))
        XCTAssertTrue(itemTitles.contains("Copy Output"))
        XCTAssertTrue(itemTitles.contains("Select All"))
        XCTAssertTrue(itemTitles.contains("Clear"))
    }

    @MainActor
    func testBlockTerminalHorizontalScrolling() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "echo long line", workingDirectory: "/Users/test")
        let longLine = String(repeating: "A", count: 200)
        multiBuffer.appendOutput(to: block.id, text: longLine + "\n")
        multiBuffer.completeBlock(id: block.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        canvas.rebuildLayout()

        // Verify totalDocumentWidth exceeds the 400 pt bounds width
        XCTAssertGreaterThan(canvas.totalDocumentWidth, 400.0)
        let maxScrollX = canvas.totalDocumentWidth - 400.0

        // Initially scrollOffsetX should be 0
        XCTAssertEqual(canvas.scrollOffsetX, 0.0)

        // Simulate horizontal scroll wheel
        if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -25, wheel3: 0),
           let nsEvent = NSEvent(cgEvent: cgEvent) {
            canvas.scrollWheel(with: nsEvent)
            XCTAssertGreaterThan(canvas.scrollOffsetX, 0.0)
        }

        // Set scrollOffsetX beyond maxScrollX and verify clamping via setFrameSize
        canvas.scrollOffsetX = maxScrollX + 100.0
        canvas.setFrameSize(NSSize(width: 400, height: 300))
        XCTAssertEqual(canvas.scrollOffsetX, maxScrollX, accuracy: 0.01)

        // Set negative scrollOffsetX and verify clamping
        canvas.scrollOffsetX = -50.0
        canvas.setFrameSize(NSSize(width: 400, height: 300))
        XCTAssertEqual(canvas.scrollOffsetX, 0.0)
    }

    @MainActor
    func testBlockTerminalScrollAxisLocking() {
        let multiBuffer = TerminalMultiBuffer()
        let block = multiBuffer.createBlock(command: "long command", workingDirectory: "/Users/test")
        let longText = (0..<50).map { "line \($0): " + String(repeating: "X", count: 120) }.joined(separator: "\n")
        multiBuffer.appendOutput(to: block.id, text: longText + "\n")
        multiBuffer.completeBlock(id: block.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        canvas.rebuildLayout()

        // 1. Dominant vertical scroll: wheel1 (Y) is -40, wheel2 (X) is -10
        if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -40, wheel2: -10, wheel3: 0),
           let nsEvent = NSEvent(cgEvent: cgEvent) {
            canvas.scrollWheel(with: nsEvent)
            // Vertical axis is locked: scrollOffsetY should increase, scrollOffsetX should remain 0
            XCTAssertGreaterThan(canvas.scrollOffsetY, 0.0)
            XCTAssertEqual(canvas.scrollOffsetX, 0.0)
        }

        // Reset offsets
        canvas.scrollOffsetY = 0
        canvas.scrollOffsetX = 0

        // 2. Dominant horizontal scroll: wheel1 (Y) is -5, wheel2 (X) is -40
        // Wait slightly or simulate fresh gesture so timeSinceLastEvent > 0.35
        Thread.sleep(forTimeInterval: 0.4)
        if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -5, wheel2: -40, wheel3: 0),
           let nsEvent = NSEvent(cgEvent: cgEvent) {
            canvas.scrollWheel(with: nsEvent)
            // Horizontal axis is locked: scrollOffsetX should increase, scrollOffsetY should remain 0
            XCTAssertGreaterThan(canvas.scrollOffsetX, 0.0)
            XCTAssertEqual(canvas.scrollOffsetY, 0.0)
        }
    }

    @MainActor
    func testBlockTerminalStickyHeaderFadeWhenPushed() {
        let multiBuffer = TerminalMultiBuffer()
        let block1 = multiBuffer.createBlock(command: "command 1", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block1.id, text: "output 1\noutput 2\noutput 3\noutput 4\noutput 5\n")
        multiBuffer.completeBlock(id: block1.id, exitCode: 0)

        let block2 = multiBuffer.createBlock(command: "command 2", workingDirectory: "/Users/test")
        multiBuffer.appendOutput(to: block2.id, text: "output line\n")
        multiBuffer.completeBlock(id: block2.id, exitCode: 0)

        let session = BlockTerminalSession(workingDirectory: "/Users/test", multiBuffer: multiBuffer)
        let canvas = BlockTerminalNSView(session: session, theme: .vesper, fontSize: 12)
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        canvas.rebuildLayout()

        // Scroll so block 2 pushes block 1's sticky header halfway
        let block2StartY = canvas.blockLayouts[1].startY
        canvas.scrollOffsetY = block2StartY - 10.0 // stickyScreenY = 10 - 28 = -18 < 0

        // Render into a bitmap context to exercise drawHeader with negative minY (contentAlpha fade)
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        XCTAssertEqual(rep.size.width, 400)
        XCTAssertEqual(rep.size.height, 300)
    }

    // MARK: - Multi-Terminal Coordinator & Background Execution Tests

    @MainActor
    func testTerminalCoordinatorTabManagement() {
        let coordinator = TerminalCoordinator(workingDirectory: "/tmp")
        XCTAssertEqual(coordinator.tabs.count, 1)
        XCTAssertEqual(coordinator.tabs[0].title, "Terminal 1")
        XCTAssertEqual(coordinator.activeTabId, coordinator.tabs[0].id)

        // Create second tab
        let tab2 = coordinator.createTab(workingDirectory: "/tmp", title: "Tab Two")
        XCTAssertEqual(coordinator.tabs.count, 2)
        XCTAssertEqual(coordinator.activeTabId, tab2.id)
        XCTAssertEqual(coordinator.activeTab?.id, tab2.id)
        XCTAssertEqual(tab2.title, "Tab Two")

        // Create third tab
        let tab3 = coordinator.createTab(workingDirectory: "/tmp")
        XCTAssertEqual(coordinator.tabs.count, 3)
        XCTAssertEqual(coordinator.tabs[2].title, "Terminal 3")
        XCTAssertEqual(coordinator.activeTabId, tab3.id)

        // Select first tab
        coordinator.selectTab(id: coordinator.tabs[0].id)
        XCTAssertEqual(coordinator.activeTabId, coordinator.tabs[0].id)

        // Select next / previous
        coordinator.selectNextTab()
        XCTAssertEqual(coordinator.activeTabId, tab2.id)
        coordinator.selectNextTab()
        XCTAssertEqual(coordinator.activeTabId, tab3.id)
        coordinator.selectPreviousTab()
        XCTAssertEqual(coordinator.activeTabId, tab2.id)

        // Close middle tab
        coordinator.closeTab(id: tab2.id)
        XCTAssertEqual(coordinator.tabs.count, 2)
        XCTAssertEqual(coordinator.activeTabId, tab3.id)

        // Close others
        coordinator.closeOtherTabs(except: tab3.id)
        XCTAssertEqual(coordinator.tabs.count, 1)
        XCTAssertEqual(coordinator.tabs[0].id, tab3.id)

        // Clean up
        coordinator.terminateAll()
        XCTAssertTrue(coordinator.tabs.isEmpty)
    }

    @MainActor
    func testTerminalTabDisplayTitleAndRename() {
        let tab = TerminalTab(title: "Terminal 1", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "tmp")

        tab.rename(to: "Dev Server")
        XCTAssertEqual(tab.displayTitle, "Dev Server")

        tab.rename(to: "")
        XCTAssertEqual(tab.displayTitle, "tmp")

        tab.terminate()
    }

    @MainActor
    func testMultipleTerminalsBackgroundExecution() {
        let coordinator = TerminalCoordinator(workingDirectory: "/tmp")
        let tab1 = coordinator.tabs[0]
        let tab2 = coordinator.createTab(workingDirectory: "/tmp")

        // Both tabs have active, distinct sessions
        XCTAssertNotEqual(tab1.id, tab2.id)
        XCTAssertNotEqual(tab1.blockSession.persistentSession.id, tab2.blockSession.persistentSession.id)

        // Tab 1 executes command
        tab1.blockSession.execute(command: "echo test-bg-1")
        // Tab 2 executes different command
        tab2.blockSession.execute(command: "echo test-bg-2")

        XCTAssertEqual(tab1.blockSession.multiBuffer.blocks.count, 1)
        XCTAssertEqual(tab2.blockSession.multiBuffer.blocks.count, 1)
        XCTAssertEqual(tab1.blockSession.multiBuffer.blocks[0].command, "echo test-bg-1")
        XCTAssertEqual(tab2.blockSession.multiBuffer.blocks[0].command, "echo test-bg-2")

        coordinator.terminateAll()
    }
}



