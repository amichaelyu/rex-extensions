import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Streams the hidden window's composited frames from the window server
/// (ScreenCaptureKit, own-process content: no Screen Recording permission).
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "rex-browser.capture")
    var onFrame: ((CGImage, [CGRect]) -> Void)?
    /// Called (on the main queue) when capture can't start or stops.
    var onFailure: (() -> Void)?

    private func fail(_ message: String) {
        Log.write("capture: \(message)")
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }

    private static func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.queueDepth = 4
        return config
    }
    var frames = 0

    func start(windowNumber: Int, width: Int, height: Int) {
        SCShareableContent.getCurrentProcessShareableContent { [weak self] content, error in
            guard let self else { return }
            guard let content, let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) else {
                self.fail("no shareable window (\(error?.localizedDescription ?? "not listed"))")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = Self.configuration(width: width, height: height)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                self.fail("addStreamOutput failed: \(error)")
                return
            }
            stream.startCapture { error in
                if let error { self.fail("start failed: \(error)") } else { Log.write("capture: started") }
            }
            self.stream = stream
        }
    }

    /// Captures at a new pixel size (after the window was resized).
    func resize(width: Int, height: Int) {
        guard let stream else { return }
        let config = Self.configuration(width: width, height: height)
        stream.updateConfiguration(config) { error in
            if let error { Log.write("capture: resize failed: \(error)") }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("stopped: \(error)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pixels = sample.imageBuffer
        else { return }
        let dirty = (info[.dirtyRects] as? [NSDictionary] ?? []).compactMap { CGRect(dictionaryRepresentation: $0) }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        frames += 1
        DispatchQueue.main.async { [weak self] in self?.onFrame?(image, dirty) }
    }
}
