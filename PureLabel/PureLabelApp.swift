import SwiftUI

@main
struct PureLabelApp: App {
    @State private var isShowingSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()

                if isShowingSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                CameraCaptureModel.shared.warmupIfAuthorized()
                LabelProcessor.warmup()

                try? await Task.sleep(for: .seconds(1.0))

                withAnimation(.easeOut(duration: 0.3)) {
                    isShowingSplash = false
                }
            }
        }
    }
}
