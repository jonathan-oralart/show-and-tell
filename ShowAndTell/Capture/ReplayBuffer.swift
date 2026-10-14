import AppKit
import ScreenCaptureKit
import VideoToolbox

/// Keeps the last 30 seconds of every display while it's on, compressed in memory by the hardware encoder, so a bug
/// can be looked at after it happened. Nothing is written to disk until it's saved. A screen that isn't changing
/// sends no frames, so it costs next to nothing. Show & Tell's own windows aren't left out: the overlay and toasts
/// only appear after a save.
@Observable
final class ReplayBuffer {
    static let shared = ReplayBuffer()
    static let length: TimeInterval = 30
    private static let defaultsKey = "keepsReplay"

    /// The setting: off by default, since macOS shows the screen recording indicator the whole time it's on.
    var isOn = UserDefaults.standard.bool(forKey: defaultsKey) {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.defaultsKey)
            restart()
        }
    }

    @ObservationIgnored private var displays: [CGDirectDisplayID: DisplayReplay] = [:]
    @ObservationIgnored private var clicks: ClickLog?
    /// The latest restart; each waits for the one before, so streams are never started twice.
    @ObservationIgnored private var restarting: Task<Void, Never>?
    @ObservationIgnored private var retrying: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { ReplayBuffer.shared.restart() }
        }
    }

    /// Starts or stops the streams to match the setting, one per display, from scratch.
    func restart() {
        let previous = restarting
        restarting = Task {
            await previous?.value
            await stopAll()
            guard isOn, Permission.screenRecording.isGranted else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                // While the screen is locked there are no displays, and the streams stopped when it locked.
                guard !content.displays.isEmpty else { throw NotRecording() }
                clicks = ClickLog(keeps: Self.length * 2)
                for display in content.displays {
                    let replay = DisplayReplay(display: display, length: Self.length) { error in
                        Task { @MainActor in ReplayBuffer.shared.streamStopped(error) }
                    }
                    try await replay.start()
                    displays[display.displayID] = replay
                }
            } catch {
                retryLater()
            }
        }
    }

    /// Writes the last 30 seconds of the front window's display to a temporary movie.
    func save() async throws -> ScreenRecording {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let (display, front) = try ScreenRecording.frontDisplay(in: content)
        guard let replay = displays[display.displayID] else { throw NotRecording() }
        let url = FileManager.default.temporaryDirectory.appending(path: "ShowAndTell-\(UUID().uuidString).mov")
        let start = try await replay.write(to: url, until: now)
        var recording = ScreenRecording(url: url, display: display, front: front)
        recording.clicks = clicks?.clicks(on: display.frame, from: start.seconds) ?? []
        return recording
    }

    private func stopAll() async {
        let stopping = displays.values
        displays = [:]
        clicks?.stop()
        clicks = nil
        for replay in stopping { await replay.stop() }
    }

    /// Stopping from the screen recording indicator in the menu bar turns it off; anything else is retried.
    private func streamStopped(_ error: Error) {
        if (error as NSError).code == SCStreamError.userStopped.rawValue {
            isOn = false
        } else {
            retryLater()
        }
    }

    /// One retry at a time, however many streams stopped.
    private func retryLater() {
        retrying?.cancel()
        retrying = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            restart()
        }
    }
}

/// One display's stream, encoder and the compressed frames kept from it. ScreenCaptureKit and the encoder call it on
/// their own threads.
nonisolated private final class DisplayReplay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let framesPerSecond: Int32 = 30
    /// A keyframe at least this often, so the kept frames can start no more than this before the 30 seconds.
    private static let keyframeInterval: Double = 2
    private static let bitRate = 12_000_000

    private let length: Double
    private let onStop: @Sendable (Error) -> Void
    private let filter: SCContentFilter
    private let config = SCStreamConfiguration()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Show & Tell replay")
    private var encoder: VTCompressionSession?
    /// Only touched on `queue`.
    private var lastKeyframe: Double = -.infinity

    private let lock = NSLock()
    /// Encoded frames from oldest to newest, in groups that each start with a keyframe.
    private var groups: [[CMSampleBuffer]] = []

    init(display: SCDisplay, length: Double, onStop: @escaping @Sendable (Error) -> Void) {
        self.length = length
        self.onStop = onStop
        filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        // What the encoder takes, so the frames needn't be converted.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        super.init()
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(config.width), height: Int32(config.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTSessionSetProperties(session, propertyDictionary: [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
                kVTCompressionPropertyKey_AverageBitRate: Self.bitRate,
                kVTCompressionPropertyKey_ExpectedFrameRate: Self.framesPerSecond,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: Self.keyframeInterval,
            ] as CFDictionary)
            VTCompressionSessionPrepareToEncodeFrames(session)
        }
        encoder = session
    }

    func start() async throws {
        guard encoder != nil else { throw NotRecording() }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        queue.sync {
            if let encoder {
                VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(encoder)
            }
            encoder = nil
        }
        lock.withLock { groups = [] }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Idle frames, sent when nothing changed, carry no picture.
        guard type == .screen, let encoder, let image = sampleBuffer.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete
        else { return }
        let time = sampleBuffer.presentationTimeStamp
        // The encoder's own interval counts frames, and a still screen sends none, so keyframes are asked for by time.
        var properties: CFDictionary?
        if time.seconds - lastKeyframe >= Self.keyframeInterval {
            lastKeyframe = time.seconds
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            keep(encoded)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    private func keep(_ frame: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        lock.withLock {
            if isKeyframe || groups.isEmpty {
                groups.append([frame])
            } else {
                groups[groups.count - 1].append(frame)
            }
            dropOld(before: frame.presentationTimeStamp.seconds - length)
        }
    }

    /// Drops a group once the next one starts before `cutoff`, so the frame on screen at the cutoff is always kept,
    /// however long the screen has been still.
    private func dropOld(before cutoff: Double) {
        while groups.count > 1, let next = groups[1].first, next.presentationTimeStamp.seconds <= cutoff {
            groups.removeFirst()
        }
    }

    /// Writes the kept frames up to `end` to a movie, the last one lasting until `end`. Returns the time the movie
    /// starts at, on the system uptime clock.
    @concurrent
    func write(to url: URL, until end: CMTime) async throws -> CMTime {
        let frames = lock.withLock {
            dropOld(before: end.seconds - length)
            return groups.flatMap { $0 }
        }
        guard let first = frames.first, let format = first.formatDescription else { throw EmptyRecording() }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Already encoded: copied into the movie as they are.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EmptyRecording() }
        let start = first.presentationTimeStamp
        writer.startSession(atSourceTime: start)
        // The last frame is still on screen; a frame at least.
        let last = CMTimeMaximum(end, frames[frames.count - 1].presentationTimeStamp + CMTime(value: 1, timescale: Self.framesPerSecond))
        for (index, frame) in frames.enumerated() {
            // Each frame lasts until the next, as the screen didn't change in between.
            let next = index + 1 < frames.count ? frames[index + 1].presentationTimeStamp : last
            var timing = CMSampleTimingInfo(duration: next - frame.presentationTimeStamp,
                                            presentationTimeStamp: frame.presentationTimeStamp, decodeTimeStamp: .invalid)
            var timed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &timed)
            guard let timed else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard input.append(timed) else { throw writer.error ?? EmptyRecording() }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EmptyRecording() }
        return start
    }
}
