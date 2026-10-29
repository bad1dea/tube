import Foundation
import Citadel
import NIOCore
import NIOPosix

/// What to show a user for a connect or session failure. NIO and Citadel
/// errors print as type dumps ("connectTimeout(TimeAmount(...))").
public enum SSHErrorText {
    public static func describe(_ error: Error, target: String) -> String {
        switch error {
        case let e as SSHConnectError:
            switch e {
            case .authenticationFailed(let h, let p, let u):
                return "\(u)@\(h):\(p) didn’t accept the password or key."
            case .hostKeyRejected(let h, _):
                return "You didn’t trust \(h)’s host key, so Tube didn’t connect."
            case .hostKeyChanged(let h, let p, _, _):
                return "The host key for \(h):\(p) has changed since you last connected. This happens after a server is reinstalled, but it can also mean someone is intercepting the connection."
            case .unsupportedKey(let t):
                return "This key can’t be used (\(t))."
            case .badPassphrase:
                return "Wrong passphrase for the key."
            case .needsPassphrase:
                return "Couldn’t read the key. If it has a passphrase, enter it."
            }
        case let e as NIOConnectionError:
            if e.connectionErrors.isEmpty, e.dnsAError != nil || e.dnsAAAAError != nil {
                return "Couldn’t find \(e.host). Check the host name."
            }
            if let first = e.connectionErrors.first?.error {
                return describe(first, target: "\(e.host):\(e.port)")
            }
            return "Couldn’t connect to \(e.host):\(e.port)."
        case let e as IOError:
            switch e.errnoCode {
            case ECONNREFUSED: return "\(target) refused the connection. Check the port and that SSH is running."
            case ENETUNREACH, EHOSTUNREACH: return "Can’t reach \(target). Check your network or VPN."
            case ETIMEDOUT: return "Timed out connecting to \(target)."
            case EADDRINUSE: return "That port is already in use on this device."
            case ECONNRESET: return "\(target) closed the connection."
            default: return "Couldn’t connect to \(target): \(String(cString: strerror(e.errnoCode)))."
            }
        case let e as ChannelError:
            switch e {
            case .connectTimeout: return "Timed out connecting to \(target)."
            case .alreadyClosed, .ioOnClosedChannel, .eof, .outputClosed, .inputClosed:
                return "The connection to \(target) was closed."
            default: return "Connection to \(target) failed (\(e))."
            }
        case let e as SSHClient.CommandFailed:
            return "The command exited with status \(e.exitCode)."
        case let e as CustomStringConvertible:
            return e.description
        default:
            return error.localizedDescription
        }
    }
}
