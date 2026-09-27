# =============================================================================
# Ontology Builder — source/terraform/main.tf
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

    # -------------------------------------------------------------------------
    # CLOUD
    # -------------------------------------------------------------------------
    # The hyperscalers and the second tier. Between them these carry the bulk
    # of compute / network / storage / identity nomenclature that everything
    # else borrows from.
    # -------------------------------------------------------------------------

    alicloud = {
      source = "aliyun/alicloud"
    }

    aws = {
      source = "hashicorp/aws"
    }

    azuread = {
      source = "hashicorp/azuread"
    }

    azuredevops = {
      source = "microsoft/azuredevops"
    }

    azurerm = {
      source = "hashicorp/azurerm"
    }

    digitalocean = {
      source = "digitalocean/digitalocean"
    }

    google = {
      source = "hashicorp/google"
    }

    ibm = {
      source = "IBM-Cloud/ibm"
    }

    linode = {
      source = "linode/linode"
    }

    oci = {
      source = "oracle/oci"
    }

    # -------------------------------------------------------------------------
    # VIRTUALISATION / ON-PREM
    # -------------------------------------------------------------------------
    # Physical-adjacent. These are the closest a schema gets to describing
    # hosts, clusters, datastores and vSwitches as real objects rather than
    # cloud abstractions.
    # -------------------------------------------------------------------------

    libvirt = {
      source = "dmacvicar/libvirt" # community
    }

    nutanix = {
      source = "nutanix/nutanix"
    }

    openstack = {
      source = "terraform-provider-openstack/openstack"
    }

    proxmox = {
      source = "bpg/proxmox" # community; the actively maintained one
    }

    vsphere = {
      source = "vmware/vsphere" # moved from hashicorp/ to vmware/ namespace
    }

    # -------------------------------------------------------------------------
    # OBSERVABILITY / OPERATIONS
    # -------------------------------------------------------------------------
    # Monitors, dashboards, alert policies, on-call schedules, service
    # definitions. These providers encode how vendors *classify* services
    # and signals — useful APM nomenclature beyond the raw resource types.
    # -------------------------------------------------------------------------

    datadog = {
      source = "DataDog/datadog"
    }

    dynatrace = {
      source = "dynatrace-oss/dynatrace"
    }

    grafana = {
      source = "grafana/grafana"
    }

    newrelic = {
      source = "newrelic/newrelic"
    }

    pagerduty = {
      source = "PagerDuty/pagerduty"
    }

    splunk = {
      source = "splunk/splunk"
    }

    # -------------------------------------------------------------------------
    # IDENTITY / SECRETS / CERTIFICATES
    # -------------------------------------------------------------------------
    # Users, groups, apps, policies, roles, secret engines, certificate
    # authorities. Overlaps SCIM and entitlement models in later phases.
    # -------------------------------------------------------------------------

    acme = {
      source = "vancluever/acme" # community; Let's Encrypt and other ACME CAs
    }

    auth0 = {
      source = "auth0/auth0"
    }

    okta = {
      source = "okta/okta"
    }

    vault = {
      source = "hashicorp/vault"
    }

    venafi = {
      source = "Venafi/venafi"
    }

    # -------------------------------------------------------------------------
    # PLATFORM / CONTAINERS
    # -------------------------------------------------------------------------
    # Kubernetes carries the CNCF workload vocabulary (Deployment, StatefulSet,
    # Service, Ingress...). Helm and Docker fill in packaging and runtime.
    # -------------------------------------------------------------------------

    docker = {
      source = "kreuzwerker/docker" # community; the de-facto standard
    }

    helm = {
      source = "hashicorp/helm"
    }

    kubernetes = {
      source = "hashicorp/kubernetes"
    }

    # -------------------------------------------------------------------------
    # SOURCE CONTROL / CI
    # -------------------------------------------------------------------------
    # Repos, branches, protection rules, runners, pipelines, environments.
    # -------------------------------------------------------------------------

    github = {
      source = "integrations/github"
    }

    gitlab = {
      source = "gitlabhq/gitlab"
    }

    # -------------------------------------------------------------------------
    # NETWORKING / EDGE / SECURITY APPLIANCES
    # -------------------------------------------------------------------------
    # CDN, DNS, WAF, load balancers, firewalls, switches and routers. This is
    # where the physical-network nomenclature (VLAN, VRF, ACL, pool, VIP)
    # lives.
    # -------------------------------------------------------------------------

    aci = {
      source = "CiscoDevNet/aci"
    }

    akamai = {
      source = "akamai/akamai"
    }

    bigip = {
      source = "F5Networks/bigip"
    }

    cloudflare = {
      source = "cloudflare/cloudflare"
    }

    fastly = {
      source = "fastly/fastly"
    }

    iosxe = {
      source = "CiscoDevNet/iosxe"
    }

    nxos = {
      source = "CiscoDevNet/nxos"
    }

    panos = {
      source = "PaloAltoNetworks/panos"
    }

    # -------------------------------------------------------------------------
    # DATA / STORAGE / MESSAGING
    # -------------------------------------------------------------------------
    # Databases, warehouses, caches, streams. Schema-level objects: databases,
    # schemas, tables, roles, grants, topics, connectors.
    # -------------------------------------------------------------------------

    confluent = {
      source = "confluentinc/confluent"
    }

    databricks = {
      source = "databricks/databricks"
    }

    kafka = {
      source = "Mongey/kafka" # community
    }

    mongodbatlas = {
      source = "mongodb/mongodbatlas"
    }

    mysql = {
      source = "petoju/mysql" # community
    }

    postgresql = {
      source = "cyrilgdn/postgresql" # community
    }

    rediscloud = {
      source = "RedisLabs/rediscloud"
    }

    snowflake = {
      source = "snowflakedb/snowflake" # moved from Snowflake-Labs/ namespace
    }

    # -------------------------------------------------------------------------
    # DATA / ML PLATFORMS
    # -------------------------------------------------------------------------
    # Orchestration, transformation, experiment tracking.
    # -------------------------------------------------------------------------

    astro = {
      source = "astronomer/astro" # managed Airflow
    }

    dbtcloud = {
      source = "dbt-labs/dbtcloud"
    }

    wandb = {
      source = "wandb/wandb"
    }

    # -------------------------------------------------------------------------
    # ARTIFACTS
    # -------------------------------------------------------------------------
    # Repositories, permissions, replication, retention.
    # -------------------------------------------------------------------------

    artifactory = {
      source = "jfrog/artifactory"
    }

    # -------------------------------------------------------------------------
    # SAAS / COLLABORATION / COMMS
    # -------------------------------------------------------------------------
    # Channels, projects, issue types, workflows, phone numbers, messaging
    # services.
    # -------------------------------------------------------------------------

    slack = {
      source = "pablovarela/slack" # community
    }

    twilio = {
      source = "twilio/twilio"
    }

    # -------------------------------------------------------------------------
    # UNVERIFIED — do not enable until the source address is confirmed
    # -------------------------------------------------------------------------
    # Candidates whose registry address, namespace or maintenance status was
    # not confirmed at authoring time. Enable one at a time, run init, and
    # promote to the right category above on green. If no maintained provider
    # exists, the vocabulary comes from a non-Terraform source instead (see
    # CLAUDE.md, later phases).
    #
    #   circleci      — CI pipelines / contexts        (CircleCI-Public/circleci?)
    #   jenkins       — jobs / folders / credentials    (taiidani/jenkins, community)
    #   junos         — Juniper routers / switches      (jeremmfr/junos, community)
    #   sendgrid      — templates / API keys            (community only)
    #   stripe        — products / prices / webhooks    (community only)
    #   huggingface   — models / spaces / endpoints     (unclear if one exists)
    #   nexus         — Sonatype repositories           (community only)
    #   jira          — projects / issue types          (community only)
    #   confluence    — spaces / pages                  (community only)
    #   chef          — nodes / roles / environments    (no maintained provider)
    #   puppet        — classes / environments          (no maintained provider)
    # -------------------------------------------------------------------------

  }
}
