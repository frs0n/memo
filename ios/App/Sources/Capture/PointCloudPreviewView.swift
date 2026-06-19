import SceneKit
import SwiftUI

#if canImport(MetalSplatter)
import MetalSplatter
#endif

struct PointCloudPreviewView: View {
    let package: CaptureSessionPackage

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            PointCloudSceneView(pointCloudURL: package.pointCloudURL)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TrainButton {}
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .navigationTitle("Train")
        .navigationBarTitleDisplayMode(.inline)
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

private struct PointCloudSceneView: UIViewRepresentable {
    let pointCloudURL: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .systemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = PointCloudSceneBuilder.scene(from: pointCloudURL)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

private enum PointCloudSceneBuilder {
    static func scene(from url: URL) -> SCNScene {
        let scene = SCNScene()
        let points = PLYPointCloudLoader.load(url: url, maximumPointCount: 160_000)
        let geometry = makeGeometry(points: points)
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        let bounds = bounds(for: points)
        let center = SCNVector3(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        node.position = SCNVector3(-center.x, -center.y, -center.z)

        let span = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.001
        cameraNode.camera?.zFar = Double(max(span * 8, 20))
        cameraNode.position = SCNVector3(0, 0, max(span * 1.8, 1.2))
        scene.rootNode.addChildNode(cameraNode)

        return scene
    }

    private static func makeGeometry(points: [PreviewPoint]) -> SCNGeometry {
        var vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        var colors = points.flatMap { point in
            [
                Float(point.r) / 255,
                Float(point.g) / 255,
                Float(point.b) / 255,
                Float(1)
            ]
        }

        let vertexData = vertices.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let colorData = colors.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector3>.stride
        )
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.stride * 4
        )
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: points.count, bytesPerIndex: 0)
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 4

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static func bounds(for points: [PreviewPoint]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = points.first else {
            return (SIMD3<Float>(-0.5, -0.5, -0.5), SIMD3<Float>(0.5, 0.5, 0.5))
        }

        var minPoint = SIMD3<Float>(first.x, first.y, first.z)
        var maxPoint = minPoint
        for point in points.dropFirst() {
            let value = SIMD3<Float>(point.x, point.y, point.z)
            minPoint = simd_min(minPoint, value)
            maxPoint = simd_max(maxPoint, value)
        }
        return (minPoint, maxPoint)
    }
}

private enum PLYPointCloudLoader {
    static func load(url: URL, maximumPointCount: Int) -> [PreviewPoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let headerEnd = text.range(of: "end_header\n")?.upperBound else {
            return []
        }

        let lines = text[headerEnd...].split(separator: "\n", omittingEmptySubsequences: true)
        let stride = max(lines.count / maximumPointCount, 1)
        return lines.enumerated().compactMap { index, line in
            guard index.isMultiple(of: stride) else { return nil }
            return PreviewPoint(line: line)
        }
    }
}

private struct PreviewPoint {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init?(line: Substring) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let x = Float(parts[0]),
              let y = Float(parts[1]),
              let z = Float(parts[2]),
              let r = UInt8(parts[3]),
              let g = UInt8(parts[4]),
              let b = UInt8(parts[5]) else {
            return nil
        }

        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.g = g
        self.b = b
    }
}
