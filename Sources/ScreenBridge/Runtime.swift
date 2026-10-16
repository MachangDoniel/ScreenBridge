#if SCREENBRIDGE_ENABLED && canImport(UIKit)
import UIKit
import ScreenBridgeProtocol

/// Main-actor coordinator: loads the build-generated configuration and attaches one
/// overlay per foreground window scene.
@MainActor
final class ScreenBridgeRuntime: NSObject {
    static let shared = ScreenBridgeRuntime()

    private(set) var options = ScreenBridge.Options()
    private(set) var connection: ConnectionManager?
    private var overlays: [ObjectIdentifier: OverlayWindowController] = [:]
    private var started = false

    var projectRoot: String? { connection?.config?.projectRoot }

    func start(_ options: ScreenBridge.Options) {
        guard !started else { return }
        started = true
        self.options = options

        let (config, problem) = Self.loadConfiguration(options.connectionConfigurationURL)
        if let problem { ScreenBridge.log(problem, level: .warning, category: "connection") }
        let manager = ConnectionManager(config: config, configProblem: problem, outboxCapacity: options.outboxCapacity)
        connection = manager
        ScreenBridge.log("Debug inspector started", category: "lifecycle")
        manager.start()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sceneActivated(_:)), name: UIScene.didActivateNotification, object: nil)
        nc.addObserver(self, selector: #selector(sceneWillEnterForeground(_:)), name: UIScene.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(sceneDisconnected(_:)), name: UIScene.didDisconnectNotification, object: nil)
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene, ws.activationState != .background, ws.activationState != .unattached {
                attach(to: ws)
            }
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        for (_, o) in overlays { o.tearDown() }
        overlays.removeAll()
        connection?.stop()
        connection = nil
        started = false
    }

    @objc private func sceneActivated(_ n: Notification) {
        if let s = n.object as? UIWindowScene { attach(to: s) }
    }

    @objc private func sceneWillEnterForeground(_ n: Notification) {
        if let s = n.object as? UIWindowScene { attach(to: s) }
        connection?.resume()
    }

    @objc private func sceneDisconnected(_ n: Notification) {
        if let s = n.object as? UIScene { detach(from: s) }
    }

    private func attach(to scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard overlays[key] == nil, options.showsFloatingButton, let connection else { return }
        overlays[key] = OverlayWindowController(scene: scene, connection: connection)
    }

    private func detach(from scene: UIScene) {
        let key = ObjectIdentifier(scene)
        overlays[key]?.tearDown()
        overlays[key] = nil
    }

    static func loadConfiguration(_ override: URL?) -> (ConnectionConfig?, String?) {
        let url = override ?? Bundle.main.url(forResource: WireProtocol.connectionResourceName, withExtension: WireProtocol.connectionResourceExtension)
        guard let url else {
            return (nil, "This build has no ScreenBridgeConnection.json. Add the ScreenBridge build phase to your app target, open the ScreenBridge helper on your Mac, and rebuild. See Docs/Installation.md.")
        }
        do {
            let config = try ConnectionConfig.decode(Data(contentsOf: url))
            if let bundleID = Bundle.main.bundleIdentifier, bundleID != config.appBundleIdentifier {
                return (nil, "The connection file was generated for \(config.appBundleIdentifier), not \(bundleID). Clean the build folder and rebuild.")
            }
            return (config, nil)
        } catch {
            return (nil, "ScreenBridgeConnection.json could not be read (\(error)). Rebuild with the current ScreenBridge helper.")
        }
    }
}
#endif
