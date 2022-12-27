import AVFoundation

#if os(iOS) || os(macOS)
extension AVCaptureSession.Preset {
    static let `default`: AVCaptureSession.Preset = .hd1280x720
}
#endif

protocol IOMixerDelegate: AnyObject {
    func mixer(_ mixer: IOMixer, didOutput audio: AVAudioPCMBuffer, presentationTimeStamp: CMTime)
    func mixer(_ mixer: IOMixer, didOutput video: CMSampleBuffer)
}

/// An object that mixies audio and video for streaming.
public class IOMixer {
    /// The default fps for an IOMixer, value is 30.
    public static let defaultFrameRate: Float64 = 30

    enum MediaSync {
        case video
        case passthrough
    }
    
    
    public init() {
        
    }

    #if os(iOS) || os(macOS)
    var isMultitaskingCameraAccessEnabled = true

    var isMultiCamSessionEnabled = false {
        didSet {
            guard oldValue != isMultiCamSessionEnabled else {
                return
            }
            #if os(iOS)
            session = makeSession()
            #endif
        }
    }

    var sessionPreset: AVCaptureSession.Preset = .default {
        didSet {
            guard sessionPreset != oldValue, session.canSetSessionPreset(sessionPreset) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = sessionPreset
            session.commitConfiguration()
        }
    }

    /// The capture session instance.
    public internal(set) lazy var session: AVCaptureSession = makeSession() {
        didSet {
            if oldValue.isRunning {
                removeSessionObservers(oldValue)
                oldValue.stopRunning()
            }
            audioIO.capture?.detachSession(oldValue)
            videoIO.capture?.detachSession(oldValue)
            if session.canSetSessionPreset(sessionPreset) {
                session.sessionPreset = sessionPreset
            }
            audioIO.capture?.attachSession(session)
            videoIO.capture?.attachSession(session)
        }
    }
    #endif
    /// The recorder instance.
    public lazy var recorder = IORecorder()

    /// Specifies the drawable object.
    public weak var drawable: NetStreamDrawable? {
        get {
            videoIO.drawable
        }
        set {
            videoIO.drawable = newValue
        }
    }

    var mediaSync = MediaSync.passthrough

    weak var delegate: IOMixerDelegate?

    lazy var audioIO: IOAudioUnit = {
        var audioIO = IOAudioUnit()
        audioIO.mixer = self
        return audioIO
    }()

    lazy var videoIO: IOVideoUnit = {
        var videoIO = IOVideoUnit()
        videoIO.mixer = self
        return videoIO
    }()

    lazy var mediaLink: MediaLink = {
        var mediaLink = MediaLink()
        mediaLink.delegate = self
        return mediaLink
    }()

    private var audioTimeStamp = CMTime.zero
    private var videoTimeStamp = CMTime.zero

    func useSampleBuffer(sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) -> Bool {
        switch mediaSync {
        case .video:
            if mediaType == .audio {
                return !videoTimeStamp.seconds.isZero && videoTimeStamp.seconds <= sampleBuffer.presentationTimeStamp.seconds
            }
            if videoTimeStamp == CMTime.zero {
                videoTimeStamp = sampleBuffer.presentationTimeStamp
            }
            return true
        default:
            return true
        }
    }

    #if os(iOS)
    private func makeSession() -> AVCaptureSession {
        let session: AVCaptureSession
        if isMultiCamSessionEnabled, #available(iOS 13.0, *) {
            session = AVCaptureMultiCamSession()
        } else {
            session = AVCaptureSession()
        }
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        if #available(iOS 16.0, *), isMultitaskingCameraAccessEnabled, session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        return session
    }
    #endif

    #if os(macOS)
    private func makeSession() -> AVCaptureSession {
        let session = AVCaptureSession()
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        return session
    }
    #endif

    #if os(iOS) || os(macOS)
    deinit {
        if session.isRunning {
            session.stopRunning()
        }
    }
    #endif
}

extension IOMixer: IOUnitEncoding {
    /// Starts encoding for video and audio data.
    public func startEncoding(_ delegate: AVCodecDelegate) {
        videoIO.startEncoding(delegate)
        audioIO.startEncoding(delegate)
    }

    /// Stop encoding.
    public func stopEncoding() {
        videoTimeStamp = CMTime.zero
        audioTimeStamp = CMTime.zero
        videoIO.stopEncoding()
        audioIO.stopEncoding()
    }
}

extension IOMixer: IOUnitDecoding {
    /// Starts decoding for video and audio data.
    public func startDecoding(_ audioEngine: AVAudioEngine) {
        mediaLink.startRunning()
        audioIO.startDecoding(audioEngine)
        videoIO.startDecoding(audioEngine)
    }

    /// Stop decoding.
    public func stopDecoding() {
        mediaLink.stopRunning()
        audioIO.stopDecoding()
        videoIO.stopDecoding()
    }
}

extension IOMixer: MediaLinkDelegate {
    // MARK: MediaLinkDelegate
    func mediaLink(_ mediaLink: MediaLink, dequeue sampleBuffer: CMSampleBuffer) {
        videoIO.codec.inputBuffer(sampleBuffer)
    }

    func mediaLink(_ mediaLink: MediaLink, didBufferingChanged: Bool) {
        logger.info(didBufferingChanged)
    }
}

#if os(iOS) || os(macOS)
extension IOMixer: Running {
    // MARK: Running
    public var isRunning: Atomic<Bool> {
        .init(session.isRunning)
    }

    public func startRunning() {
        guard !isRunning.value else {
            return
        }
        addSessionObservers(session)
        session.startRunning()
    }

    public func stopRunning() {
        guard isRunning.value else {
            return
        }
        removeSessionObservers(session)
        session.stopRunning()
    }

    private func addSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        #if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: session)
        #endif
    }

    private func removeSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        #if os(iOS)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: session)
        #endif
    }

    @objc
    private func sessionRuntimeError(_ notification: NSNotification) {
        guard
            let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        let error = AVError(_nsError: errorValue)
        switch error.code {
        case .unsupportedDeviceActiveFormat:
            #if os(iOS)
            let isMultiCamSupported: Bool
            if #available(iOS 13.0, *) {
                isMultiCamSupported = session is AVCaptureMultiCamSession
            } else {
                isMultiCamSupported = false
            }
            #else
            let isMultiCamSupported = true
            #endif
            guard let device = error.device,
                  let format = device.videoFormat(
                    width: sessionPreset.width ?? videoIO.codec.width,
                    height: sessionPreset.height ?? videoIO.codec.height,
                    isMultiCamSupported: isMultiCamSupported
                  ), device.activeFormat != format else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
                session.startRunning()
            } catch {
                logger.warn(error)
            }
        default:
            break
        }
    }

    #if os(iOS)
    @objc
    private func didEnterBackground(_ notification: Notification) {
        if #available(iOS 16, *) {
            guard !session.isMultitaskingCameraAccessEnabled else {
                return
            }
        }
        videoIO.multiCamCapture?.detachSession(session)
        videoIO.capture?.detachSession(session)
    }

    @objc
    private func didBecomeActive(_ notification: Notification) {
        if #available(iOS 16, *) {
            guard !session.isMultitaskingCameraAccessEnabled else {
                return
            }
        }
        videoIO.capture?.attachSession(session)
        videoIO.multiCamCapture?.attachSession(session)
    }
    #endif
}
#else
extension IOMixer: Running {
    // MARK: Running
    public var isRunning: Atomic<Bool> {
        .init(false)
    }

    public func startRunning() {
    }

    public func stopRunning() {
    }
}
#endif
