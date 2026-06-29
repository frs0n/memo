import SwiftUI
import UIKit

struct DroneRemoteControl: View {
    @Binding var vector: CGSize

    private let controlSize: CGFloat = 108
    private let thumbSize: CGFloat = 42

    var body: some View {
        VStack {
            controlSurface
                .frame(width: controlSize, height: controlSize)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            vector = clampedControlVector(value.translation)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                vector = .zero
                            }
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Drone remote control")
                .accessibilityValue(accessibilityValue)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var controlSurface: some View {
        if #available(iOS 26.0, *) {
            ZStack {
                GlassEffectContainer(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(.secondary.opacity(0.04))
                            .glassEffect(.regular.tint(.primary.opacity(0.08)).interactive(), in: .circle)

                        Circle()
                            .fill(.secondary.opacity(0.06))
                            .frame(width: controlSize * 0.46, height: controlSize * 0.46)
                            .glassEffect(.regular.tint(.secondary.opacity(0.12)), in: .circle)
                    }
                }

                Circle()
                    .fill(Color(uiColor: .black))
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(vector)
            }
        } else {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .strokeBorder(.secondary.opacity(0.22), lineWidth: 1)
                    }

                Circle()
                    .fill(.secondary.opacity(0.12))
                    .frame(width: controlSize * 0.44, height: controlSize * 0.44)

                Circle()
                    .fill(.primary.opacity(0.86))
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(vector)
            }
        }
    }

    private var accessibilityValue: String {
        guard vector != .zero else { return "Centered" }
        let vertical = vector.height < 0 ? "forward" : "backward"
        let horizontal = vector.width < 0 ? "left" : "right"
        if abs(vector.height) > abs(vector.width) {
            return vertical
        }
        return horizontal
    }

    private func clampedControlVector(_ translation: CGSize) -> CGSize {
        let radius = (controlSize - thumbSize) * 0.5
        let length = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard length > radius else { return translation }
        let scale = radius / length
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
