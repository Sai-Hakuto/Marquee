import Foundation
import Network
import Observation
import os

// Live connectivity signal (NWPathMonitor). Two faces for two audiences:
//  - `NetworkMonitor.shared.isOnline` — @Observable, main-actor, for SwiftUI (the offline badge,
//    Fix Cover's notice) so views re-render on transitions.
//  - `NetworkMonitor.isOnlineNow` — nonisolated + lock-backed, for the fetch actors
//    (ArtFetcher/GameDetailsFetcher), which must consult it without hopping to the main actor.
// `onReconnect` fires once per offline→online transition — wired in MarqueeApp to re-try art
// that couldn't be fetched and to invalidate detail lookups that missed while offline.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private nonisolated static let onlineState = OSAllocatedUnfairLock(initialState: true)
    nonisolated static var isOnlineNow: Bool { onlineState.withLock { $0 } }

    private(set) var isOnline: Bool = true
    var onReconnect: (() -> Void)? = nil

    private let monitor = NWPathMonitor()

    private init() {
        // Test hook: MARQUEE_SIMULATE_OFFLINE=N starts the app "offline" and flips to online
        // (firing onReconnect) after N seconds — the only way to exercise the offline paths on
        // a dev machine whose network can't actually be dropped (remote session). Replaces the
        // real monitor entirely for the run; N=0 stays offline for the whole session.
        if let sim = ProcessInfo.processInfo.environment["MARQUEE_SIMULATE_OFFLINE"] {
            Self.onlineState.withLock { $0 = false }
            isOnline = false
            if let secs = TimeInterval(sim), secs > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    Self.onlineState.withLock { $0 = true }
                    self?.isOnline = true
                    self?.onReconnect?()
                }
            }
            return
        }

        monitor.pathUpdateHandler = { path in
            let nowOnline = path.status == .satisfied
            Self.onlineState.withLock { $0 = nowOnline }
            Task { @MainActor in
                let wasOnline = Self.shared.isOnline
                Self.shared.isOnline = nowOnline
                if !wasOnline && nowOnline { Self.shared.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.marquee.network-monitor"))
    }
}

extension URLSession {
    // Every art/metadata/search request goes through this instead of URLSession.shared: its
    // default 60s request timeout means one flaky connection (captive portal, sleeping router)
    // can hang the serial startup art loop for minutes. Nothing Marquee fetches is worth
    // waiting more than a few seconds for — fail fast and fall back to cache/placeholders.
    static let marquee: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()
}
