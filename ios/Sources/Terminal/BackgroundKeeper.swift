import UIKit
import CoreLocation

/// iOS suspends an app shortly after it leaves the foreground, which freezes
/// every socket. Two levels:
///   - always: a background task, which buys roughly 30 seconds;
///   - opt-in: a coarse location session, during which iOS keeps the app
///     running and shows the location indicator. Locations are discarded.
@MainActor
final class BackgroundKeeper: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var locating = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    var locationAllowed: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func enteredBackground(hasSessions: Bool, keepAlive: Bool) {
        guard hasSessions else { return }
        if task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "ssh-sessions") { [weak self] in
                Task { @MainActor in self?.endTask() }
            }
        }
        if keepAlive && locationAllowed && !locating {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            locating = true
        }
    }

    func becameActive() {
        endTask()
        if locating {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            locating = false
        }
    }

    /// Called when the last session closes while in the background.
    func sessionsEnded() {
        becameActive()
    }

    private func endTask() {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Only the running location session matters; the fixes are dropped.
    }
}
