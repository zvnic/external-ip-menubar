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

@main
struct ExternalIPMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var ipMenuItem: NSMenuItem?
    private var updatedMenuItem: NSMenuItem?
    private var copyMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "zvnic.ExternalIPMenuBar.network")

    private var currentIP: String?
    private var refreshTask: Task<Void, Never>?
    private var debounceWorkItem: DispatchWorkItem?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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

            // Дебаунс: при переключении сети приходит несколько событий подряд.
            DispatchQueue.main.async {
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
            let ip = await Self.fetch_external_ip()
            guard !Task.isCancelled else { return }
            await self?.applyResult(ip)
        }
    }

    @MainActor
    private func applyResult(_ ip: String?) {
        guard let ip else {
            showNoNetwork()
            return
        }

        currentIP = ip

        set_status_icon(
            systemName: "network",
            color: .systemGreen,
            tooltip: "External IP: \(ip)",
            title: " \(ip)"
        )

        ipMenuItem?.title = "IP: \(ip)"
        updatedMenuItem?.title = "Обновлено: \(timeFormatter.string(from: Date()))"
    }

    private func showNoNetwork() {
        currentIP = nil
        set_status_icon(
            systemName: "wifi.exclamationmark",
            color: .systemRed,
            tooltip: "Нет сети",
            title: " нет сети"
        )
        ipMenuItem?.title = "IP: нет сети"
        updatedMenuItem?.title = "Обновлено: \(timeFormatter.string(from: Date()))"
    }

    private static func fetch_external_ip() async -> String? {
        let urls = [
            "https://api.ipify.org",
            "https://ifconfig.me/ip",
            "https://icanhazip.com"
        ]

        for url_string in urls {
            guard let url = URL(string: url_string) else {
                continue
            }

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

    private static func is_valid_ip(_ value: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#

        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return false
        }

        return value
            .split(separator: ".")
            .compactMap { Int($0) }
            .allSatisfy { $0 >= 0 && $0 <= 255 }
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
