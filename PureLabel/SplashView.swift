import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color(.systemGray5)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Text("PureLabel")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.85))

                ProgressView()
                    .controlSize(.regular)
                    .tint(Color.blue)
            }
        }
    }
}

#Preview {
    SplashView()
}
