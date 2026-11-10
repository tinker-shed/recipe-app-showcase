import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
  public typealias PlatformRecipeImage = NSImage
#else
  import UIKit
  public typealias PlatformRecipeImage = UIImage
#endif

public enum RecipeImages {
  /// Inspect the bytes rather than trusting a filename, without transcoding the original.
  public static func fileExtension(for data: Data) throws -> String {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let identifier = CGImageSourceGetType(source) as String?
    else { throw CocoaError(.fileReadCorruptFile) }
    let known = [
      "public.jpeg": "jpg", "public.png": "png", "com.compuserve.gif": "gif",
      "public.tiff": "tiff", "public.heic": "heic", "public.heif": "heif",
      "org.webmproject.webp": "webp", "com.microsoft.bmp": "bmp",
    ]
    guard let extensionName = known[identifier] ?? UTType(identifier)?.preferredFilenameExtension,
      extensionName.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil
    else { throw CocoaError(.fileReadUnknown) }
    return extensionName.lowercased()
  }

  /// Decode only enough pixels for display and apply the photograph's orientation.
  static func downsample(_ url: URL, maximumPixels: Int) -> CGImage? {
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  }

  /// Derived files are replaceable; a missing or unsupported original keeps its placeholder.
  static func makeThumbnail(heroPath: String?, assetsDirectory: URL) -> String? {
    guard let heroPath else { return nil }
    let source = assetsDirectory.appendingPathComponent(heroPath).standardizedFileURL
      .resolvingSymlinksInPath()
    let root = assetsDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    guard source.path.hasPrefix(root), let image = downsample(source, maximumPixels: 400) else {
      return nil
    }
    let relative = "Thumbnails/" + MarkdownImporter.digest(Data(heroPath.utf8)) + ".jpg"
    let destination = assetsDirectory.appendingPathComponent(relative)
    let bytes = NSMutableData()
    guard let encoder = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(encoder) else { return nil }
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (bytes as Data).write(to: destination, options: .atomic)
      return relative
    } catch { return nil }
  }
}

/// A serial actor bounds concurrent decoding; NSCache bounds retained decoded pixels.
/// No disk read or decode runs on the main actor. Reused by all native platforms.
public actor RecipeImageLoader {
  public static let shared = RecipeImageLoader()
  private let cache = NSCache<NSString, PlatformRecipeImage>()

  public init() {
    // Hold enough grid thumbnails that scrolling back through a large library does
    // not re-decode. Hero-sized images are large but few are shown at once.
    cache.countLimit = 240
    cache.totalCostLimit = 64 * 1024 * 1024
  }

  public func image(at url: URL, maximumPixels: Int = 1600) -> PlatformRecipeImage? {
    let size = max(1, min(maximumPixels, 2400))
    let key = "\(url.path)|\(size)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    guard let decoded = RecipeImages.downsample(url, maximumPixels: size) else { return nil }
    #if os(macOS)
      let image = NSImage(
        cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
    #else
      let image = UIImage(cgImage: decoded)
    #endif
    cache.setObject(image, forKey: key, cost: decoded.bytesPerRow * decoded.height)
    return image
  }
}
