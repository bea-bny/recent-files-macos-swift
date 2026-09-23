import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import ApplicationServices

@main
struct RecentFilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = RecentStore()
    let presentation = WindowPresentation()
    var window: PanelWindow!
    let hotKey = GlobalHotKey()
    private var transitionToken = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store.start()
        store.onThemeChange = { [weak self] dark in self?.updateApplicationIcon(dark: dark) }
        updateApplicationIcon(dark: store.dark)
        hotKey.onPress = { [weak self] in self?.toggleWindow() }
        makeWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showWindow() }
    }

    private func updateApplicationIcon(dark: Bool) {
        let name = dark ? "RecentFiles-icon-dark" : "RecentFiles-icon-light"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return }
        let sourceSize = image.size
        let iconSize = NSSize(width: 512, height: 512)
        let iconFrame = NSRect(origin: .zero, size: iconSize)
        let roundedIcon = NSImage(size: iconSize)
        roundedIcon.lockFocus()
        NSBezierPath(roundedRect: iconFrame, xRadius: iconSize.width * 0.22, yRadius: iconSize.height * 0.22).addClip()
        image.draw(in: iconFrame, from: NSRect(origin: .zero, size: sourceSize), operation: .copy, fraction: 1)
        roundedIcon.unlockFocus()
        NSApp.applicationIconImage = roundedIcon
    }

    private func makeWindow() {
        let root = RootView(store: store, hotKey: hotKey, presentation: presentation, close: { [weak self] in self?.hideWindow() })
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = 35
        hosting.layer?.masksToBounds = true
        window = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 440, height: 360)
        window.center()
    }

    func toggleWindow() { window.isVisible && NSApp.isActive ? hideWindow() : showWindow() }
    func showWindow() {
        guard window != nil else { return }
        transitionToken = UUID()
        placeAtBottomLeft()
        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 0
        window.setFrame(window.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        presentation.visible = true
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; context.timingFunction = CAMediaTimingFunction(name: .easeOut); window.animator().alphaValue = 1 }
    }
    func hideWindow() {
        guard window.isVisible else { return }
        transitionToken = UUID()
        let token = transitionToken
        presentation.visible = false
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; context.timingFunction = CAMediaTimingFunction(name: .easeIn); window.animator().alphaValue = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
        }
    }
    private func placeAtBottomLeft() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 14
        window.setFrameOrigin(NSPoint(x: visible.minX + margin, y: visible.minY + margin))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
}

final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func close() { (NSApp.delegate as? AppDelegate)?.hideWindow() }
}

@MainActor final class WindowPresentation: ObservableObject {
    @Published var visible = false
}

struct RecentEntry: Identifiable, Hashable {
    let path: String
    var action: String
    var date: Date
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var folder: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
    var ext: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
}

@MainActor final class RecentStore: ObservableObject {
    @Published var files: [RecentEntry] = []
    @Published var folders: [String] = []
    @Published var dark = false
    var onThemeChange: ((Bool) -> Void)?
    private var timers: [any DispatchSourceFileSystemObject] = []
    private var refreshWorkItem: DispatchWorkItem?
    private var isRefreshing = false
    private var refreshAgain = false
    private let defaults = UserDefaults(suiteName: "com.example.recentFiles1") ?? .standard
    private let maxAge: TimeInterval = 30 * 86400
    func start() {
        let home = NSHomeDirectory()
        folders = defaults.stringArray(forKey: "folders") ?? [home + "/Downloads", home + "/Desktop"]
        dark = defaults.bool(forKey: "dark_theme")
        refresh()
        watchFolders()
    }
    func addFolder(_ path: String) {
        guard !folders.contains(path) else { return }
        folders.append(path); defaults.set(folders, forKey: "folders"); watchFolders(); refresh()
    }
    func removeFolder(_ path: String) { folders.removeAll { $0 == path }; defaults.set(folders, forKey: "folders"); watchFolders(); refresh() }
    func setDark(_ value: Bool) { dark = value; defaults.set(value, forKey: "dark_theme"); onThemeChange?(value) }
    func query(_ text: String, period: TimeInterval) -> [RecentEntry] {
        let cutoff = Date().addingTimeInterval(-min(period, maxAge))
        return files.filter { $0.date >= cutoff && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)) }
    }
    func refresh() {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        let roots = folders
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            var result: [String: RecentEntry] = [:]
            for root in roots {
                guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for url in urls {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]), values.isDirectory != true,
                          let modified = values.contentModificationDate, now.timeIntervalSince(modified) <= 30 * 86400,
                          !Self.ignored(url.lastPathComponent) else { continue }
                    let created = values.creationDate ?? modified
                    let action = abs(modified.timeIntervalSince(created)) < 120 ? (root.hasSuffix("/Downloads") ? "Downloaded" : "Created") : "Modified"
                    result[url.path] = RecentEntry(path: url.path, action: action, date: modified)
                }
            }
            let sorted = result.values.sorted { $0.date > $1.date }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.files = sorted
                self.isRefreshing = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }
    nonisolated private static func ignored(_ name: String) -> Bool { name.hasPrefix(".") || [".crdownload", ".download", ".part", ".tmp", ".partial", "~"].contains(where: name.hasSuffix) }
    private func watchFolders() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        timers.forEach { $0.cancel() }; timers.removeAll()
        for folder in folders where FileManager.default.fileExists(atPath: folder) {
            let fd = open(folder, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(fd) }; source.resume(); timers.append(source)
        }
    }
    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWorkItem = nil
            self.refresh()
        }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
}

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

final class GlobalHotKey {
    var onPress: (() -> Void)?
    var onError: ((String) -> Void)?
    var onSuccess: (() -> Void)?
    private var captureHandler: ((UInt32, UInt32) -> Void)?
    private var captureCancelHandler: (() -> Void)?
    private var shortcut: Shortcut?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var isCapturing = false
    private let defaults = UserDefaults(suiteName: "com.example.recentFiles1") ?? .standard
    var isActive: Bool { eventTap != nil }
    deinit {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }
    func registerStored() {
        let key = defaults.object(forKey: "shortcut_key_mac") == nil
            ? Self.macKeyCode(fromUSB: UInt32(defaults.integer(forKey: "shortcut_key")))
            : UInt32(defaults.integer(forKey: "shortcut_key_mac"))
        let names = defaults.stringArray(forKey: "shortcut_modifiers") ?? ["alt"]
        let mods = Self.carbonModifiers(names)
        let normalized = key == 0 ? 49 : key
        _ = register(Shortcut(keyCode: normalized, modifiers: mods, label: Self.label(keyCode: normalized, names: names)), persist: false)
    }
    func register(_ shortcut: Shortcut, persist: Bool = true) -> Bool {
        guard installEventTap() else { return false }
        self.shortcut = shortcut
        if persist {
            defaults.set(Int(Self.usbUsage(fromMac: shortcut.keyCode)), forKey: "shortcut_key")
            defaults.set(Int(shortcut.keyCode), forKey: "shortcut_key_mac")
            defaults.set(Self.names(from: shortcut.modifiers), forKey: "shortcut_modifiers")
        }
        onSuccess?()
        return true
    }
    func beginCapture(onCapture: @escaping (UInt32, UInt32) -> Void, onCancel: @escaping () -> Void) -> Bool {
        guard installEventTap() else { return false }
        captureHandler = onCapture
        captureCancelHandler = onCancel
        isCapturing = true
        return true
    }
    private func installEventTap() -> Bool {
        if eventTap != nil { return true }
        guard AXIsProcessTrusted() else {
            onError?("An exclusive global shortcut requires Accessibility access. It stays on this Mac and reads only key codes and modifiers.")
            return false
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: globalKeyboardTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onError?("To use an exclusive global shortcut, allow Recent Files under System Settings → Privacy & Security → Accessibility, then return to the app.")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            onError?("macOS could not start the keyboard shortcut monitor.")
            return false
        }
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    fileprivate func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifiers(from: event.flags)
        if isCapturing {
            if keyCode == 53 && modifiers == 0 {
                let cancel = captureCancelHandler
                captureCancelHandler = nil
                captureHandler = nil
                DispatchQueue.main.async { [weak self] in
                    self?.isCapturing = false
                    cancel?()
                }
                return nil
            }
            guard modifiers != 0 else { return nil }
            let capture = captureHandler
            captureHandler = nil
            captureCancelHandler = nil
            DispatchQueue.main.async { [weak self] in
                self?.isCapturing = false
                capture?(keyCode, modifiers)
            }
            return nil
        }
        if let shortcut, shortcut.keyCode == keyCode, shortcut.modifiers == modifiers {
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
    private static func modifiers(from flags: CGEventFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.maskCommand) { value |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { value |= UInt32(optionKey) }
        if flags.contains(.maskControl) { value |= UInt32(controlKey) }
        if flags.contains(.maskShift) { value |= UInt32(shiftKey) }
        return value
    }
    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var m: UInt32 = 0
        if names.contains("meta") { m |= UInt32(cmdKey) }; if names.contains("alt") { m |= UInt32(optionKey) }
        if names.contains("control") { m |= UInt32(controlKey) }; if names.contains("shift") { m |= UInt32(shiftKey) }
        return m
    }
    static func names(from m: UInt32) -> [String] { var a: [String] = []; if m & UInt32(cmdKey) != 0 { a.append("meta") }; if m & UInt32(optionKey) != 0 { a.append("alt") }; if m & UInt32(controlKey) != 0 { a.append("control") }; if m & UInt32(shiftKey) != 0 { a.append("shift") }; return a }
    static func label(keyCode: UInt32, names: [String]) -> String {
        var out = ""; if names.contains("control") { out += "⌃" }; if names.contains("alt") { out += "⌥" }; if names.contains("shift") { out += "⇧" }; if names.contains("meta") { out += "⌘" }
        let map: [UInt32: String] = [49:"Space",36:"Return",53:"Esc",48:"Tab",51:"Delete",0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:"."]
        return out + (map[keyCode] ?? "Key \(keyCode)")
    }
    static func macKeyCode(fromUSB usage: UInt32) -> UInt32 {
        let map: [UInt32: UInt32] = [4:0,5:11,6:8,7:2,8:14,9:3,10:5,11:4,12:34,13:38,14:40,15:37,16:46,17:45,18:31,19:35,20:12,21:15,22:1,23:17,24:32,25:9,26:13,27:7,28:16,29:6,30:18,31:19,32:20,33:21,34:23,35:22,36:26,37:28,38:25,39:29,40:36,41:53,42:51,43:48,44:49]
        return map[usage] ?? usage
    }
    static func usbUsage(fromMac keyCode: UInt32) -> UInt32 {
        let pairs: [UInt32: UInt32] = [0:4,11:5,8:6,2:7,14:8,3:9,5:10,4:11,34:12,38:13,40:14,37:15,46:16,45:17,31:18,35:19,12:20,15:21,1:22,17:23,32:24,9:25,13:26,7:27,16:28,6:29,18:30,19:31,20:32,21:33,23:34,22:35,26:36,28:37,25:38,29:39,36:40,53:41,51:42,48:43,49:44,24:46,30:48,33:47,39:52,41:51,42:49,43:54,44:56,50:53,122:58,120:59,99:60,118:61,96:62,97:63,98:64,100:65,101:66,109:67,103:68,111:69,105:104,107:105,113:106,106:107,64:108,79:109,80:110,90:111,126:82,125:81,123:80,124:79]
        return pairs[keyCode] ?? keyCode
    }
}

private let globalKeyboardTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()
    return hotKey.handle(event: event, type: type)
}

struct RootView: View {
    @ObservedObject var store: RecentStore
    let hotKey: GlobalHotKey
    @ObservedObject var presentation: WindowPresentation
    let close: () -> Void
    @State private var search = ""
    @State private var days = 3
    @State private var settings = false
    @State private var toast = false
    @State private var shortcutCapture = false
    @State private var errorMessage: String?
    @State private var login = false
    @State private var hoveredPeriods: Set<Int> = []
    @State private var hotkeyLabel = "⌥Space"
    @FocusState private var searchFocused: Bool
    private let periods: [(String, TimeInterval)] = [("1 hour", 3600), ("24 hours", 86400), ("7 days", 604800), ("30 days", 2592000)]
    private var colors: Palette { Palette(dark: store.dark) }
    var body: some View {
        VStack(spacing: 12) {
            header
            ZStack {
                if settings { settingsView.transition(.opacity) } else { fileList.transition(.opacity) }
                VStack { Spacer(); if toast { Text("Path copied").font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7).background(colors.toast).clipShape(Capsule()).transition(.move(edge: .bottom).combined(with: .opacity)) } }
                    .padding(.bottom, 10).allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.surface.opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(colors.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .padding(16)
        .background(LinearGradient(colors: colors.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(RoundedRectangle(cornerRadius: 35).stroke(colors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 35))
        .shadow(color: colors.shadow, radius: 25, x: 0, y: 10)
        .frame(minWidth: 440, minHeight: 360)
        .buttonStyle(SoftBounceButtonStyle())
        .preferredColorScheme(store.dark ? .dark : .light)
        .opacity(presentation.visible ? 1 : 0)
        .scaleEffect(presentation.visible ? 1 : 0.97)
        .animation(.easeOut(duration: 0.18), value: presentation.visible)
        .onAppear {
            searchFocused = true
            hotKey.onError = { errorMessage = $0 }
            hotKey.onSuccess = { errorMessage = nil }
            hotKey.registerStored()
            hotkeyLabel = storedHotkeyLabel()
            if #available(macOS 13, *) { login = SMAppService.mainApp.status == .enabled }
        }
        .alert("Keyboard shortcut", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Open Accessibility Settings") {
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }
            }
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !hotKey.isActive { hotKey.registerStored() }
        }
        .onExitCommand { if settings { settings = false } else { close() } }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: Bundle.main.url(forResource: store.dark ? "RecentFiles-icon-dark" : "RecentFiles-icon-light", withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage)
                .resizable().aspectRatio(contentMode: .fill).frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(colors.border, lineWidth: 1))
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundColor(colors.muted)
                        TextField("Find file", text: $search).textFieldStyle(.plain).focused($searchFocused)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(colors.muted) }.buttonStyle(SoftBounceButtonStyle()) }
                    }.padding(.horizontal, 15).frame(height: 52).background(colors.surface).overlay(RoundedRectangle(cornerRadius: 18).stroke(colors.border, lineWidth: 1)).clipShape(RoundedRectangle(cornerRadius: 18))
                    Button { withAnimation(.easeOut(duration: 0.18)) { settings.toggle() } } label: { Image(systemName: settings ? "xmark" : "slider.horizontal.3").font(.system(size: 19)).foregroundColor(colors.text).frame(width: 52, height: 52).background(colors.surface).overlay(RoundedRectangle(cornerRadius: 18).stroke(colors.border, lineWidth: 1)).clipShape(RoundedRectangle(cornerRadius: 18)) }.buttonStyle(SoftBounceButtonStyle())
                }
                HStack(spacing: 8) {
                    ForEach(Array(periods.enumerated()), id: \.offset) { index, item in
                        Button { days = index; settings = false } label: { Text(item.0).font(.system(size: 12, weight: days == index ? .semibold : .medium)).foregroundColor(colors.text.opacity(hoveredPeriods.contains(index) ? 0.82 : 1)).frame(maxWidth: .infinity).frame(height: 36).background(days == index ? colors.selected : colors.surface.opacity(0.35)).clipShape(Capsule()).overlay(Capsule().stroke(days == index ? colors.border : .clear, lineWidth: 1)) }
                            .buttonStyle(SoftBounceButtonStyle())
                            .scaleEffect(hoveredPeriods.contains(index) ? 1.035 : 1)
                            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: hoveredPeriods.contains(index))
                            .onHover { hovering in
                                if hovering { hoveredPeriods.insert(index) } else { hoveredPeriods.remove(index) }
                            }
                    }
                }
            }
        }.frame(height: 96)
    }
    private var fileList: some View {
        let selectedPeriod = periods.indices.contains(days) ? periods[days].1 : 30 * 86400
        let files = store.query(search, period: search.isEmpty ? selectedPeriod : 30 * 86400)
        return Group {
            if files.isEmpty { Text("Nothing found").font(.system(size: 14)).foregroundColor(colors.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ScrollView { LazyVStack(spacing: 4) { ForEach(files) { fileRow($0) } }.padding(12) } }
        }
    }
    private func fileRow(_ file: RecentEntry) -> some View {
        HoverTrackingRow(colors: colors) {
            HStack(spacing: 12) {
                fileIcon(file).frame(width: 40, height: 40).background(colors.thumb).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(colors.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 14, weight: .medium)).foregroundColor(colors.text).lineLimit(1)
                    Text(file.path).font(.system(size: 10)).foregroundColor(colors.secondary).lineLimit(1).truncationMode(.middle)
                    Text("\(timeString(file.date)) · \(file.action)").font(.system(size: 10)).foregroundColor(colors.muted).lineLimit(1)
                }.contentShape(Rectangle()).onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]); close() }
                Spacer(minLength: 2)
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]); close() } label: { Image(systemName: "folder").foregroundColor(colors.secondary) }.buttonStyle(SoftBounceButtonStyle()).help("Reveal in Finder")
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string); withAnimation(.easeInOut(duration: 0.2)) { toast = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { toast = false } } } label: { Image(systemName: "doc.on.doc").foregroundColor(colors.secondary) }.buttonStyle(SoftBounceButtonStyle()).help("Copy path")
            }
        }
        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]); close() }; Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string); withAnimation { toast = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { toast = false } } } }
    }
    private func fileIcon(_ file: RecentEntry) -> some View {
        Image(systemName: icon(for: file.ext)).font(.system(size: 21)).foregroundColor(colors.accent)
    }
    private func icon(for ext: String) -> String {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "xlsx", "xls", "csv", "numbers": return "tablecells"
        case "doc", "docx", "pages", "txt", "rtf", "md": return "doc.text"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "zip", "rar", "7z", "gz", "tar": return "archivebox"
        case "mp3", "wav", "m4a", "aiff", "flac": return "music.note"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "dmg", "pkg": return "shippingbox"
        default: return "doc"
        }
    }
    private var settingsView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) { Text("Tracked folders").font(.system(size: 17, weight: .semibold)).foregroundColor(colors.text); Text("Only files from these folders are shown").font(.system(size: 11)).foregroundColor(colors.secondary); Spacer() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                Rectangle().fill(colors.border).frame(width: 1).padding(.vertical, 4)
                VStack(spacing: 8) {
                    ScrollView { VStack(spacing: 6) { ForEach(store.folders, id: \.self) { folder in HStack(spacing: 8) { Image(systemName: "folder.fill").foregroundColor(colors.accent); Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundColor(colors.text); Spacer(minLength: 0); Button { store.removeFolder(folder) } label: { Image(systemName: "minus.circle").foregroundColor(colors.muted) }.buttonStyle(SoftBounceButtonStyle()) }.font(.system(size: 12)).padding(.horizontal, 9).frame(height: 36).background(colors.surface.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 13)) } } }
                    Button { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { store.addFolder(url.path) } } label: { Label("Add folder", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundColor(colors.text).frame(maxWidth: .infinity).frame(height: 38).background(colors.selected).clipShape(RoundedRectangle(cornerRadius: 15)) }.buttonStyle(SoftBounceButtonStyle())
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                HStack { Image(systemName: "power").foregroundColor(colors.accent); Text("Launch at login").font(.system(size: 12)).foregroundColor(colors.text); Spacer(); Toggle("", isOn: $login).labelsHidden().toggleStyle(.switch).scaleEffect(0.75).onChange(of: login) { enabled in
                    if #available(macOS 13, *) { do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { errorMessage = error.localizedDescription; login = SMAppService.mainApp.status == .enabled } } else { errorMessage = "Launch at login requires macOS 13 or later."; login = false }
                } }.padding(.horizontal, 9)
                Rectangle().fill(colors.border).frame(width: 1, height: 34)
                HStack(spacing: 8) {
                    Image(systemName: store.dark ? "moon.fill" : "sun.max.fill").foregroundColor(colors.accent)
                    Text("Theme").font(.system(size: 12)).foregroundColor(colors.text)
                    Spacer(minLength: 2)
                    Toggle("Theme", isOn: Binding(get: { store.dark }, set: { value in withAnimation(.easeOut(duration: 0.18)) { store.setDark(value) } }))
                        .labelsHidden().toggleStyle(SwitchToggleStyle(tint: colors.accent)).scaleEffect(0.78)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(height: 46).background(colors.selected).clipShape(RoundedRectangle(cornerRadius: 16))
            Button { beginShortcutCapture() } label: { HStack { Image(systemName: "keyboard").foregroundColor(colors.accent); Text("Keyboard Shortcut").font(.system(size: 12)).foregroundColor(colors.text); Spacer(); Text(shortcutCapture ? "Press a shortcut…" : hotkeyLabel).font(.system(size: 12)).foregroundColor(colors.secondary).padding(.horizontal, 9).padding(.vertical, 5).background(colors.surface).clipShape(RoundedRectangle(cornerRadius: 9)) }.padding(.horizontal, 12).frame(height: 46).background(colors.selected).clipShape(RoundedRectangle(cornerRadius: 16)) }.buttonStyle(SoftBounceButtonStyle())
        }.padding(14)
    }
    private func storedHotkeyLabel() -> String { let defaults = UserDefaults(suiteName: "com.example.recentFiles1"); let names = defaults?.stringArray(forKey: "shortcut_modifiers") ?? ["alt"]; let key = defaults?.object(forKey: "shortcut_key_mac") == nil ? GlobalHotKey.macKeyCode(fromUSB: UInt32(defaults?.integer(forKey: "shortcut_key") ?? 44)) : UInt32(defaults?.integer(forKey: "shortcut_key_mac") ?? 49); return GlobalHotKey.label(keyCode: key, names: names) }
    private func beginShortcutCapture() {
        guard hotKey.beginCapture(onCapture: { key, modifiers in capture(key: key, modifiers: modifiers) }, onCancel: { shortcutCapture = false }) else { return }
        shortcutCapture = true
    }
    private func capture(key: UInt32, modifiers: UInt32) {
        shortcutCapture = false
        let shortcut = Shortcut(keyCode: key, modifiers: modifiers, label: GlobalHotKey.label(keyCode: key, names: GlobalHotKey.names(from: modifiers)))
        if hotKey.register(shortcut) { hotkeyLabel = shortcut.label }
    }
    private func timeString(_ date: Date) -> String {
        let cal = Calendar.current; let now = Date(); if now.timeIntervalSince(date) < 60 { return "Just now" }; if now.timeIntervalSince(date) < 3600 { return "\(Int(now.timeIntervalSince(date) / 60)) min ago" }; let f = DateFormatter(); f.dateFormat = cal.isDateInToday(date) ? "'Today,' HH:mm" : (cal.isDateInYesterday(date) ? "'Yesterday,' HH:mm" : "d MMM, HH:mm"); return f.string(from: date)
    }
}

private struct HoverTrackingRow<Content: View>: View {
    let colors: Palette
    let content: Content
    @State private var isHovered = false

    init(colors: Palette, @ViewBuilder content: () -> Content) {
        self.colors = colors
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 56)
            .background(isHovered ? colors.selected.opacity(0.55) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.012 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

struct Palette {
    let dark: Bool
    var text: Color { dark ? Color(red: 0.90, green: 0.93, blue: 0.96) : Color(red: 0.27, green: 0.32, blue: 0.37) }
    var secondary: Color { dark ? Color(red: 0.66, green: 0.72, blue: 0.78) : Color(red: 0.45, green: 0.51, blue: 0.57) }
    var muted: Color { dark ? Color(red: 0.50, green: 0.57, blue: 0.64) : Color(red: 0.58, green: 0.64, blue: 0.70) }
    var accent: Color { dark ? Color(red: 0.45, green: 0.72, blue: 0.91) : Color(red: 0.37, green: 0.66, blue: 0.86) }
    var gradient: [Color] { dark ? [Color(red: 0.20, green: 0.27, blue: 0.32), Color(red: 0.14, green: 0.20, blue: 0.24)] : [Color(red: 0.92, green: 0.96, blue: 0.99), Color(red: 0.83, green: 0.91, blue: 0.97)] }
    var surface: Color { dark ? Color(red: 0.15, green: 0.21, blue: 0.25) : .white.opacity(0.70) }
    var selected: Color { dark ? Color(red: 0.20, green: 0.27, blue: 0.32) : .white.opacity(0.90) }
    var border: Color { dark ? Color.white.opacity(0.18) : Color.white.opacity(0.78) }
    var thumb: Color { dark ? Color(red: 0.19, green: 0.25, blue: 0.29) : Color(red: 0.91, green: 0.96, blue: 0.99) }
    var toast: Color { dark ? Color(red: 0.20, green: 0.28, blue: 0.33) : Color(red: 0.86, green: 0.92, blue: 0.97) }
    var shadow: Color { dark ? .black.opacity(0.25) : Color(red: 0.35, green: 0.55, blue: 0.72).opacity(0.18) }
}

struct SoftBounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.58), value: configuration.isPressed)
    }
}
