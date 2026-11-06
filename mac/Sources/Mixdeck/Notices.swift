import Foundation
import os

/// System log for Mixdeck (spec/features/mixer.md, "Problems and notices").
let appLog = Logger(subsystem: "local.mixdeck.app", category: "app")

/// A dismissible problem banner. `key` identifies the problem, so reporting it again
/// replaces the banner instead of adding another, and the source can clear it.
struct Notice: Identifiable, Equatable {
    let id = UUID()
    let key: String
    let message: String
}

extension MixerModel {
    static let maxNotices = 4

    /// Shows a notice and writes it to the system log.
    func report(_ message: String, key: String? = nil) {
        let key = key ?? message
        // Unchanged repeats (e.g. a failing save every 0.5 s) are neither re-logged nor re-shown.
        if notices.contains(where: { $0.key == key && $0.message == message }) { return }
        appLog.error("\(key, privacy: .public): \(message, privacy: .public)")
        notices.removeAll { $0.key == key }
        notices.append(Notice(key: key, message: message))
        if notices.count > Self.maxNotices { notices.removeFirst(notices.count - Self.maxNotices) }
    }

    func clearNotice(_ key: String) {
        if notices.contains(where: { $0.key == key }) { notices.removeAll { $0.key == key } }
    }

    func dismissNotice(_ id: UUID) { notices.removeAll { $0.id == id } }

    /// Runs a user action that can fail and turns a failure into a notice.
    func attempt(_ what: String, key: String? = nil, _ body: () throws -> Void) {
        do { try body() } catch { report("\(what): \(describe(error))", key: key ?? what) }
    }
}

/// A readable one-line description of any error.
func describe(_ error: Error) -> String {
    switch error {
    case let e as DecodingError:
        let (ctx, what): (DecodingError.Context, String) = {
            switch e {
            case .typeMismatch(_, let c): return (c, "wrong type")
            case .valueNotFound(_, let c): return (c, "missing value")
            case .keyNotFound(let k, let c): return (c, "missing key '\(k.stringValue)'")
            case .dataCorrupted(let c): return (c, "invalid data")
            @unknown default: return (DecodingError.Context(codingPath: [], debugDescription: ""), "invalid data")
            }
        }()
        let path = ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        let detail = (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? ctx.debugDescription
        return [what, path.isEmpty ? nil : "at \(path.hasPrefix(".") ? String(path.dropFirst()) : path)", detail.isEmpty ? nil : "(\(detail))"]
            .compactMap { $0 }.joined(separator: " ")
    case let e as LocalizedError where e.errorDescription != nil:
        return e.errorDescription ?? error.localizedDescription
    // Our own error types describe themselves; Cocoa errors (real NSError objects) do not.
    case let e as CustomStringConvertible where !(type(of: error) is NSError.Type):
        return e.description
    default:
        return error.localizedDescription
    }
}
