import SwiftUI
import TubeCore

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
                Text("Run snippets from the key panel during a session. Put {{name}} where you want to fill something in each time.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Snippet(name: "", command: "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add Snippet")
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
                    Text("You’ll be asked for: " + snippet.variables.joined(separator: ", "))
                }
            }
            Toggle("Press Return After Inserting", isOn: $snippet.runImmediately)
        }
        .navigationTitle(snippet.name.isEmpty ? "New Snippet" : snippet.name)
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
