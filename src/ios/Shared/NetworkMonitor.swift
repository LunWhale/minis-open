import Foundation
import Network
import CFNetwork

// BEGIN ContainerDnsSettings
/// [T-container-network-dns GH#396] What the Shell Container's /etc/resolv.conf
/// should contain: the system's DNS (`auto`, the default) or a fixed list the
/// user entered (`custom`).
///
/// Why both: some networks (LAN-only resolvers, Tailscale, private DNS) hand out
/// servers that cannot resolve public names, so `apk add` / `pip` / `git` time
/// out — those users need their own servers. But forcing public DNS for
/// everyone breaks proxy apps in Fake-IP / TUN mode (Clash, Surge, sing-box),
/// whose system DNS must stay in charge. So `auto` stays exactly as before and
/// `custom` is opt-in: in `custom` the file is built only from the user's
/// validated addresses and is no longer replaced when the network changes.
///
/// Pure (Foundation + inet_pton/inet_ntop) and exposed to Objective-C, so the
/// kernel's `configureDns` asks it first and MinisTests/Standalone/
/// ISHContainerNetworkDnsTests.swift compiles this block by itself.
@objc(MinisContainerDns)
final class ContainerDnsSettings: NSObject {
    enum Mode: String, CaseIterable {
        case auto, custom
    }

    /// UserDefaults keys; also the `minis-config` paths.
    static let modeKey = "network.dnsMode"
    static let serversKey = "network.dnsCustomServers"

    struct Parsed: Equatable {
        /// Valid addresses in canonical form, first occurrence order, no duplicates.
        var servers: [String]
        /// Tokens that are not an IPv4 or IPv6 address, as typed.
        var invalid: [String]
    }

    /// Split `text` on newlines, commas, semicolons and whitespace, and check
    /// every token. IPv6 zone ids (`fe80::1%en0`), brackets and ports are not
    /// addresses a resolver can use from inside the container, so they are
    /// invalid rather than silently stripped.
    static func parse(_ text: String) -> Parsed {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        var out = Parsed(servers: [], invalid: [])
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            if let address = canonicalAddress(token) {
                if !out.servers.contains(address) { out.servers.append(address) }
            } else if !out.invalid.contains(token) {
                out.invalid.append(token)
            }
        }
        return out
    }

    /// The address in canonical form (`2001:4860:4860::8888`, `10.0.0.1`), or
    /// nil if `token` is not a literal IPv4 or IPv6 address.
    static func canonicalAddress(_ token: String) -> String? {
        // Darwin's inet_pton ACCEPTS a zone id and folds the interface index
        // into the address (`fe80::1%en0` → `fe80:7::1`, a different, bogus
        // address), so reject `%` before parsing.
        guard !token.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, token, &v4) == 1 {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &buf, socklen_t(buf.count)) != nil else { return nil }
            return String(cString: buf)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, token, &v6) == 1 {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &buf, socklen_t(buf.count)) != nil else { return nil }
            return String(cString: buf)
        }
        return nil
    }

    /// resolv.conf for a custom list: one `nameserver` line per address, in the
    /// user's order. No `search` line — custom mode is exactly what was entered.
    static func resolvConf(servers: [String]) -> String {
        var out = "# Custom DNS set in Minis (Rootfs > Container Network).\n"
            + "# Kept across network changes; set DNS Mode to Auto to follow the system.\n"
        for server in servers { out += "nameserver \(server)\n" }
        return out
    }

    static func mode(_ defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .auto
    }

    /// The saved list, re-validated on read: a value written by an older build
    /// or by hand can never put a malformed line into resolv.conf.
    static func storedServers(_ defaults: UserDefaults = .standard) -> [String] {
        parse(defaults.string(forKey: serversKey) ?? "").servers
    }

    /// The resolv.conf to write in custom mode, or nil when the system's DNS
    /// should be used: mode `auto`, or `custom` with no valid server saved
    /// (an empty resolv.conf would break every lookup, so custom-without-servers
    /// falls back to auto instead).
    static func customResolvConf(_ defaults: UserDefaults = .standard) -> String? {
        guard mode(defaults) == .custom else { return nil }
        let servers = storedServers(defaults)
        guard !servers.isEmpty else { return nil }
        return resolvConf(servers: servers)
    }

    /// Objective-C entry for `-[ISHKernel configureDns]`.
    @objc static func customResolvConfForKernel() -> String? {
        customResolvConf()
    }
}
// END ContainerDnsSettings

/// Monitors network path changes and updates iSH's /etc/resolv.conf
/// so DNS resolution stays current when switching between WiFi/cellular/etc.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openminis.networkmonitor")
    private let logger = AppLogger(category: "Network")
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType> = []
    private var isStarted = false

    private init() {}

    func start() {
        NSLog("NetworkMonitor: start() called, isStarted=%d", isStarted ? 1 : 0)
        guard !isStarted else { return }
        isStarted = true

        // Capture initial state and do an immediate DNS write so resolv.conf is
        // populated before the first NWPathMonitor callback fires (which can be
        // delayed by several hundred milliseconds).
        let initialPath = monitor.currentPath
        lastInterfaceTypes = activeInterfaceTypes(initialPath)
        logger.info("[Network] Monitor started — writing initial DNS config")
        NSLog("NetworkMonitor: about to refreshDns + dump proxy")
        ISHKernel.shared.refreshDns()
        dumpSystemProxySettings(reason: "monitor-start")

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
        logger.info("[Network] Monitor stopped")
    }

    private func handlePathUpdate(_ path: NWPath) {
        let currentTypes = activeInterfaceTypes(path)
        let satisfied = path.status == .satisfied

        logger.info("[Network] Path update — status: \(String(describing: path.status)), interfaces: \(currentTypes.map { String(describing: $0) })")

        let typesChanged = currentTypes != lastInterfaceTypes
        lastInterfaceTypes = currentTypes

        // Always refresh DNS on any path update — even when unsatisfied, refreshDns
        // will write the public-DNS fallback so resolv.conf is never left empty.
        if !satisfied {
            logger.info("[Network] Network unsatisfied — writing fallback DNS")
        } else if typesChanged {
            logger.info("[Network] Interface change detected — refreshing DNS")
        } else {
            logger.info("[Network] Path updated — refreshing DNS")
        }

        ISHKernel.shared.refreshDns()
        dumpSystemProxySettings(reason: typesChanged ? "interface-change" : "path-update")

        // Evict LLM provider connection pools ONLY when the active interface
        // set actually changed (WiFi <-> cellular, gained/lost connectivity,
        // airplane toggle). After such a transition the pooled HTTP/2
        // connections backing our long-lived streaming sessions can be dead
        // sockets; reusing one on a retry hangs until the 600s timeout. A
        // plain path tick with the SAME interfaces (signal-strength wobble,
        // route refresh) does NOT evict, so steady-state requests and
        // in-flight streams are never disturbed. Mirrors Android #740.
        if typesChanged {
            LLMSessionRegistry.shared.evictAllConnections(
                reason: satisfied ? "interface-change" : "connectivity-lost")
        }
    }

    /// Diagnostic: dump CFNetwork's view of the system proxy settings.
    /// Used to verify what (if anything) we see on 5G + VPN scenarios before
    /// deciding whether/how to inject http_proxy into the iSH shell.
    private func dumpSystemProxySettings(reason: String) {
        guard let cf = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let dict = cf as? [String: Any] else {
            logger.info("[Proxy] dump (\(reason)): CFNetworkCopySystemProxySettings returned nil")
            return
        }

        // Pull the keys we care about. iOS marks every CFNetworkProxies* CF
        // constant unavailable, so we use the documented string literals (same
        // values the macOS constants resolve to).
        let httpEnabled  = (dict["HTTPEnable"]   as? Int)    ?? 0
        let httpHost     =  dict["HTTPProxy"]    as? String
        let httpPort     =  dict["HTTPPort"]     as? Int
        let httpsEnabled = (dict["HTTPSEnable"]  as? Int)    ?? 0
        let httpsHost    =  dict["HTTPSProxy"]   as? String
        let httpsPort    =  dict["HTTPSPort"]    as? Int
        let socksEnabled = (dict["SOCKSEnable"]  as? Int)    ?? 0
        let socksHost    =  dict["SOCKSProxy"]   as? String
        let socksPort    =  dict["SOCKSPort"]    as? Int
        let pacEnabled   = (dict["ProxyAutoConfigEnable"]    as? Int) ?? 0
        let pacURL       =  dict["ProxyAutoConfigURLString"] as? String
        let exceptions   =  dict["ExceptionsList"]           as? [String]

        logger.info("[Proxy] dump (\(reason)) http=\(httpEnabled):\(httpHost ?? "-"):\(httpPort.map(String.init) ?? "-") https=\(httpsEnabled):\(httpsHost ?? "-"):\(httpsPort.map(String.init) ?? "-") socks=\(socksEnabled):\(socksHost ?? "-"):\(socksPort.map(String.init) ?? "-") pac=\(pacEnabled):\(pacURL ?? "-") exceptions=\(exceptions ?? [])")

        // Also dump every other key CFNetwork hands back so we don't miss
        // VPN-specific or future fields.
        let knownKeys: Set<String> = [
            "HTTPEnable", "HTTPProxy", "HTTPPort",
            "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
            "SOCKSEnable", "SOCKSProxy", "SOCKSPort",
            "ProxyAutoConfigEnable", "ProxyAutoConfigURLString",
            "ExceptionsList",
        ]
        let extras = dict.filter { !knownKeys.contains($0.key) }
        if !extras.isEmpty {
            logger.info("[Proxy] dump (\(reason)) extra keys: \(extras)")
        }

        // Per-URL probe: ask CFNetwork what it would actually pick for a real
        // request. On VPN-injected / PAC scenarios this may return a proxy
        // even when the top-level dict above looks empty.
        if let probeURL = URL(string: "https://api.anthropic.com/v1/messages") {
            let arr = CFNetworkCopyProxiesForURL(probeURL as CFURL, cf).takeRetainedValue() as? [[String: Any]]
            logger.info("[Proxy] dump (\(reason)) CFNetworkCopyProxiesForURL(api.anthropic.com)=\(arr ?? [])")
        }
    }

    private func activeInterfaceTypes(_ path: NWPath) -> Set<NWInterface.InterfaceType> {
        var types = Set<NWInterface.InterfaceType>()
        for iface in path.availableInterfaces {
            types.insert(iface.type)
        }
        return types
    }
}
