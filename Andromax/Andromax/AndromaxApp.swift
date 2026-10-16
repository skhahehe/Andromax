import SwiftUI

@main
struct AndromaxApp: App {
    @StateObject private var store = DeviceStore()
    @StateObject private var browser = Browser()

    var body: some Scene {
        Window("Andromax", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(browser)
                .preferredColorScheme(.dark)
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 1000, height: 640)
    }
}
