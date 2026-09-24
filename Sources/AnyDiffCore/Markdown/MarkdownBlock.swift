import Foundation

public enum MarkdownBlock: Identifiable, Equatable, Sendable {
    case header(level: Int, text: String)
    case bulletItem(String)
    case numberedItem(number: String, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case quote(String)
    case table(headers: [String], rows: [[String]])
    case divider
    case image(alt: String, path: String)

    public var id: String {
        switch self {
        case .header(let level, let text):
            return "h_\(level)_\(text.hashValue)"
        case .bulletItem(let text):
            return "b_\(text.hashValue)"
        case .numberedItem(let number, let text):
            return "n_\(number)_\(text.hashValue)"
        case .paragraph(let text):
            return "p_\(text.hashValue)"
        case .codeBlock(let lang, let code):
            return "c_\(lang ?? "")_\(code.hashValue)"
        case .quote(let text):
            return "q_\(text.hashValue)"
        case .table(let headers, let rows):
            return "t_\(headers.joined())_\(rows.count)"
        case .divider:
            return "d"
        case .image(let alt, let path):
            return "img_\(alt)_\(path.hashValue)"
        }
    }
}
