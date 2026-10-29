import ActivityKit
import Foundation

/// Live Activity shown on the lock screen and in the Dynamic Island while
/// sessions are open. Shared by the app and the TubeWidgets extension.
struct SessionsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct Session: Codable, Hashable {
            var title: String
            var osID: String?
            var connected: Bool
        }
        var sessions: [Session]
    }
}
