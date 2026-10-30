import SwiftUI

struct AboutView: View {
    private let repo = URL(string: "https://github.com/bad1dea/tube")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Tube SSH").font(.title2.bold())
                    Text("Version \(version)").font(.footnote).foregroundStyle(.secondary)
                    Text("Made by khuong").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                Text("A free, open source SSH client. No accounts, no tracking. Your hosts, keys and passwords stay on your devices, and sync only goes to a server you run.")
            }
            Section {
                Link(destination: repo) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: repo.appending(path: "issues/new")) { Label("Report a Problem", systemImage: "ladybug") }
                Link(destination: repo.appending(path: "blob/main/docs/privacy.md")) { Label("Privacy Policy", systemImage: "hand.raised") }
                Link(destination: repo.appending(path: "blob/main/LICENSE")) { Label("License (MIT)", systemImage: "doc.text") }
            }
            Section("Built With") {
                credit("SwiftTerm", "Miguel de Icaza", "https://github.com/migueldeicaza/SwiftTerm")
                credit("Citadel", "Orlandos", "https://github.com/orlandos-nl/Citadel")
                credit("SwiftNIO SSH", "Apple", "https://github.com/apple/swift-nio-ssh")
                credit("Swift Crypto", "Apple", "https://github.com/apple/swift-crypto")
                credit("Color schemes", "iTerm2-Color-Schemes", "https://github.com/mbadolato/iTerm2-Color-Schemes")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ name: String, _ author: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            LabeledContent(name, value: author)
        }
        .foregroundStyle(.primary)
    }
}
