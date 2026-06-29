import SwiftUI
import UIKit

struct CapturedImagesGalleryView: View {
    @Environment(\.dismiss) private var dismiss

    let scan: MemoScanRecord
    @State private var selectedImage: CapturedImageSelection?

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(scan.capturedImageURLs, id: \.self) { url in
                        Button {
                            selectedImage = CapturedImageSelection(url: url)
                        } label: {
                            CapturedImageThumbnail(url: url)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .navigationTitle("\(scan.keyframeCount) Images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if scan.capturedImageURLs.isEmpty {
                    ContentUnavailableView("No images", systemImage: "photo")
                }
            }
        }
        .sheet(item: $selectedImage) { selection in
            CapturedImageDetailView(url: selection.url)
        }
    }
}

private struct CapturedImageSelection: Identifiable {
    var url: URL
    var id: URL { url }
}

private struct CapturedImageThumbnail: View {
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
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct CapturedImageDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Image missing", systemImage: "photo")
                }
            }
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
