import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject private var browser: Browser

    @State private var dropTargeted = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renameTarget: RemoteItem?
    @State private var renameText = ""
    @State private var deleteTargets: [RemoteItem] = []

    var body: some View {
        VStack(spacing: 0) {
            if browser.device != nil, browser.transport != nil {
                PathBar()
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if dropTargeted && browser.canModify {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white, lineWidth: 2)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            BottomBar()
        }
        .background(Color.black)
        .navigationTitle(browser.crumbs.last?.name ?? browser.device?.name ?? "Andromax")
        .toolbar { toolbar }
        .searchable(text: $browser.search, prompt: "Search this folder")
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { browser.makeFolder(named: folderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: presence(of: $renameTarget), presenting: renameTarget) { item in
            TextField("Name", text: $renameText)
            Button("Rename") { browser.rename(item, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(deleteTitle, isPresented: Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } })) {
            Button("Delete", role: .destructive) { browser.delete(deleteTargets) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(deleteTargets.count == 1 ? "it" : "them") from the phone immediately. It can't be undone.")
        }
        .alert("Replace existing items?", isPresented: presence(of: $browser.conflict), presenting: browser.conflict) { conflict in
            Button("Replace") { browser.resolve(conflict, replace: true) }
            Button("Skip Existing") { browser.resolve(conflict, replace: false) }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text(conflict.clashing.count == 1
                 ? "“\(conflict.clashing[0])” already exists in this folder on the phone."
                 : "\(conflict.clashing.count) items with the same names already exist in this folder on the phone.")
        }
        .alert("Andromax", isPresented: presence(of: $browser.alertMessage), presenting: browser.alertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let device = browser.device {
            if browser.transport == nil {
                Guidance(symbol: "lock.iphone", title: waitingTitle(device), steps: waitingSteps(device))
            } else if let problem = browser.problem {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(problem).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Button("Try Again") { browser.retry() }
                }
                .padding()
            } else {
                fileTable
                    .overlay {
                        if browser.isLoading && browser.items.isEmpty {
                            ProgressView().controlSize(.small)
                        } else if browser.visibleItems.isEmpty && !browser.isLoading {
                            Text(browser.search.isEmpty ? "This folder is empty — drop files here to copy them to the phone." : "No matches")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        } else {
            Guidance(symbol: "cable.connector", title: "Connect your Android phone", steps: [
                "Plug it into this Mac with a USB cable and unlock it.",
                "On the phone, open the USB notification and choose File Transfer.",
                "For faster transfers, turn on USB debugging in Developer options and tap Allow.",
            ])
        }
    }

    private var fileTable: some View {
        Table(of: RemoteItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    Image(systemName: browser.atRoots ? "internaldrive.fill" : item.symbol)
                        .foregroundStyle(item.isDirectory ? .primary : .secondary)
                        .frame(width: 18)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Size", value: \.size) { item in
                Text(item.sizeText).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 100, max: 160)
            TableColumn("Modified", value: \.modifiedSort) { item in
                Text(item.modifiedText).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 240)
        } rows: {
            ForEach(browser.visibleItems) { item in
                TableRow(item).itemProvider { dragProvider(for: item) }
            }
        }
        .scrollContentBackground(.hidden)
        .plainRows()
        .background(Color.black)
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            contextMenu(for: browser.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let item = browser.items.first(where: { ids.contains($0.id) }) {
                if item.isDirectory {
                    browser.open(item)
                } else {
                    browser.download([item], to: Browser.downloadsFolder)
                }
            }
        }
        .onDeleteCommand {
            if !browser.selectedItems.isEmpty { deleteTargets = browser.selectedItems }
        }
    }

    @ViewBuilder
    private func contextMenu(for targets: [RemoteItem]) -> some View {
        if browser.atRoots {
            if let first = targets.first { Button("Open") { browser.open(first) } }
        } else if targets.isEmpty {
            Button("New Folder…") { beginNewFolder() }
            Button("Copy Files to Phone…") { chooseUploads() }
            Button("Refresh") { browser.refresh() }
        } else {
            if targets.count == 1, let item = targets.first, item.isDirectory {
                Button("Open") { browser.open(item) }
                Divider()
            }
            Button("Copy to Downloads") { browser.download(targets, to: Browser.downloadsFolder) }
            Button("Copy to…") { chooseDestination(for: targets, move: false) }
            Button("Move to Mac…") { chooseDestination(for: targets, move: true) }
            Divider()
            if targets.count == 1, let item = targets.first {
                Button("Rename…") {
                    renameText = item.name
                    renameTarget = item
                }
            }
            Button("Delete…", role: .destructive) { deleteTargets = targets }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: browser.goUp) {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(browser.atRoots)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Go to the enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let device = browser.device, device.transports.count > 1, let current = browser.transport {
                Picker("Connection", selection: Binding(get: { current }, set: { browser.choose($0) })) {
                    ForEach(device.transports) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("ADB is faster; MTP works without USB debugging")
            }
            Button(action: beginNewFolder) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!browser.canModify)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("New folder")

            Button(action: chooseUploads) {
                Label("Copy to Phone", systemImage: "square.and.arrow.up")
            }
            .disabled(!browser.canModify)
            .help("Copy files from this Mac to the phone")

            Button {
                browser.download(browser.selectedItems, to: Browser.downloadsFolder)
            } label: {
                Label("Copy to Mac", systemImage: "square.and.arrow.down")
            }
            .disabled(browser.selectedItems.isEmpty)
            .help("Copy the selection to Downloads")

            Menu {
                Toggle("Show Hidden Files", isOn: $browser.showHidden)
                Button("Refresh") { browser.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(browser.transport == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    private var deleteTitle: String {
        deleteTargets.count == 1 ? "Delete “\(deleteTargets[0].name)”?" : "Delete \(deleteTargets.count) items?"
    }

    private func beginNewFolder() {
        folderName = "New Folder"
        showNewFolder = true
    }

    private func chooseUploads() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        if panel.runModal() == .OK { browser.upload(panel.urls) }
    }

    private func chooseDestination(for targets: [RemoteItem], move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Browser.downloadsFolder
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = move ? "The originals are deleted from the phone after they have been copied." : ""
        if panel.runModal() == .OK, let folder = panel.url {
            browser.download(targets, to: folder, deleteAfterwards: move)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard browser.canModify else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, url.isFileURL { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { browser.upload(urls) }
        }
        return true
    }

    /// Lets a file be dragged straight to Finder; the copy starts when it is dropped.
    private func dragProvider(for item: RemoteItem) -> NSItemProvider? {
        guard !browser.atRoots, !item.isDirectory else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    completion(try await browser.fetchForDrag(item), false, nil)
                } catch {
                    completion(nil, false, error)
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }

    private func waitingTitle(_ device: PhoneDevice) -> String {
        device.adbState == "unauthorized" ? "Allow this Mac on your phone" : "\(device.name) isn't ready yet"
    }

    private func waitingSteps(_ device: PhoneDevice) -> [String] {
        if device.adbState == "unauthorized" {
            return [
                "Unlock the phone and tap Allow on the “Allow USB debugging?” prompt.",
                "No prompt? Unplug and replug the cable, or choose File Transfer from the USB notification instead.",
            ]
        }
        return ["Unplug the cable, plug it back in and unlock the phone."]
    }

    private func presence<Value>(of value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

// MARK: - Pieces

private extension View {
    /// Striped rows look busy on pure black; the modifier only exists on macOS 14 and later.
    @ViewBuilder
    func plainRows() -> some View {
        if #available(macOS 14.0, *) {
            alternatingRowBackgrounds(.disabled)
        } else {
            self
        }
    }
}

private struct Guidance: View {
    let symbol: String
    let title: String
    let steps: [String]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white))
                            .foregroundStyle(.black)
                        Text(step).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(32)
    }
}

private struct PathBar: View {
    @EnvironmentObject private var browser: Browser

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(browser.device?.name ?? "Phone", symbol: "iphone", depth: 0)
                ForEach(Array(browser.crumbs.enumerated()), id: \.offset) { index, item in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(item.name, symbol: nil, depth: index + 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.07))
    }

    private func crumb(_ title: String, symbol: String?, depth: Int) -> some View {
        let isCurrent = depth == browser.crumbs.count
        return Button {
            browser.jump(toDepth: depth)
        } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }
}

private struct BottomBar: View {
    @EnvironmentObject private var browser: Browser
    @State private var showDetails = false

    var body: some View {
        Group {
            if let activity = browser.activity {
                transfer(activity)
            } else if let summary = browser.summary {
                finished(summary)
            } else {
                status
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.07))
    }

    private var status: some View {
        HStack {
            if let opening = browser.opening {
                ProgressView().controlSize(.mini)
                Text("Opening “\(opening)”…")
            } else if browser.transport != nil {
                let count = browser.visibleItems.count
                Text(browser.selection.isEmpty ? "\(count) item\(count == 1 ? "" : "s")" : "\(browser.selection.count) of \(count) selected")
            } else {
                Text("No phone connected")
            }
            Spacer()
            if let transport = browser.transport {
                Text("Connected over \(transport.rawValue)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func transfer(_ activity: Browser.Activity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(activity.title).fontWeight(.semibold)
                Text(activity.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if activity.count > 1 { Text("\(activity.index) of \(activity.count)").foregroundStyle(.secondary) }
                if let rate = activity.rate { Text(rate).foregroundStyle(.secondary).monospacedDigit() }
                if let fraction = activity.fraction { Text("\(Int(fraction * 100))%").monospacedDigit() }
                Button(action: browser.cancelTransfers) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .font(.callout)
            if let fraction = activity.fraction {
                ProgressView(value: fraction).tint(.white)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.white)
            }
        }
    }

    private func finished(_ summary: Browser.Summary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: summary.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(summary.text).lineLimit(2)
            Spacer()
            if !summary.details.isEmpty {
                Button("Details") { showDetails = true }
                    .popover(isPresented: $showDetails) {
                        ScrollView {
                            Text(summary.details.joined(separator: "\n"))
                                .font(.callout)
                                .textSelection(.enabled)
                                .padding()
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    }
            }
            if !summary.reveal.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(summary.reveal) }
            }
            Button {
                browser.summary = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .font(.callout)
        .controlSize(.small)
    }
}
