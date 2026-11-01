import Foundation

/// The fixed answer strings the review website recognises, spelled exactly
/// the way the answer file uses them.
public enum AnswerValues {
    public static let yes = "Yes"
    public static let no = "No"
    /// The universal "I can't tell" answer (straight apostrophe, exactly as
    /// PRD 4.4 specifies and as the server stores it).
    public static let dontKnow = "Don't know"
    /// PRD 4.4: a report that the question does not apply at this point.
    public static let wrongLocation = "WRONG LOCATION"
}
