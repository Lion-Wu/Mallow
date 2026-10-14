import SwiftUI

private enum HighlightEnvironmentDefaults {
    static let highlight = Highlight()
}

extension EnvironmentValues {
    @Entry var highlight: Highlight = HighlightEnvironmentDefaults.highlight
}
