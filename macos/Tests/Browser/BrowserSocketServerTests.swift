import Darwin
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct BrowserSocketServerTests {
    @Test func stopCommandWithoutActiveModelReturnsClearError() throws {
        let server = BrowserSocketServer(paneId: UUID())
        try server.start()
        defer { server.stop() }

        let response = try BrowserSocketTestClient.send(
            ["cmd": "stop"],
            to: server.socketPath
        )

        #expect(response["ok"] as? Bool == false)
        #expect(response["error"] as? String == "no active browser model")
    }

    @Test func invalidProxyURLIsRejectedBeforeMutation() throws {
        let server = BrowserSocketServer(paneId: UUID())
        try server.start()
        defer { server.stop() }

        let response = try BrowserSocketTestClient.send(
            ["cmd": "proxy_set", "url": "not-a-url"],
            to: server.socketPath
        )

        #expect(response["ok"] as? Bool == false)
        #expect(response["error"] as? String == "invalid proxy URL")
    }

    @Test func validProxyURLStillNeedsActiveBrowserModel() throws {
        let server = BrowserSocketServer(paneId: UUID())
        try server.start()
        defer { server.stop() }

        let response = try BrowserSocketTestClient.send(
            ["cmd": "proxy_set", "url": "http://127.0.0.1:8080"],
            to: server.socketPath
        )

        #expect(response["ok"] as? Bool == false)
        #expect(response["error"] as? String == "no active browser model")
    }

    @Test func startRemovesDeadBrowserSocketFiles() throws {
        let stalePath = "/tmp/trident/b-deadbeef.sock"
        try FileManager.default.createDirectory(
            atPath: "/tmp/trident",
            withIntermediateDirectories: true
        )
        try BrowserSocketFixture.createDeadSocket(at: stalePath)
        #expect(FileManager.default.fileExists(atPath: stalePath))
        defer { unlink(stalePath) }

        let server = BrowserSocketServer(paneId: UUID())
        try server.start()
        defer { server.stop() }

        #expect(FileManager.default.fileExists(atPath: stalePath) == false)
    }

    @Test func invalidatingTabManagerStopsOldSocketBeforeReplacement() throws {
        let manager = BrowserTabManager()
        let oldSocketPath = try #require(manager.socketServer?.socketPath)
        #expect(FileManager.default.fileExists(atPath: oldSocketPath))

        manager.invalidate()
        #expect(FileManager.default.fileExists(atPath: oldSocketPath) == false)

        let replacement = BrowserTabManager()
        defer { replacement.invalidate() }
        let newSocketPath = try #require(replacement.socketServer?.socketPath)
        #expect(newSocketPath != oldSocketPath)
        #expect(FileManager.default.fileExists(atPath: newSocketPath))
    }
}

private enum BrowserSocketTestClient {
    static func send(_ command: [String: Any], to socketPath: String) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        var payload = data
        payload.append(0x0A)
        let writeResult = payload.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, bytes.count)
        }
        guard writeResult == payload.count else {
            throw POSIXError(.EIO)
        }

        var readBuffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &readBuffer, readBuffer.count)
        guard bytesRead > 0 else {
            throw POSIXError(.EIO)
        }

        let prefix = Array(readBuffer[0..<bytesRead])
        let newlineIndex = prefix.firstIndex(of: 0x0A) ?? prefix.endIndex
        let responseData = Data(prefix[0..<newlineIndex])
        let object = try JSONSerialization.jsonObject(with: responseData)
        return object as? [String: Any] ?? [:]
    }
}

private enum BrowserSocketFixture {
    static func createDeadSocket(at path: String) throws {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map(UInt8.init(bitPattern:))
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
