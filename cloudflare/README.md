# Cloudflare edge for LunoX

Why: Cloudflare's edge speaks WebSocket (not HTTP CONNECT). The app opens `wss://edge.<domain>:8443/v1/tunnel`,
lands on the nearest Cloudflare node, and Cloudflare forwards to your server over its backbone. The app measures
**direct-to-server vs. via-Cloudflare** and uses whichever answers fastest (re-tested every few minutes).

Cloudflare itself chooses the exact edge city (anycast). The app shows which one you got (the `cf-ray` suffix, e.g. HKG).

## Setup (needs a domain that is already on Cloudflare)
```
CF_API_TOKEN=<your token> node cloudflare/setup.mjs --zone yourdomain.com --ip 186.244.245.83
```
Dry run first: add `--dry-run`. Token scopes: Zone:Read, DNS:Edit, Zone Settings:Edit (one zone).
The gateway must be listening on 8443 (installed by `server/deploy/install.sh`) and the port must be open.
