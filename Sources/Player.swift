import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum SleepMode: Equatable {
    case off
    case minutes(Int)
    case endOfChapter
}

/// Plays a book as one continuous timeline, even when it is split over many files.
///
/// Built for instant response:
/// - The last book is loaded (but not started) at launch, so the first press of play just starts it.
/// - The UI updates at once on play/pause/skip; the audio catches up in the background.
/// - The next file is prepared ahead so moving between files doesn't stall.
@MainActor @Observable
final class Player {
    static let back: Double = 15
    static let forward: Double = 30

    private(set) var book: Book?
    private(set) var isPlaying = false
    /// Seconds from the start of the book.
    private(set) var time: Double = 0
    private(set) var sleepMode: SleepMode = .off
    private(set) var sleepRemaining: Double = 0

    var chapterIndex: Int { book?.chapterIndex(at: time) ?? 0 }
    var chapter: Chapter? {
        guard let book, !book.chapters.isEmpty else { return nil }
        return book.chapters[min(chapterIndex, book.chapters.count - 1)]
    }

    private let library: Library
    private let player = AVPlayer()
    @ObservationIgnored private var trackIndex = -1
    @ObservationIgnored private var preloaded: (index: Int, item: AVPlayerItem)?
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var seekIssued = Date.distantPast
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var lastChapterIndex = -1
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?

    init(library: Library) {
        self.library = library
        // Local files never need buffering, so don't let AVPlayer wait before starting.
        player.automaticallyWaitsToMinimizeStalling = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        observe()
        setUpRemoteCommands()
        if let last = library.lastPlayed { load(last, autoplay: false) }
    }

    // MARK: - Controls

    func load(_ book: Book, autoplay: Bool) {
        if self.book?.id == book.id {
            if autoplay { play() }
            return
        }
        if self.book != nil { savePosition() }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        trackIndex = -1
        preloaded = nil
        self.book = book
        artwork = CoverCache.image(book.id, thumb: false).map(Self.makeArtwork)
        let start = book.isFinished ? 0 : book.position
        lastChapterIndex = book.chapterIndex(at: start)
        seek(to: start)
        if autoplay { play() } else { updateNowPlaying() }
    }

    func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        book = nil
        isPlaying = false
        trackIndex = -1
        preloaded = nil
        setSleep(.off)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func play() {
        guard let book else { return }
        if time >= book.duration - 1 { seek(to: 0) }
        if !sessionActive {
            sessionActive = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
        }
        player.play()
        isPlaying = true
        lastTick = Date()
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func skip(by seconds: Double) { seek(to: time + seconds) }

    func seek(to target: Double) {
        guard let book, !book.tracks.isEmpty else { return }
        let t = min(max(0, target), max(0, book.duration - 0.25))
        time = t // update the UI right away

        let index = book.trackIndex(at: t)
        if index != trackIndex {
            let item: AVPlayerItem
            if let preloaded, preloaded.index == index {
                item = preloaded.item
            } else {
                item = makeItem(book, index)
            }
            preloaded = nil
            player.replaceCurrentItem(with: item)
            trackIndex = index
            preloadNext()
        }

        seekTarget = t
        seekIssued = Date()
        let local = t - book.tracks[index].start
        player.seek(to: CMTime(seconds: local, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)

        lastChapterIndex = book.chapterIndex(at: t)
        updateNowPlaying()
        savePosition()
    }

    func nextChapter() {
        guard let book else { return }
        let next = chapterIndex + 1
        if next < book.chapters.count { seek(to: book.chapters[next].start) }
    }

    /// Back to the start of this chapter, or to the previous one if already near its start.
    func previousChapter() {
        guard let book, let chapter else { return }
        if time - chapter.start > 3 || chapterIndex == 0 {
            seek(to: chapter.start)
        } else {
            seek(to: book.chapters[chapterIndex - 1].start)
        }
    }

    func setSleep(_ mode: SleepMode) {
        sleepMode = mode
        player.volume = 1
        if case .minutes(let m) = mode { sleepRemaining = Double(m * 60) } else { sleepRemaining = 0 }
    }

    func savePosition() {
        guard let book else { return }
        library.updatePosition(book.id, time)
        lastSave = Date()
    }

    // MARK: - Internals

    private func makeItem(_ book: Book, _ index: Int) -> AVPlayerItem {
        let url = Storage.fileURL(book.id, book.tracks[index].fileName)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return AVPlayerItem(asset: asset)
    }

    private func preloadNext() {
        guard let book, trackIndex + 1 < book.tracks.count else {
            preloaded = nil
            return
        }
        let item = makeItem(book, trackIndex + 1)
        let asset = item.asset
        Task { _ = try? await asset.load(.isPlayable, .duration) }
        preloaded = (trackIndex + 1, item)
    }

    private func tick(local: Double) {
        guard let book, trackIndex >= 0, trackIndex < book.tracks.count, local.isFinite else { return }
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastTick), 1)
        lastTick = now

        let reported = book.tracks[trackIndex].start + local
        if let target = seekTarget {
            // Ignore stale times from before a seek landed, so the UI never jumps back.
            if abs(reported - target) < 1.5 || now.timeIntervalSince(seekIssued) > 3 {
                seekTarget = nil
            } else {
                return
            }
        }
        time = min(reported, book.duration)
        guard isPlaying else { return }

        switch sleepMode {
        case .off:
            break
        case .minutes:
            sleepRemaining -= elapsed
            if sleepRemaining <= 0 {
                pause()
                setSleep(.off)
                return
            }
            player.volume = Float(min(1, sleepRemaining / 10)) // fade out over the last 10 seconds
        case .endOfChapter:
            if let chapter, chapter.end < book.duration - 0.5, chapter.end - time <= 0.3 {
                pause()
                setSleep(.off)
                return
            }
        }

        let ci = book.chapterIndex(at: time)
        if ci != lastChapterIndex {
            lastChapterIndex = ci
            updateNowPlaying()
        }
        if now.timeIntervalSince(lastSave) > 5 { savePosition() }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let book, let item, item === player.currentItem else { return }
        let next = trackIndex + 1
        if next < book.tracks.count {
            let stopHere = sleepMode == .endOfChapter
            seek(to: book.tracks[next].start)
            if stopHere {
                pause()
                setSleep(.off)
            } else if isPlaying {
                player.play()
            }
        } else {
            player.pause()
            isPlaying = false
            time = book.duration
            if sleepMode != .off { setSleep(.off) }
            savePosition()
            updateNowPlaying()
        }
    }

    private func observe() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(local: seconds) }
        }

        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        })

        // Phone calls, Siri, other apps taking over the audio.
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            MainActor.assumeIsolated { self?.interrupted(began: type == .began, shouldResume: shouldResume) }
        })

        // Headphones unplugged / Bluetooth disconnected: pause instead of playing out loud.
        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                if self?.isPlaying == true { self?.pause() }
            }
        })
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            sessionActive = false
            resumeAfterInterruption = isPlaying
            if isPlaying {
                isPlaying = false
                savePosition()
                updateNowPlaying()
            }
        } else if shouldResume && resumeAfterInterruption {
            resumeAfterInterruption = false
            play()
        }
    }

    // MARK: - Lock screen, Control Center, headphones

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.forward)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: Player.forward) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.back)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -Player.back) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let book else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPMediaItemPropertyPlaybackDuration: book.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let chapter { info[MPMediaItemPropertyAlbumTitle] = chapter.title }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: iOS calls the artwork closure from a background thread.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
