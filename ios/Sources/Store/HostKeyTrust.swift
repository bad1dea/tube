import Foundation
import TubeCore
import TubeSSH

struct HostKeyQuestion: Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let algorithm: String
    let fingerprint: String
}

/// Locked copy of the known hosts. Host key checks run on NIO's event loop and
/// need a synchronous answer.
final class KnownHostsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: KnownHosts

    init(_ value: KnownHosts) { self.value = value }

    func read<T>(_ body: (KnownHosts) -> T) -> T { lock.withLock { body(value) } }
    func update(_ body: (inout KnownHosts) -> Void) -> KnownHosts {
        lock.withLock {
            body(&value)
            return value
        }
    }
}

@MainActor
final class HostKeyTrust: ObservableObject, HostKeyTrustStore {
    @Published var question: HostKeyQuestion?
    private var answer: CheckedContinuation<Bool, Never>?
    nonisolated private let box: KnownHostsBox
    private weak var store: AppStore?

    init(store: AppStore) {
        self.store = store
        box = KnownHostsBox(store.data.knownHosts)
    }

    /// Call after the known hosts list is edited in the UI.
    func reload() {
        guard let kh = store?.data.knownHosts else { return }
        _ = box.update { $0 = kh }
    }

    nonisolated func check(host: String, port: Int, algorithm: String, keyBase64: String) -> HostKeyCheck {
        box.read { $0.check(host: host, port: port, algorithm: algorithm, keyBase64: keyBase64) }
    }

    nonisolated func confirmUnknown(host: String, port: Int, algorithm: String, keyBase64: String, fingerprint: String) async -> Bool {
        let q = HostKeyQuestion(host: host, port: port, algorithm: algorithm, fingerprint: fingerprint)
        guard await ask(q) else { return false }
        let updated = box.update { $0.trust(host: host, port: port, algorithm: algorithm, keyBase64: keyBase64) }
        await save(updated)
        return true
    }

    private func save(_ kh: KnownHosts) {
        store?.data.knownHosts = kh
    }

    private func ask(_ q: HostKeyQuestion) async -> Bool {
        // One question at a time; a second connection waits for the first answer.
        while answer != nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await withCheckedContinuation { cont in
            answer = cont
            question = q
        }
    }

    func respond(_ accepted: Bool) {
        question = nil
        let cont = answer
        answer = nil
        cont?.resume(returning: accepted)
    }
}
