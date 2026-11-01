// Runs a scene file against Bytes Dev, the Debug build, never the installed Bytes.app.
//
//   videos/bytes-video capture scenes/rollover.yaml   write the window block from Bytes Dev as you arranged it
//   videos/bytes-video watch   scenes/rollover.yaml   on every save: fresh vault, set up, replay (no recording)
//   videos/bytes-video record  scenes/rollover.yaml   set up, record, polish (--full for full quality)
//   videos/bytes-video setup   scenes/rollover.yaml   only set the window up
//   videos/bytes-video check   scenes/rollover.yaml   where each step aims in the Bytes Dev open now; no input
//
// Setup goes through the Accessibility tree only: menu items by title, sidebar rows by name, the window's
// frame. Steps aim at the text of an element, not at pixels. Every keyboard or mouse input first checks
// Bytes Dev is in front and stops the run otherwise. Abort: pkill -f "Bytes Dev"; pkill -x screencapture
import AppKit

let bundleID = "md.bytes.app.dev"
// Everything it makes lives in the repo's .build/ (gitignored); bytes-video runs it from the repo's top.
let work = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build")
let appPath = ProcessInfo.processInfo.environment["BYTES_DEV_APP"]
    ?? work.appending(path: "dd/Build/Products/Debug/Bytes Dev.app/Contents/MacOS/Bytes Dev").path
let vaultCopy = work.appending(path: "vault")
let captureDelay = 0.2  // screencapture's first frame comes about this long after it is launched

func fail(_ message: String) -> Never { print("error: \(message)"); exit(1) }

// MARK: Scene file: a small YAML subset (maps, lists of maps, [inline, lists], quoted or bare scalars).

func scalar(_ raw: String) -> Any {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("[") && s.hasSuffix("]") {
        return s.dropFirst().dropLast().split(separator: ",").map { scalar(String($0)) }
    }
    if s.count >= 2, let q = s.first, q == "\"" || q == "'", s.last == q { return String(s.dropFirst().dropLast()) }
    if let n = Double(s) { return n }
    return s
}

func stripComment(_ line: String) -> String {
    var quote: Character? = nil
    for (i, c) in line.enumerated() {
        if c == "\"" || c == "'" { quote = quote == c ? nil : (quote ?? c) }
        if c == "#" && quote == nil && (i == 0 || line[line.index(line.startIndex, offsetBy: i - 1)] == " ") {
            return String(line.prefix(i))
        }
    }
    return line
}

func parseYAML(_ text: String) -> [String: Any] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { stripComment(String($0)) }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { line in (indent: line.prefix { $0 == " " }.count, text: line.trimmingCharacters(in: .whitespaces)) }
    var i = 0
    func block(_ indent: Int) -> Any {
        if i < lines.count, lines[i].text.hasPrefix("- ") {
            var list: [Any] = []
            while i < lines.count, lines[i].indent == indent, lines[i].text.hasPrefix("- ") {
                let item = String(lines[i].text.dropFirst(2))
                if item.contains(": ") || item.hasSuffix(":") {
                    var map: [String: Any] = [:]
                    let (k, v) = pair(item)
                    map[k] = v ?? ""
                    i += 1
                    while i < lines.count, lines[i].indent > indent, !lines[i].text.hasPrefix("- ") {
                        let (k, v) = pair(lines[i].text)
                        map[k] = v ?? ""
                        i += 1
                    }
                    list.append(map)
                } else {
                    list.append(scalar(item)); i += 1
                }
            }
            return list
        }
        var map: [String: Any] = [:]
        while i < lines.count, lines[i].indent == indent {
            let (k, v) = pair(lines[i].text)
            i += 1
            map[k] = v ?? (i < lines.count && lines[i].indent > indent ? block(lines[i].indent) : "")
        }
        return map
    }
    func pair(_ s: String) -> (String, Any?) {
        guard let r = s.range(of: ":") else { return (s, nil) }
        let value = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (String(s[..<r.lowerBound]), value.isEmpty ? nil : scalar(value))
    }
    return block(0) as? [String: Any] ?? [:]
}

// MARK: Dates: {today}, {yesterday}, {today:title} as in vault/ and the scenes.

let day = 86_400.0
func dayString(_ offset: Double, _ format: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f.string(from: Date().addingTimeInterval(offset * day))
}
let tokens: [(String, String)] = [
    ("{today:title}", dayString(0, "EEE, d MMM yyyy")), ("{yesterday:title}", dayString(-1, "EEE, d MMM yyyy")),
    ("{today}", dayString(0, "yyyy-MM-dd")), ("{yesterday}", dayString(-1, "yyyy-MM-dd")),
]
func fill(_ s: String) -> String { tokens.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }
func unfill(_ s: String) -> String {
    tokens.filter { !$0.0.contains(":") }.reduce(s) { $0.replacingOccurrences(of: $1.1, with: $1.0) }
}

func copyVault(from source: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: vaultCopy)
    guard let files = fm.enumerator(at: source, includingPropertiesForKeys: nil) else { fail("no vault at \(source.path)") }
    let base = source.resolvingSymlinksInPath().path
    for case let file as URL in files where !file.hasDirectoryPath {
        let relative = String(file.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
        let target = vaultCopy.appending(path: fill(relative))
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if file.pathExtension == "md", let text = try? String(contentsOf: file, encoding: .utf8) {
            try? fill(text).write(to: target, atomically: true, encoding: .utf8)
        } else {
            try? fm.copyItem(at: file, to: target)
        }
    }
}

// MARK: Accessibility

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return v
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
func texts(_ e: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { attr(e, $0) as? String }.filter { !$0.isEmpty }
}
func all(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
    guard depth < 60 else { return [] }
    return children(e).flatMap { (match($0) ? [$0] : []) + all($0, depth: depth + 1, match) }
}
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func press(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }

struct Dev {
    let app: NSRunningApplication
    var ax: AXUIElement { AXUIElementCreateApplication(app.processIdentifier) }
    var window: AXUIElement? { (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first }

    func menuItem(_ title: String) -> AXUIElement? {
        guard let bar = attr(ax, kAXMenuBarAttribute) else { return nil }
        return all(bar as! AXUIElement) { (attr($0, kAXTitleAttribute) as? String) == title }.first
    }
    func pressMenu(_ title: String) {
        guard let item = menuItem(title) else { fail("no menu item \"\(title)\"") }
        press(item)
        Thread.sleep(forTimeInterval: 0.5)
    }
    var sidebarShown: Bool { window.map { all($0) { role($0) == "AXOutline" }.isEmpty == false } ?? false }
    func toggleSidebar() {
        guard let w = window, let button = all(w, { role($0) == "AXButton" && texts($0).contains("Toggle Sidebar") }).first
        else { fail("no Toggle Sidebar button") }
        press(button)
        Thread.sleep(forTimeInterval: 0.6)
    }
    /// The editor panes, left to right.
    var panes: [AXUIElement] {
        guard let w = window else { return [] }
        return all(w) { role($0) == "AXWebArea" }.sorted { frame($0).minX < frame($1).minX }
    }
    /// Opens a vault path in the active tab by selecting its sidebar row, unfolding its folders first.
    func open(_ path: String) {
        guard let w = window else { fail("no window") }
        let parts = path.split(separator: "/").map(String.init)
        func label(_ row: AXUIElement) -> String {
            children(row).flatMap(children).compactMap { attr($0, kAXValueAttribute) as? String }.first ?? ""
        }
        func rows() -> [AXUIElement] { all(w) { role($0) == "AXRow" } }
        for folder in parts.dropLast() {
            guard let row = rows().last(where: { label($0) == folder }) else { fail("no folder \(folder) in the sidebar") }
            if (attr(row, kAXDisclosingAttribute) as? Bool) != true,
                let triangle = all(row, { role($0) == "AXDisclosureTriangle" }).first
            {
                press(triangle)
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        let name = (parts.last ?? path).replacingOccurrences(of: ".md", with: "")
        var names = [name]
        if name == dayString(0, "yyyy-MM-dd") { names.append("Today") }
        if name == dayString(-1, "yyyy-MM-dd") { names.append("Yesterday") }
        guard let row = rows().last(where: { names.contains(label($0)) }) else { fail("no note \(path) in the sidebar") }
        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.8)
    }
}

func runningDev() -> Dev? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.map(Dev.init)
}

func quitDev() {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.forceTerminate() }
    for _ in 0..<50 where runningDev() != nil { Thread.sleep(forTimeInterval: 0.1) }
}

func launchDev() -> Dev {
    quitDev()
    let p = Process()
    p.executableURL = URL(filePath: appPath)
    p.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    p.environment = ProcessInfo.processInfo.environment.merging(["BYTES_VAULT": vaultCopy.path]) { $1 }
    p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    p.standardError = p.standardOutput
    do { try p.run() } catch { fail("Bytes Dev isn't built yet: run videos/bytes-video build") }
    for _ in 0..<100 {
        if let dev = runningDev(), dev.window != nil {
            Thread.sleep(forTimeInterval: 1)
            return dev
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("Bytes Dev didn't open a window")
}

// MARK: Input, each checked against the front app

func guardFront() {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
        for p in ["screencapture"] { Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-x", p]).waitUntilExit() }
        fail("stopped: Bytes Dev is not in front")
    }
}

var events: [[String: Any]] = []
var clock: Date? = nil
func log(_ kind: String, _ p: CGPoint) {
    guard let start = clock else { return }
    events.append(["t": ((Date().timeIntervalSince(start) - captureDelay) * 1000).rounded() / 1000,
                   "x": p.x, "y": p.y, "kind": kind])
}
var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

func move(_ p: CGPoint) {
    guardFront()
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    log("move", p)
}
func glide(to end: CGPoint, seconds: Double = 0.8) {
    let from = cursor, steps = Int(seconds * 60)
    for i in 1...steps {
        let s = Double(i) / Double(steps), e = s < 0.5 ? 4 * s * s * s : 1 - pow(-2 * s + 2, 3) / 2
        move(CGPoint(x: from.x + (end.x - from.x) * e, y: from.y + (end.y - from.y) * e))
        Thread.sleep(forTimeInterval: seconds / Double(steps))
    }
}
func click(_ p: CGPoint) {
    guardFront()
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
    log("click", p)
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]
let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
    "cmd": (55, .maskCommand), "shift": (56, .maskShift), "alt": (58, .maskAlternate), "ctrl": (59, .maskControl),
]
/// Presses "cmd+return": modifiers down, the key, then every modifier released, so none stays held.
func key(_ combo: String) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let last = parts.last, let code = keyCodes[last] else { fail("unknown key \(combo)") }
    let mods = parts.dropLast().map { m -> (CGKeyCode, CGEventFlags) in
        guard let mod = modifiers[m] else { fail("unknown modifier \(m)") }
        return mod
    }
    let flags = CGEventFlags(mods.map(\.1))
    let src = CGEventSource(stateID: .hidSystemState)
    var sequence = mods.map { ($0.0, true, flags) }
    sequence += [(code, true, flags), (code, false, flags)]
    sequence += mods.reversed().map { ($0.0, false, CGEventFlags()) }
    for (k, down, f) in sequence {
        guardFront()
        let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down)!
        e.flags = f
        e.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    log("key", cursor)
}
func type(_ text: String) {
    for ch in text.utf16 {
        guardFront()
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: [ch])
            e.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
}

// MARK: Scene

struct Scene {
    let url: URL
    let data: [String: Any]
    var root: URL { url.deletingLastPathComponent().deletingLastPathComponent() }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var window: [String: Any] { data["window"] as? [String: Any] ?? [:] }
    var steps: [[String: Any]] { data["steps"] as? [[String: Any]] ?? [] }
    var camera: [String: Any] { data["camera"] as? [String: Any] ?? [:] }
    var tabs: [String] { (window["tabs"] as? [Any] ?? []).map { fill("\($0)") } }

    init(_ path: String) {
        url = URL(filePath: path).standardizedFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { fail("can't read \(path)") }
        data = parseYAML(text)
    }
}

func themeColors(_ name: String) -> (bg: String, text: String) {
    let editor = URL(filePath: appPath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/Editor")
    if name == "Bytes", let d = try? Data(contentsOf: editor.appending(path: "bytes.json")),
        let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: [String: Any]]],
        let c = j["light"]?["color"]
    {
        return (c["bg"] as? String ?? "#ffffff", c["textPrimary"] as? String ?? "#000000")
    }
    if let d = try? Data(contentsOf: editor.appending(path: "themes.json")),
        let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]],
        let c = j[name]?["color"] as? [String: String]
    {
        return (c["bg"] ?? "#ffffff", c["textPrimary"] ?? "#000000")
    }
    return ("#ffffff", "#000000")
}

func currentTheme() -> String {
    guard let defaults = UserDefaults(suiteName: bundleID), let d = defaults.data(forKey: "preferences"),
        let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    else { return "" }
    return j["lightTheme"] as? String ?? ""
}

/// A fresh vault copy and Bytes Dev arranged as the scene's window block says.
func setUp(_ scene: Scene) -> Dev {
    copyVault(from: scene.root.appending(path: scene.data["vault"] as? String ?? "vault"))
    let dev = launchDev()
    dev.app.activate()
    Thread.sleep(forTimeInterval: 0.5)
    let w = scene.window
    guard let window = dev.window else { fail("no window") }
    if let size = w["size"] as? [Any], size.count == 2, let width = size[0] as? Double, let height = size[1] as? Double,
        let screen = NSScreen.screens.first
    {
        let top = screen.frame.height - screen.visibleFrame.maxY
        var origin = CGPoint(x: (screen.frame.width - width) / 2, y: top + (screen.visibleFrame.height - height) / 2)
        var s = CGSize(width: width, height: height)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    }
    if let theme = w["theme"] as? String {
        // The theme palette has no Accessibility rows: it is typed into, which needs Bytes Dev in front.
        dev.pressMenu("Light Theme…")
        type(theme)
        Thread.sleep(forTimeInterval: 0.4)
        key("return")
        Thread.sleep(forTimeInterval: 0.5)
    }
    if !dev.sidebarShown { dev.toggleSidebar() }
    for (i, tab) in scene.tabs.enumerated() {
        if i > 0 {
            // A new tab opens with Open Note up; selecting a sidebar row leaves it open, so close it first.
            dev.pressMenu("New Tab")
            key("escape")
            Thread.sleep(forTimeInterval: 0.3)
        }
        dev.open(tab)
    }
    let single = dev.menuItem("Show Tabs Side by Side") != nil
    if (w["layout"] as? String == "single") != single, scene.tabs.count > 1 { dev.pressMenu("Toggle Single Tab") }
    if (w["sidebar"] as? String ?? "on") == "off", dev.sidebarShown { dev.toggleSidebar() }
    // shortcut: the last tab opened is the focused one; no menu item switches tabs, so focus must be the last tab.
    if let focus = (w["focus"] as? String).map(fill), focus != scene.tabs.last {
        print("note: focus is the last tab in tabs; put \(focus) last")
    }
    return dev
}

/// The center of the element showing `text`, in the pane holding `pane` if given.
func target(_ dev: Dev, _ text: String, pane: String?, scene: Scene) -> CGPoint {
    var roots = [dev.window].compactMap { $0 }
    if let pane, let i = scene.tabs.firstIndex(of: fill(pane)), dev.panes.count == scene.tabs.count {
        roots = [dev.panes[i]]
    }
    let found = roots.flatMap { root in all(root) { el in texts(el).contains(text) && frame(el).width > 0 } }
    guard let el = found.first else { fail("nothing shows \"\(text)\"") }
    let f = frame(el)
    // Text runs wider than its words; aim a little in from the left edge of long text.
    return CGPoint(x: f.width > 160 ? f.minX + 60 : f.midX, y: f.midY)
}

func play(_ scene: Scene, _ dev: Dev) {
    for step in scene.steps {
        if let s = step["wait"] as? Double { Thread.sleep(forTimeInterval: s); continue }
        if let combo = step["key"] as? String { key(combo); continue }
        let pane = step["pane"] as? String
        if let text = step["click"] as? String {
            let p = target(dev, text, pane: pane, scene: scene)
            glide(to: p)
            Thread.sleep(forTimeInterval: 0.15)
            click(p)
        } else if let text = step["move"] as? String {
            glide(to: target(dev, text, pane: pane, scene: scene))
        }
    }
}

/// Steps' length, for screencapture's fixed duration: waits, 0.95 s a glide, 0.2 s a key.
func length(_ scene: Scene) -> Double {
    scene.steps.reduce(0.0) { sum, step in
        sum + ((step["wait"] as? Double) ?? (step["key"] != nil ? 0.2 : 0.95))
    } + ((scene.camera["end"] as? Double) ?? 1) + 1
}

// MARK: Commands

func capture(_ scene: Scene) {
    guard let dev = runningDev(), let window = dev.window else { fail("open Bytes Dev and arrange it first") }
    let size = frame(window).size
    let paths: [String] = dev.panes.compactMap { pane in
        let heading = all(pane) { role($0) == "AXStaticText" }.compactMap { texts($0).first }.first ?? ""
        let fm = FileManager.default
        let files = fm.enumerator(at: vaultCopy, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let file = files.first { f in
            f.pathExtension == "md" && (try? String(contentsOf: f, encoding: .utf8))?
                .split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } == heading
        }
        let base = vaultCopy.resolvingSymlinksInPath().path
        return file.map { unfill(String($0.resolvingSymlinksInPath().path.dropFirst(base.count + 1))) }
    }
    let focused = (attr(dev.ax, kAXFocusedUIElementAttribute)).map { $0 as! AXUIElement }
    let focusIndex = dev.panes.firstIndex { pane in
        guard let focused else { return false }
        return all(pane) { CFEqual($0, focused) }.isEmpty == false || CFEqual(pane, focused)
    }
    var block = ["window:", "  size: [\(Int(size.width)), \(Int(size.height))]", "  theme: \(currentTheme())",
                 "  sidebar: \(dev.sidebarShown ? "on" : "off")",
                 "  tabs: [\(paths.map { "\"\($0)\"" }.joined(separator: ", "))]",
                 "  layout: \(dev.panes.count > 1 ? "side-by-side" : "single")"]
    if let i = focusIndex ?? (paths.isEmpty ? nil : paths.count - 1), i < paths.count { block.append("  focus: \"\(paths[i])\"") }
    var lines = (try? String(contentsOf: scene.url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
    if let start = lines.firstIndex(where: { $0.hasPrefix("window:") }) {
        let end = lines[(start + 1)...].firstIndex { !$0.hasPrefix(" ") && !$0.isEmpty } ?? lines.count
        lines.replaceSubrange(start..<end, with: block)
    } else {
        lines.insert(contentsOf: block, at: min(2, lines.count))
    }
    try? lines.joined(separator: "\n").write(to: scene.url, atomically: true, encoding: .utf8)
    print(block.joined(separator: "\n"))
    if paths.count < dev.panes.count { print("note: a pane's note wasn't found in \(vaultCopy.path)") }
}

func record(_ scene: Scene, full: Bool) {
    for n in [3, 2, 1] { print("recording in \(n)… hands off the Mac"); Thread.sleep(forTimeInterval: 1) }
    let dev = setUp(scene)
    guard let window = dev.window else { fail("no window") }
    guardFront()
    let f = frame(window)
    let out = scene.root.appending(path: "raw")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let mov = out.appending(path: "\(scene.name).mov"), json = out.appending(path: "\(scene.name).json")
    try? FileManager.default.removeItem(at: mov)
    let capture = Process()
    capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
    capture.arguments = ["-v", "-V", "\(Int(length(scene).rounded(.up)))",
                         "-R", "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))", mov.path]
    clock = Date()
    try? capture.run()
    play(scene, dev)
    capture.waitUntilExit()
    let theme = themeColors(scene.window["theme"] as? String ?? "Bytes")
    let log: [String: Any] = [
        "region": [f.minX, f.minY, f.width, f.height], "scale": 2, "windows": [[f.minX, f.minY, f.width, f.height]],
        "radius": 26, "background": theme.bg, "text": theme.text, "camera": scene.camera,
        "captureDelay": captureDelay, "events": events,
    ]
    try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]).write(to: json)
    quitDev()
    let mp4 = out.appending(path: "\(scene.name)\(full ? "" : "-preview").mp4")
    let venv = work.appending(path: "venv/bin/python").path
    let python = FileManager.default.fileExists(atPath: venv) ? venv : "/usr/bin/env"
    let polish = Process()
    polish.executableURL = URL(filePath: python)
    polish.arguments = (python == "/usr/bin/env" ? ["python3"] : [])
        + [scene.root.appending(path: "videos/polish.py").path, mov.path, json.path, mp4.path] + (full ? [] : ["--preview"])
    try? polish.run()
    polish.waitUntilExit()
    print("raw: \(mov.path)\nlog: \(json.path)\nclip: \(mp4.path)")
    NSWorkspace.shared.open(mp4)
}

func watch(_ scene: Scene) {
    print("watching \(scene.url.lastPathComponent): save it to replay, ctrl-C to stop")
    var seen: Date? = nil
    while true {
        let modified = (try? scene.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != seen {
            seen = modified
            let fresh = Scene(scene.url.path)
            print("replaying…")
            play(fresh, setUp(fresh))
            print("done; waiting for the next save")
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: bytes-video capture|watch|record|setup|check <scene.yaml> [--full]"); exit(2) }
guard AXIsProcessTrusted() else { fail("this app needs Accessibility (Privacy & Security → Device Control and Data Access)") }
let scene = Scene(args[1])
switch args[0] {
case "capture": capture(scene)
case "watch": watch(scene)
case "record": record(scene, full: args.contains("--full"))
case "setup": _ = setUp(scene)
case "check":
    // Read-only: where each step would aim in the Bytes Dev that is open now.
    guard let dev = runningDev() else { fail("Bytes Dev isn't running") }
    for step in scene.steps {
        if let text = (step["click"] ?? step["move"]) as? String {
            print(step["click"] != nil ? "click" : "move", text, target(dev, text, pane: step["pane"] as? String, scene: scene))
        }
    }
default: fail("unknown command \(args[0])")
}
