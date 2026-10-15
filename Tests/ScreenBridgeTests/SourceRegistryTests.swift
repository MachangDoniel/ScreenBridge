import Foundation
import Testing
@testable import ScreenBridge
import ScreenBridgeProtocol
#if canImport(UIKit)
import UIKit
#endif

#if SCREENBRIDGE_ENABLED

private class BaseScreen: NSObject {}
private final class DerivedScreen: BaseScreen {}
private final class ProfileViewModel {}
private final class UnregisteredService {}

@MainActor
@Suite(.serialized) struct SourceRegistryTests {
    let root = "/Users/dev/App"

    @Test func typeRegistrationResolvesThroughSuperclass() {
        let registry = SourceRegistry()
        registry.register(type: BaseScreen.self, registration: SourceRegistration(symbol: "BaseScreen", role: "screen", file: "\(root)/Sources/Base.swift", line: 10))
        let reg = registry.registration(forClassOf: DerivedScreen())
        #expect(reg?.symbol == "BaseScreen")
    }

    @Test func instanceRegistrationWinsAndIsOverwritten() {
        let registry = SourceRegistry()
        let obj = NSObject()
        registry.attach(SourceRegistration(symbol: "First", role: "view", file: "\(root)/A.swift", line: 1), to: obj)
        registry.attach(SourceRegistration(symbol: "Second", role: "view", file: "\(root)/B.swift", line: 2), to: obj)
        #expect(registry.instanceRegistration(of: obj) == .valid(SourceRegistration(symbol: "Second", role: "view", file: "\(root)/B.swift", line: 2)))
    }

    @Test func reuseValidityDetectsStaleRegistration() {
        let registry = SourceRegistry()
        final class Container: NSObject { var current: [ObjectIdentifier: IndexPath] = [:] }
        let container = Container()
        let cell = NSObject()
        container.current[ObjectIdentifier(cell)] = IndexPath(indexes: [0, 0])
        let reg = SourceRegistration(symbol: "AccountCell", role: "cell", file: "\(root)/Cell.swift", line: 5)
        registry.attach(reg, to: cell, reuse: ReuseValidity(container: container, indexPath: IndexPath(indexes: [0, 0])) { c, cell in
            (c as? Container)?.current[ObjectIdentifier(cell)]
        })
        #expect(registry.instanceRegistration(of: cell) == .valid(reg))

        // The cell is reused for row 7 without re-registering.
        container.current[ObjectIdentifier(cell)] = IndexPath(indexes: [0, 7])
        guard case .stale(_, let reason) = registry.instanceRegistration(of: cell) else {
            Issue.record("stale registration was treated as valid")
            return
        }
        #expect(reason.contains("0/7"))
        // The effective lookup falls back (here: nothing) and reports the stale entry.
        let (eff, note) = registry.effectiveRegistration(of: cell)
        #expect(eff == nil)
        #expect(note != nil)
    }

    @Test func reuseValidityIsStaleWhenContainerIsGone() {
        let registry = SourceRegistry()
        let cell = NSObject()
        do {
            let container = NSObject()
            registry.attach(SourceRegistration(symbol: "C", role: "cell", file: "f", line: 1), to: cell, reuse: ReuseValidity(container: container, indexPath: IndexPath(indexes: [0, 0])) { _, _ in IndexPath(indexes: [0, 0]) })
        }
        guard case .stale = registry.instanceRegistration(of: cell) else {
            Issue.record("expected stale after container deallocation")
            return
        }
    }

    @Test func registrationDoesNotRetainObjectsOrContainers() {
        let registry = SourceRegistry()
        weak var weakObject: NSObject?
        weak var weakContainer: NSObject?
        do {
            let obj = NSObject()
            let container = NSObject()
            weakObject = obj
            weakContainer = container
            registry.attach(SourceRegistration(symbol: "X", role: "cell", file: "f", line: 1), to: obj, reuse: ReuseValidity(container: container, indexPath: IndexPath(indexes: [0, 0])) { _, _ in nil })
            registry.register(type: NSObject.self, registration: SourceRegistration(symbol: "T", role: "screen", file: "f", line: 1))
        }
        #expect(weakObject == nil)
        #expect(weakContainer == nil)
    }

    @Test func anchorsAreRepositoryRelativeWithProvenance() {
        let registry = SourceRegistry()
        registry.register(type: ProfileViewModel.self, registration: SourceRegistration(symbol: "ProfileViewModel", role: "viewModel", file: "\(root)/Sources/Profile/ProfileViewModel.swift", line: 8))
        let reg = SourceRegistration(symbol: "ProfileScreen", role: "screen", file: "\(root)/Sources/Profile/ProfileScreen.swift", line: 20, related: [
            .type(ProfileViewModel.self, role: "viewModel"),
            .type(UnregisteredService.self, role: "service"),
            .file("\(root)/Sources/API/Client.swift", line: 3, role: "service"),
            .file("/elsewhere/Outside.swift"),
        ])
        let anchors = registry.anchors(for: reg, projectRoot: root)
        #expect(anchors[0] == SourceAnchor(symbol: "ProfileScreen", role: "screen", path: "Sources/Profile/ProfileScreen.swift", line: 20, pathStatus: .repositoryRelative, evidence: .registered))
        #expect(anchors[1].path == "Sources/Profile/ProfileViewModel.swift" && anchors[1].line == 8)
        #expect(anchors[2].path == nil && anchors[2].pathStatus == .unknown)
        #expect(anchors[3].path == "Sources/API/Client.swift")
        #expect(anchors[4].path == "Outside.swift" && anchors[4].pathStatus == .outsideProject)
        #expect(anchors.allSatisfy { !($0.path ?? "").hasPrefix("/") })
    }
}

#if canImport(UIKit)
/// Real UITableView reuse: a cell registered for one row must not report that
/// registration after it is reused for another row.
@MainActor
@Suite(.serialized) struct UIKitReuseTests {
    final class DataSource: NSObject, UITableViewDataSource {
        var registerRows: Set<Int> = []
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 200 }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
            cell.textLabel?.text = "Row \(indexPath.row)"
            if registerRows.contains(indexPath.row) {
                cell.screenBridgeSource("Row\(indexPath.row)Cell", at: indexPath, in: tableView)
            }
            return cell
        }
    }

    @Test func reusedCellDropsStaleRegistration() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let table = UITableView(frame: window.bounds)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        let ds = DataSource()
        ds.registerRows = [0] // only row 0 registers
        table.dataSource = ds
        window.addSubview(table)
        window.isHidden = false
        table.layoutIfNeeded()

        let cell0 = try #require(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        guard case .valid(let reg) = SourceRegistry.shared.instanceRegistration(of: cell0) else {
            Issue.record("row 0 should be registered")
            return
        }
        #expect(reg.symbol == "Row0Cell" && reg.role == "cell" && reg.file.hasSuffix("SourceRegistryTests.swift"))

        // Scroll far enough that row 0's cell is reused for a row that doesn't register.
        table.scrollToRow(at: IndexPath(row: 150, section: 0), at: .top, animated: false)
        table.layoutIfNeeded()
        let visibleNow = table.visibleCells
        for cell in visibleNow {
            switch SourceRegistry.shared.instanceRegistration(of: cell) {
            case .valid(let r): Issue.record("reused cell still claims \(r.symbol) at \(table.indexPath(for: cell)!)")
            default: break
            }
        }
        // Whether row 0's cell was reused for another row or parked in the reuse pool,
        // its old registration must not be reported as valid.
        if case .valid = SourceRegistry.shared.instanceRegistration(of: cell0) {
            Issue.record("row 0's registration survived reuse")
        }
    }

    @Test func viewControllerRegistrationIsReleasedWithController() {
        weak var weakVC: UIViewController?
        do {
            let vc = UIViewController()
            vc.screenBridgeSource("Temp")
            weakVC = vc
        }
        #expect(weakVC == nil)
    }
}
#endif

#endif
