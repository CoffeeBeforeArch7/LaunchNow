import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var appStore: AppStore
    @StateObject private var updater = Updater.shared
    @State private var showResetConfirm = false
    @State private var hideAppSearchText: String = ""
    @State private var showAddHiddenApps: Bool = false
    @State private var pendingHiddenSelections: Set<String> = []
    @State private var appIconChoice = AppIconChoice.current

    /// 设置约 840pt 高，面板缩小后会从屏幕下边跑出去：限高到屏幕放得下的高度，放不下就滚动。
    /// ScrollView 的理想高度就是内容高度，加 maxHeight 一次排版就是 min(内容, 上限)，不用先量再改（不会闪一下）；
    /// fixedSize 把这个高度定死：不然 sheet 会把可伸缩的内容压到比面板矮 40pt，面板小时设置也跟着变矮
    var body: some View {
        ScrollView {
            settingsContent
        }
        .frame(maxHeight: appStore.settingsMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var settingsContent: some View {
        let hidableApps = appStore.hidableApps(searchText: hideAppSearchText)
        let hiddenApps = hidableApps.filter { appStore.isAppHidden(path: $0.url.path) }
        let addableApps = hidableApps.filter { !appStore.isAppHidden(path: $0.url.path) }
        VStack {
            HStack(alignment: .firstTextBaseline) {
                Text("LaunchNow")
                    .font(.title)
                Text("v\(getVersion())")
                    .font(.footnote)
                Spacer()
                Button {
                    appStore.isSetting = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.bold())
                        .foregroundStyle(.placeholder)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            
            VStack {
                HStack {
                    Text(NSLocalizedString("Style", comment: "Classic Launchpad (Fullscreen)"))
                    Spacer()
                    Toggle(isOn: $appStore.isFullscreenMode) {
                        
                    }
                    .toggleStyle(.switch)
                }
                HStack {
                    Text(NSLocalizedString("ShowAppName", comment: "Show app name"))
                    Spacer()
                    Toggle(isOn: $appStore.showAppNameBelowIcon) {}
                        .toggleStyle(.switch)
                }
                HStack {
                    Text(NSLocalizedString("Gesture", comment: "Gesture"))
                    Spacer()
                    Toggle(isOn: $appStore.isGlobalPinchEnabled) {}
                        .toggleStyle(.switch)
                }
                HStack {
                    Text(NSLocalizedString("MaterialOpacity", comment: "Material opacity"))
                    VStack {
                        Slider(value: $appStore.materialOpacity, in: 0.1...1.0)
                        HStack {
                            Text(NSLocalizedString("Low", comment: "Low"))
                                .font(.footnote)
                            Spacer()
                            Text(NSLocalizedString("High", comment: "High"))
                                .font(.footnote)
                        }
                    }
                }
                HStack {
                    Text(NSLocalizedString("ScrollSensitivity", comment: "Scrolling sensitivity"))
                    VStack {
                        Slider(value: $appStore.scrollSensitivity, in: 0.01...0.99)
                        HStack {
                            Text(NSLocalizedString("Low", comment: "Low"))
                                .font(.footnote)
                            Spacer()
                            Text(NSLocalizedString("High", comment: "High"))
                                .font(.footnote)
                        }
                    }
                }
                // 窗口、图标、名字、间距一起按比例缩放；拖窗口边缘也是同一回事
                HStack {
                    Text(NSLocalizedString("PanelSize", comment: "Panel size"))
                    VStack {
                        Slider(value: $appStore.panelScale, in: AppStore.panelScaleRange, step: 0.05)
                        HStack {
                            Text(NSLocalizedString("Small", comment: "Small"))
                                .font(.footnote)
                            Spacer()
                            Text("\(Int((appStore.panelScale * 100).rounded()))%")
                                .font(.footnote)
                                .monospacedDigit()
                            Spacer()
                            Text(NSLocalizedString("Large", comment: "Large"))
                                .font(.footnote)
                        }
                    }
                    Button {
                        appStore.panelScale = 1.0
                    } label: {
                        Text(NSLocalizedString("DefaultSize", comment: "Default size"))
                    }
                }
                .disabled(appStore.isFullscreenMode)
                HStack {
                    Text(NSLocalizedString("IconSize", comment: "Icon size"))
                    VStack {
                        Slider(value: $appStore.iconScale, in: 0.3...1.2)
                        HStack {
                            Text(NSLocalizedString("Small", comment: "Small"))
                                .font(.footnote)
                            Spacer()
                            Text(NSLocalizedString("Large", comment: "Large"))
                                .font(.footnote)
                        }
                    }
                    Button {
                        appStore.iconScale = 1.0
                    } label: {
                        Text(NSLocalizedString("DefaultSize", comment: "Default size"))
                    }
                }
                HStack {
                    Text("App 图标")
                    Spacer()
                    ForEach(AppIconChoice.allCases) { choice in
                        Button {
                            appIconChoice = choice
                            choice.apply()
                            appStore.refresh() // 网格里 LaunchNow 自己的图标也跟着换
                        } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: choice.preview)
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                Text(choice.title)
                                    .font(.caption)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(appIconChoice == choice ? Color.accentColor : .clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text(NSLocalizedString("DisplayedLanguage", comment: "Displayed Language"))
                    Spacer()
                    Button {
                        AppDelegate.shared?.hideAndOpen(URL(string: "x-apple.systempreferences:com.apple.Localization")!)
                    } label: {
                        Text(NSLocalizedString("Language", comment: "Language..."))
                    }
                }
            }
            .padding(.horizontal)
            
            Divider()
            
            VStack(alignment: .leading) {
                HStack {
                    Text(NSLocalizedString("CustomizeScannedFolder", comment: "Customize scanned folder"))
                    Spacer()
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = true
                        panel.canCreateDirectories = false
                        panel.prompt = NSLocalizedString("Add", comment: "Add")
                        panel.message = NSLocalizedString("AddFolder", comment: "Add folder")
                        if panel.runModal() == .OK {
                            let chosen = panel.urls.map { $0.path }
                            var merged = appStore.customSearchPaths
                            for p in chosen {
                                let expanded = (p as NSString).expandingTildeInPath
                                if !merged.contains(expanded) {
                                    merged.append(expanded)
                                }
                            }
                            appStore.customSearchPaths = merged
                        }
                    } label: {
                        Label(NSLocalizedString("Add", comment: "Add"), systemImage: "plus")
                    }
                    Button {
                        appStore.resetDefaultSearchPaths()
                    } label: {
                        Label(NSLocalizedString("ResetToDefault", comment: "Reset to default"), systemImage: "arrow.uturn.backward")
                    }
                }
                
                // 列表 + 添加按钮
                VStack(alignment: .leading) {
                    if appStore.defaultSearchPaths.isEmpty && appStore.customSearchPaths.isEmpty {
                        Text(NSLocalizedString("NoFolders", comment: "No folders"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            ForEach(Array(appStore.defaultSearchPaths.enumerated()), id: \.offset) { idx, path in
                                HStack {
                                    Text(path)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.vertical, 3)
                                    Spacer()
                                    Button(role: .destructive) {
                                        var paths = appStore.defaultSearchPaths
                                        if idx < paths.count { paths.remove(at: idx) }
                                        appStore.defaultSearchPaths = paths
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            ForEach(Array(appStore.customSearchPaths.enumerated()), id: \.offset) { idx, path in
                                HStack {
                                    Text(path)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.vertical, 3)
                                    Spacer()
                                    Button(role: .destructive) {
                                        var paths = appStore.customSearchPaths
                                        if idx < paths.count { paths.remove(at: idx) }
                                        appStore.customSearchPaths = paths
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: 80)
                        .scrollIndicators(.hidden)
                        // 列表放得下时不拦滚轮，交给外面整页滚动
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
            .padding(.horizontal)
            
            Divider()
            
            VStack(alignment: .leading) {
                HStack {
                    Text(NSLocalizedString("HiddenApps", comment: "Hide apps from grid"))
                    Spacer()
                    Button {
                        showAddHiddenApps = true
                    } label: {
                        Label(NSLocalizedString("Add", comment: "Add"), systemImage: "plus")
                    }
                    Button {
                        let hiddenApps = appStore.hidableApps(searchText: "")
                            .filter { appStore.isAppHidden(path: $0.url.path) }
                        for app in hiddenApps {
                            appStore.setAppHidden(false, app: app)
                        }
                    } label: {
                        Label(NSLocalizedString("ClearHiddenApps", comment: "Clear hidden apps"), systemImage: "arrow.uturn.backward")
                    }
                }

                if hiddenApps.isEmpty {
                    Text(NSLocalizedString("NoHiddenApps", comment: "No hidden apps"))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(hiddenApps, id: \.id) { app in
                                HStack(spacing: 10) {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.body)
                                        Text(app.url.path)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        appStore.setAppHidden(false, app: app)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 80)
                    .scrollBounceBehavior(.basedOnSize)
                }

            }
            .padding(.horizontal)
            .sheet(isPresented: $showAddHiddenApps) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(NSLocalizedString("AddHiddenApps", comment: "Add hidden apps"))
                            .font(.title)
                        Spacer()
                        .buttonStyle(.plain)
                        Button {
                            showAddHiddenApps = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.title3.bold())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField(NSLocalizedString("Search", comment: "Search"), text: $hideAppSearchText)
                        .textFieldStyle(.roundedBorder)

                    if addableApps.isEmpty {
                        Text(NSLocalizedString("NoAppsFound", comment: "No apps found"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(addableApps, id: \.id) { app in
                                    HStack(spacing: 10) {
                                        Image(nsImage: app.icon)
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.body)
                                            Text(app.url.path)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        
                                        Spacer()
                                        
                                        Toggle("", isOn: Binding(
                                            get: { pendingHiddenSelections.contains(app.url.path) },
                                            set: { isOn in
                                                if isOn {
                                                    pendingHiddenSelections.insert(app.url.path)
                                                } else {
                                                    pendingHiddenSelections.remove(app.url.path)
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal)
                        }
                        .frame(height: 450)
                        .padding()
                    }
                    
                    HStack {
                        Spacer()
                        Button(NSLocalizedString("Confirm", comment: "Confirm")) {
                            for path in pendingHiddenSelections {
                                if let app = addableApps.first(where: { $0.url.path == path }) {
                                    appStore.setAppHidden(true, app: app)
                                }
                            }
                            pendingHiddenSelections.removeAll()
                            showAddHiddenApps = false
                        }
                        .disabled(pendingHiddenSelections.isEmpty)
                    }
                }
                .padding()
                .padding()
                .onAppear {
                    pendingHiddenSelections.removeAll()
                }
            }
            
            Divider()
            
            HStack {
                Button {
                    exportDataFolder()
                } label: {
                    Label(NSLocalizedString("Export", comment: "Export Data"), systemImage: "square.and.arrow.up")
                }

                Button {
                    importDataFolder()
                } label: {
                    Label(NSLocalizedString("Import", comment: "Import Data"), systemImage: "square.and.arrow.down")
                }
            }
            .padding(.horizontal)
            
            Divider()
            
            HStack {
                Button(NSLocalizedString("CheckUpdates", comment: "Check for Updates")) {
                    Updater.shared.checkForUpdate()
                }
                .alert(updater.alertTitle, isPresented: $updater.showAlert) {
                    if let url = updater.alertURL {
                        Button(NSLocalizedString("Confirm", comment: "Confirm")) {
                            AppDelegate.shared?.hideAndOpen(url)
                        }
                        Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
                    } else {
                        Button(NSLocalizedString("Confirm", comment: "Confirm"), role: .cancel) {}
                    }
                } message: {
                    Text(updater.alertMessage)
                }
                
                Spacer()
                
                Button {
                    appStore.showWelcomeSheet = true
                } label: {
                    Text(NSLocalizedString("ShowWelcome", comment: "Show Introduction"))
                }
                .sheet(isPresented: $appStore.showWelcomeSheet) {
                    WelcomeView(appStore: appStore)
                }
            }
            .padding(.horizontal)

            HStack {
                Button {
                    appStore.refresh()
                } label: {
                    Label(NSLocalizedString("Refresh", comment: "Refresh"), systemImage: "arrow.clockwise")
                }

                Spacer()

                Button {
                    showResetConfirm = true
                } label: {
                    Label(NSLocalizedString("ResetLayout", comment: "Reset Layout"), systemImage: "arrow.counterclockwise")
                        .foregroundStyle(Color.red)
                }
                .alert(NSLocalizedString("ConfirmReset", comment: "Confirm to reset layout?"), isPresented: $showResetConfirm) {
                    Button(NSLocalizedString("Reset", comment: "Reset"), role: .destructive) { appStore.resetLayout() }
                    Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("ResetAlert", comment: "ResetAlert"))
                }
                                
                Button {
                    exit(0)
                } label: {
                    Label(NSLocalizedString("Quit", comment: "Quit"), systemImage: "xmark.circle")
                        .foregroundStyle(Color.red)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)

        }
        .padding()
    }
    
    func getVersion() -> String {
            return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    // MARK: - Export / Import Application Support Data
    private func supportDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("LaunchNow", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func exportDataFolder() {
        do {
            let sourceDir = try supportDirectoryURL()
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Choose a destination folder to export LaunchNow data"
            if panel.runModal() == .OK, let destParent = panel.url {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let folderName = "LaunchNow_Export_" + formatter.string(from: Date())
                let destDir = destParent.appendingPathComponent(folderName, isDirectory: true)
                try copyDirectory(from: sourceDir, to: destDir)
            }
        } catch {
            // 忽略错误或可在此添加用户提示
        }
    }

    private func importDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder previously exported from LaunchNow"
        if panel.runModal() == .OK, let srcDir = panel.url {
            do {
                // 验证是否为有效的排序数据目录
                guard isValidExportFolder(srcDir) else { return }
                let destDir = try supportDirectoryURL()
                // 若用户选的就是目标目录，跳过
                if srcDir.standardizedFileURL == destDir.standardizedFileURL { return }
                try replaceDirectory(with: srcDir, at: destDir)
                // 导入完成后加载并刷新
                appStore.applyOrderAndFolders()
                appStore.refresh()
            } catch {
                // 忽略错误或可在此添加用户提示
            }
        }
    }

    private func copyDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private func replaceDirectory(with src: URL, at dst: URL) throws {
        let fm = FileManager.default
        // 确保父目录存在
        let parent = dst.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private func isValidExportFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let storeURL = folder.appendingPathComponent(ModelContext.fileName)
        guard fm.fileExists(atPath: storeURL.path) else { return false }
        // 尝试读取该布局文件并检查是否有排序数据
        do {
            let ctx = ModelContext(url: storeURL)
            let pageEntries = try ctx.fetch(FetchDescriptor<PageEntryData>())
            if !pageEntries.isEmpty { return true }
            let legacyEntries = try ctx.fetch(FetchDescriptor<TopItemData>())
            return !legacyEntries.isEmpty
        } catch {
            return false
        }
    }
}
