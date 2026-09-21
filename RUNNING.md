# Running the agent

How to start the agent and point it at a DCP instance — on your own machine
first, then as a container, then on Cloud Run.

If you only want it deployed, skip to [README.md](README.md); `./deploy.sh`
does everything below for you.

- [What the agent needs](#what-the-agent-needs)
- [Connecting to a DCP MCP endpoint](#connecting-to-a-dcp-mcp-endpoint)
- [Running it locally](#running-it-locally)
- [Running the container](#running-the-container)
- [Building the image with Cloud Build](#building-the-image-with-cloud-build)
- [Checking the connection](#checking-the-connection)
- [When it does not connect](#when-it-does-not-connect)

## What the agent needs

Four things, whatever it is running on:

| | Where it comes from |
|---|---|
| **An MCP endpoint** | Your DCP instance. `MCP_SERVER_URL`. |
| **A Gemini API key** | Secret Manager via `GEMINI_API_KEYS_SECRET`, or `gemini.api_keys[]` in its config. |
| **Its config** | `agent/config.json` on disk, or fetched from a bucket via `CONFIG_URL`. |
| **Its prompts** | Merged into that config. Deployed, they come from `prompts/` in the bucket. |

The last one catches people out. The agent merges `prompts/*.md` into its config
**only** when it boots from `CONFIG_URL`. Start it locally without that and every
phase runs with an empty system instruction: it answers, badly, and nothing in
the logs says why. `run-local.sh` assembles the prompts for you, which is most
of the reason it exists.

## Connecting to a DCP MCP endpoint

Your DCP instance serves MCP at `/mcp` on its Cloud Run URL. The agent resolves
that endpoint in this order:

1. `MCP_SERVER_URL` — wins over everything.
2. `mcp.server_url` in its config.
3. `http://localhost:3000/mcp` — the fallback, for an MCP server on the same host.

A bare origin is fine. `https://acme-dc-datacommons-service-xyz.run.app` gets
`/mcp` appended for you, so both spellings work.

On connect the agent performs the MCP handshake — a JSON-RPC `initialize` at
protocol version `2024-11-05`, then an `initialized` notification — and holds
the session id for later calls. If the server later says the session is gone,
the agent re-handshakes and retries once, so a restarted DCP does not need the
agent restarted too.

### Authentication, and why localhost matters

A DCP service is normally IAM-gated. The agent authenticates by minting a
Google-signed ID token for the target's origin and sending it as a bearer
token. It gets that token from the **GCP metadata server** — which exists on
Cloud Run and does not exist on your laptop.

So pointing a local agent straight at `https://...run.app` sends an
unauthenticated request, and DCP refuses it. That looks like the agent finding
no data rather than like an auth failure.

The way around it is a local proxy, which carries *your* gcloud credentials:

```bash
gcloud run services proxy <DCP_SERVICE_NAME> --region=<REGION> --port=8082
```

Now `http://127.0.0.1:8082/mcp` reaches your DCP as you. The agent skips token
minting for `http://` and localhost targets, so nothing fights the proxy.

## Running it locally

```bash
# 1. Dependencies, once.
python3 -m venv .venv
.venv/bin/pip install -r agent/requirements.txt

# 2. Open a tunnel to your DCP instance. Leave it running.
gcloud run services proxy <DCP_SERVICE_NAME> --region=<REGION> --port=8082

# 3. In another terminal, start the agent.
PATH="$PWD/.venv/bin:$PATH" GEMINI_API_KEY=... ./run-local.sh
```

The agent comes up on `http://localhost:5001`. Ask it something:

```bash
curl -N -X POST http://localhost:5001/agent/chat/stream \
  -H 'Content-Type: application/json' \
  -d '{"message":"What data do you have for Bengaluru?"}'
```

`-N` matters — without it curl buffers the stream and you wait for the whole
answer instead of watching it arrive.

### Keeping the key off disk

If you have already deployed once, the key is in Secret Manager and your local
gcloud credentials can read it. Use that instead and nothing lands on disk:

```bash
gcloud auth application-default login
GEMINI_API_KEYS_SECRET=<instance>-gemini-api-keys ./run-local.sh
```

With `GEMINI_API_KEY` instead, `run-local.sh` writes the key into
`agent/config.json`. That file is gitignored. Keep it that way.

### What run-local.sh actually does

Nothing magic, and worth knowing so you can do it by hand:

1. Reads `agent-config.json`, strips the `$schema` and `$comment` keys.
2. Reads `prompts/*.md` into a `prompts` object on the config — the step the
   bucket does in a real deployment.
3. Sets `mcp.server_url` to `MCP_SERVER_URL`.
4. Writes the result to `agent/config.json`.
5. Runs `python3 main.py` from `agent/`.

The agent re-reads `agent/config.json` whenever its modification time changes,
so you can edit a prompt, save, and ask again without a restart.

## Running the container

Same image the deploy uses:

```bash
docker build -t dc-agent:local agent/

docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e MCP_SERVER_URL="http://host.docker.internal:8082/mcp" \
  -e ALLOWED_ORIGIN="http://localhost:3000" \
  -e CONFIG_URL="https://storage.googleapis.com/<config-bucket>/agent-config.json" \
  -e GEMINI_API_KEYS_SECRET="<instance>-gemini-api-keys" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/adc.json \
  -v "$HOME/.config/gcloud/application_default_credentials.json:/adc.json:ro" \
  dc-agent:local
```

Three things differ from the bare local run:

- `host.docker.internal` reaches the `gcloud run services proxy` running on
  your host. On Linux add `--add-host=host.docker.internal:host-gateway`.
- `CONFIG_URL` means prompts come from the bucket, as they do in production —
  so this is the closer rehearsal of a real deployment.
- Credentials have to be mounted in. The container has no gcloud.

The image is built `linux/amd64` only. Cloud Run rejects arm64 with a startup
error that does not mention architecture, so on Apple silicon keep the
`--platform linux/amd64` the Dockerfile pins.

## Building the image with Cloud Build

`./deploy.sh` already builds through Cloud Build — the `gcloud builds submit`
it runs uploads `agent/` as the build context, builds the Dockerfile on
Google's infrastructure and pushes the result to Artifact Registry, tagged with
your current git SHA. You do not have to have Docker installed for that to
work.

To build without deploying:

```bash
gcloud builds submit \
  --tag="<region>-docker.pkg.dev/<project>/dc-agent/agent:$(git rev-parse --short HEAD)" \
  --project=<project> \
  agent
```

The last argument is the build context, and it is `agent/` rather than `.` on
purpose — nothing outside that directory belongs in the image.

### Continuous builds

`cloudbuild.yaml` at the repository root builds, pushes and rolls out. Wire it
to your default branch:

```bash
gcloud builds triggers create github \
  --name=agent-main \
  --repo-owner=<org> --repo-name=<repo> --branch-pattern='^main$' \
  --build-config=cloudbuild.yaml \
  --substitutions=_REGION=<region>,_INSTANCE=<instance>
```

Run `./deploy.sh` once before the first trigger fires. Nothing in
`cloudbuild.yaml` creates the Artifact Registry repository or the Cloud Run
service; it expects both to exist.

### This drifts from Terraform, and you should decide how

Terraform owns the Cloud Run service, including which image it runs. When a
build deploys an image directly, Terraform does not know about it — and the
next `terraform apply` sees an image it did not set and reverts it. You get
silently rolled back to whatever `./deploy.sh` last applied, which is a
confusing afternoon.

Pick one:

| | How | Trade-off |
|---|---|---|
| **Terraform stays in charge** | Set `_DEPLOY=false`. CI only pushes images. Roll out with `./deploy.sh --code-only`. | A deploy is a manual step. Nothing ever drifts. |
| **CI deploys** | Leave `_DEPLOY=true`. | Pass the built tag the next time you apply, or accept the revert. |

The first is the quieter option, and it is what `--code-only` exists for: it
rebuilds the image and applies Terraform together, so the two never disagree.

### Permissions the build needs

Builds run as a service account, and it needs more than the defaults in a fresh
project. Grant these to whichever account your builds use:

| Role | Why |
|---|---|
| `roles/artifactregistry.writer` | Push the image. |
| `roles/run.admin` | Update the Cloud Run service. Only if `_DEPLOY=true`. |
| `roles/iam.serviceAccountUser` on `<instance>-agent@...` | Deploy a service that *runs as* the agent's identity. Only if `_DEPLOY=true`. |

That last one is the one people miss. Without it the build fails at the deploy
step with a permission error naming the runtime service account rather than the
build one, which reads as though the wrong thing is broken.

## Checking the connection

```bash
curl -s http://localhost:5001/agent/health | python3 -m json.tool
```

```jsonc
{
  "status": "ok",
  "mcp_url": "http://127.0.0.1:8082/mcp",   // where it is actually pointed
  "mcp": { ... }                            // what the handshake discovered
}
```

`mcp_url` is resolved, not declared — it tells you where the agent really ended
up, which is the fastest way to catch a `MCP_SERVER_URL` that never took effect.

The tool surface is worth a look too, because an empty list means the handshake
did not complete:

```bash
curl -s http://localhost:5001/agent/api/tools | python3 -m json.tool
```

## When it does not connect

| Symptom | Cause |
|---|---|
| `mcp_url` is `http://localhost:3000/mcp` | `MCP_SERVER_URL` never reached the process. Check it is exported, not just set. |
| Tool list is empty, no error | The handshake failed. Almost always auth — see the next row. |
| Answers say there is no data, logs look clean | The call reached DCP and was refused. Off GCP: use the proxy. On Cloud Run: the agent's service account is missing `run.invoker` on the DCP service. |
| `Connection refused` on 127.0.0.1:8082 | The `gcloud run services proxy` is not running, or is on another port. |
| 404 from the MCP endpoint | The URL has a path that is not `/mcp`. A bare origin is safer — the agent appends it. |
| Answers arrive but are vague and uncited | No prompts. You started `main.py` directly without `CONFIG_URL`. Use `run-local.sh`. |
| `ALLOWED_ORIGIN is unset in a deployed environment` | Only fires on Cloud Run. Locally the agent falls back to localhost origins and logs a warning, which is fine. |

For anything past this point, the logs say more than the HTTP responses do —
the agent logs the resolved MCP endpoint, the handshake result and every tool
call it makes.
