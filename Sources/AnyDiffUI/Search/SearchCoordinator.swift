import Foundation
import Combine
import AnyDiffCore

@MainActor
public final class SearchCoordinator: ObservableObject {
    @Published public var isActive: Bool = false
    @Published public var query: ProjectSearchQuery = ProjectSearchQuery()
    @Published public var matches: [ProjectSearchMatch] = []
    @Published public var activeMatchIndex: Int? = nil
    @Published public var scrollRequest: SearchMatchScrollRequest? = nil
    @Published public var viewStateResetToken: UInt64 = 0
    @Published public var isSearching: Bool = false
    @Published public var isTruncated: Bool = false
    @Published public var hasExecutedSearch: Bool = false
    @Published public var focusToken: UInt64 = 0

    public let multiBuffer: MultiBuffer
    public let displayMap: DisplayMap

    private var searchTask: Task<Void, Never>? = nil
    private var debounceWorkItem: DispatchWorkItem? = nil
    private var scrollRequestId: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    public init(reviewManager: ReviewManager = ReviewManager()) {
        let mb = MultiBuffer()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: reviewManager)
        dm.layoutMode = .unified
        self.multiBuffer = mb
        self.displayMap = dm

        mb.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        dm.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public func toggle(in directory: String, selectedText: String? = nil) {
        if isActive {
            close()
        } else {
            open(in: directory, selectedText: selectedText)
        }
    }

    public func open(in directory: String, selectedText: String? = nil) {
        focusToken &+= 1
        let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            query.query = trimmed
            isActive = true
            triggerSearch(in: directory, delay: 0)
        } else {
            isActive = true
        }
    }

    public func close(clearResults: Bool = false) {
        isActive = false
        isSearching = false
        searchTask?.cancel()
        searchTask = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if clearResults {
            multiBuffer.clear()
            displayMap.rebuild()
            matches = []
            activeMatchIndex = nil
            scrollRequest = nil
            isTruncated = false
            hasExecutedSearch = false
            viewStateResetToken &+= 1
        }
    }

    public func reset() {
        close(clearResults: true)
        query = ProjectSearchQuery()
        hasExecutedSearch = false
    }

    public func selectNextMatch() {
        guard !matches.isEmpty else { return }
        let nextIndex: Int
        if let current = activeMatchIndex {
            nextIndex = (current + 1) % matches.count
        } else {
            nextIndex = 0
        }
        activeMatchIndex = nextIndex
        requestScrollToMatch(at: nextIndex)
    }

    public func selectPreviousMatch() {
        guard !matches.isEmpty else { return }
        let prevIndex: Int
        if let current = activeMatchIndex {
            prevIndex = (current - 1 + matches.count) % matches.count
        } else {
            prevIndex = matches.count - 1
        }
        activeMatchIndex = prevIndex
        requestScrollToMatch(at: prevIndex)
    }

    public func handleContentEdited() {
        let updatedMatches = ProjectSearchEngine.shared.recalculateMatches(
            query: query,
            in: multiBuffer
        )
        matches = updatedMatches
        if let activeIdx = activeMatchIndex {
            if activeIdx >= updatedMatches.count {
                activeMatchIndex = updatedMatches.isEmpty ? nil : (updatedMatches.count - 1)
            }
        } else if !updatedMatches.isEmpty {
            activeMatchIndex = 0
        }
    }

    public func triggerSearch(in directory: String, delay: Double = 0.15) {
        debounceWorkItem?.cancel()
        searchTask?.cancel()

        guard !query.isEmpty else {
            multiBuffer.clear()
            displayMap.rebuild()
            matches = []
            activeMatchIndex = nil
            scrollRequest = nil
            isSearching = false
            isTruncated = false
            hasExecutedSearch = false
            viewStateResetToken &+= 1
            return
        }

        multiBuffer.clear()
        displayMap.rebuild()
        matches = []
        activeMatchIndex = nil
        scrollRequest = nil
        isTruncated = false
        hasExecutedSearch = false
        viewStateResetToken &+= 1

        let currentQuery = query
        isSearching = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.searchTask = Task { @MainActor in
                guard !Task.isCancelled else { return }

                self.multiBuffer.baseDirectory = directory
                self.multiBuffer.setContentMode(.text)

                let backgroundTask = Task.detached(priority: .userInitiated) {
                    await ProjectSearchEngine.shared.searchStreaming(
                        query: currentQuery,
                        in: directory,
                        onBatch: { batch in
                            Task { @MainActor in
                                guard !Task.isCancelled else { return }

                                if !batch.newBuffers.isEmpty {
                                    for buf in batch.newBuffers {
                                        self.multiBuffer.addBuffer(buf)
                                    }
                                    for excerpt in batch.newExcerpts {
                                        self.multiBuffer.addExcerpt(excerpt)
                                    }
                                    self.matches.append(contentsOf: batch.newMatches)
                                    self.displayMap.rebuild()

                                    if self.activeMatchIndex == nil && !self.matches.isEmpty {
                                        self.activeMatchIndex = 0
                                        self.requestScrollToMatch(at: 0)
                                    }
                                }

                                if batch.isTruncated {
                                    self.isTruncated = true
                                }

                                if batch.isFinished {
                                    self.isSearching = false
                                    self.hasExecutedSearch = true
                                }
                            }
                        },
                        isCancelled: {
                            Task.isCancelled
                        }
                    )
                }

                _ = await withTaskCancellationHandler {
                    if Task.isCancelled {
                        backgroundTask.cancel()
                    }
                    return await backgroundTask.value
                } onCancel: {
                    backgroundTask.cancel()
                }
            }
        }

        debounceWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    @discardableResult
    public func applyWatchedFile(path: String, fullDiskPath: String) -> Bool {
        guard hasExecutedSearch, !query.isEmpty else { return false }
        guard !multiBuffer.isFileDirty(filePath: path) else { return false }

        let wasInSearch = multiBuffer.excerpts.contains { $0.filePath == path }
        let (newBuffers, newExcerpts) = ProjectSearchEngine.shared.rescanFile(
            filePath: path,
            fullDiskPath: fullDiskPath,
            query: query
        )

        if !wasInSearch && newBuffers.isEmpty {
            return false
        }

        multiBuffer.replaceFile(
            filePath: path,
            buffers: newBuffers,
            excerpts: newExcerpts
        )
        return true
    }

    public func recalculateAfterWatch(invalidatedPaths: Set<String>) {
        guard !invalidatedPaths.isEmpty else { return }
        let updatedMatches = ProjectSearchEngine.shared.recalculateMatches(
            query: query,
            in: multiBuffer
        )
        matches = updatedMatches
        if let activeIdx = activeMatchIndex {
            if updatedMatches.isEmpty {
                activeMatchIndex = nil
            } else if activeIdx >= updatedMatches.count {
                activeMatchIndex = updatedMatches.count - 1
            }
        }
        displayMap.rebuild(invalidatingPaths: invalidatedPaths)
    }

    private func requestScrollToMatch(at index: Int) {
        scrollRequestId &+= 1
        scrollRequest = SearchMatchScrollRequest(id: scrollRequestId, matchIndex: index)
    }
}
