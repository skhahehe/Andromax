import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var browser: Browser
    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            BrowserView()
        }
        .onAppear {
            store.start()
            sync()
        }
        .onChange(of: store.devices) { _ in sync() }
        .onChange(of: selectedID) { _ in sync() }
    }

    /// Keeps a phone selected whenever one is connected, so plugging in is all it takes.
    private func sync() {
        if !store.devices.contains(where: { $0.id == selectedID }) {
            selectedID = store.devices.first?.id
        }
        browser.show(store.devices.first { $0.id == selectedID })
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: DeviceStore
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section("Phones") {
                if store.devices.isEmpty {
                    Label("Waiting for a phone…", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.devices) { device in
                    DeviceRow(device: device).tag(device.id)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(white: 0.07))
        .safeAreaInset(edge: .bottom) {
            if store.adbInstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Setting up ADB (first run)…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if store.adbMissing {
                Text("Couldn't set up ADB (no internet?), so only MTP (File Transfer mode) is available. Restart Andromax to try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: PhoneDevice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(device.transports.isEmpty ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                if let status = device.statusText {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ForEach(device.transports) { transport in
                Text(transport.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.35)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
