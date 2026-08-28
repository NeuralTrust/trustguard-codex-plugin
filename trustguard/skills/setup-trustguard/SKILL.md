---
name: setup-trustguard
description: Set up the TrustGuard AI firewall for Codex — install the trustguard-codex binary, configure the TrustGuard endpoint and API key, and verify the hooks work. Use when the user installs the TrustGuard plugin, asks to configure TrustGuard, or when trustguard-codex is missing from the PATH.
---

# Set up TrustGuard for Codex

The TrustGuard plugin gates this agent with hooks that run `trustguard-codex hook`
on `UserPromptSubmit`, `PreToolUse` and `PostToolUse`. Enterprise orgs ship one
Codex collector for the whole company: employees do **not** need a NeuralTrust
account. Walk the user through the steps below.

## 1. Check for MDM (enterprise) first

Look for the managed config file:

- macOS: `/Library/Application Support/TrustGuard/codex.json`
- Linux: `/etc/trustguard/codex.json`
- Windows: `%ProgramData%\TrustGuard\codex.json`

If it exists and contains an `api_key`, setup is already done by IT. Tell the
user their org firewall is managed — they cannot (and should not) override
`api_key`, `data_url` or `fail_mode`. Skip to step 3 (verify). Soft prefs such
as `transform_action` or `timeout_ms` can still live in `~/.trustguard/codex.json`.

Also check whether IT deployed managed hooks via Codex `requirements.toml`
(`allow_managed_hooks_only`, `managed_dir`). If so, `/hooks` in the CLI should
show TrustGuard hooks marked managed.

## 2. Install the binary (if needed)

On macOS/Linux this is usually automatic: the bootstrap hook downloads the
pinned release into `~/.trustguard/bin` (SHA-256 verified) on the first event.
Check whether a binary is already available:

```bash
trustguard-codex version || ls ~/.trustguard/bin/
```

Install manually only if both are missing:

- **From a release**: download the binary for the user's OS/arch from
  https://github.com/NeuralTrust/trustguard-codex-plugin/releases and place
  it on the PATH (e.g. `/usr/local/bin/trustguard-codex`, `chmod +x`).
- **From source** (requires Go): in a clone of this repo run `make build`,
  then copy `bin/trustguard-codex` onto the PATH.

For local plugin testing from a clone:

```bash
make install-local
```

That copies the plugin under `~/.codex/plugins/trustguard` and wires absolute
paths into `~/.codex/hooks.json`. Then run `/hooks` in Codex and trust the new
definitions.

## 3. Configure the connection (BYO / non-MDM only)

Only when step 1 found no managed key. Ask the user for the data-plane URL and
the **org** Codex collector API key (`tgk_…`) from their security/platform
team. Do NOT ask the user to paste the key into the chat — have them create
the file themselves:

```json
{
  "data_url": "https://<trustguard-data-plane>",
  "api_key": "tgk_REPLACE_ME",
  "fail_mode": "closed"
}
```

Path: `~/.trustguard/codex.json`, `chmod 600`.

## 4. Verify

```bash
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hello"},"session_id":"thr_test"}' | trustguard-codex hook
```

Expected: `{}` (allow). A quick block test (needs `code_sanitation` enabled):

```bash
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"},"session_id":"thr_test"}' | trustguard-codex hook
```

Expected: `decision:"block"` with `permissionDecision:"deny"`.

## Notes

- Codex External guardrails (Prisma AIRS) is a separate, OpenAI-partner path.
  This plugin uses **local managed hooks**, same class of control as Cursor.
- Prefer `transform_action: "deny"` in enterprise if DLP findings must stop
  the tool call; Codex does not yet honour `permissionDecision:"ask"`.
- Attribution sends the account email (hook `user_email` or
  `~/.codex/auth.json`) as `attributes.user.email`. `consumer_id` is only sent
  when set via `TRUSTGUARD_CONSUMER_ID` or config.
