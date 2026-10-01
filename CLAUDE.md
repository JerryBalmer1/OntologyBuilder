# CLAUDE.md — Claude.Ontology (INTERIM, dev phase)

This file is deliberately temporary. It exists to speed up the current
build-out. Do not "improve" it, restructure it, or add sections. If you
think it is wrong, stop and say so.

## What this repo is

Harvests type systems from where they already exist — Terraform provider
schemas first — into a source registry, then renders the result as a graph.

Pipeline (each phase lands as its own file so failures are traceable):

    harvest -> docs -> flatten (types.json) -> links (links.json)
            -> classify (categories.json) -> graph (graph.json)
            -> render (HTML via PSGraphRender)

## Layout

    sources/terraform/
      main.tf                       input: providers to harvest (no credentials, no provider blocks)
      terraform.schema.build.ps1    the harvester. ALL phases live in this one script as functions.
      .terraform/                   terraform init output. Never read, never delete.
      .terraform.lock.hcl           schema cache key. Never edit.
      out/terraform/                harvest output. NEVER READ FILE CONTENTS. See "Reading output".
    src/modules/PSGraphRender/      vendored graph-to-HTML renderer (Public/, Private/, TemplateSets/, .psd1)
    ontology.build.ps1              Invoke-Build entry point. `Invoke-Build` alone must run the whole chain.
    Dockerfile, dockerignore        container packaging. Do not touch until told.
    _scratch/                       Jerry's sandbox. Do not touch.

## Files you may edit

    sources/terraform/terraform.schema.build.ps1
    ontology.build.ps1
    src/modules/PSGraphRender/**      (only when the task explicitly names it)
    tests/**                          (create this folder if a task asks for Pester tests)
    .gitignore                        (only when the task explicitly names it)

Everything else is read-only. If a task seems to require touching another
file, stop and say which file and why. Do not make the change.

## Never

- Never run `terraform init`, `terraform init -upgrade`, or delete `.terraform/`.
  Init is run once by Jerry outside the container. Providers are 4 GB.
- Never read file contents under `out/` or `.cache/`. Verify output using
  file size, line count, `Test-Path`, or a single-field pull with `jq`
  (e.g. `jq '.docTypeUnmatched' out/terraform/index.json`).
- Never write bash. PowerShell 7.4+ only, `#Requires -Version 7.4` at the top.
- Never create a module out of the harvester. It stays one script, functions inside.
- Never emit diffs, snippets, or "apply this change". Write the WHOLE file,
  same filename, so it overwrites in place.
- Never commit. Jerry commits. When you finish, list the files you changed.
- Never add credentials, `provider "x" {}` blocks, or version pins to `main.tf`.
- Never run the harvester with `-From harvest` or `-Clean` unless the task says so.
  Cached runs take seconds; a cold run takes minutes.

## Workflow (what "run it" means)

    Invoke-Build                     default task: TerraformScript -> ImportPSGraphRender -> RenderGraph
    Invoke-Build TerraformScript     harvest only (cached; only re-dumps when the lock hash changes)
    Invoke-Build RenderGraph         render out/terraform/graph.json through PSGraphRender

Every task in `ontology.build.ps1`:
- wraps `Push-Location`/`Pop-Location` in `try/finally`
- uses `exec { }` for external commands
- rethrows with `throw`, never `Write-Error $_` — a non-terminating error lets
  Invoke-Build report success on a failed run and swallows the script's diagnostics block

`ImportPSGraphRender` must `Import-Module ./src/modules/PSGraphRender/PSGraphRender.psd1 -Force`
so edits to the module are picked up on every run without a shell restart.

## Conventions

- Provider slug: drop `registry.terraform.io/`, replace `/` with `_`, lowercase.
  `hashicorp/aws` -> `hashicorp_aws`. Namespace stays on purpose.
- Type id: resources are bare (`aws_instance`); data sources are `data.aws_instance`;
  ephemeral are `ephemeral.x`. Matches Terraform HCL addressing. Nested blocks
  inherit via `/` (`data.azuredevops_project/filter`).
- Every JSON output is pretty-printed through `Write-JsonFile`. Hash the compact
  form before writing. Use `System.Text.Json`, never `ConvertTo-Json -Depth` (caps at 100;
  akamai nests 30 levels of `sub_groups`).
- Tiers: 1 executable schema, 2 vendor docs, 3 vendor taxonomy, 4 inferred (always flagged).
  Doc-example edges are tier 2. `*_id` name guesses are tier 4 with a score.
- Tests are Pester, fail-first. Commit trailer `who:` is Jerry's concern, not yours.
- StrictMode Latest is on. `$null` into a `[string]` param becomes `""` — normalise it.
  Do not name a variable `$matches`.

## Reading output (the only allowed ways)

    (Get-Item out/terraform/index.json).Length
    (Get-Content out/terraform/graph.json | Measure-Object -Line).Lines
    jq '.providers[] | {slug, docTypeUnmatched, docEdgeCount}' out/terraform/index.json
    jq '.nodes | length' out/terraform/graph.json

If a check needs more than one field, ask Jerry to look instead.

## Current tasks (in order; do the first, stop, report)

1. Delete stray root artifacts from a doc-fetch test run from the wrong directory:
   `guides/`, `overview/`, `docs.index.json`, `test.ps1`, root `.terraform.lock.hcl`, root `.terraform/`.
   Confirm each path before deleting. Do not touch `sources/terraform/` or `_scratch/`.
2. `ontology.build.ps1`: add `ImportPSGraphRender` and `RenderGraph` tasks; make `.`
   the chain above; fix `Pop-Location` into `finally` and `Write-Error` into `throw`
   in `TerraformInit` and `TerraformScript`.
3. Run `Invoke-Build`. Report `docTypeUnmatched` per provider (expect 0 for azuredevops),
   `docEdgeCount` vs `inferredEdgeCount`, and node/edge counts from `graph.json`.
   Report only the numbers.
4. If the renderer needs a shape `graph.json` does not provide, say what field is
   missing. Do not change either side until Jerry decides which one moves.

## When unsure

Stop. Say what you would do and which file it touches. Wait.
