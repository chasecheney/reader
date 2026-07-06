import SwiftUI

/// Editor for the synced phrase → tag auto-tagging rules.
/// Reached from the sidebar ("Tag Library…"). Changes apply on Save and
/// sync to the other device through the iCloud container.
struct TagLibraryView: View {
    @EnvironmentObject var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var rules: [TagRule] = []
    @State private var newPhrase = ""
    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rules.isEmpty {
                        Text("No rules yet. Add one below — for example, phrase “marine” → tag “military”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($rules) { $rule in
                        HStack(spacing: 8) {
                            TextField("Word or phrase", text: $rule.phrase)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                            HStack(spacing: 2) {
                                Text("#").foregroundStyle(.secondary)
                                TextField("tag", text: $rule.tag)
                                    .textFieldStyle(.roundedBorder)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                            }
                            .frame(maxWidth: 160)
                            Button {
                                rules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this rule")
                        }
                    }
                    .onDelete { rules.remove(atOffsets: $0) }
                } header: {
                    Text("When story text contains…")
                } footer: {
                    Text("Matching is case-insensitive and whole-word (“war” won’t match “warm”). Several phrases may share one tag — e.g. army, marine, and air force can all assign #military. A phrase can exclude following words with “!”: “navy !blue|blazer|suit|tie” matches navy except in navy blue/blazer/suit/tie. Rules are used when you import files with “auto-tag” checked; matched tags become custom tags, files are never renamed.")
                }

                Section("Add Rule") {
                    HStack(spacing: 8) {
                        TextField("Word or phrase", text: $newPhrase)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addRule)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        HStack(spacing: 2) {
                            Text("#").foregroundStyle(.secondary)
                            TextField("tag", text: $newTag)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .onSubmit(addRule)
                        }
                        .frame(maxWidth: 160)
                        Button("Add", action: addRule)
                            .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty
                                      || TagLibrary.normalizeTag(newTag).isEmpty)
                    }
                }
            }
            .navigationTitle("Tag Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    Button("Restore Defaults") { restoreDefaults() }
                }
                #else
                ToolbarItem(placement: .secondaryAction) {
                    Button("Restore Defaults") { restoreDefaults() }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        addRule()   // catch a filled-in but un-added row
                        vm.setTagRules(rules)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { rules = vm.tagRules }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
    }

    /// Re-adds any default rule that's missing; keeps everything the user added.
    private func restoreDefaults() {
        let existing = Set(rules.map { "\($0.phrase.lowercased())→\($0.tag)" })
        for def in TagLibrary.defaultRules
        where !existing.contains("\(def.phrase.lowercased())→\(def.tag)") {
            rules.append(def)
        }
    }

    private func addRule() {
        let phrase = newPhrase.trimmingCharacters(in: .whitespaces)
        let tag = TagLibrary.normalizeTag(newTag)
        guard !phrase.isEmpty, !tag.isEmpty else { return }
        rules.append(TagRule(phrase: phrase, tag: tag))
        newPhrase = ""
        newTag = ""
    }
}
