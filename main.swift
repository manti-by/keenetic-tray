import Cocoa
import CryptoKit
import CommonCrypto
import Security

// MARK: - Config

let routerHost = "http://192.168.1.1"
let routerLogin = "admin"
let keychainService = "keenetic-router"
let keychainAccount = "admin"

// MARK: - Keychain

func routerPassword() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
          let pwd = String(data: data, encoding: .utf8) else { return nil }
    return pwd
}

// MARK: - NDMS auth + HTTP

func md5Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

final class Router {
    private var cookie: String = ""

    private func send(_ req: URLRequest) -> (Int, [String: String], Data)? {
        var r = req
        if !cookie.isEmpty { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let sema = DispatchSemaphore(value: 0)
        var out: (Int, [String: String], Data)?
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            if let http = resp as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headers[String(describing: k).lowercased()] = String(describing: v)
                }
                out = (http.statusCode, headers, data ?? Data())
            }
            sema.signal()
        }.resume()
        sema.wait()
        return out
    }

    func login() throws {
        guard let url = URL(string: "\(routerHost)/auth") else { throw E.badURL }
        guard let (code, headers, _) = send(URLRequest(url: url)) else {
            FileHandle.standardError.write("auth: no response\n".data(using: .utf8)!); throw E.authFailed
        }
        if code == 200 { return } // shared cookie jar already has a valid session
        guard code == 401, let realm = headers["x-ndm-realm"], let challenge = headers["x-ndm-challenge"] else {
            FileHandle.standardError.write("auth: unexpected GET /auth: code=\(code)\n".data(using: .utf8)!); throw E.authFailed
        }
        if let sc = headers["set-cookie"] { cookie = sc.components(separatedBy: ";").first ?? "" }
        guard let password = routerPassword() else { throw E.noPassword }
        let md5 = md5Hex("\(routerLogin):\(realm):\(password)")
        let sha = sha256Hex(challenge + md5)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["login": routerLogin, "password": sha])
        let resp = send(req)
        guard let resp, resp.0 == 200 else {
            FileHandle.standardError.write("auth: POST /auth failed: code=\(String(describing: resp?.0)) body=\(String(data: resp?.2 ?? Data(), encoding: .utf8) ?? "")\n".data(using: .utf8)!)
            throw E.authFailed
        }
        let h2 = resp.1
        if let sc = h2["set-cookie"] { cookie = sc.components(separatedBy: ";").first ?? cookie }
    }

    func get(_ path: String) throws -> Any {
        guard let url = URL(string: "\(routerHost)\(path)") else { throw E.badURL }
        var code: Int?
        var data: Data?
        for _ in 0..<2 {
            try loginIfNeeded()
            if let (c, _, d) = send(URLRequest(url: url)) { code = c; data = d }
            if code == 200 { break }
            authed = false // session may have expired — re-authenticate once
        }
        guard code == 200, let data else { throw E.requestFailedMsg(String(data: data ?? Data(), encoding: .utf8) ?? "HTTP error") }
        return try JSONSerialization.jsonObject(with: data)
    }

    func post(_ path: String, body: [String: Any]) throws {
        guard let url = URL(string: "\(routerHost)\(path)") else { throw E.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try loginIfNeeded()
        var resp = send(req)
        if resp?.0 != 200 {
            authed = false // session may have expired — re-authenticate once
            try loginIfNeeded()
            resp = send(req)
        }
        guard let resp, resp.0 == 200 else {
            throw E.requestFailedMsg(resp.flatMap { String(data: $0.2, encoding: .utf8) } ?? "HTTP error")
        }
    }

    private var authed = false
    private func loginIfNeeded() throws {
        if !authed {
            try login()
            authed = true
        }
    }

    enum E: Error, CustomStringConvertible {
        case badURL, authFailed, noPassword, requestFailed, requestFailedMsg(String)
        var description: String {
            switch self {
            case .badURL: return "bad URL"
            case .authFailed: return "auth failed"
            case .noPassword: return "password not found in Keychain (service: \(keychainService), account: \(keychainAccount))"
            case .requestFailed: return "request failed"
            case .requestFailedMsg(let m): return "request failed: \(m)"
            }
        }
    }
}

// MARK: - Models

struct Host {
    let mac: String
    let name: String
    let hostname: String
    let ip: String
    let policy: String // "" = default
    let active: Bool
}

struct Policy {
    let id: String
    let description: String
}

func fetchHosts(_ r: Router) throws -> [Host] {
    let obj = try r.get("/rci/show/ip/hotspot") as? [String: Any]
    guard let list = obj?["host"] as? [[String: Any]] else { return [] }
    return list.map { h in
        Host(mac: h["mac"] as? String ?? "",
             name: h["name"] as? String ?? "",
             hostname: h["hostname"] as? String ?? "",
             ip: h["ip"] as? String ?? "",
             policy: h["policy"] as? String ?? "",
             active: h["active"] as? Bool ?? false)
    }
}

func fetchPolicies(_ r: Router) throws -> [Policy] {
    let obj = try r.get("/rci/show/ip/policy") as? [String: Any] ?? [:]
    var result: [Policy] = []
    for (id, v) in obj {
        guard let d = v as? [String: Any] else { continue }
        result.append(Policy(id: id, description: d["description"] as? String ?? id))
    }
    return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
}

// MARK: - App

let routerIconPNGBase64 = "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"

func trayIcon() -> NSImage? {
    guard let data = Data(base64Encoded: routerIconPNGBase64),
          let img = NSImage(data: data) else { return nil }
    img.size = NSSize(width: 18, height: 18)
    img.isTemplate = true
    return img
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let router = Router()
    var hosts: [Host] = []
    var policies: [Policy] = []
    var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let img = trayIcon() {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "⌁"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshAsync()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }
    }

    func refreshAsync() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let h = try fetchHosts(self.router)
                let p = try fetchPolicies(self.router)
                DispatchQueue.main.async {
                    self.hosts = h.sorted { ($0.name.isEmpty ? $0.hostname : $0.name).localizedStandardCompare($1.name.isEmpty ? $1.hostname : $1.name) == .orderedAscending }
                    self.policies = p
                    self.lastError = nil
                    self.setIconError(false)
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = String(describing: error)
                    self.setIconError(true)
                }
            }
        }
    }

    // NSMenuDelegate — rebuild menu each time it opens
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        if let err = lastError {
            let it = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            menu.addItem(.separator())
        }
        let allowed = allowedClients()
        let shown: [Host] = allowed.isEmpty ? hosts : hosts.filter { h in
            allowed.contains(h.name.lowercased()) || allowed.contains(h.hostname.lowercased())
        }
        if shown.isEmpty {
            let it = NSMenuItem(title: "No clients (click Refresh)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        for host in shown {
            let title = "\(host.name.isEmpty ? host.hostname : host.name)\(host.active ? "" : " (offline)")"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let defaultItem = NSMenuItem(title: "Default policy", action: #selector(setDefault(_:)), keyEquivalent: "")
            defaultItem.target = self
            defaultItem.representedObject = host.mac
            defaultItem.state = host.policy.isEmpty ? .on : .off
            sub.addItem(defaultItem)
            for p in policies {
                let pi = NSMenuItem(title: p.description, action: #selector(setPolicy(_:)), keyEquivalent: "")
                pi.target = self
                pi.representedObject = [host.mac, p.id]
                pi.state = host.policy == p.id ? .on : .off
                sub.addItem(pi)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func refresh() { refreshAsync() }

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Visible clients"
        alert.informativeText = "Comma-separated list of client names (as shown on the router) to display in the menu. Leave empty to show all clients."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = UserDefaults.standard.string(forKey: "allowedClients") ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(input.stringValue, forKey: "allowedClients")
        }
    }

    func allowedClients() -> [String] {
        let s = UserDefaults.standard.string(forKey: "allowedClients") ?? ""
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    @objc func setDefault(_ sender: NSMenuItem) {
        guard let mac = sender.representedObject as? String else { return }
        apply(mac: mac, policy: nil)
    }

    @objc func setPolicy(_ sender: NSMenuItem) {
        guard let ro = sender.representedObject as? [String], ro.count == 2 else { return }
        apply(mac: ro[0], policy: ro[1])
    }

    func apply(mac: String, policy: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var body: [String: Any] = ["mac": mac]
                if let policy { body["policy"] = policy } else { body["policy"] = false }
                try self.router.post("/rci/ip/hotspot/host", body: body)
                DispatchQueue.main.async { self.refreshAsync() }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = String(describing: error)
                    self.setIconError(true)
                }
            }
        }
    }

    private func setIconError(_ err: Bool) {
        if err {
            statusItem.button?.image = nil
            statusItem.button?.title = "⚠️"
        } else {
            statusItem.button?.image = trayIcon()
            statusItem.button?.title = ""
        }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
