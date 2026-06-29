import SwiftUI
import UIKit

struct ScanDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let scan: MemoScanRecord
    @ObservedObject var store: MemoScanStore

    @StateObject private var trainer: ScanTrainingController
    @State private var shareSheet: SharedFileSheetItem?
    @State private var shareError: String?
    @State private var isShowingCapturedImages = false
    @State private var isDroneModeEnabled = false
    @State private var droneControlVector = CGSize.zero

    init(scan: MemoScanRecord, store: MemoScanStore) {
        self.scan = scan
        self.store = store
        _trainer = StateObject(wrappedValue: ScanTrainingController(scan: scan, store: store))
    }

    var body: some View {
        GeometryReader { proxy in
            previewLayout(
                usesLeadingDroneControl: proxy.size.width > proxy.size.height &&
                    trainer.phase.isRendering &&
                    isDroneModeEnabled
            )
        }
        .navigationTitle(trainer.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .accessibilityLabel("Back")
            }

            if trainer.phase.isRendering {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isDroneModeEnabled.toggle()
                            if !isDroneModeEnabled {
                                droneControlVector = .zero
                            }
                        }
                    } label: {
                        Image(systemName: isDroneModeEnabled ? "l.joystick.fill" : "l.joystick")
                    }
                    .accessibilityLabel(isDroneModeEnabled ? "Exit drone mode" : "Enter drone mode")
                    .accessibilityAddTraits(isDroneModeEnabled ? .isSelected : [])
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareGaussianSplat()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share splat")
                }
            }

            if !scan.capturedImageURLs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingCapturedImages = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel("View selected images")
                }
            }
        }
        .sheet(isPresented: $isShowingCapturedImages) {
            CapturedImagesGalleryView(scan: scan)
        }
        .sheet(item: $shareSheet) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .alert("Unable to Share", isPresented: shareErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "The exported splat file is unavailable.")
        }
        .onDisappear {
            trainer.cancel(scan: scan)
        }
        .onChange(of: trainer.phase.isRendering) { _, isRendering in
            if !isRendering {
                isDroneModeEnabled = false
                droneControlVector = .zero
            }
        }
    }

    private func previewLayout(usesLeadingDroneControl: Bool) -> some View {
        ZStack {
            previewSurface

            controls(usesLeadingDroneControl: usesLeadingDroneControl)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: usesLeadingDroneControl ? .leading : .bottom
                )
        }
    }

    private var previewSurface: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            if let previewImage = trainer.previewImage {
                TrainingImagePreview(image: previewImage)
                    .ignoresSafeArea()
            } else if let gaussianFileURL = trainer.previewGaussianFileURL {
                GaussianSplatView(
                    gaussianFileURL: gaussianFileURL,
                    reloadToken: trainer.previewReloadToken,
                    isDroneModeEnabled: isDroneModeEnabled,
                    droneControlVector: droneControlVector
                )
                .ignoresSafeArea()
            } else {
                PreviewPlaceholder(thumbnailURL: scan.thumbnailURL)
                    .ignoresSafeArea()
            }
        }
    }

    private func controls(usesLeadingDroneControl: Bool) -> some View {
        ScanDetailControls(
            phase: trainer.phase,
            iteration: trainer.iteration,
            totalIterations: trainer.totalIterations,
            errorMessage: trainer.errorMessage,
            mode: Binding(
                get: { trainer.trainingMode },
                set: { trainer.trainingMode = $0 }
            ),
            isDroneModeEnabled: isDroneModeEnabled,
            isLeadingDroneControl: usesLeadingDroneControl,
            droneControlVector: $droneControlVector,
            action: { trainer.start(scan: scan) }
        )
    }

    private var shareErrorBinding: Binding<Bool> {
        Binding(
            get: { shareError != nil },
            set: { isPresented in
                if !isPresented {
                    shareError = nil
                }
            }
        )
    }

    private func shareGaussianSplat() {
        let url = scan.gaussianSplatURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            shareError = "This scan does not have an exported Gaussian splat file yet."
            return
        }
        shareSheet = SharedFileSheetItem(url: url)
    }
}
