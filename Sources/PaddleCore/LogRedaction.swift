import Foundation

/// Hides addresses in text that goes to a log: an exception's reason can quote a page's URL, a private window's
/// included. Every `scheme://rest` token is replaced, and so is `scheme:rest` for the schemes that carry data without
/// slashes (data, mailto, javascript, ...). Ordinary prose such as "key: value" is left alone.
public enum LogRedaction {
    public static let placeholder = "<url>"

    public static func redactURLs(_ text: String) -> String {
        text.replacing(
            #/(?i)(?:[a-z][a-z0-9+.\-]*://|(?:https?|data|mailto|javascript|file|blob|about|ftp|wss?|tel|sms|view-source|filesystem):)[^\s"']+/#,
            with: placeholder)
    }
}
