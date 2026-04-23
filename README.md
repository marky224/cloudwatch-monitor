# CloudWatch Infrastructure Monitor

A lightweight infrastructure monitoring system built on AWS CloudWatch Synthetics and managed with Terraform. A single canary checks 7 endpoints every 30 minutes, CloudWatch Alarms trigger email alerts on failures, and a public status page displays uptime history.

**Status page:** [status.markandrewmarquez.com](https://status.markandrewmarquez.com)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  CloudWatch Synthetics Canary (runs every 30 min)           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ executeHttpStep() × 7 endpoints                      │   │
│  │  → portfolio-site       (website)                    │   │
│  │  → github-status        (api)                        │   │
│  │  → ms-graph-api         (api)                        │   │
│  │  → azure-devops-status  (api)                        │   │
│  │  → docker-hub           (website)                    │   │
│  │  → ollama-registry      (website)                    │   │
│  │  → m365-portal          (website)                    │   │
│  └──────────┬───────────────────────────────────────────┘   │
│             │ SuccessPercent metrics per step                │
│             ▼                                               │
│  ┌──────────────────┐    ┌──────────────────┐               │
│  │ CloudWatch Alarms │───▶│   SNS → Email    │               │
│  │ (1 per endpoint)  │    │  (failure/recovery)│              │
│  └──────────────────┘    └──────────────────┘               │
│             │                                               │
│             ▼                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Lambda (every 5 min) → status.json → S3 → CloudFront │   │
│  │                         ▼                             │   │
│  │              status.markandrewmarquez.com              │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Cost

~$1.73/month — one canary at 30-minute intervals. Lambda, S3, CloudFront, and CloudWatch are well within free tier for this usage level.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) with credentials configured
- An AWS account with permissions for S3, IAM, Lambda, CloudWatch, CloudFront, ACM, and Synthetics

```powershell
# Install (Windows)
winget install Hashicorp.Terraform
winget install Amazon.AWSCLI

# Verify
terraform -version
aws --version
aws sts get-caller-identity
```

## Deployment

### 1. Configure variables

```powershell
copy terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set your email address
```

### 2. Initialize and deploy

```powershell
terraform init
terraform plan
terraform apply
```

### 3. During apply — add the ACM DNS record

`terraform apply` will **pause** while waiting for the ACM certificate to be validated. While it's waiting:

1. Look at the terminal output for `dns_1_acm_validation_record` — it shows the CNAME name and value
2. Go to [GoDaddy DNS Management](https://dcc.godaddy.com/manage-dns)
3. Add a **CNAME** record with the name and value from the output
4. Wait 1–5 minutes for DNS propagation
5. Terraform will detect the validation and continue

### 4. After apply — add the status page CNAME

1. Look at the `dns_2_status_page_cname` output — it shows the CloudFront domain
2. In GoDaddy, add another **CNAME** record:
   - **Name:** `status`
   - **Value:** the CloudFront domain (e.g., `d1234abcd.cloudfront.net`)

### 5. Confirm the SNS email subscription

AWS sends a confirmation email after the first apply. **Click the confirmation link** or alarm notifications won't be delivered.

### 6. Verify

- Check the canary: [CloudWatch Synthetics console](https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#synthetics:canary/list)
- Check the dashboard: link in `terraform output dashboard_url`
- Check the status page: [status.markandrewmarquez.com](https://status.markandrewmarquez.com)

## Adding or Removing Endpoints

Edit the `monitors` list in `variables.tf`:

```hcl
variable "monitors" {
  default = [
    {
      name = "my-new-service"
      url  = "https://example.com/health"
      type = "api"      # "website" or "api"
    },
    # ... existing endpoints ...
  ]
}
```

Then run:

```powershell
terraform plan    # Review changes
terraform apply   # Deploy
```

Terraform will automatically update the canary script, create/remove CloudWatch Alarms, and update the dashboard.

## Project Structure

```
cloudwatch-monitor/
├── main.tf                  # Terraform + AWS provider config
├── variables.tf             # Endpoints, interval, email, domain
├── canary.tf                # S3 artifacts, IAM role, Synthetics canary
├── alarms.tf                # SNS topic + per-endpoint CloudWatch Alarms
├── status-page.tf           # S3, CloudFront, ACM, Lambda, EventBridge
├── dashboard.tf             # CloudWatch dashboard
├── outputs.tf               # Console URLs, DNS instructions
├── terraform.tfvars.example # Template for sensitive vars (safe to commit)
├── .gitignore               # Excludes state, secrets, build artifacts
├── canary-script/
│   └── index.js.tftpl       # Canary script template (rendered by Terraform)
└── status-page/
    ├── index.html            # Public status page (static HTML/CSS/JS)
    └── generate-status.py    # Lambda: CloudWatch metrics → status.json
```

## License

MIT
