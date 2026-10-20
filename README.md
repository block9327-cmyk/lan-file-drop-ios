# 電腦傳檔（LAN File Drop）

在 iPhone 開啟 App，按「開始接收」後，電腦輸入 App 顯示的 `http://...:8080/...` 網址，即可上傳檔案。每次開始接收都會產生新的臨時網址。收到的檔案會出現在 iPhone「檔案」→「我的 iPhone」→「電腦傳檔」。

此服務只供同一區網使用。傳輸使用 HTTP，請只在信任的網路中開啟，並在完成後按「停止接收」。上傳時 App 必須留在前景，螢幕保持開啟。單一檔案上限為 4 GiB。

GitHub Actions 使用 macOS 編譯並輸出 **未簽名 IPA**。使用者須以自己的 Apple 帳號及 AltStore、Sideloadly 等工具簽名安裝。Actions 建置成功只表示已產出安裝包，未代表真機安裝與傳輸已經測試。
