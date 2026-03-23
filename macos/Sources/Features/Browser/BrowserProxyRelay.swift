import Foundation
import Network

/// Lightweight local TCP proxy relay using Network.framework.
/// Sits between WKWebView and an optional upstream proxy, handling
/// HTTP CONNECT tunneling (HTTPS) and plain HTTP forwarding.
/// Also logs request metadata for HAR recording when a recorder is attached.
class BrowserProxyRelay {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.trident.proxy-relay", qos: .userInitiated)
    private var connections: [ObjectIdentifier: RelayConnection] = []

    /// The upstream proxy URL (e.g., "http://127.0.0.1:8080").
    /// When nil, the relay connects directly to targets.
    /// Changing this affects new connections only; existing tunnels continue unchanged.
    /// Thread-safe: reads/writes go through the relay's serial queue.
    private var _upstreamProxy: String?
    var upstreamProxy: String? {
        get { queue.sync { _upstreamProxy } }
        set { queue.sync { _upstreamProxy = newValue } }
    }

    /// Optional HAR recorder — if set and recording, the relay logs request metadata.
    weak var harRecorder: BrowserHARRecorder?

    /// The local port the relay is listening on (available after start).
    private var _localPort: UInt16 = 0
    var localPort: UInt16 {
        queue.sync { _localPort }
    }

    /// Whether the relay is currently listening.
    var isRunning: Bool { queue.sync { listener != nil } }

    /// Start listening on a random loopback port.
    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let newListener = try NWListener(using: params)
        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = newListener.port {
                    self?._localPort = port.rawValue
                    print("[ProxyRelay] Listening on 127.0.0.1:\(port.rawValue)")
                }
            case .failed(let error):
                print("[ProxyRelay] Listener failed: \(error)")
                self?.stop()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        newListener.start(queue: queue)
        self.listener = newListener
    }

    /// Stop the relay and close all connections.
    /// Uses async to avoid deadlock if called from the relay queue.
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self._localPort = 0
            for conn in self.connections.values {
                conn.cancel()
            }
            self.connections.removeAll()
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ clientConnection: NWConnection) {
        clientConnection.start(queue: queue)

        // Read initial request line to determine if CONNECT or plain HTTP
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                clientConnection.cancel()
                return
            }
            self.processInitialData(data, client: clientConnection)
        }
    }

    private func processInitialData(_ data: Data, client: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            client.cancel()
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            client.cancel()
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            client.cancel()
            return
        }

        let method = String(parts[0])
        let target = String(parts[1])

        // Parse request headers for logging
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name: name, value: value))
            }
        }

        let startTime = Date()

        if method == "CONNECT" {
            handleConnect(target: target, client: client, headers: headers, startTime: startTime)
        } else {
            handleHTTP(method: method, target: target, fullRequest: data, client: client, headers: headers, startTime: startTime)
        }
    }

    // MARK: - CONNECT Tunneling

    private func handleConnect(target: String, client: NWConnection, headers: [(name: String, value: String)], startTime: Date) {
        let (host, port) = parseHostPort(target, defaultPort: 443)

        let connectStart = Date()
        let remote: NWConnection

        if let upstream = _upstreamProxy, let (proxyHost, proxyPort) = parseProxyURL(upstream) {
            // Connect to upstream proxy and forward the CONNECT request
            remote = NWConnection(host: NWEndpoint.Host(proxyHost), port: NWEndpoint.Port(integerLiteral: proxyPort), using: .tcp)
        } else {
            // Direct connection to target
            remote = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port), using: .tcp)
        }

        let relay = RelayConnection(client: client, remote: remote, queue: queue)
        let relayId = ObjectIdentifier(relay)
        connections[relayId] = relay

        remote.stateUpdateHandler = { [weak self, weak relay] state in
            switch state {
            case .ready:
                let connectDuration = Date().timeIntervalSince(connectStart)

                if let upstream = self?._upstreamProxy, self?.parseProxyURL(upstream) != nil {
                    // When going through upstream proxy, forward the CONNECT request
                    let connectRequest = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
                    remote.send(content: connectRequest.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
                        // Read upstream proxy response and validate before tunneling
                        remote.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            if let data = data,
                               let responseStr = String(data: data.prefix(128), encoding: .utf8),
                               responseStr.contains("200") {
                                let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                                client.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                                    relay?.startBidirectionalRelay()
                                })
                            } else {
                                // Forward upstream error to client or send 502
                                let errorData = data ?? "HTTP/1.1 502 Bad Gateway\r\n\r\n".data(using: .utf8)!
                                client.send(content: errorData, completion: .contentProcessed { _ in
                                    client.cancel()
                                })
                                self?.connections.removeValue(forKey: relayId)
                            }
                        }
                    })
                } else {
                    // Direct connection — send 200 and start tunneling
                    let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                    client.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        relay?.startBidirectionalRelay()
                    })
                }

                // Log CONNECT to HAR
                self?.harRecorder?.append(HAREntry(
                    startedDateTime: startTime,
                    method: "CONNECT",
                    url: "https://\(target)",
                    httpVersion: "HTTP/1.1",
                    requestHeaders: headers,
                    responseStatus: 200,
                    responseStatusText: "Connection Established",
                    responseHeaders: [],
                    responseBodySize: 0,
                    timings: HARTimings(connect: connectDuration, send: 0, wait: 0, receive: 0),
                    source: .relay
                ))

            case .failed, .cancelled:
                let errorResponse = "HTTP/1.1 502 Bad Gateway\r\n\r\n"
                client.send(content: errorResponse.data(using: .utf8), completion: .contentProcessed { _ in
                    client.cancel()
                })
                self?.connections.removeValue(forKey: relayId)

            default:
                break
            }
        }

        remote.start(queue: queue)
    }

    // MARK: - Plain HTTP Forwarding

    private func handleHTTP(method: String, target: String, fullRequest: Data, client: NWConnection,
                            headers: [(name: String, value: String)], startTime: Date) {
        let sendStart = Date()
        let remote: NWConnection

        if let upstream = _upstreamProxy, let (proxyHost, proxyPort) = parseProxyURL(upstream) {
            // Forward entire request to upstream proxy as-is
            remote = NWConnection(host: NWEndpoint.Host(proxyHost), port: NWEndpoint.Port(integerLiteral: proxyPort), using: .tcp)
        } else {
            // Parse target URL for direct connection
            guard let url = URL(string: target), let host = url.host else {
                let response = "HTTP/1.1 400 Bad Request\r\n\r\n"
                client.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    client.cancel()
                })
                return
            }
            let port = UInt16(url.port ?? 80)
            remote = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port), using: .tcp)
        }

        let relay = RelayConnection(client: client, remote: remote, queue: queue)
        let relayId = ObjectIdentifier(relay)
        connections[relayId] = relay

        remote.stateUpdateHandler = { [weak self, weak relay] state in
            switch state {
            case .ready:
                let connectDuration = Date().timeIntervalSince(sendStart)

                // Forward the request to remote
                remote.send(content: fullRequest, completion: .contentProcessed { _ in
                    let waitStart = Date()

                    // Read response and forward to client, also log for HAR
                    remote.receive(minimumIncompleteLength: 1, maximumLength: 65536) { responseData, _, isComplete, _ in
                        let waitDuration = Date().timeIntervalSince(waitStart)

                        if let responseData = responseData {
                            let receiveStart = Date()
                            client.send(content: responseData, completion: .contentProcessed { _ in
                                let receiveDuration = Date().timeIntervalSince(receiveStart)

                                // Parse response status for HAR
                                let (status, statusText, respHeaders) = self?.parseHTTPResponse(responseData) ?? (0, "", [])

                                self?.harRecorder?.append(HAREntry(
                                    startedDateTime: startTime,
                                    method: method,
                                    url: target,
                                    httpVersion: "HTTP/1.1",
                                    requestHeaders: headers,
                                    responseStatus: status,
                                    responseStatusText: statusText,
                                    responseHeaders: respHeaders,
                                    responseBodySize: Int64(responseData.count),
                                    timings: HARTimings(
                                        connect: connectDuration,
                                        send: 0,
                                        wait: waitDuration,
                                        receive: receiveDuration
                                    ),
                                    source: .relay
                                ))

                                // Continue relaying remaining data
                                relay?.startBidirectionalRelay()
                            })
                        } else if isComplete {
                            // Connection closed without response data
                            client.cancel()
                            self?.connections.removeValue(forKey: relayId)
                        }
                    }
                })

            case .failed, .cancelled:
                client.cancel()
                self?.connections.removeValue(forKey: relayId)

            default:
                break
            }
        }

        remote.start(queue: queue)
    }

    // MARK: - Parsing Helpers

    private func parseHostPort(_ target: String, defaultPort: UInt16) -> (String, UInt16) {
        let components = target.split(separator: ":")
        if components.count == 2, let port = UInt16(components[1]) {
            return (String(components[0]), port)
        }
        return (target, defaultPort)
    }

    private func parseProxyURL(_ urlString: String) -> (String, UInt16)? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        let port = UInt16(url.port ?? 8080)
        return (host, port)
    }

    private func parseHTTPResponse(_ data: Data) -> (Int, String, [(name: String, value: String)]) {
        guard let str = String(data: data.prefix(4096), encoding: .utf8) else {
            return (0, "", [])
        }
        let lines = str.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return (0, "", []) }

        let parts = statusLine.split(separator: " ", maxSplits: 2)
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        let statusText = parts.count >= 3 ? String(parts[2]) : ""

        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name: name, value: value))
            }
        }

        return (status, statusText, headers)
    }
}

// MARK: - Bidirectional Relay Connection

private class RelayConnection {
    let client: NWConnection
    let remote: NWConnection
    let queue: DispatchQueue
    private var cancelled = false

    init(client: NWConnection, remote: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.remote = remote
        self.queue = queue
    }

    func startBidirectionalRelay() {
        pipeData(from: client, to: remote)
        pipeData(from: remote, to: client)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        client.cancel()
        remote.cancel()
    }

    private func pipeData(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.cancelled else { return }

            if let data = data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if sendError != nil {
                        self?.cancel()
                    } else if isComplete || error != nil {
                        // Final chunk sent — close after delivery
                        self?.cancel()
                    } else {
                        self?.pipeData(from: source, to: destination)
                    }
                })
            } else if isComplete || error != nil {
                self.cancel()
            }
        }
    }
}
