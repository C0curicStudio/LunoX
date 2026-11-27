# LunoX

iOS 浏览器（SwiftUI + WKWebView，iOS 26 液态玻璃，iOS 17+ 自动降级为材质玻璃）+ 自建服务器网关。

- `ios/` — App（XcodeGen 工程，`project.yml`）。GitHub Actions 在 macOS 上编译并产出**未签名 IPA**（Actions → iOS IPA → Artifacts）。
- `server/` — 网关：HTTPS CONNECT 代理 + 抓取/搜索建议/AI/搜索/加密同步 API，零依赖 Node。详见 `server/README.md`。

## 部署服务器（不影响其他服务）
```
git clone -b claude/focused-gauss-7jmxgt <本仓库> lunox && cd lunox/server
ss -ltn | grep 8443          # 只读：确认端口空闲
sudo bash deploy/install.sh 186.244.245.83 8443
```
脚本末尾会打印 `lunox://setup?...` 链接：在 iPhone 上点开即可自动配置服务器地址、密钥和证书指纹。
防火墙脚本不会动，需要你自己放行 TCP 8443（云厂商安全组 / ufw）。

## 安装 IPA
IPA 是未签名的，需要用 AltStore / Sideloadly / TrollStore 或你自己的证书签名后安装。

## 已知限制
- iOS 不允许第三方内置 Chromium，内核是系统 WebKit；Chrome 的 .crx 扩展不能运行，改为支持 `.user.js` 与 JSON 扩展。
- 代理使用 WebKit 的 `proxyConfigurations`（iOS 17+）走服务器 HTTPS CONNECT，而不是在 iOS 上直接跑 hysteria2。
