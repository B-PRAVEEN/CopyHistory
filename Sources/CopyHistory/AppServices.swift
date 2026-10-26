import Foundation
import CopyHistoryCore

/// The single seam where the app gets its backing services.
@MainActor
struct AppServices {
  let store: any ClipboardHistoryStore
  let detector: any SecretDetecting
  let pasteStack: PasteStackController
  /// Called once after launch: registers transforms and starts the clipboard monitor.
  let start: @MainActor () -> Void

  static func make() -> AppServices {
    let store = HistoryStore()
    let detector = SecretDetector()
    let monitor = ClipboardMonitor(detector: detector)
    monitor.ocr = VisionOCR()
    let pasteStack = PasteStackController()

    // Settings live in UserDefaults (see AppSettings.Key); keep the monitor in sync with them.
    let applySettings: @MainActor () -> Void = {
      let d = UserDefaults.standard
      monitor.ignoredApps = Set(d.stringArray(forKey: AppSettings.Key.ignoredApps) ?? [])
      monitor.secretExpiry = TimeInterval(d.object(forKey: AppSettings.Key.redactionExpirySeconds) as? Int ?? 60)
    }

    return AppServices(store: store, detector: detector, pasteStack: pasteStack) {
      TransformRegistry.registerDefaults()
      applySettings()
      NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
      ) { _ in MainActor.assumeIsolated { applySettings() } }
      // Store first, then the Paste Stack. The stack gets the monitor's own entry (not the deduped one
      // the store returns) so its id matches the later OCR update.
      monitor.connect(to: store)
      let storeCapture = monitor.onCapture
      let storeOCR = monitor.onOCR
      monitor.onCapture = { entry, awaiting in
        storeCapture?(entry, awaiting)
        pasteStack.handleCopied(entry, awaitingOCR: awaiting, capturedChangeCount: monitor.capturingChangeCount)
      }
      monitor.onOCR = { update in
        storeOCR?(update)
        pasteStack.applyOCR(entryID: update.entryID, scanned: update.scanned, ocrText: update.ocrText,
                            findings: update.findings)
      }
      monitor.start()
    }
  }
}
