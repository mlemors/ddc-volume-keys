import AppKit
import ApplicationServices
import DDCVolumeKeysCore
import ServiceManagement

private func localized(_ key: String) -> String {
  Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func localized(_ key: String, _ arguments: CVarArg...) -> String {
  String(
    format: localized(key),
    locale: Locale.current,
    arguments: arguments
  )
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let settings = SettingsStore()
  private lazy var ddcService = DDCService(settings: settings)
  private lazy var mediaKeyHandler = MediaKeyHandler(
    shouldHandle: { [weak self] in self?.ddcService.isConnected == true },
    volumeUp: { [weak self] step in self?.ddcService.changeVolume(by: step) },
    volumeDown: { [weak self] step in self?.ddcService.changeVolume(by: -step) },
    toggleMute: { [weak self] in self?.ddcService.toggleMute() }
  )

  private var statusItem: NSStatusItem!
  private let headerItem = NSMenuItem(title: "DDCVolumeKeys", action: nil, keyEquivalent: "")
  private let launchAtLoginMenuItem = NSMenuItem(
    title: localized("menu.launchAtLogin"),
    action: #selector(toggleLaunchAtLogin),
    keyEquivalent: ""
  )
  private var currentDisplays: [DisplayInfo] = []
  private var permissionTimer: Timer?
  private var refreshTimer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var accessibilityTrusted = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configureMainMenu()
    configureMenuBar()
    configureStateUpdates()
    configureDisplayObservers()
    startPermissionMonitoring()
    refreshDisplays()
  }

  func applicationWillTerminate(_ notification: Notification) {
    mediaKeyHandler.stop()
    permissionTimer?.invalidate()
    refreshTimer?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  private func configureMenuBar() {
    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        ?? Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
      let icon = NSImage(contentsOf: iconURL)
    {
      NSApp.applicationIconImage = icon
    } else {
      NSApp.applicationIconImage = NSImage(
        systemSymbolName: "speaker.wave.2.circle.fill",
        accessibilityDescription: "DDCVolumeKeys"
      )
    }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    configureStaticStatusIcon(description: "DDCVolumeKeys")

    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "0.3.0"
    headerItem.title = "DDCVolumeKeys \(version)"
    headerItem.isEnabled = false

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(headerItem)
    menu.addItem(.separator())

    launchAtLoginMenuItem.target = self
    updateLaunchAtLoginMenuItem()
    menu.addItem(launchAtLoginMenuItem)

    menu.addItem(.separator())
    let aboutItem = NSMenuItem(
      title: localized("menu.about"),
      action: #selector(showAbout),
      keyEquivalent: ""
    )
    aboutItem.target = self
    menu.addItem(aboutItem)

    menu.addItem(.separator())
    let quitItem = NSMenuItem(
      title: localized("menu.quit"),
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)
    statusItem.menu = menu
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: "DDCVolumeKeys")
    let quitItem = NSMenuItem(
      title: localized("menu.quit"),
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    appMenu.addItem(quitItem)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: localized("menu.edit"))
    editMenu.addItem(
      NSMenuItem(
        title: localized("menu.copy"),
        action: #selector(NSText.copy(_:)),
        keyEquivalent: "c"
      )
    )
    editMenu.addItem(
      NSMenuItem(
        title: localized("menu.selectAll"),
        action: #selector(NSResponder.selectAll(_:)),
        keyEquivalent: "a"
      )
    )
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    NSApp.mainMenu = mainMenu
  }

  private func configureStateUpdates() {
    ddcService.onStateChange = { [weak self] state in
      guard let self else { return }
      switch state {
      case .checking:
        self.settings.recordRuntime(status: "checking")
        self.updateStatusTooltip(localized("status.checking"))
      case .connected:
        self.settings.recordRuntime(status: "connected")
        if self.accessibilityTrusted {
          self.updateStatusTooltip(localized("status.active"))
        } else {
          self.updateStatusTooltip(localized("status.accessibilityRequired"))
        }
      case .unavailable(let reason):
        self.settings.recordRuntime(status: "unavailable: \(reason.diagnosticCode)")
        self.updateStatusTooltip(self.localizedDescription(for: reason))
      }
    }
  }

  private func configureDisplayObservers() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.refreshDisplays() }
    )
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.refreshDisplays() }
    )
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      self?.refreshDisplays()
    }
  }

  private func refreshDisplays() {
    ddcService.discoverDisplays { [weak self] displays in
      guard let self else { return }
      self.currentDisplays = displays
      self.settings.recordRuntime(displays: displays)
      if displays.count == 1 { self.ddcService.probe() }
    }
  }

  private func startPermissionMonitoring() {
    refreshPermissionState(prompt: true)
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.refreshPermissionState(prompt: false)
    }
  }

  private func refreshPermissionState(prompt: Bool) {
    let options =
      [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
      ] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    accessibilityTrusted = trusted
    if trusted {
      _ = mediaKeyHandler.isRunning || mediaKeyHandler.start()
    } else {
      mediaKeyHandler.stop()
    }
  }

  private func configureStaticStatusIcon(description: String) {
    guard let button = statusItem?.button else { return }
    button.image = nil
    button.title = "DDC"
    button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
    button.toolTip = description
    button.setAccessibilityLabel(description)
  }

  private func updateStatusTooltip(_ description: String) {
    statusItem?.button?.toolTip = description
  }

  private func localizedDescription(for reason: DDCUnavailableReason) -> String {
    switch reason {
    case .noDisplay: localized("error.noDisplay")
    case .multipleDisplays: localized("error.multipleDisplays")
    case .noUniqueDisplay: localized("error.noUniqueDisplay")
    case .monitorUnreachable: localized("error.monitorUnreachable")
    case .volumeReadFailed: localized("error.volumeReadFailed")
    case .muteFailed: localized("error.muteFailed")
    case .communicationFailed: localized("error.communicationFailed")
    case .toolMissing: localized("error.toolMissing")
    case .timedOut: localized("error.timedOut")
    case .external(let message): message
    }
  }

  private func updateLaunchAtLoginMenuItem() {
    switch SMAppService.mainApp.status {
    case .enabled:
      launchAtLoginMenuItem.state = .on
      launchAtLoginMenuItem.title = localized("menu.launchAtLogin")
    case .requiresApproval:
      launchAtLoginMenuItem.state = .mixed
      launchAtLoginMenuItem.title = localized("menu.approveLaunchAtLogin")
    default:
      launchAtLoginMenuItem.state = .off
      launchAtLoginMenuItem.title = localized("menu.launchAtLogin")
    }
  }

  @objc private func toggleLaunchAtLogin() {
    do {
      switch SMAppService.mainApp.status {
      case .enabled: try SMAppService.mainApp.unregister()
      case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
      default: try SMAppService.mainApp.register()
      }
    } catch {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = "DDCVolumeKeys"
      alert.informativeText = localized(
        "alert.launchAtLoginFailed",
        error.localizedDescription
      )
      alert.runModal()
    }
    updateLaunchAtLoginMenuItem()
  }

  private func diagnosticsReport() -> String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let displays = currentDisplays.map(\.menuTitle).joined(separator: ", ")
    let none = localized("diagnostics.none")
    let selected = ddcService.activeDisplay?.menuTitle ?? none
    let report = """
      DDCVolumeKeys \(version)
      \(localized("diagnostics.runtime")) \(settings.runtimeStatus ?? localized("diagnostics.unknown"))
      \(localized("diagnostics.displays")) \(currentDisplays.count) (\(displays.isEmpty ? none : displays))
      \(localized("diagnostics.selected")) \(selected)
      \(localized("diagnostics.accessibilityTrusted")) \(AXIsProcessTrusted())
      \(localized("diagnostics.eventTapRunning")) \(mediaKeyHandler.isRunning)
      m1ddc: \(settings.m1ddcPath)
      \(localized("diagnostics.launchAtLogin")) \(String(describing: SMAppService.mainApp.status))
      """
    return report
  }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let diagnostics = NSAttributedString(
      string: diagnosticsReport(),
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationIcon: NSApp.applicationIconImage as Any,
      .credits: diagnostics,
    ])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.makeDiagnosticsSelectableInAboutPanel()
    }
  }

  private func makeDiagnosticsSelectableInAboutPanel() {
    guard
      let window = NSApp.keyWindow
        ?? NSApp.windows.reversed().first(where: { $0.isVisible && $0.title.contains("DDC") }),
      let contentView = window.contentView
    else { return }

    for textView in contentView.descendants(ofType: NSTextView.self)
    where textView.string.contains(localized("diagnostics.runtime")) {
      textView.isEditable = false
      textView.isSelectable = true
      window.makeFirstResponder(textView)
      return
    }

    for textField in contentView.descendants(ofType: NSTextField.self)
    where textField.stringValue.contains(localized("diagnostics.runtime")) {
      textField.isEditable = false
      textField.isSelectable = true
      window.makeFirstResponder(textField)
      return
    }
  }

  @objc private func quit() { NSApp.terminate(nil) }

  func menuWillOpen(_ menu: NSMenu) {
    updateLaunchAtLoginMenuItem()
  }
}

private extension NSView {
  func descendants<T: NSView>(ofType type: T.Type) -> [T] {
    subviews.flatMap { subview -> [T] in
      var matches = subview.descendants(ofType: type)
      if let match = subview as? T {
        matches.insert(match, at: 0)
      }
      return matches
    }
  }
}
