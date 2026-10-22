import CarPlay
import Combine
import LyricsCore
import UIKit

/// Runs the CarPlay app screen. Declared in Info.plist under
/// `CPTemplateApplicationSceneSessionRoleApplication`.
///
/// Apple's CarPlay guidelines don't allow lyrics on the CarPlay screen, so
/// Apple won't grant this app a CarPlay entitlement and this screen only runs
/// in the Simulator. In a real car, lyrics appear on the CarPlay Dashboard
/// through the Drive mode Live Activity instead.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var lyricsTemplate: CarPlayLyricsTemplate?
    static let client = "carplay"

    // CarPlay calls these on the main thread; the protocol just doesn't say so.
    nonisolated func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                              didConnect interfaceController: CPInterfaceController) {
        // CarPlay hands this over on the main thread and nothing else keeps a reference.
        nonisolated(unsafe) let controller = interfaceController
        MainActor.assumeIsolated {
            self.interfaceController = controller
            let template = CarPlayLyricsTemplate(model: AppServices.shared.model)
            lyricsTemplate = template
            controller.setRootTemplate(template.template, animated: false, completion: nil)
        }
    }

    nonisolated func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                              didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            AppServices.shared.model.setActive(false, client: Self.client)
            lyricsTemplate = nil
            self.interfaceController = nil
        }
    }

    // Poll Spotify only while the lyrics screen is actually showing in the car,
    // not while the driver has switched to Maps or Spotify.
    func sceneDidBecomeActive(_ scene: UIScene) {
        AppServices.shared.model.setActive(true, client: Self.client)
        AppServices.shared.model.refreshNow()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        AppServices.shared.model.setActive(false, client: Self.client)
    }
}

/// A list template showing a few lines around the one being sung, the current
/// line marked with CarPlay's playing indicator. Rows aren't tappable: the
/// driver never has to interact with it.
@MainActor
final class CarPlayLyricsTemplate {
    let template: CPListTemplate
    private let model: NowPlayingModel
    private var subscription: AnyCancellable?
    private var items: [CPListItem] = []
    private var header: String?
    private var lastDisplay: LyricsDisplay?

    /// Lines kept above the current one, so the driver sees what was just sung.
    static let linesBefore = 1

    init(model: NowPlayingModel) {
        self.model = model
        template = CPListTemplate(title: "Lyrics", sections: [])
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Earlier") { _ in model.adjustTrackOffset(by: 0.25) },
            CPBarButton(title: "Later") { _ in model.adjustTrackOffset(by: -0.25) },
        ]
        subscription = model.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in self?.render(snapshot) }
    }

    /// Some cars limit lists to 12 rows; fewer, larger rows are easier to read at a glance.
    static var maxRows: Int {
        min(Int(CPListTemplate.maximumItemCount), 6)
    }

    func render(_ snapshot: NowPlayingSnapshot) {
        let display = LyricsDisplay.make(for: snapshot, maxRows: Self.maxRows, linesBefore: Self.linesBefore)
        guard display != lastDisplay else { return }
        lastDisplay = display

        switch display {
        case .message(let title, let subtitle):
            template.emptyViewTitleVariants = [title]
            template.emptyViewSubtitleVariants = subtitle.map { [$0] } ?? []
            items = []
            header = nil
            template.updateSections([])
        case .rows(let newHeader, let rows):
            if newHeader == header, rows.count == items.count {
                // Same shape: update rows in place, which avoids the list flickering on some head units.
                for (item, row) in zip(items, rows) {
                    if item.text != row.text { item.setText(row.text) }
                    if item.detailText != row.detail { item.setDetailText(row.detail) }
                    if item.isPlaying != row.isCurrent { item.isPlaying = row.isCurrent }
                }
            } else {
                items = rows.map(Self.makeItem)
                header = newHeader
                template.updateSections([CPListSection(items: items, header: newHeader, sectionIndexTitle: nil)])
            }
        }
    }

    static func makeItem(_ row: LyricsRow) -> CPListItem {
        let item = CPListItem(text: row.text, detailText: row.detail)
        item.isPlaying = row.isCurrent
        item.playingIndicatorLocation = .leading
        return item
    }

    /// The rows currently on screen, for tests.
    var visibleRows: [(text: String?, detail: String?, isCurrent: Bool)] {
        items.map { ($0.text, $0.detailText, $0.isPlaying) }
    }
}
