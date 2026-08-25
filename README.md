# TrustGuard for Codex

AI firewall for the [OpenAI Codex](https://openai.com/codex) agent. One org
collector, MDM-deployed — every developer is protected without a NeuralTrust
account.

Same model as the [Cursor plugin](https://github.com/NeuralTrust/trustguard-cursor-plugin):
local hooks call `trustguard-codex`, which maps Codex events to TrustGuard
`POST /v1/evaluate` and returns allow / deny.

> Codex **External guardrails** (Prisma AIRS) is a separate OpenAI-partner
> path. This repo implements **lifecycle hooks** (the Cursor-class control).

## Install

### Local / BYO

```bash
make build
make install-local   # copies plugin + wires ~/.codex/hooks.json with absolute paths
```

Then in Codex run `/hooks`, trust the TrustGuard definitions, and write
`~/.trustguard/codex.json`:

```json
{
  "data_url": "https://<trustguard-data-plane>",
  "api_key": "tgk_…",
  "fail_mode": "closed"
}
```

### Enterprise (MDM)

1. Deploy `trustguard-codex` onto developer machines (PATH or
   `~/.trustguard/bin`).
2. Drop a managed config with the org Codex collector key:
   - macOS: `/Library/Application Support/TrustGuard/codex.json`
   - Linux: `/etc/trustguard/codex.json`
   - Windows: `%ProgramData%\TrustGuard\codex.json`
3. Enforce hooks via Codex `requirements.toml` (see
   [`docs/enterprise-requirements.toml`](./docs/enterprise-requirements.toml)):
   - `[features] hooks = true`
   - `allow_managed_hooks_only = true`
   - `managed_dir` pointing at the installed bootstrap scripts

Developers cannot disable managed hooks from `/hooks`.

## Event → evaluation mapping

| Codex event | TrustGuard protocol | Direction | Notes |
|---|---|---|---|
| `UserPromptSubmit` | `llm` | input | Block with `decision: "block"` |
| `PreToolUse` (`Bash` / `apply_patch`) | `all` | input | Deny with `permissionDecision: "deny"`. Gate `ask` collapses to allow + context (Codex does not honour `permissionDecision:"ask"`) |
| `PreToolUse` (MCP / other tools) | `mcp` tools/call | input | Same deny / ask-as-context shape |
| `PostToolUse` | `mcp` result | output | Detector `block` replaces the tool result; gate `ask` is ignored |

`consumer_id` prefers `user_email` from the payload when present, otherwise
the configured / OS fallback, always prefixed `codex:`.

## Repository layout

| Path | Role |
|---|---|
| [`trustguard/`](./trustguard/) | Codex plugin (hooks, bootstraps, skill, logo) |
| [`cli/`](./cli/) | `trustguard-codex` binary (Go, stdlib-only) |
| [`scripts/`](./scripts/) | Cross-compile + local hook install |
| [`docs/`](./docs/) | Enterprise `requirements.toml` example |

```bash
make build          # ./bin/trustguard-codex
make test           # go test -race ./cli/
make install-local  # plugin + ~/.codex/hooks.json
make dist VERSION=0.1.0
```

## Verify

```bash
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"thr_1"}' \
  | ./bin/trustguard-codex hook
```

## License

Apache-2.0 — see [`LICENSE`](./LICENSE).
