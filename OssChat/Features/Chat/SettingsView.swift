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
                Section("Connection") {
                    TextField("Base URL", text: $store.settings.baseURLString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            store.refreshServerMetadata()
                        }

                    SecureField("API Key (optional)", text: $store.settings.apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button("Check Connection") {
                            store.refreshServerMetadata()
                        }

                        Button("Use Ollama Defaults") {
                            store.useOllamaDefaults()
                        }
                    }

                    connectionStatusView
                }

                Section("Models") {
                    TextField("Default model", text: $store.settings.defaultModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            store.selectModel(store.settings.defaultModel)
                        }

                    TextField("Current model", text: $store.settings.selectedModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            store.selectModel(store.settings.selectedModel)
                        }

                    if !store.availableModels.isEmpty {
                        Picker("Detected models", selection: $store.settings.selectedModel) {
                            ForEach(store.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    Picker("Default reasoning", selection: $store.settings.selectedReasoningEffort) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                }

                Section("Interface") {
                    Toggle("Auto-show thoughts when the server returns them", isOn: $store.settings.autoShowThoughts)
                }
            }
            .formStyle(.grouped)
            .padding(20)

            Divider()

            HStack {
                Text("Changes apply to the next response.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.refreshServerMetadata()
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch store.connectionState {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking local server…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case .connected(let models):
            Label(
                "Connected. Found \(models.count) model\(models.count == 1 ? "" : "s").",
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.green.opacity(0.85))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.9))
        }
    }
}
