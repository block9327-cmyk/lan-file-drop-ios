import SwiftUI

@main
struct LANFileDropApp: App {
    @StateObject private var server = TransferServer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        server.stop()
                    }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var server: TransferServer

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("電腦與 iPhone 連到同一個區域網路後，從電腦瀏覽器開啟下方網址即可傳檔。")
                        .foregroundColor(.secondary)

                    if let address = server.address {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("電腦輸入這個網址")
                                .font(.headline)
                            Text(address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button("複製網址") {
                                UIPasteboard.general.string = address
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }

                    Button(server.isRunning ? "停止接收" : "開始接收") {
                        if server.isRunning { server.stop() } else { server.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(server.isRunning ? .red : .blue)

                    Text(server.status)
                        .foregroundColor(server.hasError ? .red : .secondary)

                    Text("傳檔時請保持此畫面與螢幕開啟。檔案會存入「檔案」App →「我的 iPhone」→「電腦傳檔」。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if !server.receivedFiles.isEmpty {
                        Divider()
                        Text("已收到")
                            .font(.headline)
                        ForEach(server.receivedFiles, id: \.self) { name in
                            Text(name)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("電腦傳檔")
        }
    }
}
