# ──────────────────────────────────────────────────────────────
# variables.tf — Input variables for the monitoring stack
# ──────────────────────────────────────────────────────────────
# To add or remove a monitored endpoint, just edit the
# "monitors" list below and run `terraform apply`.
# ──────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources. us-east-1 is required for CloudFront ACM certs."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for resource naming (S3 buckets, IAM roles, etc.)"
  type        = string
  default     = "markmarquez-monitor"
}

variable "alert_email" {
  description = "Email address that receives alarm notifications via SNS"
  type        = string
  # No default — Terraform will prompt for this on first apply.
  # You can also pass it via: terraform apply -var='alert_email=you@example.com'
}

variable "canary_interval_minutes" {
  description = "How often the canary runs, in minutes. 30 min ≈ $1.73/month."
  type        = number
  default     = 30
}

variable "status_page_domain" {
  description = "Custom domain for the public status page (e.g. status.markandrewmarquez.com)"
  type        = string
  default     = "status.markandrewmarquez.com"
}

# ──────────────────────────────────────────────────────────────
# Monitored endpoints
# ──────────────────────────────────────────────────────────────
# Each entry has:
#   name — unique identifier (used in CloudWatch step names, alarm names)
#   url  — the full URL to check
#   type — "website" (check for HTTP 200) or "api" (validate response body)
#
# The canary loops through this list every run. Each endpoint
# becomes its own executeStep(), which emits a per-step
# SuccessPercent metric in CloudWatch.
# ──────────────────────────────────────────────────────────────

variable "monitors" {
  description = "List of endpoints to monitor"
  type = list(object({
    name = string
    url  = string
    type = string # "website" or "api"
  }))

  default = [
    {
      name = "portfolio-site"
      url  = "https://markandrewmarquez.com"
      type = "website"
    },
    {
      name = "github-status"
      url  = "https://www.githubstatus.com/api/v2/status.json"
      type = "api"
    },
    {
      name = "ms-graph-api"
      url  = "https://graph.microsoft.com/v1.0/$metadata"
      type = "api"
    },
    {
      name = "azure-devops-status"
      url  = "https://status.dev.azure.com/_apis/status/health?api-version=7.1-preview.1"
      type = "api"
    },
    {
      name = "docker-hub"
      url  = "https://hub.docker.com/"
      type = "website"
    },
    {
      name = "ollama-registry"
      url  = "https://registry.ollama.ai/"
      type = "website"
    },
    {
      name = "m365-portal"
      url  = "https://www.office.com"
      type = "website"
    },
  ]
}
