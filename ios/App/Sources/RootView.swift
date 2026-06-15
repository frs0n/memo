import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("memo")
                .font(.largeTitle.bold())

            Text("local capture · local training · local rendering")
                .foregroundStyle(.secondary)

            Text("Project scaffold only. Main app features have not been implemented yet.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}

#Preview {
    RootView()
}

