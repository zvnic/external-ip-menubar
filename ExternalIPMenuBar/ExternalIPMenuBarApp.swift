//
//  ExternalIPMenuBarApp.swift
//  ExternalIPMenuBar
//
//  Created by zvnic on 27.04.2026.
//

import SwiftUI
import AppKit
import Network
import ServiceManagement
import Darwin

@main
struct ExternalIPMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Результат запроса внешнего IP вместе с геоданными (если их удалось получить).
struct IPInfo {
    let ip: String
    var country: String?
    var countryCode: String?
    var flag: String?
    var isp: String?

    var isIPv6: Bool { ip.contains(":") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var ipMenuItem: NSMenuItem?
    private var geoMenuItem: NSMenuItem?
    private var netMenuItem: NSMenuItem?
    private var updatedMenuItem: NSMenuItem?
    private var copyMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "zvnic.ExternalIPMenuBar.network")

    private var currentIP: String?
    private var lastInterfaceType: NWInterface.InterfaceType?
    private var refreshTask: Task<Void, Never>?
    private var debounceWorkItem: DispatchWorkItem?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запрет дубликатов: если копия с тем же bundle id уже запущена
        // (другой путь, автозапуск + ручной старт и т.п.) — выходим.
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        set_status_icon(
            systemName: "network",
            color: .systemOrange,
            tooltip: "Получение IP...",
            title: " ..."
        )

        buildMenu()
        startNetworkMonitor()
        refresh_ip()

        // Резервное периодическое обновление (на случай смены IP без смены сети).
        timer = Timer.scheduledTimer(
            timeInterval: 300,
            target: self,
            selector: #selector(refresh_ip),
            userInfo: nil,
            repeats: true
        )
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        return !others.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        pathMonitor.cancel()
        timer?.invalidate()
        refreshTask?.cancel()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        ipMenuItem = NSMenuItem(
            title: "IP: ...",
            action: #selector(copy_ip),
            keyEquivalent: ""
        )
        ipMenuItem?.target = self
        menu.addItem(ipMenuItem!)

        geoMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        geoMenuItem?.isEnabled = false
        geoMenuItem?.isHidden = true
        menu.addItem(geoMenuItem!)

        netMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        netMenuItem?.isEnabled = false
        netMenuItem?.isHidden = true
        menu.addItem(netMenuItem!)

        updatedMenuItem = NSMenuItem(title: "Обновлено: —", action: nil, keyEquivalent: "")
        updatedMenuItem?.isEnabled = false
        menu.addItem(updatedMenuItem!)

        menu.addItem(NSMenuItem.separator())

        copyMenuItem = NSMenuItem(
            title: "Скопировать IP",
            action: #selector(copy_ip),
            keyEquivalent: "c"
        )
        copyMenuItem?.target = self
        menu.addItem(copyMenuItem!)

        let refreshItem = NSMenuItem(
            title: "Обновить",
            action: #selector(refresh_ip),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        loginMenuItem = NSMenuItem(
            title: "Запускать при входе",
            action: #selector(toggle_login),
            keyEquivalent: ""
        )
        loginMenuItem?.target = self
        menu.addItem(loginMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let authorItem = NSMenuItem(title: "Автор — @zvnic", action: nil, keyEquivalent: "")
        authorItem.isEnabled = false
        menu.addItem(authorItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Выход",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        updateLoginMenuState()
    }

    // MARK: - Network monitoring

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let type = Self.primaryInterfaceType(path)

            // Дебаунс: при переключении сети приходит несколько событий подряд.
            DispatchQueue.main.async {
                self.lastInterfaceType = type
                self.debounceWorkItem?.cancel()

                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if path.status == .satisfied {
                        self.refresh_ip()
                    } else {
                        self.showNoNetwork()
                    }
                }

                self.debounceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private static func primaryInterfaceType(_ path: NWPath) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular, .other, .loopback] {
            if path.usesInterfaceType(type) {
                return type
            }
        }
        return nil
    }

    // MARK: - Refresh

    @objc private func refresh_ip() {
        set_status_icon(
            systemName: "arrow.triangle.2.circlepath",
            color: .systemOrange,
            tooltip: "Обновление IP...",
            title: " ..."
        )

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let info = await Self.fetch_ip_info()
            guard !Task.isCancelled else { return }
            await self?.applyResult(info)
        }
    }

    @MainActor
    private func applyResult(_ info: IPInfo?) {
        guard let info else {
            showNoNetwork()
            return
        }

        currentIP = info.ip

        let vpnActive = Self.isVPNActive()

        // Геострока: 🇩🇪 Германия — Deutsche Telekom
        if info.country != nil || info.isp != nil {
            let flag = info.flag.map { "\($0) " } ?? ""
            let country = info.country ?? info.countryCode ?? ""
            let isp = info.isp.map { country.isEmpty ? $0 : " — \($0)" } ?? ""
            geoMenuItem?.title = "\(flag)\(country)\(isp)"
            geoMenuItem?.isHidden = false
        } else {
            geoMenuItem?.isHidden = true
        }

        // Сетевая строка: Сеть: Wi-Fi · VPN: активен
        var netParts = ["Сеть: \(networkTypeName(lastInterfaceType))"]
        if vpnActive {
            netParts.append("VPN: активен")
        }
        if info.isIPv6 {
            netParts.append("IPv6")
        }
        netMenuItem?.title = netParts.joined(separator: " · ")
        netMenuItem?.isHidden = false

        updatedMenuItem?.title = "Обновлено: \(timeFormatter.string(from: Date()))"
        ipMenuItem?.title = "IP: \(info.ip)"

        // Иконка в статус-баре: при VPN — щит, иначе сеть.
        var tooltipLines = ["External IP: \(info.ip)"]
        if let geo = geoMenuItem?.title, geoMenuItem?.isHidden == false {
            tooltipLines.append(geo)
        }
        tooltipLines.append(netMenuItem?.title ?? "")

        set_status_icon(
            systemName: vpnActive ? "lock.shield" : "network",
            color: vpnActive ? .systemBlue : .systemGreen,
            tooltip: tooltipLines.joined(separator: "\n"),
            title: " \(info.ip)"
        )
    }

    private func networkTypeName(_ type: NWInterface.InterfaceType?) -> String {
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "Сотовая"
        case .loopback: return "loopback"
        case .other: return "прочая"
        default: return "неизвестно"
        }
    }

    private func showNoNetwork() {
        currentIP = nil
        geoMenuItem?.isHidden = true
        netMenuItem?.isHidden = true
        set_status_icon(
            systemName: "wifi.exclamationmark",
            color: .systemRed,
            tooltip: "Нет сети",
            title: " нет сети"
        )
        ipMenuItem?.title = "IP: нет сети"
        updatedMenuItem?.title = "Обновлено: \(timeFormatter.string(from: Date()))"
    }

    // MARK: - Fetching

    private struct IPWhoResponse: Decodable {
        let ip: String?
        let success: Bool?
        let country: String?
        let country_code: String?
        let connection: Connection?
        let flag: Flag?

        struct Connection: Decodable { let isp: String?; let org: String? }
        struct Flag: Decodable { let emoji: String? }
    }

    private static func fetch_ip_info() async -> IPInfo? {
        // 1. ipwho.is отдаёт IP + страну + провайдера + флаг одним HTTPS-запросом.
        if let info = await fetch_from_ipwhois() {
            return info
        }

        // 2. Резерв: быстрые провайдеры, отдающие только сам IP (без гео).
        if let ip = await fetch_plain_ip() {
            return IPInfo(ip: ip)
        }

        return nil
    }

    private static func fetch_from_ipwhois() async -> IPInfo? {
        guard let url = URL(string: "https://ipwho.is/") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(IPWhoResponse.self, from: data)

            guard decoded.success == true,
                  let ip = decoded.ip,
                  is_valid_ip(ip)
            else {
                return nil
            }

            return IPInfo(
                ip: ip,
                country: decoded.country,
                countryCode: decoded.country_code,
                flag: decoded.flag?.emoji,
                isp: decoded.connection?.isp ?? decoded.connection?.org
            )
        } catch {
            return nil
        }
    }

    private static func fetch_plain_ip() async -> String? {
        let urls = [
            "https://api64.ipify.org",   // вернёт IPv4 или IPv6 в зависимости от подключения
            "https://ifconfig.me/ip",
            "https://icanhazip.com"
        ]

        for url_string in urls {
            guard let url = URL(string: url_string) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                request.cachePolicy = .reloadIgnoringLocalCacheData

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let ip = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      is_valid_ip(ip)
                else {
                    continue
                }
                return ip
            } catch {
                continue
            }
        }
        return nil
    }

    /// Валидация IPv4 и IPv6 через системный inet_pton.
    private static func is_valid_ip(_ value: String) -> Bool {
        var buf4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &buf4) }) == 1 {
            return true
        }
        var buf6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &buf6) }) == 1 {
            return true
        }
        return false
    }

    /// Эвристика наличия VPN: ищем поднятый туннельный интерфейс с назначенным адресом.
    /// Учитывает utun/ppp/ipsec/tap/tun. Может срабатывать и на iCloud Private Relay.
    private static func isVPNActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }

        let tunnelPrefixes = ["utun", "ppp", "ipsec", "tap", "tun"]
        var ptr = addrs
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            let flags = Int32(current.pointee.ifa_flags)
            let family = current.pointee.ifa_addr?.pointee.sa_family

            let isUp = (flags & Int32(IFF_UP)) != 0
            let hasIPv4 = family == sa_family_t(AF_INET)

            if isUp, hasIPv4, tunnelPrefixes.contains(where: { name.hasPrefix($0) }) {
                return true
            }
            ptr = current.pointee.ifa_next
        }
        return false
    }

    // MARK: - Actions

    @objc private func copy_ip() {
        guard let ip = currentIP else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ip, forType: .string)
    }

    @objc private func toggle_login() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Login item toggle failed: \(error.localizedDescription)")
        }
        updateLoginMenuState()
    }

    private func updateLoginMenuState() {
        loginMenuItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Status icon

    private func set_status_icon(
        systemName: String,
        color: NSColor,
        tooltip: String,
        title: String
    ) {
        guard let button = statusItem?.button else {
            return
        }

        let image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: tooltip
        )

        image?.isTemplate = false

        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        button.image = image?.withSymbolConfiguration(config)

        button.title = title
        button.toolTip = tooltip
    }
}
