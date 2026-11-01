import Foundation
import SwiftData

/// Lifecycle of an answer the app submitted but has not confirmed yet.
public enum OutboxState: String, Codable, Sendable {
    case pending
    /// The server rejected it (400, e.g. unknown id). Never retried; shown in
    /// Settings until the user deletes it (PRD 4.1).
    case rejected
}

/// An answer waiting to be POSTed. Re-answers to the same question create a
/// new item; the oldest first is what the sync posts in order.
@Model
public final class OutboxItem {
    @Attribute(.unique) public var uuid: String
    public var questionID: String
    public var answer: String
    public var comment: String?
    public var createdAt: Date
    public var stateRaw: String
    public var rejectReason: String?

    public var state: OutboxState {
        get { OutboxState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    public init(questionID: String, answer: String, comment: String?, createdAt: Date = .now) {
        uuid = UUID().uuidString
        self.questionID = questionID
        self.answer = answer
        self.comment = comment
        self.createdAt = createdAt
        stateRaw = OutboxState.pending.rawValue
    }
}
