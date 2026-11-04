// FrameRenderer.swift — Protocol for display set renderers
//
// Each display set implements this protocol.
// The frame loop calls render() to get a CGImage, then encodes it to JPEG.

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import VideoToolbox

// MARK: - Protocol

protocol FrameRenderer {
    /// Render a full frame at `Layout.width` × `Layout.height`, upright (the
    /// encoder turns it for a screen mounted upside down).
    func render() -> CGImage?
}

// MARK: - JPEG Encoding

enum JPEGEncoder {

    /// Encode CGImage to JPEG Data, turned 180° if the screen is mounted that way
    /// (`DeviceInfo.needsRotation`), with brightness adjustment.
    /// Reduces quality if over 650KB (matches Python behavior).
    ///
    /// Pixel work (rotation, brightness) runs on the CPU with Accelerate/vImage:
    /// ~0.3ms per 1920×480 frame, versus ~7ms for a CG rotate plus a Core Image
    /// GPU round trip (upload, render, blocking readback) it replaced.
    static func encode(
        _ image: CGImage, brightness: Int = 1, rotate180: Bool = false, maxBytes: Int = 650_000
    ) -> Data? {
        // process() writes into a shared buffer that lives until the JPEG is out
        encodeLock.lock()
        defer { encodeLock.unlock() }
        let factor = Brightness.factor(for: brightness)
        if hardwareOn, let data = hardwareJPEG.encode(image, rotate180: rotate180, factor: factor),
           data.count <= maxBytes {
            return data
        }
        var finalImage = image
        if rotate180 || factor > 1.0,
           let processed = process(image, rotate180: rotate180, factor: factor) {
            finalImage = processed
        }

        // Encode to JPEG with quality reduction loop. 0.8 is ~15% faster and
        // smaller than 0.9 for a PSNR barely lower (38.0 vs 38.4 dB)
        for quality in stride(from: 80, through: 30, by: -5) {
            if let data = jpegData(from: finalImage, quality: Double(quality) / 100),
               data.count <= maxBytes {
                return data
            }
        }
        return nil
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Pixel processing (vImage)

    private static let rgba = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    // Frames are opaque; declaring no alpha spares ImageIO a flatten pass
    private static let rgbx = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    private static let identityLUT: [UInt8] = (0..<256).map { UInt8($0) }

    private static let encodeLock = NSLock()

    /// Encode on Apple silicon's JPEG hardware (VideoToolbox) instead of ImageIO's
    /// software encoder; falls back to software for any frame it can't do.
    /// Saved setting; `--hw-jpeg` / `--sw-jpeg` override it for a run.
    static var useHardware: Bool {
        get { encodeLock.withLock { hardwareOn } }
        set { encodeLock.withLock { hardwareOn = newValue } }
    }
    nonisolated(unsafe) private static var hardwareOn: Bool = {
        let args = CommandLine.arguments
        if args.contains("--hw-jpeg") { return true }
        if args.contains("--sw-jpeg") { return false }
        return UserDefaults.standard.object(forKey: "hardwareJPEG") as? Bool ?? true
    }()
    nonisolated(unsafe) private static let hardwareJPEG = HardwareJPEG()

    // Reused output buffer: a fresh 3.6MB allocation per frame costs page faults
    // and zero-fill (kernel time) on every one of them.
    nonisolated(unsafe) private static var outBuffer: UnsafeMutableRawPointer?
    nonisolated(unsafe) private static var outBufferSize = 0
    nonisolated(unsafe) private static var lutCache: (factor: CGFloat, lut: [UInt8])?

    /// Rotate 180° and/or brighten RGB by `factor` into the shared output buffer.
    /// The returned image aliases that buffer, so it is only valid until the next
    /// call — encode() consumes it immediately and never hands it out.
    private static func process(_ image: CGImage, rotate180: Bool, factor: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        let rowBytes = w * 4
        guard let srcData = rgbaBytes(image) else { return nil }
        // vImage borrows the raw pointer; keep its CFData owner alive through the copy.
        defer { withExtendedLifetime(srcData) {} }
        if outBufferSize != rowBytes * h {
            outBuffer?.deallocate()
            outBuffer = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * h, alignment: 64)
            outBufferSize = rowBytes * h
        }
        guard let out = outBuffer else { return nil }

        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: srcData.bytes),
                                height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: srcData.rowBytes)
        var dst = vImage_Buffer(data: out,
                                height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: rowBytes)
        let flags = vImage_Flags(kvImageNoFlags)
        var err: vImage_Error
        if rotate180 {
            var bg: [UInt8] = [0, 0, 0, 255]
            err = vImageRotate90_ARGB8888(&src, &dst, UInt8(kRotate180DegreesClockwise), &bg, flags)
        } else {
            err = vImageCopyBuffer(&src, &dst, 4, flags)
        }
        if err == kvImageNoError && factor > 1.0 {
            // Channel tables are positional: bytes 0-2 are R,G,B in RGBA, byte 3 alpha
            if lutCache?.factor != factor { lutCache = (factor, brightnessLUT(factor)) }
            let lut = lutCache!.lut
            err = vImageTableLookUp_ARGB8888(&dst, &dst, lut, lut, lut, identityLUT, flags)
        }
        guard err == kvImageNoError,
              let provider = CGDataProvider(dataInfo: nil, data: out, size: outBufferSize,
                                            releaseData: { _, _, _ in })
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: rgbx, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// RGB scaled by `factor` in linear light, then clipped — identical (verified
    /// per value) to the CIColorMatrix filter this replaced, which ran in Core
    /// Image's linear working space. Keeps LCD brightness levels looking the same.
    fileprivate static func brightnessLUT(_ factor: CGFloat) -> [UInt8] {
        func decode(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func encode(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }
        return (0..<256).map { v in
            UInt8((encode(min(1, decode(Double(v) / 255) * Double(factor))) * 255).rounded())
        }
    }

    fileprivate struct PixelData {
        let data: CFData
        let rowBytes: Int
        var bytes: UnsafePointer<UInt8> { CFDataGetBytePtr(data) }
    }

    /// The image's pixels as tightly-typed RGBA8888. Renderer output already is;
    /// anything else (PNG test frames, etc.) is redrawn once into RGBA.
    fileprivate static func rgbaBytes(_ image: CGImage) -> PixelData? {
        let alpha = image.alphaInfo
        let isRGBA = image.bitsPerComponent == 8 && image.bitsPerPixel == 32
            && (alpha == .premultipliedLast || alpha == .noneSkipLast || alpha == .last)
            && image.bitmapInfo.intersection(.byteOrderMask).rawValue == 0
            && image.colorSpace?.model == .rgb
        if isRGBA, let data = image.dataProvider?.data {
            return PixelData(data: data, rowBytes: image.bytesPerRow)
        }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: rgba.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let redrawn = ctx.makeImage(), let data = redrawn.dataProvider?.data else { return nil }
        return PixelData(data: data, rowBytes: redrawn.bytesPerRow)
    }
}

// MARK: - Hardware JPEG (VideoToolbox)

/// JPEG on Apple silicon's media hardware. Measured at 20fps on a 1920×480 frame:
/// ~5% of a core (this process plus VTEncoderXPCService) against ~10% for
/// ImageIO's software encoder, kernel time unchanged. Used under JPEGEncoder's
/// lock only.
///
/// The frame goes into an IOSurface pixel buffer (one vImage pass, which also
/// rotates and brightens), the hardware reads it from there, and its JPEG comes
/// back in a block buffer handed on without a copy — LYProtocol copies it once,
/// into the USB packets (each needs its 16-byte header), and the USB controller
/// DMAs those from memory. Apple silicon's memory is unified: there's no GPU or
/// encoder memory a copy could be saved from.
private final class HardwareJPEG {
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var size = (w: 0, h: 0)
    private var failed = false   // no hardware encoder here: stop asking
    private var lut: (factor: CGFloat, table: [UInt8])?
    private let identity: [UInt8] = (0..<256).map { UInt8($0) }

    // The hardware's own quality scale: 0.8 ≈ 135KB a frame, as sharp to the eye
    // as ImageIO at 0.8 (~165KB); above 0.85 it only grows
    private let quality: Float = 0.8

    private final class Result: @unchecked Sendable { var data: Data? }

    func encode(_ image: CGImage, rotate180: Bool, factor: CGFloat) -> Data? {
        guard !failed else { return nil }
        let w = image.width, h = image.height
        if session == nil || size != (w, h) {
            guard start(w, h) else { failed = true; log("[JPEG] No hardware encoder, using software"); return nil }
        }
        guard let session, let pool, let pixels = fill(image, pool: pool, rotate180: rotate180, factor: factor)
        else { return nil }

        let result = Result()
        let done = DispatchSemaphore(value: 0)
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: .zero, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            defer { done.signal() }
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
            result.data = HardwareJPEG.bytes(of: block)
        }
        guard st == noErr else { return nil }
        done.wait()
        return result.data
    }

    /// The JPEG in the block buffer, without copying it when it's in one piece.
    private static func bytes(of block: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(block)
        var contiguous = 0
        var p: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous,
                                          totalLengthOut: nil, dataPointerOut: &p) == noErr, let p
        else { return nil }
        if contiguous == length {
            return Data(bytesNoCopy: p, count: length, deallocator: .custom { _, _ in withExtendedLifetime(block) {} })
        }
        var data = Data(count: length)
        let st = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        return st == noErr ? data : nil
    }

    private func start(_ w: Int, _ h: Int) -> Bool {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil; pool = nil
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_JPEG,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s
        else { return false }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // JPEG decoders take BT.601; left alone the hardware converts by BT.709
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)

        var p: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p) == kCVReturnSuccess, let p else {
            VTCompressionSessionInvalidate(s)
            return false
        }
        session = s; pool = p; size = (w, h)
        return true
    }

    /// The frame as BGRA in a pooled IOSurface buffer: turned and brightened as asked.
    private func fill(_ image: CGImage, pool: CVPixelBufferPool, rotate180: Bool, factor: CGFloat) -> CVPixelBuffer? {
        guard let src = JPEGEncoder.rgbaBytes(image) else { return nil }
        defer { withExtendedLifetime(src) {} }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = vImagePixelCount(image.width), h = vImagePixelCount(image.height)
        var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.bytes), height: h, width: w, rowBytes: src.rowBytes)
        var d = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: h, width: w,
                              rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let flags = vImage_Flags(kvImageNoFlags)
        let bgra: [UInt8] = [2, 1, 0, 3]
        var err: vImage_Error
        if rotate180 {
            var black: [UInt8] = [0, 0, 0, 255]
            err = vImageRotate90_ARGB8888(&s, &d, UInt8(kRotate180DegreesClockwise), &black, flags)
            if err == kvImageNoError { err = vImagePermuteChannels_ARGB8888(&d, &d, bgra, flags) }
        } else {
            err = vImagePermuteChannels_ARGB8888(&s, &d, bgra, flags)
        }
        if err == kvImageNoError && factor > 1.0 {
            if lut?.factor != factor { lut = (factor, JPEGEncoder.brightnessLUT(factor)) }
            let t = lut!.table   // B, G, R take the same table; byte 3 is alpha
            err = vImageTableLookUp_ARGB8888(&d, &d, t, t, t, identity, flags)
        }
        guard err == kvImageNoError else { return nil }
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        return pb
    }
}
