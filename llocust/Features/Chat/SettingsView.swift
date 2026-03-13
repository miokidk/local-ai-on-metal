import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                Section("Generation") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Repeat Penalty")
                            Spacer()
                            Text(store.settings.repeatPenalty.formatted(.number.precision(.fractionLength(1))))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $store.settings.repeatPenalty,
                            in: 0...2,
                            step: 0.1
                        )

                        Text("Higher values discourage the model from repeating the same tokens and phrases.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("System Instructions") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Set a default instruction that will be sent with every new response.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $store.settings.systemInstructions)
                            .font(.system(size: 13))
                            .frame(minHeight: 120)

                        HStack {
                            Spacer()
                            Button("Clear") {
                                store.settings.systemInstructions = ""
                            }
                            .disabled(store.settings.trimmedSystemInstructions == nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
