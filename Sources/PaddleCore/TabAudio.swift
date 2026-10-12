import Foundation

/// WebKit's `_WKMediaMutedState` bits, for the private `_setPageMuted:` / `_mediaMutedState`.
public enum MediaMutedState {
    public static let audio: UInt64 = 1 << 0
    public static let captureDevices: UInt64 = 1 << 1
    public static let screenCapture: UInt64 = 1 << 2

    /// `current` with only the audio bit changed, so a muted camera or microphone stays muted.
    public static func settingAudio(_ muted: Bool, in current: UInt64) -> UInt64 {
        muted ? current | audio : current & ~audio
    }
}

public enum MediaActivity {
    /// Whether a tab counts as busy for the sleep policy: using the camera or mic, or making sound (WebKit's
    /// `_isPlayingAudio`; muting the tab in Paddle is not an input). Video without sound doesn't count, as in
    /// Chrome: pages autoplay muted previews and ads, which would otherwise keep a background tab awake for good.
    /// `playbackIsPlaying` (any media playing, sound or not) decides only where `_isPlayingAudio` can't be observed
    /// (`audioIsObservable` false).
    public static func isBusy(isCapturing: Bool, isPlayingAudio: Bool, playbackIsPlaying: Bool, audioIsObservable: Bool) -> Bool {
        if isCapturing || isPlayingAudio { return true }
        return !audioIsObservable && playbackIsPlaying
    }
}

/// What the tab strip shows for a tab's sound.
public enum AudioIndicator: Sendable, Equatable {
    case none
    case playing
    case muted

    /// A muted tab keeps its indicator even when silent, so it can be unmuted from the tab strip.
    public init(isPlayingAudio: Bool, isMuted: Bool) {
        self = isMuted ? .muted : (isPlayingAudio ? .playing : .none)
    }
}
