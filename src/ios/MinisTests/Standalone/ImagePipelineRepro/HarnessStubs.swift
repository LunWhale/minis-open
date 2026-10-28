// [T-image-repro] Minimal stand-ins for app symbols the extracted production
// code references but that have nothing to do with images. Compiled only into
// the ImagePipelineReproTests harness (never into the app).
import Foundation

enum HarnessEnv {
    static var root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minis-image-repro-work")
    static let sessionId = "S-REPRO"
}

/// AppLogger is a thin NSLog wrapper in the app; the harness keeps stdout clean.
struct AppLogger {
    init(category: String) {}
    func info(_ m: @autoclosure () -> String) {}
    func warning(_ m: @autoclosure () -> String) {}
    func error(_ m: @autoclosure () -> String) {}
    func debug(_ m: @autoclosure () -> String) {}
    func verbose(_ m: @autoclosure () -> String) {}
    func notice(_ m: @autoclosure () -> String) {}
}
/// File-scope loggers the extracted code refers to by name.
let logger = AppLogger(category: "harness")
let ctLogger = AppLogger(category: "harness")

func AppLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String { String(localized: key) }

/// LLMTypes.swift calls this to fill catalogue metadata; not image related.
enum ModelsDevAPI {
    static func enrichModel(_ m: LLMModel) -> LLMModel { m }
}
/// ProviderTypes.swift lists these vendors' catalogues; not image related.
enum XAIModelsAPI { static var allModels: [LLMModel] { [] } }
enum KimiModelsAPI { static var allModels: [LLMModel] { [] } }
