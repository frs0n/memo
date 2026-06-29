import SwiftUI
import UIKit

struct ScanDetailControls: View {
    let phase: ScanTrainingController.Phase
    let iteration: Int
    let totalIterations: Int
    let errorMessage: String?
    @Binding var mode: ScanTrainingMode
    let isDroneModeEnabled: Bool
    let isLeadingDroneControl: Bool
    @Binding var droneControlVector: CGSize
    let action: () -> Void

    var body: some View {
        if isLeadingDroneControl {
            content
                .padding(.horizontal, 16)
                .padding(.top, 140)
                .padding(.bottom, 16)
                .frame(width: 148)
                .frame(maxHeight: .infinity, alignment: .center)
        } else {
            content
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .idle:
                TrainingModeSelector(mode: $mode)
                TrainButton(action: action)
            case .training:
                TrainingProgressBar(iteration: iteration, totalIterations: totalIterations)
                Text("\(iteration) / \(totalIterations)")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Training iteration \(iteration) of \(totalIterations)")
            case .rendering:
                if isDroneModeEnabled {
                    DroneRemoteControl(vector: $droneControlVector)
                        .transition(.move(edge: isLeadingDroneControl ? .leading : .bottom).combined(with: .opacity))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage ?? "Training failed")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.red)
                    TrainingModeSelector(mode: $mode)
                    TrainButton(action: action)
                }
            }
        }
    }
}

private struct TrainingModeSelector: View {
    @Binding var mode: ScanTrainingMode

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ScanTrainingMode.allCases) { item in
                        modeButton(item)
                    }
                }
            }
        } else {
            Picker("Training Mode", selection: $mode) {
                ForEach(ScanTrainingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Training mode")
        }
    }

    @available(iOS 26.0, *)
    private func modeButton(_ item: ScanTrainingMode) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                mode = item
            }
        } label: {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .modifier(TrainingModeGlassStyle(isSelected: mode == item))
        .accessibilityAddTraits(mode == item ? .isSelected : [])
    }
}

@available(iOS 26.0, *)
private struct TrainingModeGlassStyle: ViewModifier {
    var isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .foregroundStyle(.primary)
                .glassEffect(.regular.tint(.primary.opacity(0.16)).interactive(), in: .capsule)
        } else {
            content
                .foregroundStyle(.secondary)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

private struct TrainingProgressBar: View {
    let iteration: Int
    let totalIterations: Int

    var body: some View {
        ProgressView(value: Double(iteration), total: Double(max(totalIterations, 1)))
            .progressViewStyle(.linear)
            .tint(.primary)
            .animation(.linear(duration: 0.12), value: iteration)
    }
}

private struct TrainButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button("Train", action: action)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityLabel("Train")
        } else {
            Button("Train", action: action)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityLabel("Train")
        }
    }
}

struct PreviewPlaceholder: View {
    let thumbnailURL: URL

    var body: some View {
        ZStack {
            Color(.systemBackground)

            if let image = UIImage(contentsOfFile: thumbnailURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct TrainingImagePreview: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Color(.systemBackground)

            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        }
    }
}
