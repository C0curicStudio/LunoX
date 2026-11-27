# LunoX

iOS 浏览器（SwiftUI + WKWebView，iOS 26 液态玻璃，iOS 17+ 自动降级为材质玻璃）+ 自建服务器网关。

- `ios/` — App（XcodeGen 工程）。GitHub Actions 在 macOS 上编译、跑单元测试、在模拟器里给每个界面截图，并产出**未签名 IPA**（Actions → iOS → Artifacts）。
- `server/` — 网关：HTTPS CONNECT 代理 + WebSocket 隧道 + 抓取/搜索/AI/加密同步 API，零依赖 Node。详见 `server/README.md`。
- `cloudflare/` — 有域名时的 Cloudflare 一键配置（没有域名用 `server/deploy/edge.sh` 的免费快速隧道即可）。

## 服务器（不影响其他服务）
```
git clone -b claude/focused-gauss-7jmxgt <本仓库> && cd LunoX
sudo bash server/deploy/install.sh 186.244.245.83 8443      # 安装 / 升级（可重复运行，保留密钥与证书）
sudo bash server/deploy/open-firewall.sh 8443               # 只加一条放行规则
sudo bash server/deploy/edge.sh                             # Cloudflare 边缘（免域名、免令牌，仅出站）
sudo bash server/deploy/diagnose.sh                         # 只读诊断，不输出密钥
sudo bash server/deploy/tune-network.sh                     # 可选：BBR（会先询问）
```
`install.sh` 结束时打印 `lunox://setup?...` 配对链接，手机上点一次即可。除模型 API 密钥外，其余配置（Cloudflare 地址、搜索等）由服务器自动提供；模型 API 在 App「设置 › 智能与 AI」填写，只保存在服务器上。

## 安装 IPA
IPA 未签名，需用 AltStore / Sideloadly / TrollStore 或自己的证书签名。
可选：在仓库 Secrets 添加 `LUNOX_KEY`，编出的 IPA 即为预先配对（该 IPA 含密钥，请勿外传）。

## 已知限制
- iOS 不允许第三方内置 Chromium，内核是系统 WebKit；Chrome 的 .crx 扩展不能运行，改为支持 `.user.js` 与 JSON 扩展。
- 代理使用 WebKit 的 `proxyConfigurations`（iOS 17+），经服务器加密隧道，而不是在 iOS 上直接跑 hysteria2。
- Cloudflare 快速隧道地址是临时的（重启会变，App 自动重新获取），且无 SLA；有域名时可用 `cloudflare/setup.mjs` 做固定地址。
