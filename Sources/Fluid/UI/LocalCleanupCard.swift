import SwiftUI

/// Settings card for LaVoix's on-device cleanup model: turn it on, pick a model, watch the download, try it.
struct LocalCleanupCard: View {
    let theme: AppTheme

    @ObservedObject private var controller = LocalCleanupController.shared
    @State private var testText = "um so like i wanna uh send the the report to john on friday you know"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-device AI cleanup")
                        .font(.fluidSystem(size: 17, weight: .semibold))
                    Text("Removes filler words, fixes punctuation and resolves self-corrections, all on this Mac. Nothing is sent anywhere.")
                        .font(.fluidSystem(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { self.controller.isEnabled },
                    set: { self.controller.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Picker("Model", selection: Binding(
                get: { self.controller.modelID },
                set: { self.controller.selectModel($0) }
            )) {
                ForEach(LocalCleanupProvider.models) { model in
                    Text("\(model.displayName) · \(Self.sizeText(model.approximateBytes))").tag(model.id)
                }
            }
            .pickerStyle(.segmented)
            .disabled(self.controller.isBusy)

            Text(self.controller.selectedModel.detail)
                .font(.fluidSystem(size: 12))
                .foregroundStyle(.secondary)

            self.statusRow

            if self.controller.status == .ready {
                self.testArea
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(self.theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
        )
        .onAppear { self.controller.refreshStatus() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch self.controller.status {
        case .notDownloaded:
            HStack {
                Label("Not downloaded", systemImage: "arrow.down.circle")
                    .font(.fluidSystem(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download \(Self.sizeText(self.controller.selectedModel.approximateBytes))") {
                    self.controller.setEnabled(true)
                }
            }
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction)
                    Text("Downloading \(Int(fraction * 100))%. One-time download from Hugging Face.")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting download…")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading model…")
                    .font(.fluidSystem(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label(
                self.controller.isEnabled ? "On. Cleanup runs on your Mac." : "Downloaded. Turn it on to use it.",
                systemImage: self.controller.isEnabled ? "checkmark.circle.fill" : "checkmark.circle"
            )
            .font(.fluidSystem(size: 13))
            .foregroundStyle(self.controller.isEnabled ? Color.green : Color.secondary)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't load the model", systemImage: "exclamationmark.triangle")
                    .font(.fluidSystem(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.fluidSystem(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button("Try again") { self.controller.prepare() }
            }
        }
    }

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Try it")
                .font(.fluidSystem(size: 13, weight: .semibold))
            TextField("Type something messy…", text: self.$testText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 4)
            HStack {
                Button(self.controller.isTesting ? "Cleaning…" : "Clean it up") {
                    self.controller.runTest(self.testText)
                }
                .disabled(self.controller.isTesting || self.testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let seconds = self.controller.testSeconds {
                    Text(String(format: "%.1fs", seconds))
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let output = self.controller.testOutput {
                Text(output)
                    .font(.fluidSystem(size: 14))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
