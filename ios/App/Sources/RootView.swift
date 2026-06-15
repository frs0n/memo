import SwiftUI

struct RootView: View {
    @State private var scans = MemoScan.sampleData
    @State private var scanPendingDeletion: MemoScan?

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black
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
                    addPlaceholderScan()
                }
                .padding(.bottom, 18)
            }
            .navigationTitle("memo")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
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

    private func addPlaceholderScan() {
        let newScan = MemoScan(
            title: "New memory",
            subtitle: "capturing",
            symbolName: "camera.viewfinder",
            colors: [.memoMint, .memoBlue]
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
                LinearGradient(
                    colors: scan.colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

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
                .foregroundStyle(.white.opacity(0.82))
                .symbolRenderingMode(.hierarchical)
        }
        .overlay {
            Rectangle()
                .fill(.white.opacity(0.04))
                .blendMode(.overlay)
        }
    }
}

private struct AddScanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 64, height: 64)
        }
        .buttonStyle(MemoGlassButtonStyle(size: 64, cornerRadius: 32, prominent: true))
        .accessibilityLabel("Create scan")
    }
}

private struct MemoGlassButtonStyle: ButtonStyle {
    let size: CGFloat
    let cornerRadius: CGFloat
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
            .modifier(MemoGlassSurface(cornerRadius: cornerRadius, prominent: prominent))
    }
}

private struct MemoGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    prominent ? .regular.tint(.white.opacity(0.86)).interactive() : .regular.tint(.white.opacity(0.16)).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(prominent ? .white.opacity(0.9) : .white.opacity(0.14))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(prominent ? 0.45 : 0.18), lineWidth: 1)
                }
        }
    }
}

private struct MemoScan: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String
    var symbolName: String
    var colors: [Color]

    static let sampleData: [MemoScan] = [
        MemoScan(title: "Desk light", subtitle: "46 frames", symbolName: "macbook.and.iphone", colors: [.memoWarmGray, .memoSand]),
        MemoScan(title: "Window trace", subtitle: "local render ready", symbolName: "rectangle.split.2x1", colors: [.memoBlue, .memoIndigo]),
        MemoScan(title: "Tiny shrine", subtitle: "training 62%", symbolName: "sparkles.rectangle.stack", colors: [.memoMint, .memoGreen]),
        MemoScan(title: "Room corner", subtitle: "128 frames", symbolName: "cube.transparent", colors: [.memoSlate, .memoBlue]),
        MemoScan(title: "Work table", subtitle: "local capture", symbolName: "camera.metering.center.weighted", colors: [.memoGray, .memoWarmGray]),
        MemoScan(title: "Laptop", subtitle: "3D Gaussian", symbolName: "laptopcomputer", colors: [.memoCharcoal, .memoGray])
    ]
}

private extension Color {
    static let memoBlue = Color(red: 0.25, green: 0.42, blue: 0.62)
    static let memoCharcoal = Color(red: 0.10, green: 0.11, blue: 0.12)
    static let memoGray = Color(red: 0.42, green: 0.44, blue: 0.46)
    static let memoGreen = Color(red: 0.36, green: 0.55, blue: 0.42)
    static let memoIndigo = Color(red: 0.30, green: 0.33, blue: 0.52)
    static let memoMint = Color(red: 0.38, green: 0.62, blue: 0.58)
    static let memoSand = Color(red: 0.64, green: 0.57, blue: 0.48)
    static let memoSlate = Color(red: 0.26, green: 0.31, blue: 0.36)
    static let memoWarmGray = Color(red: 0.48, green: 0.45, blue: 0.41)
}

#Preview {
    RootView()
}
