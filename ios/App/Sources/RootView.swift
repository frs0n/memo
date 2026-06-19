import SwiftUI

struct RootView: View {
    @State private var scans = MemoScan.sampleData
    @State private var scanPendingDeletion: MemoScan?
    @State private var isCapturing = false
    @State private var capturedPreview: CaptureSessionPackage?

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(.systemBackground)
                    .ignoresSafeArea()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(scans) { scan in
                            ScanTile(scan: scan)
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

                AddScanButton {
                    isCapturing = true
                }
                .padding(.bottom, 18)
            }
            .navigationTitle("memo")
            .navigationBarTitleDisplayMode(.large)
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
            .fullScreenCover(isPresented: $isCapturing) {
                CaptureView { package in
                    addCapturedScan(package: package)
                    capturedPreview = package
                    isCapturing = false
                }
                .ignoresSafeArea()
                .statusBarHidden(true)
            }
            .navigationDestination(item: $capturedPreview) { package in
                PointCloudPreviewView(package: package)
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

    private func delete(_ scan: MemoScan) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            scans.removeAll { $0.id == scan.id }
            scanPendingDeletion = nil
        }
    }

    private func addCapturedScan(package: CaptureSessionPackage) {
        let newScan = MemoScan(
            title: package.rootURL.lastPathComponent,
            subtitle: "\(package.keyframeCount) frames",
            symbolName: "camera.viewfinder",
            tone: .highlight
        )

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            scans.insert(newScan, at: 0)
        }
    }
}

private struct ScanTile: View {
    let scan: MemoScan

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(scan.tone.fillStyle)

                ScanTexture(symbolName: scan.symbolName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scan.title)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(0.78, contentMode: .fit)
    }
}

private struct ScanTexture: View {
    let symbolName: String

    var body: some View {
        ZStack {
            Image(systemName: symbolName)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.primary.opacity(0.72))
                .symbolRenderingMode(.hierarchical)
        }
        .overlay {
            Rectangle()
                .fill(.primary.opacity(0.03))
                .blendMode(.overlay)
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

private struct MemoScan: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String
    var symbolName: String
    var tone: MemoTone

    static let sampleData: [MemoScan] = [
        MemoScan(title: "Desk light", subtitle: "46 frames", symbolName: "macbook.and.iphone", tone: .soft),
        MemoScan(title: "Window trace", subtitle: "local render ready", symbolName: "rectangle.split.2x1", tone: .contrast),
        MemoScan(title: "Tiny shrine", subtitle: "training 62%", symbolName: "sparkles.rectangle.stack", tone: .raised),
        MemoScan(title: "Room corner", subtitle: "128 frames", symbolName: "cube.transparent", tone: .contrast),
        MemoScan(title: "Work table", subtitle: "local capture", symbolName: "camera.metering.center.weighted", tone: .soft),
        MemoScan(title: "Laptop", subtitle: "3D Gaussian", symbolName: "laptopcomputer", tone: .deep)
    ]
}

private enum MemoTone {
    case soft
    case raised
    case contrast
    case deep
    case highlight

    var fillStyle: AnyShapeStyle {
        switch self {
        case .soft:
            return AnyShapeStyle(.thinMaterial)
        case .raised:
            return AnyShapeStyle(.regularMaterial)
        case .contrast:
            return AnyShapeStyle(Color(.secondarySystemFill))
        case .deep:
            return AnyShapeStyle(Color(.tertiarySystemFill))
        case .highlight:
            return AnyShapeStyle(Color(.quaternarySystemFill))
        }
    }
}

#Preview {
    RootView()
}
