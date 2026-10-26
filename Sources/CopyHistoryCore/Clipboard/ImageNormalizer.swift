import Foundation
import ImageIO

/// Raw image bytes as read from the pasteboard; cheap to read, converted later off the main thread.
public enum PasteboardImage: Sendable, Equatable {
  case png(Data)
  case tiff(Data)

  var data: Data {
    switch self { case .png(let d), .tiff(let d): return d }
  }
}

/// Turns pasteboard images into bounded PNGs with ImageIO (thread-safe, no AppKit). Images larger
/// than `maxPixelSide` are downscaled rather than dropped, so ordinary Retina screenshots survive;
/// anything whose PNG still exceeds `maxBytes` after downscaling is dropped.
public struct ImageNormalizer: Sendable {
  public static let defaultMaxInputBytes = 200_000_000
  public static let defaultMaxPixelSide = 8192
  public static let defaultMaxBytes = 20_000_000

  public var maxInputBytes: Int
  public var maxPixelSide: Int
  public var maxBytes: Int

  public init(maxInputBytes: Int = ImageNormalizer.defaultMaxInputBytes,
              maxPixelSide: Int = ImageNormalizer.defaultMaxPixelSide,
              maxBytes: Int = ImageNormalizer.defaultMaxBytes) {
    self.maxInputBytes = maxInputBytes; self.maxPixelSide = maxPixelSide; self.maxBytes = maxBytes
  }

  /// Returns a PNG within the limits, or nil when the image is unreadable or too large.
  public func png(from image: PasteboardImage) -> Data? {
    let data = image.data
    guard !data.isEmpty, data.count <= maxInputBytes,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0 else { return nil }
    // Dimensions come from the header; nothing is decoded yet.
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
    guard width > 0, height > 0 else { return nil }
    var side = min(max(width, height), maxPixelSide)

    if case .png = image, side == max(width, height), data.count <= maxBytes { return data }
    // Each retry halves the side, i.e. roughly quarters the PNG.
    for _ in 0..<4 {
      guard side >= 1, let out = encode(source, maxSide: side, original: max(width, height)) else { return nil }
      if out.count <= maxBytes { return out }
      side /= 2
    }
    return nil
  }

  private func encode(_ source: CGImageSource, maxSide: Int, original: Int) -> Data? {
    let image: CGImage?
    if maxSide >= original {
      image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    } else {
      let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
      ]
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
    guard let image else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
  }
}
