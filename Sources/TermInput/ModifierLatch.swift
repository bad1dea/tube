import Foundation

/// State of an on-screen CTRL or ALT key.
///
/// tap: off -> armed; armed -> locked if within the double-tap window, else off;
/// locked -> off. Long press always locks. An armed latch releases after one key.
public struct ModifierLatch: Equatable, Sendable {
    public enum State: Equatable, Sendable { case off, armed, locked }

    public private(set) var state: State = .off
    private var armedAt: TimeInterval = -.infinity
    public var doubleTapWindow: TimeInterval

    public init(doubleTapWindow: TimeInterval = 0.35) {
        self.doubleTapWindow = doubleTapWindow
    }

    public var isActive: Bool { state != .off }

    public mutating func tap(at now: TimeInterval) {
        switch state {
        case .off:
            state = .armed
            armedAt = now
        case .armed:
            state = now - armedAt <= doubleTapWindow ? .locked : .off
        case .locked:
            state = .off
        }
    }

    public mutating func longPress() {
        state = .locked
    }

    /// Called after a key was sent with this modifier applied.
    public mutating func consume() {
        if state == .armed { state = .off }
    }

    public mutating func reset() {
        state = .off
    }
}

/// The CTRL/ALT pair shown on the key bar.
public struct ModifierBar: Equatable, Sendable {
    public var ctrl = ModifierLatch()
    public var alt = ModifierLatch()

    public init() {}

    public var active: KeyModifiers {
        var m: KeyModifiers = []
        if ctrl.isActive { m.insert(.ctrl) }
        if alt.isActive { m.insert(.alt) }
        return m
    }

    /// Encodes a key with the latched modifiers plus any `extra` ones, then
    /// releases armed (non-locked) latches.
    public mutating func send(_ key: TerminalKey, extra: KeyModifiers = [], modes: TerminalModes) -> [UInt8] {
        let bytes = KeyEncoder.encode(key, modifiers: active.union(extra), modes: modes)
        ctrl.consume()
        alt.consume()
        return bytes
    }

    public mutating func send(text: String, modes: TerminalModes) -> [UInt8] {
        let bytes = KeyEncoder.encode(text: text, modifiers: active, modes: modes)
        ctrl.consume()
        alt.consume()
        return bytes
    }
}
