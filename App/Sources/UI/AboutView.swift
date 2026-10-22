import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("App", value: "Lyrics (CarPlay Lyrics)")
                LabeledContent("Version", value: AppConfig.version)
                LabeledContent("Made by", value: AppConfig.publisherName)
                if let email = AppConfig.supportEmail, let url = URL(string: "mailto:\(email)") {
                    Link(destination: url) { LabeledContent("Support", value: email) }
                } else {
                    Link("Contact: open an issue on GitHub", destination: AppConfig.issuesURL)
                        .accessibilityIdentifier("contactLink")
                }
                Link("Source code on GitHub", destination: AppConfig.sourceURL)
            }
            Section {
                Text("Lyrics come from LRCLIB, a free community database of synced lyrics. They may contain mistakes. Lyrics remain the property of their copyright owners; this app is for personal use.")
                Link("lrclib.net", destination: AppConfig.lrclibURL)
            } header: {
                Text("Lyrics")
            }
            Section {
                Text("Song details and artwork come from Spotify. This app isn't affiliated with, endorsed or sponsored by Spotify. Spotify is a trademark of Spotify AB.")
                Text("CarPlay and iPhone are trademarks of Apple Inc. This app isn't affiliated with Apple.")
            } header: {
                Text("Spotify and Apple")
            }
            Section {
                NavigationLink("Privacy Policy") { LegalDocumentView(document: .privacy) }
                NavigationLink("Terms of Use") { LegalDocumentView(document: .terms) }
            }
            Section {
                Text("The app icon was drawn for this project. Symbols are Apple's SF Symbols, used on Apple platforms under Apple's license.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .accessibilityIdentifier("aboutScreen")
    }
}

/// The privacy policy and terms, bundled from PRIVACY.md and TERMS.md at the repo root.
struct LegalDocumentView: View {
    enum Document: String, Identifiable {
        case privacy = "PRIVACY"
        case terms = "TERMS"
        var id: String { rawValue }
        var title: String { self == .privacy ? "Privacy Policy" : "Terms of Use" }
    }

    let document: Document

    var body: some View {
        ScrollView {
            MarkdownText(markdown: Self.load(document))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legal-\(document.rawValue)")
    }

    static func load(_ document: Document) -> String {
        guard let url = Bundle.main.url(forResource: document.rawValue, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "See \(document.rawValue).md in the source repository." }
        return text
    }
}

/// Renders the small subset of Markdown the legal documents use: headings, bullets, paragraphs, inline styles and links.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title2.bold() : .headline)
                        .padding(.top, level == 1 ? 0 : 8)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
    }

    enum Block {
        case heading(Int, String)
        case bullet(String)
        case paragraph(String)
    }

    var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                result.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// An info button that opens About.
struct LegalToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                AboutView()
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("About")
        }
    }
}

/// Opens `carplaylyrics-doc://privacy` and `carplaylyrics-doc://terms` links in a sheet.
private struct LegalLinkHandler: ViewModifier {
    @State private var document: LegalDocumentView.Document?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "carplaylyrics-doc" else { return .systemAction }
                document = url.host == "terms" ? .terms : .privacy
                return .handled
            })
            .sheet(item: $document) { document in
                NavigationStack {
                    LegalDocumentView(document: document)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { self.document = nil }
                            }
                        }
                }
            }
    }
}

extension View {
    func legalLinkHandler() -> some View { modifier(LegalLinkHandler()) }
}
