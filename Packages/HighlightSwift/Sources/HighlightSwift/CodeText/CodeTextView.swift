import SwiftUI

@available(iOS 16.1, tvOS 16.1, *)
extension CodeText: View {
    public var body: some View {
        Text(attributedText)
            .fontDesign(.monospaced)
            .padding(.vertical, style.verticalPadding)
            .padding(.horizontal, style.horizontalPadding)
            .background {
                if let cardStyle = style as? CardCodeTextStyle {
                    CodeTextCardView(
                        style: cardStyle,
                        color: highlightResult?.backgroundColor
                    )
                }
            }
            .onAppear {
                guard highlightResult == nil else {
                    return
                }
                highlightTask = Task {
                    await highlightText()
                }
            }
            .onDisappear {
                highlightTask?.cancel()
            }
            .onHighlightChange(of: mode) { newMode in
                highlightTask?.cancel()
                highlightTask = Task {
                    await highlightText(mode: newMode)
                }
            }
            .onHighlightChange(of: colors) { newColors in
                highlightTask?.cancel()
                highlightTask = Task {
                    await highlightText(colors: newColors)
                }
            }
            .onHighlightChange(of: colorScheme) { newColorScheme in
                highlightTask?.cancel()
                highlightTask = Task {
                    await highlightText(colorScheme: newColorScheme)
                }
            }
    }
}

private extension View {
    @ViewBuilder
    func onHighlightChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

//  MARK: - Preview

@available(iOS 16.1, tvOS 16.1, *)
private struct PreviewCodeText: View {
    @State var colors: CodeTextColors = .theme(.xcode)
    @State var font: Font = .body

    let code: String = """
    import SwiftUI
    
    struct SwiftUIView: View {
        var body: some View {
            Text("Hello World!")
        }
    }
    """
    
    var body: some View {
        List {
            CodeText(code)
                .codeTextStyle(.card)
                .codeTextColors(colors)
                .highlightLanguage(.swift)
                .font(font)
            Button {
                withAnimation {
                    colors = .theme(randomTheme())
                    font = randomFont()
                }
            } label: {
                Text("Random")
            }
        }
    }
    
    func randomTheme() -> HighlightTheme {
        let cases = HighlightTheme.allCases
        return cases[.random(in: 0..<cases.count)]
    }
    
    func randomFont() -> Font {
        let cases: [Font] = [
            .body,
            .callout,
            .caption,
            .caption2,
            .footnote,
            .headline,
            .largeTitle,
            .subheadline,
            .title
        ]
        return cases[.random(in: 0..<cases.count)]
    }
}

@available(iOS 16.1, tvOS 16.1, *)
#Preview {
    PreviewCodeText()
}
