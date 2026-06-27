import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var store = MemoScanStore()
    @State private var path: [MemoScanRecord] = []
    @State private var scanPendingDeletion: MemoScanRecord?
    @State private var isCapturing = false
    @State private var captureError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 10)
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Color(.systemBackground)
                    .ignoresSafeArea()

                if store.scans.isEmpty {
                    ContentUnavailableView("No scans", systemImage: "camera.viewfinder")
                        .padding(.bottom, 72)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.scans) { scan in
                                NavigationLink(value: scan) {
                                    ScanTile(scan: scan)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        scanPendingDeletion = scan
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .accessibilityAction(named: "Delete") {
                                    scanPendingDeletion = scan
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 104)
                    }
                    .scrollIndicators(.hidden)
                }

                AddScanButton {
                    triggerAddHaptic()
                    isCapturing = true
                }
                .padding(.bottom, 18)
            }
            .navigationTitle("memo")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MemoScanRecord.self) { scan in
                ScanDestinationView(scanID: scan.id, store: store)
            }
            .alert("Delete scan?", isPresented: deleteAlertBinding, presenting: scanPendingDeletion) { scan in
                Button("Delete", role: .destructive) {
                    delete(scan)
                }
                Button("Cancel", role: .cancel) {
                    scanPendingDeletion = nil
                }
            } message: { scan in
                Text("\(scan.title) will be removed from this device.")
            }
            .alert("Capture could not be saved", isPresented: captureErrorBinding) {
                Button("OK", role: .cancel) {
                    captureError = nil
                }
            } message: {
                Text(captureError ?? "Unknown error")
            }
            .fullScreenCover(isPresented: $isCapturing) {
                CaptureView { package in
                    finishCapture(package: package)
                }
                .ignoresSafeArea()
                .statusBarHidden(true)
            }
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { scanPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    scanPendingDeletion = nil
                }
            }
        )
    }

    private var captureErrorBinding: Binding<Bool> {
        Binding(
            get: { captureError != nil },
            set: { isPresented in
                if !isPresented {
                    captureError = nil
                }
            }
        )
    }

    private func finishCapture(package: CaptureSessionPackage) {
        do {
            let scan = try store.ingest(package: package)
            isCapturing = false
            path.append(scan)
        } catch {
            isCapturing = false
            captureError = error.localizedDescription
        }
    }

    private func delete(_ scan: MemoScanRecord) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            store.delete(scan)
            scanPendingDeletion = nil
        }
    }

    private func triggerAddHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}

private struct ScanDestinationView: View {
    let scanID: UUID
    @ObservedObject var store: MemoScanStore

    var body: some View {
        if let scan = store.record(id: scanID) {
            PointCloudPreviewView(scan: scan, store: store)
        } else {
            ContentUnavailableView("Scan missing", systemImage: "exclamationmark.triangle")
        }
    }
}

private struct ScanTile: View {
    let scan: MemoScanRecord

    var body: some View {
        GeometryReader { proxy in
            ScanThumbnail(url: scan.thumbnailURL)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(scan.title), \(scan.subtitle)")
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(0.78, contentMode: .fit)
    }
}

private struct ScanThumbnail: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct AddScanButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 27, weight: .semibold))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Create scan")
        } else {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 27, weight: .semibold))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Create scan")
        }
    }
}

#Preview {
    RootView()
}
