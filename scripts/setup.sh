#!/usr/bin/env bash
# One-shot local setup for this fork of multi-gmail-mcp (macOS / Linux).
#
#   ./scripts/setup.sh you@gmail.com:personal work@company.com:work
#
# Installs dependencies from this checkout, authenticates each account
# (opens your browser), and registers the server in Claude Desktop's config.
# Re-running is safe: accounts already authenticated are skipped.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OAUTH_FILE="$HOME/.gmail-mcp-oauth.json"

# 1. Node version check (node:sqlite needs >= 22.5)
if ! command -v node >/dev/null; then
  echo "Node.js >= 22.5 is required: https://nodejs.org" >&2; exit 1
fi
NODE_BIN="$(command -v node)"
if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=5)?0:1)'; then
  echo "Node.js >= 22.5 is required (found $(node --version))." >&2; exit 1
fi

# 2. Dependencies
echo "==> Installing dependencies in $REPO_DIR"
(cd "$REPO_DIR" && npm ci --no-audit --no-fund)

# 3. Google OAuth client credentials
if [[ ! -f "$OAUTH_FILE" && ( -z "${GOOGLE_CLIENT_ID:-}" || -z "${GOOGLE_CLIENT_SECRET:-}" ) ]]; then
  CANDIDATE="$(ls -t "$HOME"/Downloads/client_secret_*.json 2>/dev/null | head -1 || true)"
  if [[ -n "$CANDIDATE" ]]; then
    echo "==> Using $CANDIDATE as $OAUTH_FILE"
    cp "$CANDIDATE" "$OAUTH_FILE"
  else
    cat >&2 <<EOF
No Google OAuth credentials found. Create a "Desktop app" OAuth client in
Google Cloud Console (see SETUP_GUIDE.md, Step 2), download its JSON, then
either save it as $OAUTH_FILE or leave it in ~/Downloads and re-run this script.
EOF
    exit 1
  fi
fi
[[ -f "$OAUTH_FILE" ]] && chmod 600 "$OAUTH_FILE"

# 4. Authenticate accounts (args are email or email:label)
CLI=("$NODE_BIN" "$REPO_DIR/bin/gmail-mcp-cli.js")
EXISTING="$("${CLI[@]}" list 2>/dev/null || true)"
for spec in "$@"; do
  email="${spec%%:*}"
  label=""
  [[ "$spec" == *:* ]] && label="${spec#*:}"
  if grep -qiF "$email" <<<"$EXISTING"; then
    echo "==> $email already authenticated, skipping"
    [[ -n "$label" ]] && "${CLI[@]}" label "$email" "$label"
    continue
  fi
  echo "==> Authenticating $email (a browser window will open)"
  if [[ -n "$label" ]]; then
    "${CLI[@]}" add "$email" --label "$label"
  else
    "${CLI[@]}" add "$email"
  fi
done

# 5. Register in Claude Desktop (absolute paths, so nvm/PATH issues don't matter)
case "$(uname -s)" in
  Darwin) CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  *)      CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ;;
esac
mkdir -p "$(dirname "$CONFIG")"
[[ -f "$CONFIG" ]] && cp "$CONFIG" "$CONFIG.bak"
"$NODE_BIN" - "$CONFIG" "$NODE_BIN" "$REPO_DIR/bin/gmail-mcp.js" <<'EOF'
const fs = require('fs');
const [config, node, server] = process.argv.slice(2);
let data = {};
try { data = JSON.parse(fs.readFileSync(config, 'utf8')); } catch {}
data.mcpServers = data.mcpServers || {};
data.mcpServers['multi-gmail'] = { command: node, args: [server] };
fs.writeFileSync(config, JSON.stringify(data, null, 2) + '\n');
EOF
echo "==> Registered multi-gmail in $CONFIG"

echo
"${CLI[@]}" list
echo
echo "Done. Fully quit and reopen Claude Desktop, then ask: \"List my Gmail accounts.\""
echo "Add more accounts later with: $0 another@gmail.com:label"
