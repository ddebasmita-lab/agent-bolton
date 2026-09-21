# Data Commons Agent

A conversational agent over a Data Commons Platform (DCP) instance. It runs as a
single Cloud Run service, answers questions in natural language by calling your
DCP data plane through MCP, and streams the answer back as Server-Sent Events.

There is no user interface here. This is an API you call from your own front
end.

## Contents

- [How it fits together](#how-it-fits-together)
- [Running it](RUNNING.md) — locally, in a container, and how the DCP connection is wired
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [The API](#the-api)
- [Reaching your data plane](#reaching-your-data-plane)
- [Configuration](#configuration)
- [Access modes](#access-modes)
- [Everyday commands](#everyday-commands)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)

## How it fits together

```
   your front end
         │
         │  POST /agent/chat/stream        (SSE: thoughts, tool calls, answer)
         │  GET  /api/..., /core/...       (chart data, reverse-proxied)
         ▼
   ┌──────────────────────────────┐
   │  agent (Cloud Run)           │        Gemini  ◀── prompts + config
   │  ─ chat orchestration        │────▶            from your config bucket
   │  ─ MCP tool loop             │
   │  ─ /dcproxy reverse proxy    │
   └──────────────┬───────────────┘
                  │  ID token, minted per request
                  ▼
      your DCP instance (Cloud Run)
      provisioned separately by datacommons-cli
```

Two things follow from this shape, and both matter when you build the front end:

**Your browser code cannot call DCP directly.** The agent's service account is
the only principal granted `run.invoker` on your DCP service. Requests for chart
data go to the agent, which replays them upstream with a Google-signed ID token.
That is what `/dcproxy` is for.

**The agent holds the Gemini key.** Every chat request spends your quota. Guard
the endpoint accordingly — see [Access modes](#access-modes).

## Prerequisites

- A GCP project with billing enabled.
- A **DCP instance already provisioned** by `datacommons-cli`, and its
  `terraform output datacommons_service_url` and `datacommons_service_name`.
- A **Gemini API key** from [aistudio.google.com](https://aistudio.google.com).
- Local tools: `gcloud` (authenticated, with ADC), `terraform` >= 1.5,
  `python3`, `curl`.
- IAM in the project: enough to create Cloud Run services, service accounts,
  IAM bindings, buckets, Artifact Registry repositories and secrets. Project
  Editor plus Project IAM Admin covers it.

You also need permission to grant `run.invoker` on the **DCP** service. That
grant is what makes the backend reachable, and it is frequently the one thing a
deployer does not have.

## Quickstart

```bash
# 1. This clone IS the deployment. Fill in its settings.
$EDITOR config/instance.env

# 2. Put the Gemini key in Secret Manager — once, ever. Nothing is written to disk.
GEMINI_API_KEY=... ./deploy.sh --bootstrap-secrets

# 3. Deploy.
./deploy.sh
```

The deploy prints the agent's URL and its service account. Check it:

```bash
curl https://<agent-url>/agent/health
```

To run it on your own machine first — against the same DCP instance, without
deploying anything — see **[RUNNING.md](RUNNING.md)**.

## The API

All endpoints are under `/agent` by default. Set `AGENT_API_PREFIX` on the
service to change it.

| Method | Path | What it does |
|---|---|---|
| `POST` | `/agent/chat/stream` | The main one. Ask a question, stream the answer. |
| `GET` | `/agent/health` | Liveness and backend status. |
| `GET` | `/agent/api/config` | The active agent config, secrets redacted. |
| `GET` | `/agent/api/tools` | MCP tools currently available. |
| `POST` | `/agent/api/call` | Call one MCP tool directly, bypassing the model. |

### `POST /agent/chat/stream`

```jsonc
{
  "message": "What was the population of Karnataka in 2021?",
  "history": [],            // optional prior turns
  "session_id": "..."       // optional; returned by the first response
}
```

Responds with `text/event-stream`. Each event is one `data:` line holding a JSON
object. Switch on the key that is present:

| Key | Meaning |
|---|---|
| `session_id` | Sent first. Pass it back on follow-up turns. |
| `status` | Phase marker: `mcp_start`, `mcp_complete`, `mcp_skipped`, `kb_start`, `kb_complete`, `synthesis_start`. |
| `thought` | A chunk of the model's reasoning. Carries `phase`. |
| `thinking_complete` | Reasoning finished for the named phase. |
| `type: "tool_call"` | One MCP call, with `name`, `arguments`, `result`, `status`. |
| `data_status` | Whether the tool phase actually found observations. |
| `mcp_sources` / `kb_sources` | Numbered provenance. **Your UI must render this** — see below. |
| `text` | A chunk of the answer. Concatenate these in order. |
| `usage` | Token counts for the turn. |
| `chart_config` | Chart spec, plus `done: true` and `duration_ms`. Last substantive event. |
| `follow_up_questions` | Suggested next questions. |
| `error` | Something failed. The stream ends. |

A minimal consumer only needs `text`, `chart_config` and `error`. The rest exist
so a UI can show progress while Gemini thinks — a full turn takes tens of
seconds, and without those events the page looks frozen.

### Sources are your job to render

The answer carries inline citation markers — `[1]`, `[2]` — that refer to the
numbered list in `mcp_sources`. The agent is deliberately instructed *not* to
end its answer with a Sources section, because a model-written list is numbered
independently of the real one and the two disagree.

So if your front end drops `mcp_sources`, every answer arrives with citation
markers pointing at nothing. It looks like a prompt problem and it is not.
Collect that event and render the list under the answer.

### Chart data

Chart specs in `chart_config` reference Data Commons series. To fetch them, call
the agent at the data-plane paths it proxies: `/api`, `/core`, `/place`,
`/tools`, `/node`, `/browser`, `/explore`, `/nl`, `/ranking`, `/topic`,
`/datacommons`, and a few others. Same origin as the chat endpoint, no
credential of your own required.

## Reaching your data plane

`DCP_SERVICE_NAME` in `config/instance.env` is what the agent's service account
is granted `run.invoker` on. If it is wrong or missing, the backend refuses
every call — and the agent reports "I don't have this data" rather than
surfacing an error. If answers are consistently empty, check that binding
first:

```bash
gcloud run services get-iam-policy <DCP_SERVICE_NAME> --region=<REGION>
```

You should see the agent's service account with `roles/run.invoker`.

If your DCP service is `ingress=internal`, also set `ENABLE_VPC_EGRESS="true"`.
That routes all of the agent's outbound traffic through a VPC, which is what
reaching an internal service requires. Private Google Access covers Gemini, GCS
and Secret Manager; anything else outbound then needs Cloud NAT.

## Configuration

Two files drive the agent's behaviour. Both live in the config bucket and are
read **once at startup**, so changing them needs a restart.

### `prompts/`

| File | Used in |
|---|---|
| `mcp.md` | Choosing and calling data tools. |
| `synthesis.md` | Writing the final answer, including citation rules. |
| `kb.md` | The knowledge-base phase, when enabled. |
| `follow_up.md` | Generating follow-up questions. |

`{{instance.name}}`, `{{instance.region}}`, `{{instance.states_term}}` and
`{{CURRENT_DATETIME}}` are substituted at load time. HTML comments are stripped
before the text reaches Gemini, so you can leave authoring notes in the files.

### `agent-config.json`

Models, thinking levels, the knowledge-base toggle and the `template_vars`
above. Secrets never go here — the Gemini keys come from Secret Manager.

To enable retrieval over your own documents: create a Gemini File Search corpus
at aistudio.google.com, upload the documents, put the corpus id in
`gemini.filestores[]`, and set `knowledge_base.enabled` to `true`.

Apply either change with:

```bash
./deploy.sh --config-only --restart
```

Without `--restart` the bucket updates and the running service does not.

## Access modes

Set `ACCESS_MODE` in `config/instance.env`.

| Mode | Who gets in | Use when |
|---|---|---|
| `public` | Anyone with the URL | Your front end is a public website. Pair it with a tight `ALLOWED_ORIGIN`, or put your own backend in front. |
| `iap` | Google sign-in, `AUTHORIZED_MEMBERS` only | Internal tool. Needs an OAuth consent screen in the project — one manual console step. |
| `private` | `AUTHORIZED_MEMBERS` with an identity token | A pilot you drive yourself, via `gcloud run services proxy`. |

A browser front end cannot call an `iap` or `private` service without carrying
the user's credential. If your front end is a public page, `public` plus a tight
`ALLOWED_ORIGIN` is the workable combination.

`ALLOWED_ORIGIN` is required and has no default. This service has no UI of its
own, so every caller is cross-origin, and that list is the only thing stopping
an arbitrary website from driving your agent and spending your Gemini quota.

## Everyday commands

```bash
./deploy.sh                          # full deploy
./deploy.sh --plan                   # show the Terraform diff, change nothing
./deploy.sh --code-only              # rebuild and redeploy the image only
./deploy.sh --config-only --restart  # push prompts/config and restart
./deploy.sh --destroy                # tear down the agent (not your DCP)
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Every answer says the data is unavailable | The `run.invoker` grant on your DCP service is missing or names the wrong service. Check `DCP_SERVICE_NAME`. |
| Chat works, charts 404 | Your front end is calling DCP directly instead of the agent's proxied paths. |
| CORS errors in the browser | `ALLOWED_ORIGIN` does not list your front end's origin. It is comma-separated and exact — scheme and port included. |
| 403 after signing in successfully | `iap` mode without the IAP service agent binding, or no OAuth consent screen in the project. |
| Deploy fails on the `allUsers` binding | Your organisation enforces Domain Restricted Sharing. Use `iap`. |
| `503` on the first request after idle | Cold start. Set `agent_min_instances = 1` if that matters. |
| Prompt edits have no effect | Config is read once at startup. Add `--restart`. |

## Repository layout

```
agent/            the service — Flask app, MCP client, Gemini client, workflows
  Dockerfile      built by deploy.sh via Cloud Build
  src/server/     HTTP routes
  src/workflows/  the chat pipeline: tool loop, KB, synthesis, charts
  tests/          run with: cd agent && for t in tests/test_*.py; do python3 "$t"; done
prompts/          the four system prompts, synced to the config bucket
agent-config.json models, thinking levels, template vars
config/
  instance.env    this deployment's settings
terraform/        one Cloud Run service, one service account, access control
cloudbuild.yaml   build and roll out from CI — see RUNNING.md
deploy.sh         the deployer
run-local.sh      run it on this machine, pointed at your DCP instance
```

