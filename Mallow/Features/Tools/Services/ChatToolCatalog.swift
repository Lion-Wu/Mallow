import Foundation

enum ChatToolCatalog {
    static func prepareBuiltIn(settings: ToolUseSettings, registry: ChatToolRegistry = .builtIn) throws -> ChatToolRegistry {
        try Task.checkCancellation()
        return try registry.enabled(using: settings)
    }
}
