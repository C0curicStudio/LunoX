# LunoX Gateway

Zero-dependency Node (>=20) service. One TLS port serves:

| What | Endpoint |
|---|---|
| HTTPS **CONNECT proxy** (used by the iOS app's WebKit when a site is not directly reachable) | `CONNECT host:port`, `Proxy-Authorization: Basic lunox:<key>` |
| Health | `GET /v1/health` |
| Server-side fetch (SSRF-guarded) | `GET /v1/fetch?url=` |
| Search suggestions / favicon | `GET /v1/suggest?q=&engine=`, `GET /v1/favicon?host=` |
| Web search | `GET /v1/search?q=` (Brave or SearXNG) |
| AI (summarize / ask / translate / search_answer / act) | `POST /v1/ai`, `POST /v1/ai/stream` |
| Encrypted sync blobs | `PUT/GET /v1/sync/:bucket` |

All REST calls need `Authorization: Bearer <key>`.

## Install (does not touch other services)
```
sudo bash deploy/install.sh 186.244.245.83 8443
```
Own dir/user/unit, CPU 60% / RAM 512M cap, no firewall changes, aborts if the port is busy.
Hysteria2 keeps running untouched (it uses UDP; this uses TCP 8443).

Diagnostics (read-only): `sudo bash deploy/diagnose.sh`. Per-device key: `sudo bash deploy/add-key.sh`.

## Security
Keys compared in constant time; 8 failures/IP → 15 min ban; per-key rate limit; SSRF guard (private/loopback/metadata,
IP literals, DNS rebinding, redirects re-validated); port policy; tunnel caps and idle timeouts; no secrets in logs;
systemd sandboxing; self-signed cert pinned by SHA-256 in the app.
