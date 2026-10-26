import Foundation

public enum TransformError: Error, Equatable, LocalizedError, Sendable {
  case invalidInput(String)
  case unsupported(String)
  case noContent
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .invalidInput(let m): return m
    case .unsupported(let m): return "Unsupported: \(m)"
    case .noContent: return "Nothing to convert"
    case .timedOut: return "Took too long"
    }
  }
}

/// Inputs larger than this are refused instead of being processed (keeps transforms responsive).
let transformMaxInputBytes = 5_000_000

/// Tables wider than this are refused: padding every row to the widest one multiplies the output.
let transformMaxTableColumns = 256

/// Upper bound on the size of generated table output (padding included).
let transformMaxOutputBytes = 20_000_000
