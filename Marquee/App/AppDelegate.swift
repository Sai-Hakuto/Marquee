import AppKit
import SwiftUI
import ObjectiveC
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var mainWindow: NSWindow?

    // Breadcrumbs for window lifecycle (Console.app / `log show --predicate 'subsystem ==
    // "com.marquee.gaming-launcher"'`). Exists because the login-item no-window failure leaves
    // zero trace otherwise: the app runs, music plays, and there is nothing to inspect after
    // the fact. Keep these — they're the only forensics for launch-context-only bugs.
    private nonisolated static let log = Logger(subsystem: "com.marquee.gaming-launcher", category: "window")

    // Local event monitor for nav-bar window drag.
    //
    // WHY NOT NSPanGestureRecognizer: NSHostingView.isFlipped == true — its
    // coordinate system has y=0 at the TOP. gesture.location(in: cv) returned
    // large y-values at the BOTTOM, so "loc.y >= height-52" was checking the
    // BOTTOM 52px, never the nav bar. This was the silent bug in v0.4.3/v0.4.4.
    //
    // WHY local monitor: Apple docs guarantee events arrive here BEFORE NSApp
    // dispatches to any window or view. We pass leftMouseDown through (so buttons
    // remain clickable), consume leftMouseDragged while moving (SwiftUI never sees
    // it), and pass leftMouseUp through (button states settle correctly).
    //
    // event.locationInWindow is always in non-flipped AppKit window coords
    // (y=0 at bottom), so "y >= cvHeight-52" correctly targets the top nav bar.
    private var dragMonitor: Any?
    private var dragOriginMouse: NSPoint?
    private var dragOriginWindow: NSPoint?
    private var isDraggingWindow = false

    // Full-screen state. The window is borderless + non-resizable, which makes AppKit's
    // native full-screen flaky, so we use a "faux" full screen: remember the windowed
    // frame, hide the menu bar + Dock, and grow the window to cover its whole display.
    private var isFauxFullScreen = false
    private var savedWindowFrame: NSRect?
    private var windowedSize: NSSize?   // the fixed windowed size; min==max is pinned to it
    private var windowedFrame: NSRect?  // the intended frame on the PRIMARY display (pos + size)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.info("didFinishLaunching, windows=\(NSApplication.shared.windows.count)")
        configureMainWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installActiveObserver()

        // Self-heal watchdog for the login-item no-window launch: on a real login (not
        // reproducible via `open -g`), SwiftUI can finish launching without ever presenting the
        // WindowGroup window — NSApp.windows stays empty, the app sits in the Dock playing music
        // with nothing on any screen. Apple's fix (.defaultLaunchBehavior(.presented)) is macOS
        // 15-only, so on a 14 target we detect and recover instead. Two shots: launch-time load
        // can make the first fire too early to be trusted alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.ensureMainWindowExists()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.ensureMainWindowExists()
        }

        // Login-item / `open -g` launches never actually become the active app, no matter how
        // many times NSApp.activate(ignoringOtherApps:) is retried — verified live with `open -g`
        // (Terminal stayed frontmost per System Events for 30+ seconds straight). The window
        // still gets ordered front and grows to fill the screen (that's plain window-server
        // z-order, independent of app activation), so couch mode LOOKS like it's working, but
        // NSApp.presentationOptions only ever visually hides the Dock/menu bar while we're
        // actually active — so they sit on top of the fullscreen window forever. The one thing
        // that was verified live to force real activation from this backgrounded state is a
        // plain `open` on our own already-running bundle (unlike `-g`, LaunchServices treats that
        // as a normal user-facing open request and brings the existing instance forward instead
        // of launching a second copy). installActiveObserver() re-applies presentationOptions the
        // moment activation actually lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.forceActivationIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.forceActivationIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) { [weak self] in
            self?.forceActivationIfNeeded()
        }

        // Silent update check — couch users should never have to think about updating, so this
        // never surfaces anything unless a newer release actually exists (a failed/offline check
        // is indistinguishable from "up to date" here; the app menu's own "Check for Updates…"
        // is the userInitiated path that reports failures).
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            Task { await AppUpdater.shared.checkForUpdates(userInitiated: false, appState: self?.appState) }
        }
    }

    private func forceActivationIfNeeded() {
        guard !NSApp.isActive else { return }
        Self.log.error("forceActivationIfNeeded: still not active — self-opening bundle to force focus")
        NSWorkspace.shared.open(Bundle.main.bundleURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Dock-icon click (and our own synthesized reopen below). Returning true lets SwiftUI
    // recreate the WindowGroup window when none exists — but that fresh window arrives
    // UNCONFIGURED (titled style, windowed, not fullscreen), so re-run the whole configure
    // pass, which also re-applies couch-mode fullscreen. Verified live against a windowless
    // login-item instance: the reopen reliably rebuilds the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.log.info("shouldHandleReopen hasVisibleWindows=\(flag)")
        if !flag && NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) == nil {
            mainWindow = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.configureMainWindow()
            }
        }
        return true
    }

    // Watchdog body: if SwiftUI never presented the main window, synthesize the one stimulus
    // proven to make it do so — a reopen Apple event to ourselves (same thing a Dock-icon click
    // sends) — then configure the new window normally. If the window exists but isn't on screen
    // (activation declined on a background launch), just re-order it front.
    private func ensureMainWindowExists() {
        let hasMain = NSApplication.shared.windows.contains { !($0 is NSPanel) }
        if !hasMain {
            Self.log.error("watchdog: no main window after launch — sending self-reopen")
            mainWindow = nil
            sendSelfReopenEvent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.configureMainWindow()
            }
        } else if let window = mainWindow, !window.isVisible, !window.isMiniaturized {
            Self.log.error("watchdog: main window exists but not visible — reasserting")
            reassertIntendedFrame()
        } else {
            Self.log.info("watchdog: main window ok")
        }
    }

    private func sendSelfReopenEvent() {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: [.noReply], timeout: 1.0)
    }

    func revealWindow() {
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Window Setup

    private func configureMainWindow(retries: Int = 20, slowRetries: Int = 150) {
        // With @NSApplicationDelegateAdaptor, applicationDidFinishLaunching can fire BEFORE SwiftUI's
        // WindowGroup has created its NSWindow — in which case windows.first is nil and, historically,
        // NONE of our window config (borderless style, fixed size, primary-display centering) got
        // applied, leaving SwiftUI's restored frame to win entirely. Retry on the main queue until the
        // window exists so our configuration is applied every launch, not just when we win the race.
        //
        // Two retry gears: the original per-runloop-turn retries cover the normal race (the window
        // lands a turn or two later), but all 20 burn off in milliseconds — under login-time load
        // that's nowhere near enough, and giving up silently is exactly the no-window failure. So
        // after the fast turns, keep polling at 0.1s for ~15s more before giving up.
        guard let window = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) else {
            if retries > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.configureMainWindow(retries: retries - 1, slowRetries: slowRetries)
                }
            } else if slowRetries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.configureMainWindow(retries: 0, slowRetries: slowRetries - 1)
                }
            } else {
                Self.log.error("configureMainWindow: gave up — no main window appeared")
            }
            return
        }
        Self.log.info("configureMainWindow: configuring window \(window.windowNumber)")
        mainWindow = window

        // If the previous window died while in faux fullscreen (login-item recovery path), reset
        // the fullscreen bookkeeping so the couch-mode tail below can re-enter cleanly on this
        // fresh window instead of half-applying to state that no longer matches any window.
        if isFauxFullScreen {
            isFauxFullScreen = false
            appState.isWindowFullScreen = false
            savedWindowFrame = nil
            NSApp.presentationOptions = []
        }
        Self.forceCanAlwaysBecomeKey(window)

        // No `.resizable`: the window is a fixed size (the user can't drag-resize it).
        // The only "bigger" state is faux full screen, driven programmatically below.
        window.styleMask = [.borderless, .fullSizeContentView, .miniaturizable]
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Match the user's saved theme (not a hardcoded color) so there's no flash of the wrong
        // background before SwiftUI's first paint — appState.currentTheme is already loaded from
        // UserDefaults by the time this runs (AppDelegate's `appState` is created at init).
        window.backgroundColor = appState.currentTheme.sceneBackground
        window.isOpaque = true
        window.hasShadow = true
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]

        // WINDOW SIZE is owned by SwiftUI via .windowResizability(.contentSize) + ContentView being
        // pinned to appState.windowedContentSize (see MarqueeApp / AppState / ContentView). That is the
        // ONLY thing that reliably keeps a fixed width: SwiftUI sizes a WindowGroup to its content's
        // ideal size, and our content fills all available width, so without the pin SwiftUI grows the
        // window to ~screen width and it runs off an ultrawide's edge. Fighting that from AppKit with
        // didResize observers just produced a runaway feedback loop (x-origin flew off to infinity → the
        // "window on a screen that doesn't exist" report). With .contentSize there is nothing to fight,
        // so no observers — the window stays freely movable.
        //
        // WINDOW POSITION is owned here: we place the window centered on the PRIMARY display and, by
        // clearing SwiftUI's persisted frame (so no saved origin is restored), it opens there every
        // launch regardless of where it was last moved.
        window.isRestorable = false
        window.setFrameAutosaveName("")
        Self.clearSwiftUIFrameState()

        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let size = appState.windowedContentSize
            let vf   = screen.visibleFrame
            let x    = vf.minX + (vf.width  - size.width)  / 2
            let y    = vf.minY + (vf.height - size.height) / 2
            windowedSize  = size
            windowedFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
            window.setFrame(windowedFrame!, display: false)
            lockWindowSize(to: size)
        }

        // One-shot, a moment after launch, to guarantee the window is centered on the main display
        // even if SwiftUI nudged the origin during its initial content-size layout. Not an observer,
        // so it can't loop; skipped if the user has already moved the window. Runs a second time
        // later because on a login/background launch SwiftUI's initial layout can land well after
        // the first shot (and after the couch-mode fullscreen grow), stomping the frame back to
        // windowed size with nothing left to correct it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.reassertIntendedFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.reassertIntendedFrame()
        }

        window.makeKeyAndOrderFront(nil)
        installDragMonitor()
        installOcclusionObserver(for: window)
        installCloseLogger(for: window)

        // Couch mode: open straight into faux full screen. Deferred one turn so SwiftUI's
        // content has mounted and can pick up the lifted size pin (isWindowFullScreen) — the
        // splash overlay is opaque and covers the grow, so nothing visibly "jumps."
        if appState.startInFullScreen {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFauxFullScreen else { return }
                self.toggleFullScreen()
            }
        }
    }

    // Keeps AppState.windowVisible in sync with the window's real on-screen state — fires on
    // miniaturize/deminiaturize, full coverage by another window, and Space/display switches.
    // See AppState.windowVisible for why this exists (gating MotionOverlay's continuous 30fps
    // Canvas so it stops costing anything the instant the window isn't actually visible).
    private var occlusionObserver: (any NSObjectProtocol)?
    private var closeObserver: (any NSObjectProtocol)?

    // AppKit silently clears NSApp.presentationOptions back to [] whenever the app resigns
    // active — Apple's docs say the option only holds "while your app is active" — and never
    // restores it on our behalf. That's invisible during normal interactive use (toggling full
    // screen already implies we're frontmost), but on a login-item autostart the couch-mode
    // toggleFullScreen() can fire before activation has actually landed, or something can steal
    // active status in the gap before the window settles: the window still grows to cover the
    // whole screen (reassertIntendedFrame corrects the FRAME), but presentationOptions comes
    // back 0 and the Dock renders on top of it with nothing left to ever re-hide it. Re-assert
    // on every reactivation while in faux full screen so this can't get stuck.
    private func installActiveObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isFauxFullScreen else { return }
                NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            }
        }
    }

    private func installOcclusionObserver(for window: NSWindow) {
        // configureMainWindow can run more than once (login-item window recovery) — replace,
        // never stack, per-window observers.
        if let old = occlusionObserver { NotificationCenter.default.removeObserver(old) }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let window else { return }
                self?.appState.windowVisible = window.occlusionState.contains(.visible)
            }
        }
    }

    // Forensics only: the login-item no-window failure left an app with NSApp.windows == [] and
    // no way to tell, after the fact, whether the window was closed or never created. If the
    // main window ever closes outside a normal quit, this leaves the smoking gun (with call
    // stack) in the unified log.
    private func installCloseLogger(for window: NSWindow) {
        if let old = closeObserver { NotificationCenter.default.removeObserver(old) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            let stack = Thread.callStackSymbols.joined(separator: "\n")
            Self.log.error("main window willClose\n\(stack, privacy: .public)")
        }
    }

    // The borderless styleMask above makes AppKit's DEFAULT canBecomeKeyWindow return false —
    // SwiftUI's private window class only overrides that default some of the time (confirmed via
    // MARQUEE_DEBUG_FOCUS logging: after a Fix Cover/Banner NSPanel closes, `window.canBecomeKey`
    // reads false and stays false, so no amount of makeKeyAndOrderFront ever re-keys it — the
    // search field installs a real field editor but the window itself can never host it as key).
    // This patches the METHOD IMPLEMENTATION of canBecomeKeyWindow on the window's own dynamic
    // class so it unconditionally returns true — NOT object_setClass, which corrupts SwiftUI's
    // window bookkeeping and renders a blank window. Swizzling the
    // implementation in place leaves the object's class/identity untouched; SwiftUI keeps
    // managing the window exactly as before, it just always answers "yes" when AppKit asks if it
    // can become key.
    private static func forceCanAlwaysBecomeKey(_ window: NSWindow) {
        let cls: AnyClass = type(of: window)
        let selector = NSSelectorFromString("canBecomeKeyWindow")
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        let newImpl: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(newImpl))
    }

    // Remove SwiftUI's persisted WindowGroup frame(s) so nothing gets restored over our frame. The
    // key is "NSWindow Frame <giant modifier-chain type>-…"; the chain type changes whenever the
    // view's environment/modifiers change, so old builds leave several stale keys behind — clear them all.
    nonisolated static func clearSwiftUIFrameState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame") {
            defaults.removeObject(forKey: key)
        }
    }

    // Pin the window to an exact size so nothing (SwiftUI restore, zoom, etc.) can resize it. Note:
    // min/maxSize constrain resizing only — the window remains freely movable.
    private func lockWindowSize(to size: NSSize) {
        guard let window = mainWindow else { return }
        window.minSize = size
        window.maxSize = size
    }

    // Force the window back to its intended frame. Called only as one-shots a moment after launch
    // (see configureMainWindow) — never on an ongoing notification, so it cannot fight the user or
    // loop. Fullscreen-aware: if couch mode already grew the window to cover its display, the
    // intended frame is that display's full frame, not the windowed one — the pre-v0.34.1 version
    // no-op'd here, which meant a startInFullScreen launch whose frame SwiftUI stomped back to
    // windowed (the login-item race) was never corrected. Also re-orders the window front, since a
    // login-item launch isn't user-initiated and macOS may have declined our activation.
    private func reassertIntendedFrame() {
        guard !isDraggingWindow, let window = mainWindow else { return }
        if isFauxFullScreen {
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            if let screen = window.screen ?? NSScreen.main, window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }
        } else if let frame = windowedFrame, window.frame != frame {
            window.setFrame(frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Full Screen (faux)

    // Toggle between the fixed windowed size and a full-display cover. We don't use
    // AppKit's native full screen because borderless, non-resizable windows enter it
    // unreliably; growing the window to its screen's full frame (with the menu bar/Dock
    // auto-hidden) gives a clean full-screen feel and restores exactly on exit.
    func toggleFullScreen() {
        guard let window = mainWindow else { return }

        if isFauxFullScreen {
            NSApp.presentationOptions = []
            // Re-pin the content to the windowed size FIRST (SwiftUI .contentSize will shrink the
            // window back), then restore the exact saved frame for position + re-lock the size.
            appState.isWindowFullScreen = false
            if let frame = savedWindowFrame {
                window.setFrame(frame, display: true, animate: true)
            }
            if let size = windowedSize { lockWindowSize(to: size) }
            isFauxFullScreen = false
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            savedWindowFrame = window.frame
            // Lift the content-size pin so the content can fill the display, and the min/max lock so
            // the window can grow. Then grow the window to the whole display.
            appState.isWindowFullScreen = true
            window.minSize = NSSize(width: 200, height: 200)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.setFrame(screen.frame, display: true, animate: true)
            isFauxFullScreen = true
        }
    }

    // Send the window to the next connected display (wraps around) — the "play it on the TV"
    // affordance for an AirPlay/extended display, reachable from the pause menu so it works in
    // full screen with a controller. In faux full screen the window re-covers the new display's
    // whole frame; windowed, it re-centers there (and that becomes the remembered frame).
    func moveToNextDisplay() {
        guard let window = mainWindow else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let currentIdx = screens.firstIndex(where: { $0 == window.screen }) ?? 0
        let next = screens[(currentIdx + 1) % screens.count]

        if isFauxFullScreen {
            window.setFrame(next.frame, display: true, animate: true)
        } else {
            let vf   = next.visibleFrame
            let size = window.frame.size
            let frame = NSRect(x: vf.minX + (vf.width - size.width) / 2,
                               y: vf.minY + (vf.height - size.height) / 2,
                               width: size.width, height: size.height)
            window.setFrame(frame, display: true, animate: true)
            windowedFrame = frame
        }
    }

    // MARK: - Game Session (auto-minimize while a game is running)

    // Miniaturize to the Dock when a game takes over. We keep the window's frame and faux
    // full-screen state untouched, so deminiaturize returns the user to exactly what they had
    // (windowed or full screen). presentationOptions only apply while we're the active app, so
    // there's nothing to clear while the game is foreground.
    func minimizeForGameSession() {
        mainWindow?.miniaturize(nil)
    }

    func restoreFromGameSession() {
        mainWindow?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Drag Monitor

    private func installDragMonitor() {
        // Install once — configureMainWindow can re-run (login-item window recovery) and the
        // monitor reads `mainWindow` dynamically, so one monitor serves every window generation.
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseEvent(event) ?? event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = mainWindow else { return event }

        switch event.type {

        case .leftMouseDown:
            let loc      = event.locationInWindow   // y=0 at bottom (AppKit, not SwiftUI)
            let cvHeight = window.contentView?.bounds.height ?? window.frame.height
            // No window-dragging while full-screen — the window must stay pinned.
            if !isFauxFullScreen && loc.y >= cvHeight - 52 {
                dragOriginMouse  = NSEvent.mouseLocation   // screen coords
                dragOriginWindow = window.frame.origin
                isDraggingWindow = false
            } else {
                dragOriginMouse  = nil
                dragOriginWindow = nil
            }
            return event   // always pass through — buttons need mouseDown

        case .leftMouseDragged:
            guard let start  = dragOriginMouse,
                  let origin = dragOriginWindow else { return event }
            let cur = NSEvent.mouseLocation
            let dx  = cur.x - start.x
            let dy  = cur.y - start.y
            // 5 pt dead zone avoids accidental drags when clicking nav bar buttons
            if !isDraggingWindow && (dx * dx + dy * dy) < 25 { return event }
            isDraggingWindow = true
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
            return nil   // consume — hide drag from SwiftUI while window moves

        case .leftMouseUp:
            isDraggingWindow = false
            dragOriginMouse  = nil
            dragOriginWindow = nil
            return event   // pass through — lets buttons finish their action

        default:
            return event
        }
    }
}
