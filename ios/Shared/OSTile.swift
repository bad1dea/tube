import SwiftUI

/// Coloured tile per OS family, the way people recognise their boxes at a glance.
struct OSTile: View {
    let osID: String?
    var size: CGFloat = 36

    private var style: (Color, String?, String) {
        switch osID ?? "" {
        case "fedora": return (Color(red: 0.24, green: 0.43, blue: 0.71), nil, "f")
        case "ubuntu": return (Color(red: 0.91, green: 0.33, blue: 0.13), nil, "u")
        case "debian": return (Color(red: 0.66, green: 0.0, blue: 0.19), nil, "d")
        case "raspbian": return (Color(red: 0.77, green: 0.10, blue: 0.29), nil, "π")
        case "arch", "archarm", "manjaro", "endeavouros": return (Color(red: 0.09, green: 0.58, blue: 0.82), nil, "a")
        case "alpine": return (Color(red: 0.05, green: 0.35, blue: 0.50), nil, "α")
        case "centos", "rhel", "almalinux": return (Color(red: 0.80, green: 0.0, blue: 0.0), nil, "r")
        case "rocky": return (Color(red: 0.06, green: 0.73, blue: 0.51), nil, "r")
        case "opensuse-leap", "opensuse-tumbleweed", "sles": return (Color(red: 0.45, green: 0.73, blue: 0.15), nil, "s")
        case "nixos": return (Color(red: 0.32, green: 0.47, blue: 0.76), nil, "❄")
        case "freebsd": return (Color(red: 0.67, green: 0.17, blue: 0.16), nil, "b")
        case "darwin": return (Color(white: 0.25), "apple.logo", "")
        case "": return (Color(white: 0.30), "server.rack", "")
        default: return (Color(white: 0.30), nil, String(osID!.prefix(1)))
        }
    }

    var body: some View {
        let (color, symbol, letter) = style
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(letter).font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}
