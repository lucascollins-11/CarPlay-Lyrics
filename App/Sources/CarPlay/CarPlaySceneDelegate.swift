import CarPlay
import Combine
import LyricsCore
import UIKit

/// Runs the CarPlay screen. Declared in Info.plist under
/// `CPTemplateApplicationSceneSessionRoleApplication`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var lyricsTemplate: CarPlayLyricsTemplate?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let template = CarPlayLyricsTemplate(model: .shared)
        lyricsTemplate = template
        interfaceController.setRootTemplate(template.template, animated: false, completion: nil)
        NowPlayingModel.shared.setActive(true, client: "carplay")
        NowPlayingModel.shared.refreshNow()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        NowPlayingModel.shared.setActive(false, client: "carplay")
        lyricsTemplate = nil
        self.interfaceController = nil
    }
}

/// A list template that shows a few lines around the one being sung, with the
/// current line marked by CarPlay's playing indicator.
@MainActor
final class CarPlayLyricsTemplate {
    let template: CPListTemplate
    private let model: NowPlayingModel
    private var subscription: AnyCancellable?

    /// Lines kept above the current one, so the driver sees what was just sung.
    private let linesBefore = 1

    init(model: NowPlayingModel) {
        self.model = model
        template = CPListTemplate(title: "Lyrics", sections: [])
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "−0.25s") { _ in model.adjustOffset(by: -0.25) },
            CPBarButton(title: "+0.25s") { _ in model.adjustOffset(by: 0.25) },
        ]
        subscription = model.$snapshot
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
    }

    private var maxItems: Int {
        min(Int(CPListTemplate.maximumItemCount), 6)
    }

    private func render(_ snapshot: NowPlayingModel.Snapshot) {
        guard snapshot.isSignedIn else {
            return showEmpty("Open CarPlay Lyrics on your iPhone", "Sign in to Spotify to get started.")
        }
        guard let track = snapshot.track else {
            return showEmpty("Nothing playing", snapshot.problem ?? "Play a song on Spotify.")
        }
        let header = "\(track.title) · \(track.artistLine)"

        switch snapshot.lyrics {
        case .none, .loading:
            showMessage("Finding lyrics…", header: header)
        case .failed(let message):
            showMessage(message, header: header)
        case .loaded(.notFound):
            showMessage("No lyrics found for this song", header: header)
        case .loaded(.instrumental):
            showMessage("♪ Instrumental ♪", header: header)
        case .loaded(.plain(let lines)):
            let items = lines.filter { !$0.isEmpty }.prefix(maxItems).map { makeItem($0, isCurrent: false) }
            template.updateSections([CPListSection(items: Array(items), header: "\(header) (not synced)", sectionIndexTitle: nil)])
        case .loaded(.synced(let timeline)):
            let window = timeline.window(around: snapshot.currentLine, before: linesBefore, count: maxItems)
            var items: [CPListItem] = []
            if snapshot.currentLine == nil {
                // Before the first line: show a waiting marker, then what's coming.
                items.append(makeItem("♪", isCurrent: true))
            }
            for index in window.range where items.count < maxItems {
                let line = timeline.lines[index]
                items.append(makeItem(line.isGap ? "♪" : line.text, isCurrent: index == snapshot.currentLine))
            }
            template.updateSections([CPListSection(items: items, header: header, sectionIndexTitle: nil)])
        }
    }

    private func makeItem(_ text: String, isCurrent: Bool) -> CPListItem {
        // CarPlay rows truncate, so a long line wraps onto the detail row.
        let (first, rest) = Self.split(text, limit: 34)
        let item = CPListItem(text: first, detailText: rest)
        item.isPlaying = isCurrent
        item.playingIndicatorLocation = .leading
        item.handler = { _, completion in completion() }
        return item
    }

    private func showMessage(_ message: String, header: String) {
        template.updateSections([CPListSection(items: [makeItem(message, isCurrent: false)], header: header, sectionIndexTitle: nil)])
    }

    private func showEmpty(_ title: String, _ subtitle: String) {
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = [subtitle]
        template.updateSections([])
    }

    /// Splits `text` at a word boundary near `limit` characters.
    static func split(_ text: String, limit: Int) -> (String, String?) {
        guard text.count > limit else { return (text, nil) }
        let words = text.split(separator: " ")
        var first = ""
        var index = 0
        while index < words.count {
            let candidate = first.isEmpty ? String(words[index]) : first + " " + String(words[index])
            if candidate.count > limit, !first.isEmpty { break }
            first = candidate
            index += 1
        }
        let rest = words[index...].joined(separator: " ")
        return (first, rest.isEmpty ? nil : rest)
    }
}
