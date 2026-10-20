import Foundation
import Network
import UIKit
import Darwin

final class TransferServer: ObservableObject {
    @Published private(set) var address: String?
    @Published private(set) var status = "尚未開啟接收服務"
    @Published private(set) var isRunning = false
    @Published private(set) var hasError = false
    @Published private(set) var receivedFiles: [String] = []

    private let queue = DispatchQueue(label: "tw.codex.lanfiledrop.server")
    private var listener: NWListener?
    private var token = ""
    private var sessionIdentifier = UUID()
    private let port: UInt16 = 8080
    private let maxUploadBytes: Int64 = 4 * 1024 * 1024 * 1024

    func start() {
        stop()
        guard let ip = Self.wifiAddress() else {
            status = "找不到 Wi-Fi 位址。請先連接 Wi-Fi。"
            hasError = true
            return
        }
        let newToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let newSessionIdentifier = sessionIdentifier
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            token = newToken
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.sessionIdentifier == newSessionIdentifier else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.hasError = false
                        self.address = "http://\(ip):\(self.port)/\(newToken)"
                        self.status = "正在接收，僅限同一區域網路"
                        UIApplication.shared.isIdleTimerDisabled = true
                    case .failed(let error):
                        self.isRunning = false
                        self.hasError = true
                        self.address = nil
                        self.status = "服務無法啟動：\(error.localizedDescription)"
                        UIApplication.shared.isIdleTimerDisabled = false
                    default:
                        break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener = newListener
            status = "正在啟動…"
            hasError = false
            newListener.start(queue: queue)
        } catch {
            status = "服務無法啟動：\(error.localizedDescription)"
            hasError = true
        }
    }

    func stop() {
        sessionIdentifier = UUID()
        listener?.cancel()
        listener = nil
        isRunning = false
        address = nil
        status = "尚未開啟接收服務"
        hasError = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private static func wifiAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let entry = item.pointee
            if String(cString: entry.ifa_name) == "en0",
               let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                         &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if result == 0 { return String(cString: host) }
            }
            current = entry.ifa_next
        }
        return nil
    }

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.receiveHeader(connection, buffer: Data()) }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            guard accumulated.count <= 65536 else {
                self.reply(connection, status: "431 Request Header Fields Too Large", body: "Header too large")
                return
            }
            if let boundary = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = Data(accumulated[..<boundary.lowerBound])
                let initialBody = Data(accumulated[boundary.upperBound...])
                self.route(connection, header: header, initialBody: initialBody)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: accumulated)
            }
        }
    }

    private func route(_ connection: NWConnection, header: Data, initialBody: Data) {
        guard let text = String(data: header, encoding: .utf8) else {
            reply(connection, status: "400 Bad Request", body: "Invalid header")
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3 else {
            reply(connection, status: "400 Bad Request", body: "Invalid request")
            return
        }
        let method = String(request[0])
        let target = String(request[1])
        let basePath = "/\(token)"
        if method == "GET" && (target == basePath || target == basePath + "/") {
            reply(connection, status: "200 OK", body: Self.page(token: token), contentType: "text/html; charset=utf-8")
            return
        }
        guard method == "POST", target.hasPrefix(basePath + "/upload?") else {
            reply(connection, status: "404 Not Found", body: "網址已失效。請回到 iPhone App，確認正在接收，並輸入目前顯示的完整網址。")
            return
        }
        guard let components = URLComponents(string: "http://localhost\(target)"),
              let rawName = components.queryItems?.first(where: { $0.name == "name" })?.value,
              let safeName = Self.safeFilename(rawName),
              let lengthText = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") })?
                  .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
              let length = Int64(lengthText), length >= 0, length <= maxUploadBytes else {
            reply(connection, status: "400 Bad Request", body: "Invalid filename or content length")
            return
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + safeName)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            reply(connection, status: "500 Internal Server Error", body: "Cannot create file")
            return
        }
        do {
            let file = try FileHandle(forWritingTo: destination)
            receiveBody(connection, file: file, url: destination, remaining: length, chunk: initialBody)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            reply(connection, status: "500 Internal Server Error", body: "Cannot open file")
        }
    }

    private func receiveBody(_ connection: NWConnection, file: FileHandle, url: URL,
                             remaining: Int64, chunk: Data) {
        do {
            let amount = Int(min(Int64(chunk.count), remaining))
            if amount > 0 { try file.write(contentsOf: Data(chunk.prefix(amount))) }
            let left = remaining - Int64(amount)
            if left == 0 {
                try file.close()
                DispatchQueue.main.async { self.receivedFiles.insert(url.lastPathComponent, at: 0) }
                reply(connection, status: "200 OK", body: "上傳完成：\(url.lastPathComponent)")
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] next, _, complete, error in
                guard let self, let next, !next.isEmpty, error == nil else {
                    try? file.close()
                    try? FileManager.default.removeItem(at: url)
                    connection.cancel()
                    return
                }
                self.receiveBody(connection, file: file, url: url, remaining: left, chunk: next)
            }
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: url)
            reply(connection, status: "507 Insufficient Storage", body: "Write failed")
        }
    }

    private static func safeFilename(_ input: String) -> String? {
        let normalized = input.replacingOccurrences(of: "\\", with: "/")
        guard let last = normalized.split(separator: "/").last else { return nil }
        let result = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != ".", result != "..", result.utf8.count <= 200,
              !result.contains("\0") else { return nil }
        return result
    }

    private func reply(_ connection: NWConnection, status: String, body: String,
                       contentType: String = "text/plain; charset=utf-8") {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(token: String) -> String {
        """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>電腦傳檔</title><style>
        body{font-family:system-ui,sans-serif;max-width:560px;margin:48px auto;padding:0 18px}
        main{border:1px solid #ddd;border-radius:14px;padding:24px}
        input,button{font-size:1rem;margin-top:16px}button{padding:10px 18px}
        progress{width:100%;margin-top:20px}#result{white-space:pre-wrap}
        </style></head><body><main><h1>傳檔到 iPhone</h1>
        <p>選擇檔案，上傳後可在 iPhone「檔案」App 的「電腦傳檔」資料夾找到。</p>
        <input id="file" type="file"><br><button id="send">開始上傳</button>
        <progress id="progress" max="100" value="0"></progress><p id="result"></p>
        </main><script>
        const button=document.getElementById('send');
        button.onclick=()=>{const file=document.getElementById('file').files[0];
          if(!file){document.getElementById('result').textContent='請先選檔案';return;}
          button.disabled=true;document.getElementById('result').textContent='正在上傳…';
          const xhr=new XMLHttpRequest();
          xhr.open('POST','/\(token)/upload?name='+encodeURIComponent(file.name));
          xhr.setRequestHeader('Content-Type','application/octet-stream');
          xhr.upload.onprogress=e=>{if(e.lengthComputable)document.getElementById('progress').value=Math.round(e.loaded/e.total*100)};
          xhr.onload=()=>{document.getElementById('result').textContent=xhr.status===200?xhr.responseText:'上傳失敗：'+xhr.responseText;button.disabled=false};
          xhr.onerror=()=>{document.getElementById('result').textContent='連線中斷，請保持手機 App 開啟';button.disabled=false};
          xhr.send(file);
        };
        </script></body></html>
        """
    }
}
