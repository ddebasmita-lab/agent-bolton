# Inputs for the Data Commons agent module.
# deploy.sh renders terraform.tfvars from config/instance.env; you should not
# need to edit this file.

variable "project_id" {
  description = "GCP project hosting the agent. Billing must be enabled."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run. Use the same one as your CDC service unless you have a reason not to."
  type        = string
}

variable "instance" {
  description = "Short name for this deployment. Names every resource it creates."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.instance))
    error_message = "instance must be a DNS-safe lowercase label (RFC 1123)."
  }
}

variable "agent_image" {
  description = "Artifact Registry path to the agent image built from agent/Dockerfile."
  type        = string
}

# ---------------------------------------------------------------------------
# Your CDC data plane
# ---------------------------------------------------------------------------

variable "cdc_service_url" {
  description = <<-EOT
    Base URL of your CDC services instance — the Cloud Run service running
    Mixer, the NL server and the website.
  EOT
  type        = string

  validation {
    condition     = can(regex("^https://", var.cdc_service_url))
    error_message = "cdc_service_url must be an https:// URL."
  }
}

variable "cdc_service_name" {
  description = <<-EOT
    Cloud Run service NAME of your CDC backend — not the URL. Conventionally
    "<instance>-datacommons".

    The agent's service account is granted run.invoker on it, and that single
    binding is what makes a private CDC backend reachable. Get it wrong and
    every answer comes back "no data" with nothing logged to explain it.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.cdc_service_name)) > 0
    error_message = "cdc_service_name is required."
  }
}

variable "enable_vpc_egress" {
  description = <<-EOT
    Route the agent's outbound traffic through a VPC. Required when the CDC
    service is ingress=internal, which is how one is normally deployed —
    hence the default.

    Not a free switch: reaching a *.run.app host through a VPC requires
    egress=ALL_TRAFFIC, which routes every outbound call through the subnet.
    Private Google Access covers *.googleapis.com (Gemini, GCS, Secret
    Manager), but any genuinely public host becomes unreachable without
    Cloud NAT.
  EOT
  type        = bool
  default     = true
}

variable "agent_subnet_cidr" {
  description = "CIDR for the egress subnet. Must not overlap anything else in the project. Ignored unless enable_vpc_egress is true."
  type        = string
  default     = "10.90.0.0/24"
}

# ---------------------------------------------------------------------------
# Configuration and secrets
# ---------------------------------------------------------------------------

variable "config_bucket" {
  description = "Name (not URL) of the config bucket holding agent-config.json and prompts/. Created by deploy.sh."
  type        = string
}

variable "config_base_url" {
  description = "HTTPS base URL, no trailing slash, where the config bucket is served. Conventionally https://storage.googleapis.com/<config_bucket>."
  type        = string
}

variable "gemini_api_keys_secret_id" {
  description = "Secret Manager ID holding a JSON array of Gemini API keys. Created by deploy.sh --bootstrap-secrets. Must have an enabled version before apply."
  type        = string
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

variable "allowed_origin" {
  description = <<-EOT
    Comma-separated CORS origins allowed to call the agent, e.g.
    "https://data.acme.com".

    Required, with no default, on purpose. This service has no UI of its own,
    so every caller is cross-origin and this list is the only thing stopping an
    arbitrary website from driving your agent and spending your Gemini quota.
    "*" works and is a decision, not a default.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.allowed_origin)) > 0
    error_message = "allowed_origin is required. Set it to your front end's origin, or \"*\" if you genuinely mean any."
  }
}

variable "access_mode" {
  description = <<-EOT
    How the agent is exposed.

      "public"   allUsers gets run.invoker. Anyone with the URL can use it,
                 including the chat endpoint, which spends Gemini quota on
                 every request. Often refused outright by Domain Restricted
                 Sharing.

      "iap"      Google sign-in in front of the service. authorized_members get
                 roles/iap.httpsResourceAccessor scoped to this service, and
                 the IAP service agent gets run.invoker so it can forward
                 requests. Requires an OAuth consent screen in the project — a
                 one-time console step Terraform cannot do for you.

      "private"  No public binding and no sign-in. authorized_members get
                 run.invoker directly; reach it with
                 `gcloud run services proxy <instance>-agent --port=8080`.

    Note that a browser front end cannot call an "iap" or "private" service
    without carrying the caller's credential. If your front end is a public
    website, you want "public" here plus a tight allowed_origin — or a backend
    of your own in front of the agent.
  EOT
  type        = string

  validation {
    condition     = contains(["public", "iap", "private"], var.access_mode)
    error_message = "access_mode must be one of: public, iap, private."
  }
}

variable "authorized_members" {
  description = "Who may reach the agent, as group: or user: principals. Required for iap and private; leave empty for public."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------

variable "timezone" {
  description = "IANA timezone the agent uses when rendering {{CURRENT_DATETIME}} in prompts, e.g. \"Asia/Kolkata\"."
  type        = string
  default     = "UTC"
}

variable "agent_cpu" {
  description = "vCPU for the agent container."
  type        = string
  default     = "1"
}

variable "agent_memory" {
  description = "Memory for the agent container."
  type        = string
  default     = "1Gi"
}

variable "agent_min_instances" {
  description = "0 lets it scale to zero; 1 removes cold starts from the chat path."
  type        = number
  default     = 0
}

variable "agent_max_instances" {
  description = "Upper bound on instances."
  type        = number
  default     = 10
}

variable "agent_concurrency" {
  description = <<-EOT
    Simultaneous requests Cloud Run will send to one instance. Cloud Run's own
    default is 80, and a chat response is an SSE stream held open for tens of
    seconds — so 80 means 80 parked threads on one vCPU. Keep this modest and
    scale out with instances instead.
  EOT
  type        = number
  default     = 12
}
