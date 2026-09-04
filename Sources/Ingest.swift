import Foundation
import Network

// テキストの受け口。
//
// nagara は画面を見ない。「投げ込まれたテキストだけを読む」ので、
// 誰がどこから投げるかは投げる側の責任になる。だから入口はこの HTTP 一本で足りる。
// 127.0.0.1 にしか bind しないので、外から叩かれることはない。
final class Ingest {

    struct Command {
        let path: String
        let body: [String: Any]
    }

    private var listener: NWListener?
    private let port: UInt16
    /// 常にメインスレッドで呼ばれる。戻り値がそのまま JSON になる
    private let handle: (Command) -> [String: Any]

    init(port: UInt16, handle: @escaping (Command) -> [String: Any]) {
        self.port = port
        self.handle = handle
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 外部から届かないよう loopback に固定する
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Log.write("ingest: 127.0.0.1:\(self.port) で待ち受け開始")
            case .failed(let error): Log.write("ingest: 失敗 \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 1接続ぶんの処理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            if error != nil {
                connection.cancel()
                return
            }

            if let request = Self.parse(accumulated) {
                self.respond(to: request, on: connection)
                return
            }
            if isComplete {
                self.send(status: "400 Bad Request", json: ["error": "解釈できませんでした"],
                          on: connection)
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func respond(to request: ParsedRequest, on connection: NWConnection) {
        let body: [String: Any]
        if !request.body.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            body = parsed
        } else {
            body = [:]
        }

        let command = Command(path: request.path, body: body)
        DispatchQueue.main.async {
            let result = self.handle(command)
            let status = (result["error"] != nil) ? "400 Bad Request" : "200 OK"
            self.send(status: status, json: result, on: connection)
        }
    }

    private func send(status: String, json: [String: Any], on connection: NWConnection) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var response = Data()
        response.append(Data("HTTP/1.1 \(status)\r\n".utf8))
        response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        response.append(Data("Content-Length: \(payload.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 最小限の HTTP 解析

    private struct ParsedRequest {
        let method: String
        let path: String
        let body: Data
    }

    /// ヘッダが揃い、Content-Length ぶんの本文が届いていれば返す。まだなら nil
    private static func parse(_ data: Data) -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        let headerData = data[..<headerEnd.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        var path = String(parts[1])
        if let questionMark = path.firstIndex(of: "?") { path = String(path[..<questionMark]) }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            if pieces[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
                contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = data[bodyStart..<(bodyStart + contentLength)]
        return ParsedRequest(method: method, path: path, body: Data(body))
    }
}
