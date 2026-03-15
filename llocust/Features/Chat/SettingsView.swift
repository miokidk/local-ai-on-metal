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
                            Text("Base Temperature")
                            Spacer()
                            Text(store.settings.baseTemperature.formatted(.number.precision(.fractionLength(2))))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $store.settings.baseTemperature,
                            in: 0.7...1.1,
                            step: 0.01
                        )

                        Text("Higher values let the model explore more varied wording and ideas. Lower values keep answers steadier and more deterministic.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

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

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Base Top P")
                            Spacer()
                            Text(store.settings.topP.formatted(.number.precision(.fractionLength(2))))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $store.settings.topP,
                            in: 0.85...1,
                            step: 0.01
                        )

                        Text("Starts here and eases down only during unusually long reasoning traces to reduce spirals without cutting reasoning off.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Context Memory") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto-compress older turns", isOn: $store.settings.usesConversationMemory)

                        Text("When the live context gets too large, llocust asks the model to fold older turns into a rolling memory, then retries the reply with a fresh context window while keeping the newest messages verbatim.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Keep Recent Messages")
                            Spacer()
                            Stepper(
                                value: $store.settings.recentContextMessageCount,
                                in: 4...20,
                                step: 2
                            ) {
                                Text("\(store.settings.recentContextMessageCount)")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 28, alignment: .trailing)
                            }
                            .labelsHidden()
                        }
                        .disabled(!store.settings.usesConversationMemory)

                        Text("Higher values keep more of the latest transcript verbatim. Lower values make room for longer-running conversations.")
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
