#!/usr/bin/env bash
# Run the agent on this machine, against your DCP instance.
#
#   ./run-local.sh
#
# Assembles agent/config.json from agent-config.json and prompts/, then starts
# the agent on http://localhost:5001. See RUNNING.md for the whole story.
#
# Environment:
#   MCP_SERVER_URL              DCP endpoint. Default: http://127.0.0.1:8082/mcp
#                               (what `gcloud run services proxy` gives you)
#   GEMINI_API_KEYS_SECRET      Secret Manager id. Preferred — nothing on disk.
#   GEMINI_API_KEY              A literal key. Written into agent/config.json,
#                               which is gitignored. Used only if the above is unset.
#   PROXY_PORT                  Port to listen on. Default 5001.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0;37m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

MCP_SERVER_URL="${MCP_SERVER_URL:-http://127.0.0.1:8082/mcp}"
PROXY_PORT="${PROXY_PORT:-5001}"

if [ -z "${GEMINI_API_KEYS_SECRET:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
    die "Set GEMINI_API_KEYS_SECRET (preferred) or GEMINI_API_KEY. See RUNNING.md."
fi

command -v python3 >/dev/null || die "python3 is not on PATH."
python3 -c 'import flask, requests' 2>/dev/null || die "Dependencies missing. Run:
  python3 -m venv .venv && .venv/bin/pip install -r agent/requirements.txt
  then rerun this script with .venv/bin/python on PATH, or:
  PATH=\"\$PWD/.venv/bin:\$PATH\" ./run-local.sh"

# ---------------------------------------------------------------------------
# Assemble agent/config.json.
#
# Deployed, the agent fetches this from the config bucket and merges prompts/
# into it. Nothing does that locally, so the phases would otherwise run with no
# system instruction at all — the agent answers, badly, and nothing says why.
# ---------------------------------------------------------------------------
info "Assembling agent/config.json ..."
MCP_SERVER_URL="$MCP_SERVER_URL" python3 - <<'PYEOF'
import json, os, pathlib, re

root = pathlib.Path(__file__).parent if "__file__" in dir() else pathlib.Path.cwd()
root = pathlib.Path.cwd()
config = json.loads((root / "agent-config.json").read_text())
config.pop("$schema", None)
config.pop("$comment", None)

prompts = {}
for slot in ("mcp", "kb", "synthesis", "follow_up"):
    path = root / "prompts" / f"{slot}.md"
    if path.exists():
        body = re.sub(r"<!--.*?-->", "", path.read_text(), flags=re.DOTALL).strip()
        if body:
            prompts[slot] = body
config["prompts"] = prompts

config.setdefault("mcp", {})["server_url"] = os.environ["MCP_SERVER_URL"]
config["mcp"]["enabled"] = True

key = os.environ.get("GEMINI_API_KEY", "").strip()
if key and not os.environ.get("GEMINI_API_KEYS_SECRET"):
    config.setdefault("gemini", {})["api_keys"] = [k.strip() for k in key.split(",") if k.strip()]

(root / "agent" / "config.json").write_text(json.dumps(config, indent=2) + "\n")
print(f"  prompts: {', '.join(sorted(prompts)) or 'NONE — check prompts/'}")
print(f"  mcp:     {config['mcp']['server_url']}")
PYEOF

if [ -n "${GEMINI_API_KEY:-}" ] && [ -z "${GEMINI_API_KEYS_SECRET:-}" ]; then
    warn "Your Gemini key is now in agent/config.json. It is gitignored — keep it that way."
fi
ok "Config written."

# ---------------------------------------------------------------------------
# Reachability check. A private DCP is not reachable from a laptop directly:
# the agent can only attach a Google ID token when it runs on GCP, so off-GCP
# the call arrives unauthenticated and is refused.
# ---------------------------------------------------------------------------
case "$MCP_SERVER_URL" in
    http://127.0.0.1*|http://localhost*)
        if ! curl -fsS --max-time 3 -o /dev/null "${MCP_SERVER_URL%/mcp}" 2>/dev/null; then
            warn "Nothing is listening on ${MCP_SERVER_URL%/mcp}."
            warn "Start the proxy in another terminal:"
            echo "    gcloud run services proxy <DCP_SERVICE_NAME> --region=<REGION> --port=8082"
        fi
        ;;
    https://*)
        warn "Pointing straight at ${MCP_SERVER_URL} from this machine."
        warn "If that service is IAM-gated, every call will be refused: the agent"
        warn "mints its ID token from the GCP metadata server, which is not here."
        warn "Use 'gcloud run services proxy' instead — see RUNNING.md."
        ;;
esac

info "Starting the agent on http://localhost:${PROXY_PORT} ..."
echo
cd agent
exec env PROXY_PORT="$PROXY_PORT" MCP_SERVER_URL="$MCP_SERVER_URL" python3 main.py
