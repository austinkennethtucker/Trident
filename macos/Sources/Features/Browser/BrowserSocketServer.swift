import Darwin
import Foundation

/// Unix domain socket server that accepts newline-delimited JSON commands
/// and returns JSON responses. Used for programmatic control of a browser pane.
class BrowserSocketServer {
    let socketPath: String
    let paneId: UUID
    private var socketFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private let queue = DispatchQueue(label: "com.trident.browser-socket", qos: .userInitiated)
    weak var model: BrowserPaneModel?

    init(paneId: UUID) {
        self.paneId = paneId
        // Use /tmp/trident/ instead of $TMPDIR — macOS $TMPDIR paths are
        // too long (60+ chars) and Unix socket paths are limited to 104 bytes.
        let tmpDir = URL(fileURLWithPath: "/tmp/trident", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // Use first 8 chars of UUID to keep path short
        let shortId = String(paneId.uuidString.prefix(8)).lowercased()
        self.socketPath = tmpDir.appendingPathComponent("b-\(shortId).sock").path
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        // Remove stale socket file if present
        unlink(socketPath)

        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw ServerError.socketCreationFailed(errno: errno)
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_len) + MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(socketFD)
            socketFD = -1
            throw ServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(socketFD)
            socketFD = -1
            throw ServerError.bindFailed(errno: err)
        }

        // Set socket permissions to owner-only (0600)
        chmod(socketPath, 0o600)

        // Listen for connections
        guard listen(socketFD, 5) == 0 else {
            let err = errno
            Darwin.close(socketFD)
            socketFD = -1
            unlink(socketPath)
            throw ServerError.listenFailed(errno: err)
        }

        // Set up GCD dispatch source for accepting connections
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                Darwin.close(fd)
                self?.socketFD = -1
            }
        }
        listenSource = source
        source.resume()
    }

    func stop() {
        // Cancel listen source
        listenSource?.cancel()
        listenSource = nil

        // Cancel all client sources
        for (fd, source) in clientSources {
            source.cancel()
            Darwin.close(fd)
        }
        clientSources.removeAll()

        // Close socket FD if still open
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }

        // Remove socket file
        unlink(socketPath)
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(socketFD, sockPtr, &clientAddrLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Create per-client read source
        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        var buffer = Data()

        clientSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD, buffer: &buffer)
        }
        clientSource.setCancelHandler { [weak self] in
            Darwin.close(clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
        }
        clientSources[clientFD] = clientSource
        clientSource.resume()
    }

    private func readFromClient(fd: Int32, buffer: inout Data) {
        var readBuf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &readBuf, readBuf.count)

        if bytesRead <= 0 {
            // Client disconnected or error
            clientSources[fd]?.cancel()
            return
        }

        buffer.append(contentsOf: readBuf[0..<bytesRead])

        // Process complete lines (newline-delimited JSON)
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            guard let lineString = String(data: lineData, encoding: .utf8),
                  !lineString.isEmpty else { continue }

            // Parse JSON command
            guard let jsonData = lineString.data(using: .utf8),
                  let command = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                let errorResponse: [String: Any] = ["ok": false, "error": "invalid JSON"]
                sendResponse(errorResponse, to: fd)
                continue
            }

            // Handle command on socket queue — individual methods
            // dispatch to main thread as needed
            self.queue.async { [weak self] in
                guard let self = self else { return }
                let response = self.handleCommand(command)
                self.sendResponse(response, to: fd)
            }
        }
    }

    private func sendResponse(_ response: [String: Any], to fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              var responseString = String(data: data, encoding: .utf8) else { return }
        responseString.append("\n")
        responseString.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }

    // MARK: - Command Handling

    /// Handle a JSON command dictionary and return a response dictionary.
    /// Called on the main thread so WKWebView access is safe.
    private func handleCommand(_ command: [String: Any]) -> [String: Any] {
        guard let cmd = command["cmd"] as? String else {
            return ["ok": false, "error": "missing 'cmd' field"]
        }

        switch cmd {
        case "navigate":
            guard let url = command["url"] as? String else {
                return ["ok": false, "error": "missing 'url' parameter"]
            }
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                self?.model?.navigate(to: url)
                sem.signal()
            }
            sem.wait()
            return ["ok": true]

        case "back":
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                self?.model?.goBack()
                sem.signal()
            }
            sem.wait()
            return ["ok": true]

        case "forward":
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                self?.model?.goForward()
                sem.signal()
            }
            sem.wait()
            return ["ok": true]

        case "reload":
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                self?.model?.reload()
                sem.signal()
            }
            sem.wait()
            return ["ok": true]

        case "status":
            var result: [String: Any] = [:]
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                result = [
                    "ok": true,
                    "url": self?.model?.urlString as Any,
                    "title": self?.model?.pageTitle as Any,
                    "loading": self?.model?.isLoading as Any,
                ]
                sem.signal()
            }
            sem.wait()
            return result

        case "js_eval":
            guard let code = command["code"] as? String else {
                return ["ok": false, "error": "missing 'code' parameter"]
            }
            let semaphore = DispatchSemaphore(value: 0)
            var result: Any? = nil
            var jsError: Error? = nil
            model?.evaluateJavaScript(code) { r, e in
                result = r
                jsError = e
                semaphore.signal()
            }
            semaphore.wait()
            if let err = jsError {
                return ["ok": false, "error": err.localizedDescription]
            }
            // Convert result to JSON-safe type
            let jsonResult: Any = result ?? NSNull()
            return ["ok": true, "result": jsonResult]

        case "dom_snapshot":
            let semaphore = DispatchSemaphore(value: 0)
            var html: String = ""
            model?.evaluateJavaScript("document.documentElement.outerHTML") { r, _ in
                html = r as? String ?? ""
                semaphore.signal()
            }
            semaphore.wait()
            return ["ok": true, "html": html]

        case "screenshot":
            let semaphore = DispatchSemaphore(value: 0)
            var pngData: Data? = nil
            model?.takeSnapshot { data in
                pngData = data
                semaphore.signal()
            }
            semaphore.wait()
            if let data = pngData {
                return ["ok": true, "png_b64": data.base64EncodedString()]
            }
            return ["ok": false, "error": "screenshot failed"]

        case "cookies_get":
            let semaphore = DispatchSemaphore(value: 0)
            var cookieList: [[String: Any]] = []
            model?.getCookies { cookies in
                cookieList = cookies.map { cookie in
                    [
                        "name": cookie.name,
                        "value": cookie.value,
                        "domain": cookie.domain,
                        "path": cookie.path,
                        "secure": cookie.isSecure,
                        "httpOnly": cookie.isHTTPOnly
                    ]
                }
                semaphore.signal()
            }
            semaphore.wait()
            return ["ok": true, "cookies": cookieList]

        case "cookies_set":
            guard let props = command["cookie"] as? [String: Any],
                  let name = props["name"] as? String,
                  let value = props["value"] as? String,
                  let domain = props["domain"] as? String else {
                return ["ok": false, "error": "missing cookie properties"]
            }
            var cookieProps: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: props["path"] as? String ?? "/"
            ]
            if let secure = props["secure"] as? Bool, secure {
                cookieProps[.secure] = "TRUE"
            }
            guard let cookie = HTTPCookie(properties: cookieProps) else {
                return ["ok": false, "error": "invalid cookie"]
            }
            let semaphore = DispatchSemaphore(value: 0)
            model?.setCookie(cookie) { semaphore.signal() }
            semaphore.wait()
            return ["ok": true]

        case "session_export":
            let semaphore = DispatchSemaphore(value: 0)
            var cookieList: [[String: Any]] = []
            var localStorage: String = "{}"

            model?.getCookies { cookies in
                cookieList = cookies.map { ["name": $0.name, "value": $0.value, "domain": $0.domain, "path": $0.path, "secure": $0.isSecure] }
                semaphore.signal()
            }
            semaphore.wait()

            let semaphore2 = DispatchSemaphore(value: 0)
            model?.evaluateJavaScript("JSON.stringify(localStorage)") { r, _ in
                localStorage = r as? String ?? "{}"
                semaphore2.signal()
            }
            semaphore2.wait()

            return ["ok": true, "session": ["cookies": cookieList, "localStorage": localStorage]]

        case "session_import":
            guard let session = command["session"] as? [String: Any] else {
                return ["ok": false, "error": "missing 'session' parameter"]
            }

            // Import cookies
            if let cookies = session["cookies"] as? [[String: Any]] {
                for c in cookies {
                    guard let name = c["name"] as? String,
                          let value = c["value"] as? String,
                          let domain = c["domain"] as? String else { continue }
                    var props: [HTTPCookiePropertyKey: Any] = [
                        .name: name, .value: value, .domain: domain,
                        .path: c["path"] as? String ?? "/"
                    ]
                    if let secure = c["secure"] as? Bool, secure {
                        props[.secure] = "TRUE"
                    }
                    if let cookie = HTTPCookie(properties: props) {
                        let sem = DispatchSemaphore(value: 0)
                        model?.setCookie(cookie) { sem.signal() }
                        sem.wait()
                    }
                }
            }

            // Import localStorage
            if let ls = session["localStorage"] as? String {
                let escaped = ls.replacingOccurrences(of: "'", with: "\\'")
                let js = "Object.entries(JSON.parse('\(escaped)')).forEach(([k,v])=>localStorage.setItem(k,v))"
                let sem = DispatchSemaphore(value: 0)
                model?.evaluateJavaScript(js) { _, _ in sem.signal() }
                sem.wait()
            }

            return ["ok": true]

        default:
            return ["ok": false, "error": "unknown command"]
        }
    }

    // MARK: - Errors

    enum ServerError: Error {
        case socketCreationFailed(errno: Int32)
        case pathTooLong
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }
}
