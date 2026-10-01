# =============================================================================
# Claude.Ontology — source/terraform/main.tf
# =============================================================================
#
# PURPOSE
#   This file exists for exactly one reason: to make `terraform init` download
#   a broad set of providers so that
#
#       terraform providers schema -json
#
#   hands us every resource type, data source, attribute and block those
#   providers know about. That output is the Tier 1 ontology source.
#
# WHAT IS DELIBERATELY NOT HERE
#   - No `provider "x" {}` configuration blocks. Schema extraction only needs
#     the plugin binaries, not credentials or endpoints. Do not add them.
#   - No resources, data sources, modules or backends. This is never applied.
#
# VERSIONS
#   Constraints are intentionally omitted on the first pass. Run
#   `terraform init` once, let the resolver pick the latest of everything,
#   then pin from the resulting .terraform.lock.hcl using `~> MAJOR.0`.
#   Record the resolved source address and version in config/sources.json.
#
# ADDING A PROVIDER
#   1. Put it under the right category heading below, alphabetical within it.
#   2. Use the exact registry address (namespace/name). `hashicorp/` and
#      partner-tier namespaces are preferred; community ones are marked.
#   3. Add a matching entry to config/sources.json before harvesting.
#   4. If init fails on it, move it to the UNVERIFIED block at the bottom and
#      note it in out/harvest.jsonl — the build stays green, the gap stays
#      visible.
#
# WHY SO MANY
#   Each provider is a vocabulary. AWS alone is ~1,400 resource types. The
#   point is coverage, not a working deployment. Plugin downloads are large,
#   so run this inside the harvest container or with TF_PLUGIN_CACHE_DIR set
#   to a path outside the repo.
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {

    azuredevops = {
      source = "microsoft/azuredevops"
    }

    vsphere = {
      source = "vmware/vsphere" # moved from hashicorp/ to vmware/ namespace
    }

  }
}
