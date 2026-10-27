import Foundation

/// Tells other apps when solo starts and ends, for Frames' "while dictating"
/// overlay: distributed notifications, with nothing in them (so they'd still
/// work sandboxed), plus an answer when an app asks, in case it started
/// mid-solo.
enum SoloBroadcast {
    static let started = Notification.Name("dev.imathis.vaux.soloStarted")
    static let ended = Notification.Name("dev.imathis.vaux.soloEnded")
    static let request = Notification.Name("dev.imathis.vaux.soloStateRequest")

    static func post(_ active: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            active ? started : ended, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
