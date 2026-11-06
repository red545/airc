// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

AppPaths.prepare(LaunchOptions.current)
CrashLog.install()

#if canImport(AircCore)
if LaunchOptions.current.engine == "chromium" {
    // Chromium runs the app: AircEngine.run owns the message loop and installs its NSApplication subclass, so
    // NSApplication must not exist before it. The app starts in engineDidStart.
    // The key to saved passwords and cookies: made this build's own once, so Chromium's read never asks (SafeStorageKey.swift).
    SafeStorageKey.prepareForEngine(LaunchOptions.current)
    // Links from other apps: AppKit only hands GURL Apple events to a delegate it had when it finished launching, and
    // this one comes later (URLEvents.swift).
    let before = URLEventHandler.shared.install()
    var delegate: AppDelegate?
    let status = ChromiumRuntime.run(arguments: AppPaths.chromiumArguments(LaunchOptions.current)) {
        CrashLog.install() // Chromium startup can install its own signal handlers.
        delegate = AppDelegate()
        NSApp.delegate = delegate
        NSApp.setActivationPolicy(.regular)
        delegate?.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        LinkLog.write("launch: GURL handler before the engine \(before), at engine start \(URLEventHandler.shared.install())")
        if let delegate { URLEventHandler.shared.attach(delegate) }
    }
    delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    exit(status)
}
#endif

if LaunchOptions.current.engine == "chromium" {
    FileHandle.standardError.write("Airc: this build has no Chromium engine (build with CHROMIUM_OUT set); using WebKit.\n".data(using: .utf8)!)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
