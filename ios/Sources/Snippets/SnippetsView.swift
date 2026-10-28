import SwiftUI
import ConchCore

struct SnippetsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Snippet?

    var body: some View {
        List {
            ForEach(store.data.snippets) { s in
                Button { editing = s } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { store.data.snippets.remove(atOffsets: $0) }
            .onMove { store.data.snippets.move(fromOffsets: $0, toOffset: $1) }
            if store.data.snippets.isEmpty {
                Text("Snippets run from the terminal key panel. Use {{name}} for values asked at run time.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Snippet(name: "", command: "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add snippet")
            }
        }
        .sheet(item: $editing) { s in
            NavigationStack { SnippetEditView(snippet: s) }
        }
    }
}

struct SnippetEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet

    var body: some View {
        Form {
            TextField("Name", text: $snippet.name)
            Section {
                TextField("Command", text: $snippet.command, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...10)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if !snippet.variables.isEmpty {
                    Text("Asks for: " + snippet.variables.joined(separator: ", "))
                }
            }
            Toggle("Press return after inserting", isOn: $snippet.runImmediately)
        }
        .navigationTitle(snippet.name.isEmpty ? "New snippet" : snippet.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    snippet.updatedAt = Date()
                    if let i = store.data.snippets.firstIndex(where: { $0.id == snippet.id }) {
                        store.data.snippets[i] = snippet
                    } else {
                        store.data.snippets.append(snippet)
                    }
                    dismiss()
                }
                .disabled(snippet.name.isEmpty || snippet.command.isEmpty)
            }
        }
    }
}
