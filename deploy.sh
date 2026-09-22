#!/usr/bin/env bash
# ===========================================================================
# DATA COMMONS AGENT — DEPLOYER
#
# One repository is one deployment. Its settings are config/instance.env.
#
#   ./deploy.sh --bootstrap-secrets   write the Gemini key to Secret Manager
#   ./deploy.sh                       build, configure, apply
#   ./deploy.sh --plan                show the Terraform diff and stop
#   ./deploy.sh --config-only --restart   push prompts/config and restart
#   ./deploy.sh --destroy             tear it down
# ===========================================================================
set -euo pipefail

BOOTSTRAP_SECRETS=false
PLAN_ONLY=false
CONFIG_ONLY=false
RESTART=false
DESTROY=false
CODE_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --bootstrap-secrets) BOOTSTRAP_SECRETS=true ;;
        --plan)              PLAN_ONLY=true ;;
        --config-only)       CONFIG_ONLY=true ;;
        --restart)           RESTART=true ;;
        --destroy)           DESTROY=true ;;
        --code-only)         CODE_ONLY=true ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0;37m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

for cmd in gcloud terraform python3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "Required tool '$cmd' is not on PATH."; exit 1; }
done

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
ENV_FILE="${ROOT}/config/instance.env"
[ -f "$ENV_FILE" ] || { log_error "Missing $ENV_FILE"; exit 1; }
# shellcheck source=/dev/null
set -a; . "$ENV_FILE"; set +a

MISSING=()
for v in PROJECT_ID REGION INSTANCE CDC_SERVICE_URL CDC_SERVICE_NAME ACCESS_MODE ALLOWED_ORIGIN; do
    [ -n "${!v:-}" ] || MISSING+=("$v")
done
if [ "${ACCESS_MODE:-}" = "iap" ] || [ "${ACCESS_MODE:-}" = "private" ]; then
    [ -n "${AUTHORIZED_MEMBERS:-}" ] || MISSING+=("AUTHORIZED_MEMBERS (required when ACCESS_MODE=${ACCESS_MODE})")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "config/instance.env is incomplete. Missing:"
    printf '  - %s\n' "${MISSING[@]}" >&2
    exit 1
fi
case "$ACCESS_MODE" in
    public|iap|private) ;;
    *) log_error "ACCESS_MODE must be one of: public, iap, private (got '${ACCESS_MODE}')"; exit 1 ;;
esac

CONFIG_BUCKET="${CONFIG_BUCKET:-${PROJECT_ID}-${INSTANCE}-config}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"
AR_REPO="${AR_REPO:-dc-agent}"
TIMEZONE="${TIMEZONE:-UTC}"
ENABLE_VPC_EGRESS="${ENABLE_VPC_EGRESS:-false}"
GEMINI_SECRET_ID="${INSTANCE}-gemini-api-keys"
TF_DIR="${ROOT}/terraform"
STATE_PREFIX="dc-agent/${INSTANCE}"

log_info "Project ${PROJECT_ID} · region ${REGION} · instance ${INSTANCE}"

# ---------------------------------------------------------------------------
# Mode: --bootstrap-secrets
# ---------------------------------------------------------------------------
if [ "$BOOTSTRAP_SECRETS" = true ]; then
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        log_error "Set GEMINI_API_KEY in your shell first:"
        echo "  GEMINI_API_KEY=... ./deploy.sh --bootstrap-secrets" >&2
        exit 1
    fi
    gcloud services enable secretmanager.googleapis.com --project="$PROJECT_ID" --quiet
    if ! gcloud secrets describe "$GEMINI_SECRET_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
        gcloud secrets create "$GEMINI_SECRET_ID" --replication-policy=automatic --project="$PROJECT_ID"
    fi
    # Stored as a JSON array so keys can be rotated by adding a version.
    python3 -c 'import json,os,sys; sys.stdout.write(json.dumps([k.strip() for k in os.environ["GEMINI_API_KEY"].split(",") if k.strip()]))' \
        | gcloud secrets versions add "$GEMINI_SECRET_ID" --data-file=- --project="$PROJECT_ID"
    log_success "Gemini key(s) written to secret '${GEMINI_SECRET_ID}'. Nothing was written to disk."
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: --destroy
# ---------------------------------------------------------------------------
if [ "$DESTROY" = true ]; then
    log_warn "This destroys the agent service, its identity and its IAM bindings in ${PROJECT_ID}."
    log_warn "Your CDC data plane, the config bucket and the secret are NOT touched."
    read -r -p "Type the instance name to confirm: " confirm
    [ "$confirm" = "$INSTANCE" ] || { log_error "Did not match. Nothing destroyed."; exit 1; }
    terraform -chdir="$TF_DIR" init -reconfigure \
        -backend-config="bucket=${STATE_BUCKET}" \
        -backend-config="prefix=${STATE_PREFIX}"
    terraform -chdir="$TF_DIR" destroy -var-file=terraform.tfvars
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: --config-only
# ---------------------------------------------------------------------------
sync_config() {
    log_info "Syncing prompts and agent config to gs://${CONFIG_BUCKET}..."
    gcloud storage cp agent-config.json "gs://${CONFIG_BUCKET}/agent-config.json" --project="$PROJECT_ID"
    gcloud storage rsync prompts "gs://${CONFIG_BUCKET}/prompts" --recursive --project="$PROJECT_ID"
    log_success "Config synced."
}

if [ "$CONFIG_ONLY" = true ]; then
    sync_config
    if [ "$RESTART" = true ]; then
        # The agent reads its config and prompts once, at startup. Without a new
        # revision the bucket changes and the running service does not.
        log_info "Forcing a new revision so the running service picks it up..."
        gcloud run services update "${INSTANCE}-agent" \
            --region="$REGION" --project="$PROJECT_ID" \
            --update-env-vars="FORCE_RESTART=$(date +%s)" --quiet
        log_success "Restarted."
    else
        log_warn "Bucket updated, running service unchanged. Add --restart to apply it."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. APIs, state bucket, Artifact Registry
# ---------------------------------------------------------------------------
if [ "$CODE_ONLY" = false ]; then
    log_info "Enabling required APIs..."
    APIS=(run.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com
          storage.googleapis.com cloudbuild.googleapis.com iam.googleapis.com
          compute.googleapis.com)
    [ "$ACCESS_MODE" = "iap" ] && APIS+=(iap.googleapis.com)
    gcloud services enable "${APIS[@]}" --project="$PROJECT_ID" --quiet
    log_success "APIs enabled."

    if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_info "Creating Terraform state bucket gs://${STATE_BUCKET}..."
        gcloud storage buckets create "gs://${STATE_BUCKET}" \
            --project="$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
        gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --project="$PROJECT_ID"
    fi

    if ! gcloud artifacts repositories describe "$AR_REPO" \
            --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_info "Creating Artifact Registry repository '${AR_REPO}'..."
        gcloud artifacts repositories create "$AR_REPO" \
            --repository-format=docker --location="$REGION" --project="$PROJECT_ID"
    fi

    if ! gcloud secrets describe "$GEMINI_SECRET_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_error "Secret '${GEMINI_SECRET_ID}' does not exist. Run this first:"
        echo "  GEMINI_API_KEY=... ./deploy.sh --bootstrap-secrets" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 3. Build the agent image
# ---------------------------------------------------------------------------
IMAGE_TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
AGENT_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/agent:${IMAGE_TAG}"
log_info "Building ${AGENT_IMAGE}..."
gcloud builds submit --tag="$AGENT_IMAGE" --project="$PROJECT_ID" agent \
    || { log_error "Container build failed."; exit 1; }
log_success "Image built."

# ---------------------------------------------------------------------------
# 4. Config bucket
# ---------------------------------------------------------------------------
if [ "$CODE_ONLY" = false ]; then
    if ! gcloud storage buckets describe "gs://${CONFIG_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
        log_info "Creating config bucket gs://${CONFIG_BUCKET}..."
        gcloud storage buckets create "gs://${CONFIG_BUCKET}" \
            --project="$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
    fi
    sync_config
fi

# ---------------------------------------------------------------------------
# 5. Render terraform.tfvars
# ---------------------------------------------------------------------------
log_info "Rendering terraform.tfvars..."
V_AGENT_IMAGE="$AGENT_IMAGE" \
V_CONFIG_BUCKET="$CONFIG_BUCKET" \
V_GEMINI_SECRET="$GEMINI_SECRET_ID" \
python3 - "$TF_DIR/terraform.tfvars" <<'PYEOF'
import json, os, sys

def hcl(value):
    return json.dumps(value)

members = [m.strip() for m in os.environ.get("AUTHORIZED_MEMBERS", "").split(",") if m.strip()]
bucket = os.environ["V_CONFIG_BUCKET"]

lines = [
    "# Generated by deploy.sh from config/instance.env. Do not edit by hand.",
    "",
    f"project_id = {hcl(os.environ['PROJECT_ID'])}",
    f"region     = {hcl(os.environ['REGION'])}",
    f"instance   = {hcl(os.environ['INSTANCE'])}",
    "",
    f"agent_image = {hcl(os.environ['V_AGENT_IMAGE'])}",
    "",
    f"cdc_service_url   = {hcl(os.environ['CDC_SERVICE_URL'])}",
    f"cdc_service_name  = {hcl(os.environ['CDC_SERVICE_NAME'])}",
    f"enable_vpc_egress = {str(os.environ.get('ENABLE_VPC_EGRESS', 'true')).lower() == 'true' and 'true' or 'false'}",
    "",
    f"config_bucket             = {hcl(bucket)}",
    f"config_base_url           = {hcl('https://storage.googleapis.com/' + bucket)}",
    f"gemini_api_keys_secret_id = {hcl(os.environ['V_GEMINI_SECRET'])}",
    "",
    f"access_mode        = {hcl(os.environ['ACCESS_MODE'])}",
    f"allowed_origin     = {hcl(os.environ['ALLOWED_ORIGIN'])}",
    f"authorized_members = {json.dumps(members)}",
    "",
    f"timezone = {hcl(os.environ.get('TIMEZONE', 'UTC'))}",
    "",
]
with open(sys.argv[1], "w") as fh:
    fh.write("\n".join(lines))
print(f"  wrote {sys.argv[1]}")
PYEOF

# ---------------------------------------------------------------------------
# 6. Terraform
# ---------------------------------------------------------------------------
log_info "terraform init..."
terraform -chdir="$TF_DIR" init -reconfigure -input=false \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="prefix=${STATE_PREFIX}"

if [ "$PLAN_ONLY" = true ]; then
    terraform -chdir="$TF_DIR" plan -var-file=terraform.tfvars
    log_info "Plan only. Nothing applied."
    exit 0
fi

log_info "terraform apply..."
terraform -chdir="$TF_DIR" apply -auto-approve -input=false -var-file=terraform.tfvars

AGENT_URL="$(terraform -chdir="$TF_DIR" output -raw agent_url)"
AGENT_SA="$(terraform -chdir="$TF_DIR" output -raw agent_service_account)"

echo
log_success "Deployed."
echo "  Agent URL:       ${AGENT_URL}"
echo "  Service account: ${AGENT_SA}"
echo

case "$ACCESS_MODE" in
    public)
        log_info "Checking health..."
        if curl -fsS --max-time 30 "${AGENT_URL}/agent/health" >/dev/null; then
            log_success "GET ${AGENT_URL}/agent/health responded."
        else
            log_warn "Health check did not pass yet. Cold start can take a minute; retry it."
        fi
        ;;
    iap)
        log_info "Sign in at ${AGENT_URL} with a listed member."
        log_warn "If this project has no OAuth consent screen yet, IAP will not let anyone in."
        ;;
    private)
        log_info "Reach it with:"
        echo "  gcloud run services proxy ${INSTANCE}-agent --region=${REGION} --project=${PROJECT_ID} --port=8080"
        ;;
esac
