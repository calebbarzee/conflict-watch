// Conflict Watch — macOS helper app.
//
//   ConflictWatch notify --title T --body B [--file F] [--sound]
//       Posts a Notification Center banner; clicking it opens F (via config.openWith).
//   ConflictWatch auth
//       Prints the notification authorization status.
//   ConflictWatch install-agent | uninstall-agent
//       Registers / removes the launchd agent that runs the checks.
//   (no args / launched from Finder)
//       Opens the settings window. When macOS relaunches the app because a
//       notification was clicked, it opens the file instead and quits.

import AppKit
import SwiftUI
import UserNotifications

let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Conflict Watch"
let agentLabel = Bundle.main.bundleIdentifier ?? "local.conflict-watch"

// Config file: $CONFLICT_WATCH_CONFIG, else CWConfigPath (set by source builds),
// else ~/Library/Application Support/<app name>/config.json.
// Relative paths inside it resolve against its directory.
let configURL: URL = {
  if let env = ProcessInfo.processInfo.environment["CONFLICT_WATCH_CONFIG"], !env.isEmpty {
    return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
  }
  if let p = Bundle.main.object(forInfoDictionaryKey: "CWConfigPath") as? String, !p.isEmpty {
    return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
  }
  return FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/\(appName)/config.json")
}()
let projectDir = configURL.deletingLastPathComponent()

// Engines (run.sh + python/ + typescript/): CWEngineDir (source builds), else the copy in Resources/engine.
let engineDir: URL = {
  if let p = Bundle.main.object(forInfoDictionaryKey: "CWEngineDir") as? String, !p.isEmpty {
    return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
  }
  return Bundle.main.resourceURL!.appendingPathComponent("engine")
}()

/// Creates the config from the bundled example on first launch.
func ensureConfig() {
  let fm = FileManager.default
  guard !fm.fileExists(atPath: configURL.path) else { return }
  try? fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let example = engineDir.appendingPathComponent("config.example.json")
  if (try? fm.copyItem(at: example, to: configURL)) == nil { try? Config().save() }
}

func resolvePath(_ p: String) -> URL {
  let expanded = (p as NSString).expandingTildeInPath
  return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded).standardizedFileURL
    : projectDir.appendingPathComponent(expanded).standardizedFileURL
}
var dataDir: URL { resolvePath(Config.load().dataDir) }

// MARK: - Config (shared with the Python / TypeScript engines)

struct ActiveHours: Codable, Equatable {
  var enabled = false
  var start = "08:00"
  var end = "18:00"
  var weekdaysOnly = true

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    start = try c.decodeIfPresent(String.self, forKey: .start) ?? start
    end = try c.decodeIfPresent(String.self, forKey: .end) ?? end
    weekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? weekdaysOnly
  }
}

struct Config: Codable, Equatable {
  var name = "repo"
  var dataDir = "./data"
  var notifierApp = ""  // blank = auto ($CONFLICT_WATCH_NOTIFIER, ~/Applications, /Applications)
  var enabled = true
  var engine = "python"
  var intervalMinutes = 60
  var repoPath = "."
  var remote = "origin"
  var baseBranch = "main"
  var retainDays = 60
  var notifyMode = "new"
  var sound = true
  var includeUntracked = true
  var ignorePatterns: [String] = []
  var activeHours = ActiveHours()
  var openWith = "TextEdit"

  init() {}
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
    dataDir = try c.decodeIfPresent(String.self, forKey: .dataDir) ?? dataDir
    notifierApp = try c.decodeIfPresent(String.self, forKey: .notifierApp) ?? notifierApp
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? engine
    intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? intervalMinutes
    repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? repoPath
    remote = try c.decodeIfPresent(String.self, forKey: .remote) ?? remote
    baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch) ?? baseBranch
    retainDays = try c.decodeIfPresent(Int.self, forKey: .retainDays) ?? retainDays
    notifyMode = try c.decodeIfPresent(String.self, forKey: .notifyMode) ?? notifyMode
    sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
    includeUntracked = try c.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? includeUntracked
    ignorePatterns = try c.decodeIfPresent([String].self, forKey: .ignorePatterns) ?? ignorePatterns
    activeHours = try c.decodeIfPresent(ActiveHours.self, forKey: .activeHours) ?? activeHours
    openWith = try c.decodeIfPresent(String.self, forKey: .openWith) ?? openWith
  }

  static func load() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    return cfg
  }

  func save() throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (enc.encode(self) + Data("\n".utf8)).write(to: configURL, options: .atomic)
  }
}

func openSnapshot(_ path: String) {
  var isDir: ObjCBool = false
  guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
    let a = NSAlert()
    a.messageText = "Snapshot not found"
    a.informativeText = path.isEmpty ? "This notification has no snapshot attached." : "\(path) no longer exists (it may have aged out of history)."
    NSApp.activate()
    a.runModal()
    return
  }
  let app = Config.load().openWith.trimmingCharacters(in: .whitespaces)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  p.arguments = app.isEmpty ? ["-t", path] : ["-a", app, path]
  try? p.run()
}

func postNotification(title: String, body: String, file: String?, sound: Bool,
                      done: @escaping (String?) -> Void) {
  let center = UNUserNotificationCenter.current()
  center.requestAuthorization(options: [.alert, .sound]) { granted, err in
    guard granted else {
      return done("notifications not allowed: \(err?.localizedDescription ?? "denied in System Settings")")
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = "conflict-watch"
    if sound { content.sound = .default }
    if let file, !file.isEmpty { content.userInfo = ["file": file] }
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(req) { err in done(err?.localizedDescription) }
  }
}

// MARK: - CLI mode

func runCLI(_ args: [String]) -> Never {
  switch args.first {
  case "notify":
    var title = "Conflict watch", body = "", file: String?, sound = false
    var i = 1
    while i < args.count {
      switch args[i] {
      case "--title": i += 1; title = args[i]
      case "--body": i += 1; body = args[i]
      case "--file": i += 1; file = args[i]
      case "--sound": sound = true
      default: break
      }
      i += 1
    }
    postNotification(title: title, body: body, file: file, sound: sound) { err in
      if let err { FileHandle.standardError.write(Data("\(err)\n".utf8)); exit(2) }
      exit(0)
    }
  case "install-agent":
    ensureConfig()
    if let err = Agent.install() { FileHandle.standardError.write(Data("\(err)\n".utf8)); exit(1) }
    print("Loaded \(agentLabel) (config: \(configURL.path))")
    exit(0)
  case "uninstall-agent":
    Agent.uninstall()
    print("Removed \(agentLabel)")
    exit(0)
  case "auth":
    UNUserNotificationCenter.current().getNotificationSettings { s in
      let names: [UNAuthorizationStatus: String] = [
        .notDetermined: "notDetermined", .denied: "denied", .authorized: "authorized",
        .provisional: "provisional",
      ]
      print(names[s.authorizationStatus] ?? "unknown")
      exit(0)
    }
  default:
    FileHandle.standardError.write(Data("usage: ConflictWatch notify --title T --body B [--file F] [--sound] | auth | install-agent | uninstall-agent\n".utf8))
    exit(64)
  }
  dispatchMain()
}

// MARK: - launchd agent

enum Agent {
  static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
  }
  static var domain: String { "gui/\(getuid())" }

  @discardableResult
  static func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  static var isLoaded: Bool { launchctl("print", "\(domain)/\(agentLabel)") == 0 }

  /// launchd wakes every 5 minutes; the engine itself decides whether intervalMinutes has elapsed.
  static func install() -> String? {
    let data = resolvePath(Config.load().dataDir)
    try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "Label": agentLabel,
      // Via bash so a quarantined copy (downloaded release) doesn't need run.sh to be exec-approved.
      "ProgramArguments": ["/bin/bash", engineDir.appendingPathComponent("run.sh").path],
      "EnvironmentVariables": [
        "CONFLICT_WATCH_CONFIG": configURL.path,
        "CONFLICT_WATCH_NOTIFIER": Bundle.main.bundlePath,
      ],
      "StartInterval": 300,
      "RunAtLoad": true,
      "StandardErrorPath": data.appendingPathComponent("launchd.err").path,
    ]
    do {
      let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try xml.write(to: plistURL, options: .atomic)
    } catch { return "couldn't write \(plistURL.path): \(error.localizedDescription)" }
    launchctl("bootout", "\(domain)/\(agentLabel)")
    return launchctl("bootstrap", domain, plistURL.path) == 0 ? nil : "launchctl bootstrap failed"
  }

  static func uninstall() {
    launchctl("bootout", "\(domain)/\(agentLabel)")
    try? FileManager.default.removeItem(at: plistURL)
  }
}

// MARK: - Settings UI

final class SettingsModel: ObservableObject {
  @Published var cfg = Config.load()
  @Published var saved = Config.load()
  @Published var lastRun = ""
  @Published var authStatus = "…"
  @Published var running = false
  @Published var message = ""
  @Published var agentLoaded = Agent.isLoaded

  var ignoreText: String {
    get { cfg.ignorePatterns.joined(separator: "\n") }
    set { cfg.ignorePatterns = newValue.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
  }

  init() { refresh() }

  func refresh() {
    let log = (try? String(contentsOf: dataDir.appendingPathComponent("run.log"), encoding: .utf8)) ?? ""
    let lines = log.split(separator: "\n").suffix(4)
    lastRun = lines.isEmpty ? "No runs yet." : lines.joined(separator: "\n")
    agentLoaded = Agent.isLoaded
    UNUserNotificationCenter.current().getNotificationSettings { s in
      let text: String
      switch s.authorizationStatus {
      case .authorized, .provisional: text = "Allowed"
      case .denied: text = "Blocked — enable in System Settings › Notifications › \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Conflict Watch")"
      default: text = "Not yet requested — click “Send test notification”"
      }
      DispatchQueue.main.async { self.authStatus = text }
    }
  }

  func save() {
    do { try cfg.save(); saved = cfg; flash("Saved.") } catch { flash("Save failed: \(error.localizedDescription)") }
  }

  func runNow() {
    if cfg != saved { save() }
    running = true
    let p = Process()
    p.executableURL = engineDir.appendingPathComponent("run.sh")
    p.arguments = ["--force"]
    var env = ProcessInfo.processInfo.environment
    env["CONFLICT_WATCH_CONFIG"] = configURL.path
    env["CONFLICT_WATCH_NOTIFIER"] = Bundle.main.bundlePath
    p.environment = env
    p.terminationHandler = { proc in
      DispatchQueue.main.async {
        self.running = false
        self.refresh()
        self.flash(proc.terminationStatus == 0 ? "Check finished." : "Check failed (exit \(proc.terminationStatus)) — see run.log.")
      }
    }
    do { try p.run() } catch { running = false; flash("Couldn't start run.sh: \(error.localizedDescription)") }
  }

  func toggleAgent() {
    if agentLoaded { Agent.uninstall(); flash("Background checks stopped.") }
    else { if cfg != saved { save() }; flash(Agent.install() ?? "Background checks installed.") }
    refresh()
  }

  func testNotification() {
    let list = dataDir.appendingPathComponent("conflicts.md")
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: list.path) { FileManager.default.createFile(atPath: list.path, contents: Data()) }
    postNotification(title: "\(cfg.name): conflict watch", body: "Test notification — click to open the running list",
                     file: list.path, sound: cfg.sound) { err in
      DispatchQueue.main.async { self.flash(err ?? "Test notification sent."); self.refresh() }
    }
  }

  func reveal(_ name: String) {
    let url = dataDir.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path), name.hasSuffix(".md") {
      FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    if name.hasSuffix("/") {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
    } else { openSnapshot(url.path) }
  }

  private func flash(_ s: String) {
    message = s
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.message == s { self.message = "" } }
  }
}

func timeBinding(_ s: Binding<String>) -> Binding<Date> {
  let f = DateFormatter()
  f.dateFormat = "HH:mm"
  return Binding(
    get: { f.date(from: s.wrappedValue) ?? f.date(from: "09:00")! },
    set: { s.wrappedValue = f.string(from: $0) }
  )
}

struct SettingsView: View {
  @ObservedObject var m: SettingsModel
  let intervals = [5, 15, 30, 60, 120, 180, 240, 360, 720, 1440]

  func intervalLabel(_ n: Int) -> String {
    n < 60 ? "\(n) minutes" : n == 60 ? "1 hour" : n % 60 == 0 && n < 1440 ? "\(n / 60) hours" : n == 1440 ? "1 day" : "\(n) minutes"
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("General") {
          TextField("Name (shown in notifications)", text: $m.cfg.name)
          LabeledContent("Config file", value: configURL.path)
        }
        Section("Schedule") {
          LabeledContent("Background agent") {
            HStack {
              Text(m.agentLoaded ? "Running" : "Not installed").foregroundStyle(m.agentLoaded ? .green : .secondary)
              Button(m.agentLoaded ? "Uninstall" : "Install") { m.toggleAgent() }
            }
          }
          Toggle("Enabled", isOn: $m.cfg.enabled)
          Picker("Check every", selection: $m.cfg.intervalMinutes) {
            ForEach(intervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
            if !intervals.contains(m.cfg.intervalMinutes) {
              Text(intervalLabel(m.cfg.intervalMinutes)).tag(m.cfg.intervalMinutes)
            }
          }
          Toggle("Only during active hours", isOn: $m.cfg.activeHours.enabled)
          if m.cfg.activeHours.enabled {
            DatePicker("From", selection: timeBinding($m.cfg.activeHours.start), displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: timeBinding($m.cfg.activeHours.end), displayedComponents: .hourAndMinute)
            Toggle("Weekdays only", isOn: $m.cfg.activeHours.weekdaysOnly)
          }
          Picker("Engine", selection: $m.cfg.engine) {
            Text("Python").tag("python")
            Text("TypeScript (Node)").tag("typescript")
          }
        }
        Section("Repository") {
          TextField("Repo path", text: $m.cfg.repoPath)
            .help("Absolute, ~/…, or relative to the config file's folder")
          TextField("Remote", text: $m.cfg.remote)
          TextField("Base branch", text: $m.cfg.baseBranch)
          Toggle("Count untracked files as local changes", isOn: $m.cfg.includeUntracked)
          VStack(alignment: .leading, spacing: 4) {
            Text("Ignore patterns (one glob per line)")
            TextEditor(text: Binding(get: { m.ignoreText }, set: { m.ignoreText = $0 }))
              .font(.system(.body, design: .monospaced))
              .frame(minHeight: 60)
          }
        }
        Section("Notifications") {
          Picker("Notify", selection: $m.cfg.notifyMode) {
            Text("When new files start overlapping").tag("new")
            Text("Every check that finds overlaps").tag("every")
            Text("Never (log only)").tag("off")
          }
          Toggle("Play sound", isOn: $m.cfg.sound)
          TextField("Open diffs with (app name)", text: $m.cfg.openWith)
          LabeledContent("Permission", value: m.authStatus)
        }
        Section("Storage") {
          Stepper("Keep history for \(m.cfg.retainDays) days", value: $m.cfg.retainDays, in: 7...365)
          TextField("Data folder", text: $m.cfg.dataDir)
          TextField("Notifier app (blank = this app)", text: $m.cfg.notifierApp)
        }
        Section("Last runs") {
          Text(m.lastRun).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
      }
      .formStyle(.grouped)

      HStack {
        Button("Running list") { m.reveal("conflicts.md") }
        Button("Snapshots") { m.reveal("snapshots/") }
        Button("Send test notification") { m.testNotification() }
        Spacer()
        Text(m.message).foregroundStyle(.secondary).lineLimit(1)
        Button(m.running ? "Checking…" : "Run check now") { m.runNow() }.disabled(m.running)
        Button("Save") { m.save() }.keyboardShortcut("s").disabled(m.cfg == m.saved)
      }
      .padding(12)
    }
    .frame(minWidth: 620, minHeight: 640)
  }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  var window: NSWindow?
  var handledClick = false

  func applicationWillFinishLaunching(_ n: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    ensureConfig()
    // A notification click relaunches us and delivers didReceive right after
    // launch; give it a moment before deciding this was a normal launch.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      if !self.handledClick { self.showSettings() }
    }
  }

  func showSettings() {
    NSApp.setActivationPolicy(.regular)
    if window == nil {
      let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(m: SettingsModel())))
      w.title = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Conflict Watch") — \(Config.load().name)"
      w.setContentSize(NSSize(width: 660, height: 760))
      w.center()
      w.isReleasedWhenClosed = false
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                              withCompletionHandler done: @escaping () -> Void) {
    handledClick = true
    if let f = r.notification.request.content.userInfo["file"] as? String { openSnapshot(f) }
    done()
    if window == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) } }
  }

  func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                              withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
    done([.banner, .list, .sound])
  }

  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showSettings(); return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, !first.hasPrefix("-psn") { runCLI(cliArgs) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
