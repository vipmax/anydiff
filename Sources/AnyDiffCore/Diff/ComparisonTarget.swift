import Foundation

/// Represents the comparison target for Git diff generation
public enum ComparisonTarget: Equatable, Hashable, Sendable {
    /// Uncommitted staged + unstaged changes in working copy vs HEAD
    case workingTree
    /// Compare current branch against base branch (e.g. "main...HEAD" / PR view)
    case baseBranch(String)
    /// Direct diff against a specific branch or ref (e.g. "git diff <branch>")
    case directBranch(String)
    /// Remote GitHub PR / commit / compare diff
    case remote(GitHubDiffReference)

    public var title: String {
        switch self {
        case .workingTree:
            return "Uncommitted Changes"
        case .baseBranch(let branch):
            return "vs \(branch) (Base)"
        case .directBranch(let branch):
            return "vs \(branch)"
        case .remote(let ref):
            return ref.displayTitle
        }
    }

    public var shortDescription: String {
        switch self {
        case .workingTree:
            return "Working Tree"
        case .baseBranch(let branch):
            return "\(branch)..."
        case .directBranch(let branch):
            return "→ \(branch)"
        case .remote(let ref):
            return ref.displayTitle
        }
    }
}
