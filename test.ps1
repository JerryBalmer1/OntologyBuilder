#Requires -Version 7.4
<#
.SYNOPSIS
    Fetch Terraform Registry provider documentation via the public v2 JSON API.

.DESCRIPTION
    Endpoint chain (all unauthenticated, all JSON:API shaped):

      1. https://registry.terraform.io/v2/providers/<namespace>/<name>?include=provider-versions
           -> .included[] where type == 'provider-versions'   (id, attributes.version)
      2. https://registry.terraform.io/v2/provider-versions/<versionId>?include=provider-docs
           -> .included[] where type == 'provider-docs'       (id, attributes.{slug,category,subcategory,title,path})
      3. https://registry.terraform.io/v2/provider-docs/<docId>
           -> .data.attributes.content                        (raw markdown)

    Get-TerraformProviderDoc   returns one doc's markdown.
    Save-TerraformProviderDocs pulls every doc for a provider version to disk,
    one markdown file per doc plus a docs.index.json manifest. This is the
    function that gets folded into terraform.schema.build.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RegistryBase = 'https://registry.terraform.io/v2'

function Invoke-RegistryApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $uri = "$script:RegistryBase/$Path"
    Write-Verbose "GET $uri"
    Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'User-Agent' = 'OntologyBuilder/0.1' }
}

function Get-IncludedOfType {
    # Null-safe filter over a JSON:API 'included' array.
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Type
    )
    if (-not ($Response.PSObject.Properties.Name -contains 'included')) { return @() }
    @($Response.included | Where-Object { $_.type -eq $Type })
}

function Resolve-ProviderVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ProviderName,
        [string]$Version = 'latest'
    )

    $response = Invoke-RegistryApi -Path "providers/$Namespace/$ProviderName`?include=provider-versions"
    $versions = Get-IncludedOfType -Response $response -Type 'provider-versions'
    if ($versions.Count -eq 0) {
        throw "No versions returned for $Namespace/$ProviderName."
    }

    if ($Version -eq 'latest') {
        # Prerelease strings break [version]; fall back to string sort for those.
        $target = $versions |
            Sort-Object -Descending {
                $v = $_.attributes.version
                try { [version]$v } catch { [version]'0.0.0' }
            }, { $_.attributes.version } |
            Select-Object -First 1
    }
    else {
        $target = $versions | Where-Object { $_.attributes.version -eq $Version } | Select-Object -First 1
    }

    if (-not $target) {
        throw "Version '$Version' not found for $Namespace/$ProviderName. Available: $($versions.attributes.version -join ', ')"
    }

    [pscustomobject]@{
        namespace = $Namespace
        name      = $ProviderName
        version   = $target.attributes.version
        versionId = $target.id
    }
}

function Get-ProviderDocList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionId)

    $response = Invoke-RegistryApi -Path "provider-versions/$VersionId`?include=provider-docs"
    $docs = Get-IncludedOfType -Response $response -Type 'provider-docs'

    foreach ($doc in $docs) {
        $a = $doc.attributes
        [pscustomobject]@{
            id          = $doc.id
            slug        = $a.slug
            category    = $a.category
            subcategory = if ($a.PSObject.Properties.Name -contains 'subcategory') { $a.subcategory } else { $null }
            title       = $a.title
            path        = if ($a.PSObject.Properties.Name -contains 'path') { $a.path } else { $null }
        }
    }
}

function Get-ProviderDocContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DocId)

    $response = Invoke-RegistryApi -Path "provider-docs/$DocId"
    $response.data.attributes.content
}

function Get-TerraformProviderDoc {
    <#
    .SYNOPSIS
        Return the markdown for one doc page. Slug 'index' is the provider overview.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ProviderName,
        [string]$Version = 'latest',
        [string]$Slug = 'index',
        [ValidateSet('overview', 'resources', 'data-sources', 'guides', 'functions', 'ephemeral-resources', 'any')]
        [string]$Category = 'any'
    )

    $resolved = Resolve-ProviderVersion -Namespace $Namespace -ProviderName $ProviderName -Version $Version
    Write-Host "Resolved $Namespace/$ProviderName -> $($resolved.version) (id $($resolved.versionId))"

    $docs = @(Get-ProviderDocList -VersionId $resolved.versionId)
    $match = $docs | Where-Object {
        $_.slug -eq $Slug -and ($Category -eq 'any' -or $_.category -eq $Category)
    } | Select-Object -First 1

    if (-not $match) {
        $available = ($docs | ForEach-Object { "$($_.category)/$($_.slug)" } | Sort-Object) -join "`n  "
        throw "No doc with slug '$Slug' (category '$Category'). Available:`n  $available"
    }

    Get-ProviderDocContent -DocId $match.id
}

function Save-TerraformProviderDocs {
    <#
    .SYNOPSIS
        Pull every doc for a provider version to disk.

        <OutputRoot>/
          docs.index.json                       manifest: version, versionId, one entry per doc
          <category>/<slug>.md                  raw markdown, untouched
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$OutputRoot,
        [string]$Version = 'latest',
        [int]$ThrottleMs = 100
    )

    $resolved = Resolve-ProviderVersion -Namespace $Namespace -ProviderName $ProviderName -Version $Version
    $docs = @(Get-ProviderDocList -VersionId $resolved.versionId)
    Write-Host "Saving $($docs.Count) docs for $Namespace/$ProviderName $($resolved.version) -> $OutputRoot"

    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

    $entries = foreach ($doc in $docs) {
        $categoryDir = Join-Path $OutputRoot $doc.category
        New-Item -ItemType Directory -Path $categoryDir -Force | Out-Null

        $safeSlug = $doc.slug -replace '[^A-Za-z0-9_.-]', '_'
        $file = Join-Path $categoryDir "$safeSlug.md"
        $content = Get-ProviderDocContent -DocId $doc.id
        Set-Content -Path $file -Value $content -Encoding utf8 -NoNewline

        [pscustomobject]@{
            id          = $doc.id
            slug        = $doc.slug
            category    = $doc.category
            subcategory = $doc.subcategory
            title       = $doc.title
            file        = [System.IO.Path]::GetRelativePath($OutputRoot, $file) -replace '\\', '/'
            bytes       = (Get-Item $file).Length
        }

        if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
    }

    $manifest = [pscustomobject]@{
        namespace   = $resolved.namespace
        name        = $resolved.name
        version     = $resolved.version
        versionId   = $resolved.versionId
        fetchedUtc  = [DateTime]::UtcNow.ToString('o')
        docCount    = $docs.Count
        docs        = @($entries | Sort-Object category, slug)
    }
    $manifestPath = Join-Path $OutputRoot 'docs.index.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8

    $manifest
}

# ==========================================
# Smoke test — Azure DevOps
# ==========================================
if ($MyInvocation.InvocationName -ne '.') {
    $md = Get-TerraformProviderDoc -Namespace microsoft -ProviderName azuredevops -Slug index
    Write-Host "`n--- first 25 lines of overview ---"
    ($md -split "`n") | Select-Object -First 25

    Write-Host "`n--- full pull ---"
    $m = Save-TerraformProviderDocs -Namespace microsoft -ProviderName azuredevops -OutputRoot (Join-Path $PSScriptRoot 'out/terraform/providers/microsoft_azuredevops/docs')
    $m.docs | Group-Object category | Select-Object Name, Count
}


Save-TerraformProviderDocs -Namespace microsoft -ProviderName azuredevops -Version 1.16.0 -OutputRoot .\sources\terraform\out\terraform\providers\microsoft_azuredevops\docs






