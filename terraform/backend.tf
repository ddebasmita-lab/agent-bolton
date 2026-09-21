# Terraform state.
#
# State lives in a GCS bucket in your own project, created by deploy.sh before
# the first apply. The bucket and prefix are passed by deploy.sh at init time:
#
#   terraform init \
#     -backend-config="bucket=<project>-tfstate" \
#     -backend-config="prefix=dc-agent/<instance>"
#
# Keep versioning on for that bucket. Terraform state is the only record of
# what this deployment owns.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
