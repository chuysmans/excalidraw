#!/usr/bin/env bash
# Local verification for lifecycle hooks (run: ./.cursor/hooks/verify-fork-hooks.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_JSON="$ROOT/.cursor/hooks.json"
DANGEROUS="$ROOT/.cursor/hooks/block-dangerous.sh"
PR_HOOK="$ROOT/.cursor/hooks/block-upstream-pr.sh"
MCP_HOOK="$ROOT/.cursor/hooks/block-upstream-mcp.sh"
AUDIT_HOOK="$ROOT/.cursor/hooks/format-and-audit.sh"

run_hook() {
  local hook="$1" payload="$2"
  printf '%s' "$payload" | "$hook"
}

perm() {
  python3 -c 'import sys,json; print(json.load(sys.stdin)["permission"])'
}

assert_perm() {
  local hook="$1" payload="$2" expect="$3" label="$4"
  local out got
  out="$(run_hook "$hook" "$payload")"
  got="$(printf '%s' "$out" | perm)"
  if [[ "$got" == "$expect" ]]; then
    echo "OK  $expect  $label"
  else
    echo "FAIL expected=$expect got=$got label=$label"
    echo "    payload: $payload"
    echo "    output:  $out"
    exit 1
  fi
}

echo "hooks.json"
python3 - "$HOOKS_JSON" <<'PY'
import json, re, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

assert cfg.get("version") == 1, "hooks.json version must be 1"

shell_hooks = cfg.get("hooks", {}).get("beforeShellExecution", [])
by_cmd = {h["command"]: h for h in shell_hooks if "command" in h}

dangerous = by_cmd.get(".cursor/hooks/block-dangerous.sh")
assert dangerous, "block-dangerous.sh must be registered in beforeShellExecution"
matcher = dangerous.get("matcher", "")
assert matcher and matcher != "Shell", (
    'block-dangerous.sh matcher must be a command-string regex, not "Shell"'
)
assert dangerous.get("failClosed") is True, "block-dangerous.sh must set failClosed: true"

upstream = by_cmd.get(".cursor/hooks/block-upstream-pr.sh")
assert upstream, "block-upstream-pr.sh must be registered in beforeShellExecution"
assert upstream.get("failClosed") is True, "block-upstream-pr.sh must set failClosed: true"

# Matchers use JS-style regex against the full shell command string.
dangerous_re = re.compile(matcher)
upstream_re = re.compile(upstream.get("matcher", ""))

cases = [
    (dangerous_re, "git push origin master", True, "block-dangerous matches master push"),
    (dangerous_re, "yarn test", False, "block-dangerous ignores unrelated commands"),
    (upstream_re, "git push origin feat/x", True, "block-upstream-pr matches git push"),
    (upstream_re, "gh pr create --title x", True, "block-upstream-pr matches gh pr create"),
]

for regex, cmd, should_match, label in cases:
    matched = regex.search(cmd) is not None
    assert matched == should_match, f"{label}: expected match={should_match} for {cmd!r}"

mcp_hooks = cfg.get("hooks", {}).get("beforeMCPExecution", [])
mcp = next(
    (h for h in mcp_hooks if h.get("command") == ".cursor/hooks/block-upstream-mcp.sh"),
    None,
)
assert mcp, "block-upstream-mcp.sh must be registered in beforeMCPExecution"
assert mcp.get("failClosed") is True, "block-upstream-mcp.sh must set failClosed: true"

for rel in (
    ".cursor/hooks/block-dangerous.sh",
    ".cursor/hooks/block-upstream-pr.sh",
    ".cursor/hooks/block-upstream-mcp.sh",
    ".cursor/hooks/redact-secrets.sh",
    ".cursor/hooks/format-and-audit.sh",
):
    assert rel in {
        h.get("command")
        for event in cfg.get("hooks", {}).values()
        for h in event
        if isinstance(h, dict)
    }, f"{rel} must be referenced in hooks.json"

print("OK  hooks.json structure, matchers, and failClosed flags")
PY

echo "block-dangerous.sh"
assert_perm "$DANGEROUS" '{"command":"git push --force origin main"}' deny "force push flag"
assert_perm "$DANGEROUS" '{"command":"git push origin +main"}' deny "git +refspec force push"
assert_perm "$DANGEROUS" '{"command":"git push origin +main:main"}' deny "git +refspec mapping"
assert_perm "$DANGEROUS" '{"command":"git push origin feature-branch"}' allow "normal push"
assert_perm "$DANGEROUS" '{"command":"git push origin master"}' deny "direct push to master"
assert_perm "$DANGEROUS" '{"command":"git push origin main"}' deny "direct push to main"
assert_perm "$DANGEROUS" '{"command":"cd /repo && git checkout master && git merge feat/x && git push origin master"}' deny "chained push to master"

echo "block-upstream-pr.sh"
assert_perm "$PR_HOOK" '{"command":"gh pr create --repo excalidraw/excalidraw --title x"}' deny "explicit upstream repo"
assert_perm "$PR_HOOK" '{"command":"gh pr create --title x"}' deny "gh pr create without --repo"
assert_perm "$PR_HOOK" '{"command":"gh pr merge 1"}' deny "gh pr merge without --repo"
assert_perm "$PR_HOOK" '{"command":"git push upstream master"}' deny "push upstream"
assert_perm "$PR_HOOK" '{"command":"gh pr create --repo chuysmans/excalidraw --title x"}' allow "fork repo"
assert_perm "$PR_HOOK" '{"command":"gh issue view 1 --repo excalidraw/excalidraw"}' allow "read upstream issue"
assert_perm "$PR_HOOK" '{"command":"git push origin feat/my-branch"}' allow "push origin branch"

echo "block-upstream-mcp.sh"
assert_perm "$MCP_HOOK" '{"toolName":"create_pull_request","arguments":{"owner":"excalidraw","repo":"excalidraw","title":"x"}}' deny "upstream MCP PR write"
assert_perm "$MCP_HOOK" '{"toolName":"create_pull_request","arguments":{"title":"x"}}' deny "MCP PR write without repo"
assert_perm "$MCP_HOOK" '{"toolName":"create_pull_request","arguments":{"owner":"chuysmans","repo":"excalidraw","title":"x"}}' allow "fork MCP PR write"
assert_perm "$MCP_HOOK" '{"toolName":"issue_read","arguments":{"owner":"excalidraw","repo":"excalidraw","issue_number":1}}' allow "upstream issue read"

echo "format-and-audit.sh"
AUDIT_LOG="$ROOT/.cursor/ai-edit-audit.log.test"
rm -f "$AUDIT_LOG"
mv "$AUDIT_HOOK" "$AUDIT_HOOK.real"
trap 'mv "$AUDIT_HOOK.real" "$AUDIT_HOOK"; rm -f "$AUDIT_LOG"' EXIT
sed 's|\.cursor/ai-edit-audit\.log|.cursor/ai-edit-audit.log.test|' "$AUDIT_HOOK.real" > "$AUDIT_HOOK"
chmod +x "$AUDIT_HOOK"
payload='{"file_path":"/tmp/with\"quote.ts","conversation_id":"id\\bad"}'
run_hook "$AUDIT_HOOK" "$payload" >/dev/null
python3 - "$AUDIT_LOG" <<'PY'
import json, sys
line = open(sys.argv[1], encoding="utf-8").readline().strip()
parsed = json.loads(line)
assert parsed["file"] == '/tmp/with"quote.ts'
assert parsed["conversation"] == 'id\\bad'
print("OK  audit log line is valid JSON with escaped values")
PY
mv "$AUDIT_HOOK.real" "$AUDIT_HOOK"
trap - EXIT
rm -f "$AUDIT_LOG"

echo "All hook checks passed."
