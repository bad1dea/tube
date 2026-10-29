import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TubeWidgets: WidgetBundle {
    var body: some Widget {
        SessionsLiveActivity()
    }
}

struct SessionsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionsActivityAttributes.self) { context in
            LockScreenSessions(state: context.state)
                .widgetURL(URL(string: "tube://sessions"))
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Tube", systemImage: "terminal").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(countText(context.state)).font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionList(state: context.state, limit: 3)
                }
            } compactLeading: {
                Image(systemName: "terminal")
            } compactTrailing: {
                Text("\(context.state.sessions.count)").monospacedDigit()
            } minimal: {
                Image(systemName: "terminal")
            }
            .widgetURL(URL(string: "tube://sessions"))
        }
    }
}

func countText(_ s: SessionsActivityAttributes.ContentState) -> String {
    let n = s.sessions.count
    return n == 1 ? "1 session" : "\(n) sessions"
}

struct LockScreenSessions: View {
    let state: SessionsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.subheadline.weight(.semibold))
                Text(countText(state)).font(.subheadline.weight(.semibold))
                Spacer()
                Text("Tube").font(.caption).foregroundStyle(.secondary)
            }
            SessionList(state: state, limit: 4)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

struct SessionList: View {
    let state: SessionsActivityAttributes.ContentState
    let limit: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(state.sessions.prefix(limit).enumerated()), id: \.offset) { _, s in
                HStack(spacing: 6) {
                    OSTile(osID: s.osID, size: 24)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(s.connected ? Color.green : Color.orange).frame(width: 7, height: 7).offset(x: 2, y: 2)
                        }
                    Text(s.title).font(.caption).lineLimit(1)
                }
            }
            if state.sessions.count > limit {
                Text("+\(state.sessions.count - limit)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
