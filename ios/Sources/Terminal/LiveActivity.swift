import ActivityKit
import Foundation

/// Keeps one Live Activity in step with the open sessions: started with the
/// first, updated on changes, ended with the last.
@MainActor
final class SessionsLiveActivity {
    private var activity: Activity<SessionsActivityAttributes>?
    private var last: SessionsActivityAttributes.ContentState?

    func update(_ sessions: [SessionsActivityAttributes.ContentState.Session]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if sessions.isEmpty {
            end()
            return
        }
        let state = SessionsActivityAttributes.ContentState(sessions: sessions)
        guard state != last else { return }
        last = state
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
        } else {
            activity = try? Activity.request(attributes: SessionsActivityAttributes(), content: content, pushType: nil)
        }
    }

    func end() {
        last = nil
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
