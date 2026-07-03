import Foundation

// Entry point. We deliberately use a top-level main.swift instead of `@main` on MarqueeApp so this
// runs BEFORE SwiftUI's App bootstrap. SwiftUI reads and caches its persisted WindowGroup frame very
// early in the App lifecycle — earlier than MarqueeApp.init() — and then re-imposes that frame on the
// window for several seconds, snapping back over anything AppDelegate sets (a stale over-wide width, an
// off-screen origin). Nothing inside the app can out-fight that once SwiftUI has cached the frame. The
// only reliable cure is to delete the persisted frame BEFORE SwiftUI ever reads it, which this does.
AppDelegate.clearSwiftUIFrameState()

MarqueeApp.main()
