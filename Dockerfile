# =============================================================================
# Ontology Builder — Dockerfile
# =============================================================================
#
# Throwaway harvest image. Runs `terraform init` + `terraform providers schema
# -json` against main.tf and splits the result into one pretty-printed JSON
# file per provider on a host-mounted output directory.
#
# BUILD (from repo root):
#   docker build -t ontology-builder/terraform-schema:local .
#
# RUN (from repo root, PowerShell):
#   docker run --rm `
#     -v "${PWD}/out/terraform:/out" `
#     -v "${PWD}/.cache/terraform-plugins:/cache/terraform-plugins" `
#     ontology-builder/terraform-schema:local
#
# Output lands in out/terraform/ on the host:
#   raw/providers-schema.json   compact, untouched — the measurement artifact
#   schema/<slug>.json          one per provider, pretty-printed, with header
#   schema/index.json           every provider: source, version, sha256, counts
#
# FILE-NAMING RULE (slug)
#   Take the provider's full source address. Drop the "registry.terraform.io/"
#   prefix. Replace every remaining "/" with "_". Lowercase. Append ".json".
#     registry.terraform.io/hashicorp/aws   -> hashicorp_aws.json
#     registry.terraform.io/vmware/vsphere  -> vmware_vsphere.json
#     registry.terraform.io/DataDog/datadog -> datadog_datadog.json
#   The namespace stays in the name on purpose: bare names collide (two
#   Snowflake providers, two Docker providers). A non-default registry keeps
#   its host as the first segment with "." replaced by "-".
#
# LAYER ORDER
#   Terraform install is the expensive layer and sits first. main.tf and the
#   export script are the last two COPY lines, so editing either rebuilds only
#   that layer. Do not move ARG TERRAFORM_VERSION below the RUN line.
#
# NOTHING OF VALUE LIVES IN THE IMAGE
#   - init runs at container start, not at build, so the plugin cache mount is
#     used and the image stays small
#   - no credentials, no provider {} blocks, no cloud env vars
#   - output and plugin cache are volume mounts; the container is --rm
# =============================================================================

ARG PWSH_TAG=7.4-ubuntu-22.04
FROM mcr.microsoft.com/powershell:${PWSH_TAG}

ARG TERRAFORM_VERSION=1.9.8

# Terraform from the official release zip. Arch is detected so the same file
# builds on amd64 and arm64 hosts.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && ARCH="$(dpkg --print-architecture)" \
 && curl -fsSL -o /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
 && unzip -q /tmp/terraform.zip -d /usr/local/bin \
 && rm -f /tmp/terraform.zip \
 && chmod 0755 /usr/local/bin/terraform \
 && terraform version \
 && apt-get purge -y unzip \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE: since Terraform 1.4 the
# plugin cache is only consulted for providers already recorded in
# .terraform.lock.hcl. This container starts with no lock file every run, so
# without this flag every provider is re-downloaded regardless of the cache.
ENV TF_IN_AUTOMATION=1 \
    TF_INPUT=0 \
    TF_PLUGIN_CACHE_DIR=/cache/terraform-plugins \
    TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1 \
    CHECKPOINT_DISABLE=1

WORKDIR /work/terraform

# Only what the harvest needs. .dockerignore keeps .terraform/ (gigabytes)
# and lock/state files out of the build context.
COPY main.tf                   /work/terraform/main.tf
COPY Export-ProviderSchema.ps1 /work/Export-ProviderSchema.ps1

VOLUME ["/out", "/cache/terraform-plugins"]

ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/work/Export-ProviderSchema.ps1"]