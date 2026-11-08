import Foundation

/// Handles shell integration scripts and parses OSC 9280 completion control sequences.
public final class TerminalShellIntegration: @unchecked Sendable {
    public static let shared = TerminalShellIntegration()

    /// In-memory zsh bootstrap script that hooks into zsh completion system via ZLE and compadd.
    public static let zshBootstrapScript: String = """
    function compadd() {
        if [[ -z "$COMPADD_OVERRIDE" ]]; then
            builtin compadd "$@"
            return
        fi
        typeset -a hits
        builtin compadd -A hits "$@"
        for h in $hits; do
            printf "\\e]9280;C;%s\\a" "$h"
        done
    }

    function __ad_completer() {
        (( ${+functions[_generic]} )) || return 0
        COLUMNS=500 _generic
    }

    zle -C __ad_widget list-choices __ad_completer
    zstyle ":completion:__ad_widget:*" list-grouped false
    zstyle ":completion:__ad_widget:*" insert-tab false
    zstyle ":completion:*" completer _complete

    function __ad_init() {
        if (( ! _AD_ARMED )); then return 0; fi
        _AD_ARMED=0
        BUFFER="$_AD_LINE"
        CURSOR=${#BUFFER}
        printf "\\e]9280;A\\a"
        COMPADD_OVERRIDE=1 zle __ad_widget
        printf "\\e]9280;B\\a"
        BUFFER=" "
        CURSOR=1
        zle accept-line
    }
    zle -N zle-line-init __ad_init

    function anydiff_complete() {
        (( $+functions[compdef] )) || { autoload -Uz compinit && compinit -D; }
        _AD_LINE="$1"
        _AD_ARMED=1
        { select _ in 1; do break; done } 2>/dev/null
    }
    """

    private let lock = NSLock()
    private var pendingItems: [String] = []
    private var isCapturing: Bool = false
    public var onCompletionsReceived: (([String]) -> Void)?

    public init() {}

    /// Filters OSC 9280 sequences out of terminal output text and collects completion items.
    /// Returns the cleaned text that can safely be displayed in terminal blocks.
    public func filterAndParse(output: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        // OSC 9280 pattern: \e]9280;<type>[;<data>]\a (or \x1b]9280;...\x07)
        guard output.contains("\u{1b}]9280;") else {
            return output
        }

        var cleaned = ""
        var idx = output.startIndex

        while idx < output.endIndex {
            if let oscRange = output[idx...].range(of: "\u{1b}]9280;") {
                cleaned.append(contentsOf: output[idx..<oscRange.lowerBound])
                let afterHeader = oscRange.upperBound

                // Look for terminator: BEL (\u{07}) or ST (\u{1b}\)
                var terminatorRange: Range<String.Index>? = nil
                if let bel = output[afterHeader...].firstIndex(of: "\u{07}") {
                    terminatorRange = bel..<output.index(after: bel)
                } else if let st = output[afterHeader...].range(of: "\u{1b}\\") {
                    terminatorRange = st
                }

                if let term = terminatorRange {
                    let payload = String(output[afterHeader..<term.lowerBound])
                    handlePayload(payload)
                    idx = term.upperBound
                } else {
                    // Incomplete sequence at end of chunk: stop processing
                    idx = output.endIndex
                    break
                }
            } else {
                cleaned.append(contentsOf: output[idx...])
                break
            }
        }

        return cleaned
    }

    private func handlePayload(_ payload: String) {
        if payload == "A" {
            // Start of completion stream
            isCapturing = true
            pendingItems.removeAll(keepingCapacity: true)
        } else if payload == "B" {
            // End of completion stream
            isCapturing = false
            let items = pendingItems
            pendingItems.removeAll(keepingCapacity: true)
            onCompletionsReceived?(items)
        } else if payload.hasPrefix("C;") {
            let item = String(payload.dropFirst(2))
            if !item.isEmpty && !pendingItems.contains(item) {
                pendingItems.append(item)
            }
        }
    }
}
