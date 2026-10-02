import Foundation

/// One line to standard error when WINDOW_DEBUG is set; silent otherwise.
public enum Debug {
    public static let enabled = ProcessInfo.processInfo.environment["WINDOW_DEBUG"] != nil

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
    }
}
