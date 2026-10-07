#if canImport(UIKit)
import UIKit

/// The debug screen every SDK presents: the device, the channel, the releases, the last check, the index, the configuration
/// and this session's log, a check-now button and a share button that opens the share sheet with the screen as text.
public final class DebugScreenViewController: UITableViewController {
    private let core: Core
    private var sections: [DebugSection] = []

    public init(core: Core) {
        self.core = core
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The screen inside a navigation controller, modally over the presenter.
    public static func present(core: Core, from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: DebugScreenViewController(core: core))
        presenter.present(navigation, animated: true)
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        title = "HotCodePush"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissScreen))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share)),
            UIBarButtonItem(title: "Check now", style: .plain, target: self, action: #selector(checkNow))
        ]
        reload()
    }

    private func reload() {
        Task {
            let snapshot = await core.debugSnapshot()
            sections = DebugReport.sections(of: snapshot)
            tableView.reloadData()
        }
    }

    @objc private func checkNow() {
        Task {
            _ = try? await core.sync(trigger: .manual)
            reload()
        }
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        Task {
            let text = DebugReport.text(of: await core.debugSnapshot())
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = sender
            present(sheet, animated: true)
        }
    }

    @objc private func dismissScreen() {
        dismiss(animated: true)
    }

    // MARK: The table

    override public func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        cell.selectionStyle = .none
        cell.textLabel?.text = row.label
        cell.textLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.textLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = row.value
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.textColor = .label
        cell.detailTextLabel?.numberOfLines = 0
        return cell
    }
}
#endif
