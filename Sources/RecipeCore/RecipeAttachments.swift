import Foundation

public enum RecipeAttachments {
  /// Only open managed attachments inside this library, never an imported arbitrary path.
  public static func url(for block: RecipeBlock, assetsDirectory: URL) -> URL? {
    guard (block.kind == .pdf || block.kind == .image || block.kind == .originalImage), let path = block.assetPath, !path.hasPrefix("/") else { return nil }
    let root = assetsDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let url = assetsDirectory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(root), ["pdf", "jpg", "jpeg", "png", "heic", "webp", "tif", "tiff", "gif"].contains(url.pathExtension.lowercased()),
      (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else { return nil }
    return url
  }
}
