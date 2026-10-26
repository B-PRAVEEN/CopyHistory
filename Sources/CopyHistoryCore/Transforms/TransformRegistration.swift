import Foundation

extension TransformRegistry {
  /// The built-in transforms, in picker order.
  public static var defaultTransforms: [any Transform] {
    [
      JSONToTypeScript(),
      DelimitedToMarkdown(),
      CurlToFetch(),
      HTMLToMarkdown(),
      StripFormatting(),
    ]
  }

  /// Registers the built-in transforms. Idempotent: existing entries with the same id are replaced.
  public static func registerDefaults() {
    let defaults = defaultTransforms
    let ids = Set(defaults.map(\.id))
    update { all in all = all.filter { !ids.contains($0.id) } + defaults }
  }
}
