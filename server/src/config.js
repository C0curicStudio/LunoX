'use strict';
const env = (k, d) => (process.env[k] === undefined || process.env[k] === '' ? d : process.env[k]);
const int = (k, d) => parseInt(env(k, String(d)), 10);
const list = (k, d = '') => env(k, d).split(',').map((s) => s.trim()).filter(Boolean);

const config = {
  bind: env('LUNOX_BIND', '0.0.0.0'),
  port: int('LUNOX_PORT', 8443),
  tlsCert: env('LUNOX_TLS_CERT', '/etc/lunox/tls/server.crt'),
  tlsKey: env('LUNOX_TLS_KEY', '/etc/lunox/tls/server.key'),
  // Comma separated. One key per device so a lost phone can be revoked alone.
  apiKeys: list('LUNOX_API_KEYS'),
  syncDir: env('LUNOX_SYNC_DIR', '/var/lib/lunox/sync'),
  // Upstream LLM (anthropic | openai-compatible)
  llm: {
    provider: env('LLM_PROVIDER', 'anthropic'),
    baseUrl: env('LLM_BASE_URL', 'https://api.anthropic.com'),
    apiKey: env('LLM_API_KEY', env('ANTHROPIC_API_KEY', '')),
    model: env('LLM_MODEL', 'claude-haiku-5-5'),
    maxTokens: int('LLM_MAX_TOKENS', 2048),
  },
  search: {
    provider: env('SEARCH_PROVIDER', ''), // brave | searxng | ''
    apiKey: env('SEARCH_API_KEY', ''),
    baseUrl: env('SEARXNG_URL', ''),
  },
  limits: {
    rps: int('LUNOX_RPS', 30), // REST requests / second / key
    maxFetchBytes: int('LUNOX_MAX_FETCH_BYTES', 20 * 1024 * 1024),
    maxBodyBytes: int('LUNOX_MAX_BODY_BYTES', 512 * 1024),
    maxTunnelsPerIp: int('LUNOX_MAX_TUNNELS_PER_IP', 128),
    maxTunnels: int('LUNOX_MAX_TUNNELS', 2000),
    tunnelIdleMs: int('LUNOX_TUNNEL_IDLE_MS', 300000),
    authFailLimit: int('LUNOX_AUTH_FAIL_LIMIT', 8),
    authBanMs: int('LUNOX_AUTH_BAN_MS', 15 * 60 * 1000),
  },
  extraBlockedPorts: list('LUNOX_BLOCKED_PORTS').map(Number),
};

module.exports = { config };
