# Mallow - AI Voice Chat Client

Mallow is a native AI chat client for iPhone, iPad, Mac, and Apple Vision Pro. Connect your own local or remote AI server to chat with text, images, and voice.

## Features

- **Chat:** Streaming responses, image input, Markdown, code highlighting, and LaTeX rendering.
- **Voice:** Real-time voice conversations with Apple Speech, Personal Voice, or GPT-SoVITS. Camera input on iOS, iPadOS, and macOS adds visual context for vision-capable models.
- **Conversations:** Search history, edit messages, and explore conversation branches.
- **Presets:** Save chat servers, voice servers, voice models, and system prompts for text and voice modes.
- **Model settings:** Choose API formats, image capabilities, thinking options, and advanced request parameters.
- **Tools:** Calendar, reminders, location, motion, device information, clipboard, URL opening, time, and JavaScript execution.
- **Data management:** View storage usage, export backups, preview and merge imports, and clean up unused files.

## Platforms

| Platform | Minimum version |
| --- | --- |
| iPhone and iPad | iOS / iPadOS 18.0 |
| Mac | macOS 15.0 |
| Apple Vision Pro | visionOS 2.0 |

## Chat API Support

| API format | Chat endpoint |
| --- | --- |
| OpenAI Responses | `/v1/responses` |
| OpenAI Chat Completions | `/v1/chat/completions` |
| Anthropic Messages | `/v1/messages` |
| LM Studio native API | `/api/v1/chat` |

Select **Automatic** or your server's API format in Settings. Image input, thinking options, and tool calling follow the selected model's capabilities.

## Getting Started

### Configure a chat server

1. Open **Settings → Chat Server** and add a server preset.
2. Enter the server URL, API format, and API key required by your server.
3. In **Chat Model**, refresh the model list and select a model.
4. Start chatting.

### Configure voice output

In Settings, choose a voice provider:

- **Apple Speech:** Choose an installed system voice.
- **Apple Personal Voice:** Grant access and select your personal voice on a supported device.
- **GPT-SoVITS:** Connect an API v2 server. Create and apply a preset with the reference-audio path, reference text, language, and GPT/SoVITS weight paths. Paths point to files on the voice server.

### Enable tools and advanced settings

Enable **Tool Use**, select tool groups, and choose an authorization mode: ask every time, read-only, or read/write. Grant system permissions for the tools you use.

Enable **Developer Mode** for advanced API parameters and request settings.

## Data and Privacy

Conversations and settings are stored locally with SwiftData. API keys are stored in the system Keychain.

Your configured server processes messages, images, and tool results. Voice input uses Apple's speech-recognition service.

Manage storage and backups in **Settings → Advanced → Data Management**. Backups may include API keys, so keep them private.

See the [privacy policy](https://lionwu.com/mallow/privacy) for more information.

## Build from Source

Build with **Xcode 27 or later**. The project uses Swift 6.

```sh
git clone https://github.com/Lion-Wu/Mallow.git
cd Mallow
open Mallow.xcodeproj
```

1. Let Xcode resolve the package dependencies.
2. Select the **Mallow** scheme and a run destination.
3. For device builds, set your development team and bundle identifier in **Signing & Capabilities**.
4. Choose **Product → Run** to launch or **Product → Test** to run `MallowTests`.

Dependency versions are pinned in `Package.resolved`. Local packages live in `Packages/` and include their own tests:

- **SwiftStreamingMarkdown:** Adapted streaming Markdown renderer.
- **HighlightSwift:** Code highlighting.
- **MallowRaTeX:** Formula rendering for visionOS. iOS, iPadOS, and macOS use upstream RaTeX 0.1.15.

## Acknowledgments

- [GPT-SoVITS](https://github.com/RVC-Boss/GPT-SoVITS)
- [SwiftStreamingMarkdown](https://github.com/microsoft/SwiftStreamingMarkdown)
- [HighlightSwift](https://github.com/appstefan/highlightswift)
- [RaTeX](https://github.com/erweixin/RaTeX)
- [swift-markdown](https://github.com/swiftlang/swift-markdown)
- [swift-cmark](https://github.com/swiftlang/swift-cmark)
- [KaTeX fonts](https://github.com/KaTeX/KaTeX)
- [Highlight.js](https://highlightjs.org)
- [SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer)
- [Equatable](https://github.com/ordo-one/equatable)
- [SwiftSyntax](https://github.com/swiftlang/swift-syntax)

See [DEPENDENCIES.md](DEPENDENCIES.md) for versions, uses, and licenses.

## License

MIT — see [LICENSE](LICENSE).
