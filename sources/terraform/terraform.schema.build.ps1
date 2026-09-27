#Requires -Version 7.4

<#
.SYNOPSIS
    Harvests Terraform provider schemas into a structured ontology source tree.

.DESCRIPTION
    Runs `terraform providers schema -json` against the working directory,
    pretty-prints the raw dump, splits it into one directory per provider,
    and writes an index describing the harvest.

    Output layout (rooted at -OutputRoot, default ./out/terraform):

        index.json
        graph.json                      (cross-provider Cytoscape elements)
        raw/providers-schema.json       (cached: reused unless the lock file changed)
        raw/providers-schema.meta.json  (sha256 of the compact dump + lock file hash)
        providers/<slug>/schema.json
        providers/<slug>/types.json                     phase: flatten   (Tier 1)
        providers/<slug>/docs/docs.index.json           phase: docs      (cached by provider version)
        providers/<slug>/docs/<category>/<slug>.md      raw registry markdown, untouched
        providers/<slug>/docs.json                      phase: docs      (Tier 2, extracted from markdown)
        providers/<slug>/links.json                     phase: links     (Tier 1 identities, Tier 2 doc edges, Tier 4 inferred edges)
        providers/<slug>/categories.json                phase: classify  (Tier 4)
        providers/<slug>/categories.unclassified.json   (only when non-empty)

    Phases, in order: harvest -> docs -> flatten -> links -> classify -> graph.
    Everything after `docs` is cheap (seconds) and always re-runs. The two
    expensive steps are cached:

        harvest  re-runs `terraform providers schema -json` only when
                 raw/providers-schema.json is missing or .terraform.lock.hcl
                 has changed since it was written. -From harvest forces it.
        docs     fetches from the public registry API only when
                 docs/docs.index.json is missing or records a different
                 provider version than the lock file. -ForceDocs forces it,
                 -SkipDocs never touches the network.

    Type id rule (unique across resources and data sources):
        resource    aws_instance -> aws_instance
        data_source aws_instance -> data.aws_instance
        ephemeral   x            -> ephemeral.x
        nested      -> <owner id>/<block name>/...
    Every type record carries `name` = the bare Terraform type name.

    Provider slug rule:
        Full provider source address
          -> drop the "registry.terraform.io/" prefix
          -> replace remaining "/" with "_"
          -> lowercase
        e.g. registry.terraform.io/hashicorp/aws -> hashicorp_aws
             registry.terraform.io/vmware/vsphere -> vmware_vsphere
             registry.terraform.io/DataDog/datadog -> datadog_datadog
        A non-default registry host becomes the first segment with "." -> "-".

    Derived files are overwritten in place on every run. Nothing is deleted
    unless -Clean is passed, which removes the whole output root first.

.NOTES
    Runs locally for now. Terraform init is expected to have already been run
    in the working directory. Moves into the container once the shape settles.
#>

[CmdletBinding()]
param(
    # Directory containing main.tf and an initialised .terraform directory.
    [Parameter()]
    [string] $WorkingDirectory = $PSScriptRoot,

    # Root of the harvest output tree.
    [Parameter()]
    [string] $OutputRoot = (Join-Path $PSScriptRoot 'out' 'terraform'),

    # Earliest phase to force. 'auto' uses caches where they are valid.
    #   harvest - re-run terraform and refetch docs whose version changed
    #   docs    - use cached schema, refetch all docs
    #   flatten - use cached schema and cached docs; only rebuild derived files
    [Parameter()]
    [ValidateSet('auto', 'harvest', 'docs', 'flatten')]
    [string] $From = 'auto',

    # Refetch docs even when the cached version matches.
    [Parameter()]
    [switch] $ForceDocs,

    # Never call the registry. Extraction still runs over whatever docs are cached.
    [Parameter()]
    [switch] $SkipDocs,

    # Delete the whole output root before starting.
    [Parameter()]
    [switch] $Clean,

    # Pause between registry calls. Be polite; the API is unauthenticated.
    [Parameter()]
    [int] $DocThrottleMs = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


#region helpers

function Format-JsonText {
    <#
    .SYNOPSIS
        Re-indents a JSON string without building a PowerShell object graph.

    .DESCRIPTION
        Text in, text out. Never materialises objects, so it is immune to the
        ConvertFrom-Json / ConvertTo-Json depth ceiling of 100 that the deeply
        recursive provider schemas blow straight through.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $Json
    )

    process {
        $readerOptions = [System.Text.Json.JsonDocumentOptions]::new()
        $readerOptions.MaxDepth            = 4096
        $readerOptions.CommentHandling     = [System.Text.Json.JsonCommentHandling]::Skip
        $readerOptions.AllowTrailingCommas = $true

        $doc = [System.Text.Json.JsonDocument]::Parse($Json, $readerOptions)
        try {
            Write-JsonElement -Element $doc.RootElement
        }
        finally {
            $doc.Dispose()
        }
    }
}


function Write-JsonElement {
    <#
    .SYNOPSIS
        Serialises a JsonElement to an indented string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Element
    )

    $writerOptions = [System.Text.Json.JsonWriterOptions]::new()
    $writerOptions.Indented       = $true
    $writerOptions.SkipValidation = $true

    $stream = [System.IO.MemoryStream]::new()
    try {
        $writer = [System.Text.Json.Utf8JsonWriter]::new($stream, $writerOptions)
        try {
            $Element.WriteTo($writer)
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }

        [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}


function Get-Sha256Hex {
    <#
    .SYNOPSIS
        SHA-256 of a UTF-8 string, lowercase hex.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    try {
        [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}


function Get-ProviderSlug {
    <#
    .SYNOPSIS
        Converts a provider source address into a filesystem-safe slug.

    .EXAMPLE
        Get-ProviderSlug -Address 'registry.terraform.io/hashicorp/aws'
        hashicorp_aws
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    $work = $Address

    if ($work.StartsWith('registry.terraform.io/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $work = $work.Substring('registry.terraform.io/'.Length)
    }
    else {
        # Non-default host: keep it as the first segment, dots become dashes.
        $segments = $work.Split('/')
        if ($segments.Count -gt 2) {
            $segments[0] = $segments[0].Replace('.', '-')
            $work = $segments -join '/'
        }
    }

    $work.Replace('/', '_').ToLowerInvariant()
}


function Get-ElementPropertyCount {
    <#
    .SYNOPSIS
        Counts the properties of an optional object-valued key.

    .DESCRIPTION
        Providers and Terraform versions vary in which keys they emit. A
        missing key is zero, not an error.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Parent,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $child = [System.Text.Json.JsonElement]::new()
    if (-not $Parent.TryGetProperty($Name, [ref] $child)) { return 0 }
    if ($child.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return 0 }

    $count = 0
    foreach ($property in $child.EnumerateObject()) { $count++ }
    $count
}


function Get-LockedVersion {
    <#
    .SYNOPSIS
        Reads the resolved version for a provider address out of
        .terraform.lock.hcl. Returns $null when the lock file or the entry
        is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $LockFilePath,

        [Parameter(Mandatory)]
        [string] $Address
    )

    if (-not (Test-Path -LiteralPath $LockFilePath)) { return $null }

    $lockText = Get-Content -LiteralPath $LockFilePath -Raw
    $escaped  = [regex]::Escape($Address)
    $pattern  = 'provider\s+"' + $escaped + '"\s*\{[^}]*?version\s*=\s*"([^"]+)"'

    $match = [regex]::Match($lockText, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) { return $match.Groups[1].Value }

    $null
}


function Get-FileSha256 {
    <#
    .SYNOPSIS
        SHA-256 of a file's bytes, lowercase hex. Returns $null when the file
        is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}


function Get-ObjectProperty {
    <#
    .SYNOPSIS
        Strict-mode-safe property read on a pscustomobject. Missing -> default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Object,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [AllowNull()]
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $property.Value
}


function Read-JsonFile {
    <#
    .SYNOPSIS
        Reads a JSON file into pscustomobjects, or $null when absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}


function Write-JsonFile {
    <#
    .SYNOPSIS
        Pretty-prints an object graph to disk. Single choke point so every
        output file is formatted the same way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [int] $Depth = 8
    )

    $Object |
        ConvertTo-Json -Depth $Depth |
        Format-JsonText |
        Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

#endregion helpers


#region harvest

function Get-TerraformSchemaJson {
    <#
    .SYNOPSIS
        Runs the Terraform schema dump and returns the raw compact JSON text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Write-Verbose "[ $($MyInvocation.InvocationName) ] BEGIN"

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = & terraform providers schema -json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "terraform providers schema -json failed with exit code $LASTEXITCODE`n$($output -join [System.Environment]::NewLine)"
        }

        ($output | Where-Object { $_ -is [string] }) -join ''
    }
    finally {
        Pop-Location
        Write-Verbose "[ $($MyInvocation.InvocationName) ] END"
    }
}


function Get-TerraformVersion {
    <#
    .SYNOPSIS
        Returns the terraform_version string, or 'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $raw = (& terraform version -json) -join ''
        if ($LASTEXITCODE -ne 0) { return 'unknown' }

        $doc = [System.Text.Json.JsonDocument]::Parse($raw)
        try {
            $value = [System.Text.Json.JsonElement]::new()
            if ($doc.RootElement.TryGetProperty('terraform_version', [ref] $value)) {
                return $value.GetString()
            }
            'unknown'
        }
        finally {
            $doc.Dispose()
        }
    }
    finally {
        Pop-Location
    }
}


function Initialize-OutputTree {
    <#
    .SYNOPSIS
        Ensures the output root exists. Only destructive when -Clean is set.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $OutputRoot,

        [Parameter()]
        [switch] $Clean
    )

    if ($Clean -and (Test-Path -LiteralPath $OutputRoot)) {
        if ($PSCmdlet.ShouldProcess($OutputRoot, 'Remove existing output tree')) {
            Write-Verbose "Removing existing output tree at $OutputRoot"
            Remove-Item -LiteralPath $OutputRoot -Recurse -Force
        }
    }

    $paths = @{
        Root      = $OutputRoot
        Raw       = Join-Path $OutputRoot 'raw'
        RawFile   = Join-Path $OutputRoot 'raw' 'providers-schema.json'
        RawMeta   = Join-Path $OutputRoot 'raw' 'providers-schema.meta.json'
        Providers = Join-Path $OutputRoot 'providers'
        Index     = Join-Path $OutputRoot 'index.json'
        Graph     = Join-Path $OutputRoot 'graph.json'
    }

    foreach ($key in 'Root', 'Raw', 'Providers') {
        $null = New-Item -Path $paths[$key] -ItemType Directory -Force
    }

    $paths
}


function Get-SchemaDump {
    <#
    .SYNOPSIS
        Returns the compact schema JSON, from cache when the lock file has
        not changed since the cache was written, otherwise from terraform.

    .DESCRIPTION
        The cache key is the SHA-256 of .terraform.lock.hcl: editing main.tf
        and re-running init changes the lock, which invalidates the cache.
        The pretty-printed raw file is re-compacted on read so the sha256
        stays comparable with a fresh dump.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [hashtable] $Paths,

        [Parameter(Mandatory)]
        [string] $LockFilePath,

        [Parameter()]
        [switch] $Force
    )

    $lockSha = Get-FileSha256 -Path $LockFilePath
    $meta    = Read-JsonFile -Path $Paths.RawMeta

    $cacheValid = (-not $Force) -and
                  (Test-Path -LiteralPath $Paths.RawFile) -and
                  ($null -ne $meta) -and
                  ((Get-ObjectProperty -Object $meta -Name 'lockSha256') -eq $lockSha)

    if ($cacheValid) {
        Write-Host ('Schema cache hit (lock {0}); skipping terraform' -f ($lockSha ?? 'none').Substring(0, 12))

        # Re-compact so the hash matches what terraform would have produced.
        $pretty  = Get-Content -LiteralPath $Paths.RawFile -Raw
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 4096
        $doc     = [System.Text.Json.JsonDocument]::Parse($pretty, $options)
        try   { $compact = $doc.RootElement.GetRawText() }
        finally { $doc.Dispose() }

        return [pscustomobject] @{
            compact          = $compact
            sha256           = $meta.sha256
            terraformVersion = $meta.terraformVersion
            fromCache        = $true
        }
    }

    Write-Host 'Running terraform providers schema -json ...'
    $compact = Get-TerraformSchemaJson -WorkingDirectory $WorkingDirectory
    $sha     = Get-Sha256Hex -Text $compact
    $tfVer   = Get-TerraformVersion -WorkingDirectory $WorkingDirectory

    Write-Host ('Raw dump: {0:N1} MB, sha256 {1}' -f ($compact.Length / 1MB), $sha.Substring(0, 16))

    $compact | Format-JsonText | Set-Content -LiteralPath $Paths.RawFile -Encoding utf8NoBOM

    Write-JsonFile -Path $Paths.RawMeta -Object ([pscustomobject] @{
        harvestedAt      = [System.DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        terraformVersion = $tfVer
        sha256           = $sha
        lockSha256       = $lockSha
        bytes            = $compact.Length
    })

    [pscustomobject] @{
        compact          = $compact
        sha256           = $sha
        terraformVersion = $tfVer
        fromCache        = $false
    }
}


function Write-ProviderRecord {
    <#
    .SYNOPSIS
        Runs every per-provider phase and returns the index entry plus the
        in-memory bundle the graph phase consumes.

    .DESCRIPTION
        Order matters:
          1. schema.json  (raw, Tier 1)
          2. types.json   (flatten)
          3. docs/        (fetch, cached by version)   -- optional
          4. docs.json    (extract from markdown)      -- needs types for slug -> type mapping
          5. links.json   (identities + doc edges + inferred edges)
          6. categories.json (noun rules, description fallback)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Schema,

        [Parameter(Mandatory)]
        [string] $ProvidersRoot,

        [Parameter()]
        [AllowNull()]
        [string] $Version,

        [Parameter()]
        [ValidateSet('auto', 'force', 'skip')]
        [string] $DocsMode = 'auto',

        [Parameter()]
        [int] $DocThrottleMs = 75
    )

    $slug          = Get-ProviderSlug -Address $Address
    $providerDir   = Join-Path $ProvidersRoot $slug
    $schemaPath    = Join-Path $providerDir 'schema.json'

    $null = New-Item -Path $providerDir -ItemType Directory -Force

    $compact = $Schema.GetRawText()
    $pretty  = Write-JsonElement -Element $Schema

    # Hash the compact form so the value stays comparable across formatters.
    $hash = Get-Sha256Hex -Text $compact

    Set-Content -LiteralPath $schemaPath -Value $pretty -Encoding utf8NoBOM

    $types  = Write-ProviderTypes -Address $Address -Slug $slug -Schema $Schema -ProvidersRoot $ProvidersRoot
    $prefix = Get-ProviderPrefix -Types $types

    # --- docs: fetch (cached) then extract -------------------------------
    $docsFetch = [pscustomobject] @{ fetched = $false; skipped = $true; reason = 'skip'; docCount = 0; version = $null }
    if ($DocsMode -ne 'skip') {
        $docsFetch = Save-ProviderDocs -Address $Address -Version $Version -ProviderDir $providerDir -Force:($DocsMode -eq 'force') -ThrottleMs $DocThrottleMs
    }

    $docs = Write-ProviderDocs -Address $Address -Slug $slug -Types $types -Prefix $prefix -ProviderDir $providerDir

    # --- links and categories --------------------------------------------
    $links = Write-ProviderLinks -Address $Address -Slug $slug -Schema $Schema -Types $types -Prefix $prefix -DocEdges $docs.edges -ProvidersRoot $ProvidersRoot
    $cats  = Write-ProviderCategories -Address $Address -Slug $slug -Types $types -Prefix $prefix -Descriptions $docs.descriptions -ProvidersRoot $ProvidersRoot

    $entry = [pscustomobject] @{
        address            = $Address
        slug               = $slug
        version            = $Version
        file               = "providers/$slug/schema.json"
        typesFile          = "providers/$slug/types.json"
        typeCount          = $types.Count
        docsFile           = if ($docs.docCount -gt 0) { "providers/$slug/docs.json" } else { $null }
        docCount           = $docs.docCount
        docsVersion        = $docsFetch.version
        docsFetchedThisRun = $docsFetch.fetched
        docsSkipReason     = if ($docsFetch.fetched) { $null } else { $docsFetch.reason }
        docTypeMatched     = $docs.matchedCount
        docTypeUnmatched   = $docs.unmatchedCount
        docEdgeCount       = $docs.edges.Count
        linksFile          = "providers/$slug/links.json"
        identityCount      = $links.identityCount
        edgeCount          = $links.edgeCount
        prefix             = $prefix
        categoriesFile     = "providers/$slug/categories.json"
        classifiedCount    = $cats.classifiedCount
        classifiedByDescription = $cats.byDescriptionCount
        unclassifiedCount  = $cats.unclassifiedCount
        needsClassification = ($cats.unclassifiedCount -gt 0)
        sha256             = $hash
        resourceCount      = Get-ElementPropertyCount -Parent $Schema -Name 'resource_schemas'
        dataSourceCount    = Get-ElementPropertyCount -Parent $Schema -Name 'data_source_schemas'
        functionCount      = Get-ElementPropertyCount -Parent $Schema -Name 'functions'
        ephemeralCount     = Get-ElementPropertyCount -Parent $Schema -Name 'ephemeral_resource_schemas'
        identitySchemaCount = Get-ElementPropertyCount -Parent $Schema -Name 'resource_identity_schemas'
    }

    [pscustomobject] @{
        entry  = $entry
        bundle = [pscustomobject] @{
            slug       = $slug
            address    = $Address
            version    = $Version
            types      = $types
            edges      = $links.edges
            identities = $links.identities
            categories = $cats.records
            docs       = $docs.records
        }
    }
}


#region flatten

function Get-OptionalProperty {
    <#
    .SYNOPSIS
        Returns a JsonElement property or $null when absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Parent,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $child = [System.Text.Json.JsonElement]::new()
    if ($Parent.TryGetProperty($Name, [ref] $child)) { return $child }
    $null
}


function Get-OptionalBool {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Parent,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $child = Get-OptionalProperty -Parent $Parent -Name $Name
    if ($null -eq $child) { return $false }
    if ($child.ValueKind -eq [System.Text.Json.JsonValueKind]::True) { return $true }
    $false
}


function Get-OptionalString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Parent,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $child = Get-OptionalProperty -Parent $Parent -Name $Name
    if ($null -eq $child) { return $null }
    if ($child.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { return $null }
    $child.GetString()
}


function Get-TypeSignature {
    <#
    .SYNOPSIS
        Renders a Terraform type expression as a compact string.

    .DESCRIPTION
        Terraform emits primitive types as strings ("string") and collection
        types as arrays (["list", "string"], ["map", ["object", {...}]]).
        Objects are rendered as object({...}) with their keys so the
        signature stays readable without exploding into a tree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Type
    )

    switch ($Type.ValueKind) {
        ([System.Text.Json.JsonValueKind]::String) {
            return $Type.GetString()
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $parts = @($Type.EnumerateArray())
            if ($parts.Count -eq 0) { return 'unknown' }

            $kind = $parts[0].GetString()
            if ($parts.Count -eq 1) { return $kind }

            if ($kind -eq 'object') {
                $keys = @($parts[1].EnumerateObject() | ForEach-Object { $_.Name })
                return 'object({' + ($keys -join ',') + '})'
            }

            return $kind + '(' + (Get-TypeSignature -Type $parts[1]) + ')'
        }
        default {
            return 'unknown'
        }
    }
}


function ConvertTo-FlatAttribute {
    <#
    .SYNOPSIS
        Converts one attribute schema into a flat record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Attribute,

        # Set when the attribute carries a nested_type that was emitted as
        # its own type record.
        [Parameter()]
        [AllowNull()]
        [string] $NestedTypeId
    )

    $typeElement = Get-OptionalProperty -Parent $Attribute -Name 'type'
    $signature   = if ($null -ne $typeElement) { Get-TypeSignature -Type $typeElement } else { $null }

    [pscustomobject] @{
        name        = $Name
        type        = $signature
        nestedType  = if ([string]::IsNullOrEmpty($NestedTypeId)) { $null } else { $NestedTypeId }
        required    = Get-OptionalBool -Parent $Attribute -Name 'required'
        optional    = Get-OptionalBool -Parent $Attribute -Name 'optional'
        computed    = Get-OptionalBool -Parent $Attribute -Name 'computed'
        sensitive   = Get-OptionalBool -Parent $Attribute -Name 'sensitive'
        deprecated  = Get-OptionalBool -Parent $Attribute -Name 'deprecated'
        description = Get-OptionalString -Parent $Attribute -Name 'description'
    }
}


function Get-TypeId {
    <#
    .SYNOPSIS
        Namespaces a Terraform type name by kind so resources and data
        sources with the same name get distinct ids everywhere.

        resource    aws_instance            -> aws_instance
        data_source aws_instance            -> data.aws_instance
        ephemeral   aws_secretsmanager_secret -> ephemeral.aws_secretsmanager_secret

        Mirrors how Terraform addresses them in configuration, so a doc
        example reference (data.aws_instance.x.id) maps onto an id by
        string concatenation alone.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Name
    )

    switch ($Kind) {
        'data_source' { "data.$Name" }
        'ephemeral'   { "ephemeral.$Name" }
        default       { $Name }
    }
}


function ConvertTo-FlatType {
    <#
    .SYNOPSIS
        Walks one block schema and emits a type record for it plus one for
        every nested block or nested_type attribute beneath it.

    .DESCRIPTION
        Nested blocks are emitted as their own type records carrying a
        parent reference rather than flattened into dotted attribute names.
        A block is a type in its own right; this keeps the record shape
        uniform and survives the deeply recursive providers.

        Type ids are path-based: aws_instance, aws_instance/root_block_device,
        aws_instance/root_block_device/tags. Data sources are namespaced:
        data.aws_instance, data.aws_instance/filter. Every record also
        carries `name`, the bare Terraform type name of its top-level owner.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        # Bare Terraform type name of the top-level owner (aws_instance).
        [Parameter(Mandatory)]
        [string] $Name,

        # resource | data_source | ephemeral | block | attribute_object
        [Parameter(Mandatory)]
        [string] $Kind,

        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Block,

        [Parameter()]
        [AllowNull()]
        [string] $Parent,

        [Parameter()]
        [AllowNull()]
        [string] $NestingMode
    )

    $records    = [System.Collections.Generic.List[pscustomobject]]::new()
    $attributes = [System.Collections.Generic.List[pscustomobject]]::new()
    $children   = [System.Collections.Generic.List[string]]::new()

    $attributesElement = Get-OptionalProperty -Parent $Block -Name 'attributes'
    if ($null -ne $attributesElement -and $attributesElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        foreach ($property in $attributesElement.EnumerateObject()) {
            $nestedTypeId = $null
            $nestedType   = Get-OptionalProperty -Parent $property.Value -Name 'nested_type'

            if ($null -ne $nestedType) {
                $nestedTypeId = "$Id/$($property.Name)"
                $children.Add($nestedTypeId)

                $nestedRecords = ConvertTo-FlatType `
                    -Id          $nestedTypeId `
                    -Name        $Name `
                    -Kind        'attribute_object' `
                    -Block       $nestedType `
                    -Parent      $Id `
                    -NestingMode (Get-OptionalString -Parent $nestedType -Name 'nesting_mode')

                foreach ($r in $nestedRecords) { $records.Add($r) }
            }

            $attributes.Add((ConvertTo-FlatAttribute -Name $property.Name -Attribute $property.Value -NestedTypeId $nestedTypeId))
        }
    }

    $blockTypesElement = Get-OptionalProperty -Parent $Block -Name 'block_types'
    if ($null -ne $blockTypesElement -and $blockTypesElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        foreach ($property in $blockTypesElement.EnumerateObject()) {
            $childId    = "$Id/$($property.Name)"
            $childBlock = Get-OptionalProperty -Parent $property.Value -Name 'block'
            if ($null -eq $childBlock) { continue }

            $children.Add($childId)

            $childRecords = ConvertTo-FlatType `
                -Id          $childId `
                -Name        $Name `
                -Kind        'block' `
                -Block       $childBlock `
                -Parent      $Id `
                -NestingMode (Get-OptionalString -Parent $property.Value -Name 'nesting_mode')

            foreach ($r in $childRecords) { $records.Add($r) }
        }
    }

    $self = [pscustomobject] @{
        id          = $Id
        name        = $Name
        kind        = $Kind
        parent      = if ([string]::IsNullOrEmpty($Parent))      { $null } else { $Parent }
        nestingMode = if ([string]::IsNullOrEmpty($NestingMode)) { $null } else { $NestingMode }
        description = Get-OptionalString -Parent $Block -Name 'description'
        deprecated  = Get-OptionalBool   -Parent $Block -Name 'deprecated'
        attributes  = @($attributes)
        children    = @($children)
    }

    $records.Insert(0, $self)
    $records.ToArray()
}


function ConvertTo-FlatTypeSet {
    <#
    .SYNOPSIS
        Flattens every entry in a top-level schema map (resource_schemas,
        data_source_schemas, ...) into type records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Provider,

        [Parameter(Mandatory)]
        [string] $MapName,

        [Parameter(Mandatory)]
        [string] $Kind
    )

    $map = Get-OptionalProperty -Parent $Provider -Name $MapName
    if ($null -eq $map -or $map.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return @() }

    $records = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in $map.EnumerateObject()) {
        $block = Get-OptionalProperty -Parent $entry.Value -Name 'block'
        if ($null -eq $block) { continue }

        $id   = Get-TypeId -Kind $Kind -Name $entry.Name
        $flat = ConvertTo-FlatType -Id $id -Name $entry.Name -Kind $Kind -Block $block -Parent $null -NestingMode $null
        foreach ($r in $flat) { $records.Add($r) }
    }

    $records.ToArray()
}


function Write-ProviderTypes {
    <#
    .SYNOPSIS
        Writes providers/<slug>/types.json and returns the type records.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter(Mandatory)]
        [string] $Slug,

        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Schema,

        [Parameter(Mandatory)]
        [string] $ProvidersRoot
    )

    $types = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($r in (ConvertTo-FlatTypeSet -Provider $Schema -MapName 'resource_schemas'           -Kind 'resource'))    { $types.Add($r) }
    foreach ($r in (ConvertTo-FlatTypeSet -Provider $Schema -MapName 'data_source_schemas'        -Kind 'data_source')) { $types.Add($r) }
    foreach ($r in (ConvertTo-FlatTypeSet -Provider $Schema -MapName 'ephemeral_resource_schemas' -Kind 'ephemeral'))   { $types.Add($r) }

    $payload = [pscustomobject] @{
        address   = $Address
        slug      = $Slug
        source    = 'terraform-provider-schema'
        tier      = 1
        typeCount = $types.Count
        types     = $types.ToArray()
    }

    $typesPath = Join-Path $ProvidersRoot $Slug 'types.json'

    $payload |
        ConvertTo-Json -Depth 6 |
        Format-JsonText |
        Set-Content -LiteralPath $typesPath -Encoding utf8NoBOM

    $types.ToArray()
}

#endregion flatten


#region docs

# ---------------------------------------------------------------------------
# Registry fetch. Public JSON:API, unauthenticated.
#
#   1. v2/providers/<ns>/<name>?include=provider-versions
#        -> included[type=provider-versions]  (id, attributes.version)
#   2. v2/provider-versions/<versionId>?include=provider-docs
#        -> included[type=provider-docs]      (id, attributes.{slug,category,subcategory,title,path})
#   3. v2/provider-docs/<docId>
#        -> data.attributes.content            (raw markdown)
# ---------------------------------------------------------------------------

$script:RegistryBase = 'https://registry.terraform.io/v2'

function Invoke-RegistryApi {
    <#
    .SYNOPSIS
        GET against the public registry with a small retry on 429 / 5xx.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter()]
        [int] $MaxAttempts = 4
    )

    $uri = "$script:RegistryBase/$Path"
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            Write-Verbose "GET $uri (attempt $attempt)"
            return Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'User-Agent' = 'OntologyBuilder/0.1 (terraform.schema.build.ps1)' }
        }
        catch {
            $status = $null
            $response = Get-ObjectProperty -Object $_.Exception -Name 'Response'
            if ($null -ne $response) { $status = [int] $response.StatusCode }

            $retryable = ($status -eq 429) -or ($status -ge 500 -and $status -le 599) -or ($null -eq $status)
            if (-not $retryable -or $attempt -ge $MaxAttempts) {
                throw "Registry GET failed ($($status ?? 'no status')) for $uri : $($_.Exception.Message)"
            }

            $delay = [math]::Pow(2, $attempt) * 500
            Write-Verbose "Retrying in ${delay}ms after HTTP $status"
            Start-Sleep -Milliseconds $delay
        }
    }
}


function Get-IncludedOfType {
    <#
    .SYNOPSIS
        Null-safe filter over a JSON:API 'included' array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Response,

        [Parameter(Mandatory)]
        [string] $Type
    )

    $included = Get-ObjectProperty -Object $Response -Name 'included'
    if ($null -eq $included) { return @() }
    @($included | Where-Object { $_.type -eq $Type })
}


function ConvertFrom-ProviderAddress {
    <#
    .SYNOPSIS
        Splits a public-registry address into namespace + name. Returns
        $null for any other host; the public docs API only covers
        registry.terraform.io.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    $segments = $Address.Split('/')
    if ($segments.Count -eq 3 -and $segments[0] -eq 'registry.terraform.io') {
        return [pscustomobject] @{ namespace = $segments[1]; name = $segments[2] }
    }
    if ($segments.Count -eq 2) {
        return [pscustomobject] @{ namespace = $segments[0]; name = $segments[1] }
    }
    $null
}


function Resolve-RegistryProviderVersion {
    <#
    .SYNOPSIS
        Resolves a provider version string to its registry version id.
        'latest' picks the highest semantic version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Namespace,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter()]
        [string] $Version = 'latest'
    )

    $response = Invoke-RegistryApi -Path "providers/$Namespace/$Name`?include=provider-versions"
    $versions = Get-IncludedOfType -Response $response -Type 'provider-versions'
    if ($versions.Count -eq 0) { throw "Registry returned no versions for $Namespace/$Name." }

    if ($Version -eq 'latest') {
        $target = $versions |
            Sort-Object -Descending {
                $v = $_.attributes.version
                try { [version] $v } catch { [version] '0.0.0' }
            }, { $_.attributes.version } |
            Select-Object -First 1
    }
    else {
        $target = $versions | Where-Object { $_.attributes.version -eq $Version } | Select-Object -First 1
    }

    if ($null -eq $target) {
        throw "Version '$Version' of $Namespace/$Name is not in the registry. Known: $(($versions.attributes.version | Select-Object -First 10) -join ', ') ..."
    }

    [pscustomobject] @{
        namespace = $Namespace
        name      = $Name
        version   = $target.attributes.version
        versionId = $target.id
    }
}


function Get-RegistryDocList {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $VersionId
    )

    $response = Invoke-RegistryApi -Path "provider-versions/$VersionId`?include=provider-docs"
    $docs     = Get-IncludedOfType -Response $response -Type 'provider-docs'

    foreach ($doc in $docs) {
        $a = $doc.attributes
        [pscustomobject] @{
            id          = [string] $doc.id
            slug        = [string] $a.slug
            category    = [string] $a.category
            subcategory = Get-ObjectProperty -Object $a -Name 'subcategory'
            title       = Get-ObjectProperty -Object $a -Name 'title'
            path        = Get-ObjectProperty -Object $a -Name 'path'
        }
    }
}


function Get-RegistryDocContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DocId
    )

    $response = Invoke-RegistryApi -Path "provider-docs/$DocId"
    [string] $response.data.attributes.content
}


function Save-ProviderDocs {
    <#
    .SYNOPSIS
        Pulls every doc page for a provider version into
        providers/<slug>/docs/<category>/<slug>.md with a docs.index.json
        manifest. Skips the network entirely when the manifest already
        records the wanted version.

    .DESCRIPTION
        Cache key is the provider version. With a lock file the version is
        known before any call is made; without one the version resolves to
        'latest' (one call) and is compared to the manifest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter()]
        [AllowNull()]
        [string] $Version,

        [Parameter(Mandatory)]
        [string] $ProviderDir,

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [int] $ThrottleMs = 75
    )

    $docsDir      = Join-Path $ProviderDir 'docs'
    $manifestPath = Join-Path $docsDir 'docs.index.json'
    $manifest     = Read-JsonFile -Path $manifestPath
    $cachedVer    = Get-ObjectProperty -Object $manifest -Name 'version'
    $cachedCount  = Get-ObjectProperty -Object $manifest -Name 'docCount' -Default 0

    $result = [pscustomobject] @{ fetched = $false; skipped = $true; reason = $null; docCount = $cachedCount; version = $cachedVer }

    $parsed = ConvertFrom-ProviderAddress -Address $Address
    if ($null -eq $parsed) {
        $result.reason = 'non-public-registry'
        return $result
    }

    $wanted = if ([string]::IsNullOrEmpty($Version)) { 'latest' } else { $Version }

    # Fast path: version known from the lock file and already on disk.
    if (-not $Force -and $wanted -ne 'latest' -and $cachedVer -eq $wanted) {
        $result.reason = 'cache-hit'
        return $result
    }

    $resolved = Resolve-RegistryProviderVersion -Namespace $parsed.namespace -Name $parsed.name -Version $wanted

    if (-not $Force -and $cachedVer -eq $resolved.version) {
        $result.reason  = 'cache-hit'
        $result.version = $resolved.version
        return $result
    }

    $docs = @(Get-RegistryDocList -VersionId $resolved.versionId)
    Write-Host ('  fetching {0} docs for {1}/{2} {3}' -f $docs.Count, $parsed.namespace, $parsed.name, $resolved.version)

    # Replace the docs tree wholesale so a version bump cannot leave stale pages.
    if (Test-Path -LiteralPath $docsDir) { Remove-Item -LiteralPath $docsDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $docsDir -Force

    $entries = foreach ($doc in $docs) {
        $categoryDir = Join-Path $docsDir $doc.category
        $null = New-Item -ItemType Directory -Path $categoryDir -Force

        $safeSlug = $doc.slug -replace '[^A-Za-z0-9_.-]', '_'
        $file     = Join-Path $categoryDir "$safeSlug.md"
        $content  = Get-RegistryDocContent -DocId $doc.id
        Set-Content -LiteralPath $file -Value $content -Encoding utf8NoBOM -NoNewline

        [pscustomobject] @{
            id          = $doc.id
            slug        = $doc.slug
            category    = $doc.category
            subcategory = $doc.subcategory
            title       = $doc.title
            file        = "$($doc.category)/$safeSlug.md"
            bytes       = (Get-Item -LiteralPath $file).Length
        }

        if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
    }

    Write-JsonFile -Path $manifestPath -Depth 6 -Object ([pscustomobject] @{
        address    = $Address
        namespace  = $resolved.namespace
        name       = $resolved.name
        version    = $resolved.version
        versionId  = $resolved.versionId
        source     = 'registry.terraform.io/v2/provider-docs'
        tier       = 2
        fetchedAt  = [System.DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        docCount   = $docs.Count
        docs       = @($entries | Sort-Object category, slug)
    })

    $result.fetched  = $true
    $result.skipped  = $false
    $result.reason   = 'fetched'
    $result.docCount = $docs.Count
    $result.version  = $resolved.version
    $result
}


# ---------------------------------------------------------------------------
# Markdown extraction. Everything below is regex over the registry
# markdown. Tier 2: vendor-authored, not executable.
# ---------------------------------------------------------------------------

function ConvertFrom-DocFrontmatter {
    <#
    .SYNOPSIS
        Pulls page_title, subcategory and description out of the YAML
        frontmatter. Handles both the inline and the `|-` block forms of
        description. Returns the frontmatter fields and the body.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Markdown
    )

    $result = [pscustomobject] @{ pageTitle = $null; subcategory = $null; description = $null; body = $Markdown }

    $fm = [regex]::Match($Markdown, '\A---\s*\r?\n(?<yaml>.*?)\r?\n---\s*\r?\n', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $fm.Success) { return $result }

    $yaml = $fm.Groups['yaml'].Value
    $result.body = $Markdown.Substring($fm.Length)

    $pt = [regex]::Match($yaml, '(?m)^page_title:\s*"?(?<v>.*?)"?\s*$')
    if ($pt.Success) { $result.pageTitle = $pt.Groups['v'].Value.Trim() }

    $sc = [regex]::Match($yaml, '(?m)^subcategory:\s*"?(?<v>.*?)"?\s*$')
    if ($sc.Success -and $sc.Groups['v'].Value.Trim().Length -gt 0) { $result.subcategory = $sc.Groups['v'].Value.Trim() }

    # Block form: description: |-   followed by indented lines.
    $block = [regex]::Match($yaml, '(?m)^description:\s*[|>]-?\s*$\r?\n(?<lines>(?:[ \t]+.*(?:\r?\n|$))+)')
    if ($block.Success) {
        $lines = $block.Groups['lines'].Value -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
        $result.description = ($lines -join ' ').Trim()
        return $result
    }

    $inline = [regex]::Match($yaml, '(?m)^description:\s*"?(?<v>.+?)"?\s*$')
    if ($inline.Success) { $result.description = $inline.Groups['v'].Value.Trim() }

    $result
}


function Get-MarkdownSection {
    <#
    .SYNOPSIS
        Returns the body text under the first level-2 heading whose text
        matches -HeadingPattern (case-insensitive regex), up to the next
        level-2 heading. $null when absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Markdown,

        [Parameter(Mandatory)]
        [string] $HeadingPattern
    )

    $pattern = '(?ims)^##\s+(?:' + $HeadingPattern + ')\s*$\r?\n(?<body>.*?)(?=^##\s|\z)'
    $m = [regex]::Match($Markdown, $pattern)
    if ($m.Success) { return $m.Groups['body'].Value }
    $null
}


function Get-HclBlock {
    <#
    .SYNOPSIS
        Returns the contents of every ```hcl / ```terraform / bare ``` fence.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Markdown
    )

    $fences = [regex]::Matches($Markdown, '(?s)```(?:hcl|terraform)?[ \t]*\r?\n(?<code>.*?)```')
    foreach ($m in $fences) { $m.Groups['code'].Value }
}


function Get-ExampleReference {
    <#
    .SYNOPSIS
        Walks an HCL example and emits one record per expression that
        references another resource or data source from inside a
        resource / data block.

    .DESCRIPTION
        Only references whose namespaced id (data.x for data sources) is in
        -TypeIds are kept, which filters var.*, local.*, each.*, module.*
        and anything from other providers.

        Depth is tracked by brace counting with heredocs skipped. Good
        enough for registry examples; not an HCL parser.

        Emits:
          ownerId, ownerType, ownerKind ('resource'|'data_source'|'ephemeral')
          attribute (dotted path inside nested blocks)
          refId, refType, refKind, refAttribute ($null for depends_on-style refs)
          cardinality ('one'|'many'), expression
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Hcl,

        [Parameter(Mandatory)]
        [hashtable] $TypeIds
    )

    $out = [System.Collections.Generic.List[pscustomobject]]::new()

    $kindByKeyword = @{ resource = 'resource'; data = 'data_source'; ephemeral = 'ephemeral' }

    $refWithAttr    = '(?<![\w."/-])(?<data>data\.)?(?<type>[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\.(?<name>[A-Za-z0-9_-]+)\.(?<attr>[a-z0-9_]+)'
    $refBare        = '(?<![\w."/-])(?<data>data\.)?(?<type>[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\.(?<name>[A-Za-z0-9_-]+)(?![\w.])'

    $depth       = 0
    $ownerType   = $null
    $ownerKind   = $null
    $ownerId     = $null
    $blockPath   = [System.Collections.Generic.List[string]]::new()
    $heredocEnd  = $null

    foreach ($rawLine in ($Hcl -split '\r?\n')) {
        $line = $rawLine

        if ($null -ne $heredocEnd) {
            if ($line.Trim() -eq $heredocEnd) { $heredocEnd = $null }
            continue
        }

        # Strip trailing comments (crude, but examples are simple).
        $line = $line -replace '\s+(#|//).*$', ''
        $trim = $line.Trim()
        if ($trim.Length -eq 0) { continue }

        if ($depth -eq 0) {
            $head = [regex]::Match($trim, '^(?<kw>resource|data|ephemeral)\s+"(?<type>[^"]+)"\s+"[^"]+"\s*\{')
            if ($head.Success) {
                $ownerType = $head.Groups['type'].Value
                $ownerKind = $kindByKeyword[$head.Groups['kw'].Value]
                $ownerId   = Get-TypeId -Kind $ownerKind -Name $ownerType
            }
            else {
                $ownerType = $null
                $ownerKind = $null
                $ownerId   = $null
            }
            $blockPath.Clear()
        }
        elseif ($null -ne $ownerType) {
            # Nested block opener:  foo {   or   foo "label" {
            $nested = [regex]::Match($trim, '^(?<name>[a-z][a-z0-9_]*)(\s+"[^"]*")*\s*\{\s*$')
            if ($nested.Success) {
                $blockPath.Add($nested.Groups['name'].Value)
            }
            else {
                $assign = [regex]::Match($trim, '^(?<attr>[a-z][a-z0-9_]*)\s*=\s*(?<rhs>.+)$')
                if ($assign.Success) {
                    $attr = $assign.Groups['attr'].Value
                    $rhs  = $assign.Groups['rhs'].Value
                    $path = if ($blockPath.Count -gt 0) { ($blockPath -join '.') + '.' + $attr } else { $attr }
                    $isMany = $rhs -match '\[\s*(?:for\b|data\.|[a-z])' -or $rhs -match '\.\*\.' -or $rhs -match '\[\*\]'

                    $seen = @{}
                    $matched = [regex]::Matches($rhs, $refWithAttr)
                    foreach ($m in $matched) {
                        $refType = $m.Groups['type'].Value
                        $refKind = if ($m.Groups['data'].Success) { 'data_source' } else { 'resource' }
                        $refId   = Get-TypeId -Kind $refKind -Name $refType
                        if (-not $TypeIds.ContainsKey($refId)) { continue }
                        $key = "$refId|$($m.Groups['attr'].Value)"
                        if ($seen.ContainsKey($key)) { continue }
                        $seen[$key] = $true
                        $out.Add([pscustomobject] @{
                            ownerId      = $ownerId
                            ownerType    = $ownerType
                            ownerKind    = $ownerKind
                            attribute    = $path
                            refId        = $refId
                            refType      = $refType
                            refKind      = $refKind
                            refAttribute = $m.Groups['attr'].Value
                            cardinality  = if ($isMany) { 'many' } else { 'one' }
                            expression   = $m.Value
                        })
                    }

                    if ($attr -eq 'depends_on' -or $matched.Count -eq 0) {
                        foreach ($m in [regex]::Matches($rhs, $refBare)) {
                            $refType = $m.Groups['type'].Value
                            $refKind = if ($m.Groups['data'].Success) { 'data_source' } else { 'resource' }
                            $refId   = Get-TypeId -Kind $refKind -Name $refType
                            if (-not $TypeIds.ContainsKey($refId)) { continue }
                            $key = "$refId|"
                            if ($seen.ContainsKey($key)) { continue }
                            $seen[$key] = $true
                            $out.Add([pscustomobject] @{
                                ownerId      = $ownerId
                                ownerType    = $ownerType
                                ownerKind    = $ownerKind
                                attribute    = $path
                                refId        = $refId
                                refType      = $refType
                                refKind      = $refKind
                                refAttribute = $null
                                cardinality  = if ($isMany) { 'many' } else { 'one' }
                                expression   = $m.Value
                            })
                        }
                    }
                }
            }
        }

        # Heredoc start: everything until the marker is opaque.
        $hd = [regex]::Match($line, '<<-?(?<marker>[A-Za-z_][A-Za-z0-9_]*)\s*$')
        if ($hd.Success) { $heredocEnd = $hd.Groups['marker'].Value }

        $opens  = ([regex]::Matches($line, '\{')).Count
        $closes = ([regex]::Matches($line, '\}')).Count
        $before = $depth
        $depth  = [math]::Max(0, $depth + $opens - $closes)

        # Pop nested block path on close (one level per net close, bounded).
        if ($depth -lt $before -and $null -ne $ownerType) {
            $pop = $before - $depth
            while ($pop -gt 0 -and $blockPath.Count -gt 0) { $blockPath.RemoveAt($blockPath.Count - 1); $pop-- }
        }
    }

    $out.ToArray()
}


function ConvertFrom-ProviderDoc {
    <#
    .SYNOPSIS
        Turns one registry markdown page into a structured record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $ManifestEntry,

        [Parameter(Mandatory)]
        [string] $DocsDir,

        [Parameter()]
        [AllowNull()]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [hashtable] $TypeIds
    )

    $file = Join-Path $DocsDir $ManifestEntry.file
    $md   = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw } else { '' }

    $fm   = ConvertFrom-DocFrontmatter -Markdown $md
    $body = $fm.body

    $kindByCategory = @{
        'resources'           = 'resource'
        'data-sources'        = 'data_source'
        'ephemeral-resources' = 'ephemeral'
        'functions'           = 'function'
    }
    $kind = $kindByCategory[$ManifestEntry.category]

    # Slug -> namespaced type id. Registry slugs drop the provider prefix.
    $typeName = $null
    $typeId   = $null
    if ($null -ne $kind -and $kind -ne 'function') {
        $candidates = @()
        if (-not [string]::IsNullOrEmpty($Prefix)) { $candidates += "$Prefix`_$($ManifestEntry.slug)" }
        $candidates += $ManifestEntry.slug
        foreach ($c in $candidates) {
            $probe = Get-TypeId -Kind $kind -Name $c
            if ($TypeIds.ContainsKey($probe)) { $typeName = $c; $typeId = $probe; break }
        }
    }

    # Example usage references.
    $refs = [System.Collections.Generic.List[pscustomobject]]::new()
    $exampleSection = Get-MarkdownSection -Markdown $body -HeadingPattern 'Example Usage.*'
    $hclSource = if ($null -ne $exampleSection) { $exampleSection } else { $body }
    foreach ($hcl in (Get-HclBlock -Markdown $hclSource)) {
        foreach ($r in (Get-ExampleReference -Hcl $hcl -TypeIds $TypeIds)) { $refs.Add($r) }
    }

    # Relevant links -> [text](url)
    $links = [System.Collections.Generic.List[pscustomobject]]::new()
    $linkSection = Get-MarkdownSection -Markdown $body -HeadingPattern 'Relevant Links?|Related Links?|References?'
    if ($null -ne $linkSection) {
        foreach ($m in [regex]::Matches($linkSection, '\[(?<text>[^\]]+)\]\((?<url>https?://[^)\s]+)\)')) {
            $links.Add([pscustomobject] @{ text = $m.Groups['text'].Value; url = $m.Groups['url'].Value })
        }
    }

    # PAT permissions -> - **Scope**: Level
    $pat = [System.Collections.Generic.List[pscustomobject]]::new()
    $patSection = Get-MarkdownSection -Markdown $body -HeadingPattern 'PAT Permissions? Required'
    if ($null -ne $patSection) {
        foreach ($m in [regex]::Matches($patSection, '(?m)^\s*[-*]\s*\*\*(?<scope>[^*]+)\*\*\s*:\s*(?<level>.+?)\s*$')) {
            $pat.Add([pscustomobject] @{ scope = $m.Groups['scope'].Value.Trim(); level = $m.Groups['level'].Value.Trim() })
        }
    }

    # Timeouts -> * `read` - (Defaults to 5 minute)
    $timeouts = [System.Collections.Generic.List[pscustomobject]]::new()
    $timeoutSection = Get-MarkdownSection -Markdown $body -HeadingPattern 'Timeouts?'
    if ($null -ne $timeoutSection) {
        foreach ($m in [regex]::Matches($timeoutSection, '`(?<op>[a-z]+)`\s*-\s*\(Defaults? to (?<n>\d+)\s*(?<unit>second|minute|hour)s?\)')) {
            $timeouts.Add([pscustomobject] @{ operation = $m.Groups['op'].Value; default = [int] $m.Groups['n'].Value; unit = $m.Groups['unit'].Value })
        }
    }

    # Import section presence + first import command.
    $importSection = Get-MarkdownSection -Markdown $body -HeadingPattern 'Import'
    $importable = $null -ne $importSection
    $importExample = $null
    if ($importable) {
        $im = [regex]::Match($importSection, '(?m)^\s*(?:\$\s*)?(?<cmd>terraform import\s+.+?)\s*$')
        if ($im.Success) { $importExample = $im.Groups['cmd'].Value }
    }

    # Callouts: ~> NOTE, -> info, !> warning
    $notes = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($m in [regex]::Matches($body, '(?m)^\s*(?<sigil>~>|->|!>)\s*(?<text>.+?)\s*$')) {
        $level = switch ($m.Groups['sigil'].Value) { '!>' { 'warning' } '->' { 'info' } default { 'note' } }
        $text  = $m.Groups['text'].Value -replace '\*\*(NOTE|Note|WARNING|Warning)\*\*:?\s*', ''
        $notes.Add([pscustomobject] @{ level = $level; text = $text.Trim() })
    }

    # Headings give a cheap outline of what the page covers.
    $sections = @([regex]::Matches($body, '(?m)^##\s+(?<h>.+?)\s*$') | ForEach-Object { $_.Groups['h'].Value })

    [pscustomobject] @{
        slug          = $ManifestEntry.slug
        category      = $ManifestEntry.category
        subcategory   = if ($null -ne $fm.subcategory) { $fm.subcategory } else { $ManifestEntry.subcategory }
        title         = $ManifestEntry.title
        pageTitle     = $fm.pageTitle
        file          = "docs/$($ManifestEntry.file)"
        kind          = $kind
        type          = $typeId
        name          = $typeName
        matched       = ($null -ne $typeId)
        description   = $fm.description
        sections      = $sections
        exampleRefs   = $refs.ToArray()
        relevantLinks = $links.ToArray()
        patPermissions = $pat.ToArray()
        timeouts      = $timeouts.ToArray()
        importable    = $importable
        importExample = $importExample
        notes         = $notes.ToArray()
        tier          = 2
    }
}


function Write-ProviderDocs {
    <#
    .SYNOPSIS
        Extracts every cached doc page into providers/<slug>/docs.json and
        returns the records, the Tier 2 edges derived from example usage,
        and a type -> description map for the classifier.

    .DESCRIPTION
        Runs whether or not docs were fetched this run: extraction is over
        whatever is on disk. No docs on disk means empty results and no
        docs.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter(Mandatory)]
        [string] $Slug,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Types,

        [Parameter()]
        [AllowNull()]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [string] $ProviderDir
    )

    $empty = [pscustomobject] @{
        records = @(); edges = @(); descriptions = @{}
        docCount = 0; matchedCount = 0; unmatchedCount = 0
    }

    $docsDir      = Join-Path $ProviderDir 'docs'
    $manifestPath = Join-Path $docsDir 'docs.index.json'
    $manifest     = Read-JsonFile -Path $manifestPath
    if ($null -eq $manifest) { return $empty }

    $manifestDocs = @(Get-ObjectProperty -Object $manifest -Name 'docs' -Default @())
    if ($manifestDocs.Count -eq 0) { return $empty }

    # Set of top-level namespaced ids (aws_instance, data.aws_instance).
    $typeIds = @{}
    foreach ($t in $Types) {
        if ($t.kind -notin 'resource', 'data_source', 'ephemeral') { continue }
        $typeIds[$t.id] = $true
    }

    $records = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($entry in $manifestDocs) {
        $records.Add((ConvertFrom-ProviderDoc -ManifestEntry $entry -DocsDir $docsDir -Prefix $Prefix -TypeIds $typeIds))
    }

    # Edges: from the block that owns the attribute, to the referenced type.
    $edges = [System.Collections.Generic.List[pscustomobject]]::new()
    $seen  = @{}
    foreach ($r in $records) {
        foreach ($ref in $r.exampleRefs) {
            if ($ref.ownerId -eq $ref.refId) { continue }
            if (-not $typeIds.ContainsKey($ref.ownerId)) { continue }

            $key = "$($ref.ownerId)|$($ref.attribute)|$($ref.refId)|$($ref.refAttribute)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $edges.Add([pscustomobject] @{
                from        = $ref.ownerId
                fromKind    = $ref.ownerKind
                fromPath    = $ref.ownerId
                attribute   = $ref.attribute
                to          = $ref.refId
                toKind      = $ref.refKind
                toAttribute = $ref.refAttribute
                cardinality = $ref.cardinality
                tier        = 2
                score       = if ($null -ne $ref.refAttribute) { 2 } else { 1 }
                evidence    = [pscustomobject] @{
                    source     = 'registry-docs-example'
                    doc        = "$($r.category)/$($r.slug)"
                    expression = $ref.expression
                }
            })
        }
    }

    # Descriptions keyed by namespaced id; resource and data source docs no longer collide.
    $descriptions = @{}
    foreach ($r in ($records | Where-Object { $_.matched -and -not [string]::IsNullOrEmpty($_.description) })) {
        if (-not $descriptions.ContainsKey($r.type)) { $descriptions[$r.type] = $r.description }
    }

    $matched   = @($records | Where-Object { $_.matched })
    $unmatched = @($records | Where-Object { $null -ne $_.kind -and $_.kind -ne 'function' -and -not $_.matched })

    Write-JsonFile -Path (Join-Path $ProviderDir 'docs.json') -Depth 8 -Object ([pscustomobject] @{
        address        = $Address
        slug           = $Slug
        prefix         = $Prefix
        source         = 'registry.terraform.io/v2/provider-docs'
        tier           = 2
        docsVersion    = Get-ObjectProperty -Object $manifest -Name 'version'
        docCount       = $records.Count
        matchedCount   = $matched.Count
        unmatchedCount = $unmatched.Count
        unmatchedSlugs = @($unmatched | ForEach-Object { "$($_.category)/$($_.slug)" } | Sort-Object)
        edgeCount      = $edges.Count
        edges          = @($edges | Sort-Object from, attribute, to)
        docs           = @($records | Sort-Object category, slug)
    })

    [pscustomobject] @{
        records        = $records.ToArray()
        edges          = $edges.ToArray()
        descriptions   = $descriptions
        docCount       = $records.Count
        matchedCount   = $matched.Count
        unmatchedCount = $unmatched.Count
    }
}

#endregion docs


#region links

function Get-ProviderPrefix {
    <#
    .SYNOPSIS
        Derives the resource-name prefix (e.g. "aws") from a provider's
        resource type names by majority vote on the first token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Types
    )

    $counts = @{}
    foreach ($t in $Types) {
        if ($t.kind -notin 'resource', 'data_source') { continue }
        $token = ($t.name -split '_')[0]
        if ([string]::IsNullOrEmpty($token)) { continue }
        $counts[$token] = 1 + ($counts[$token] ?? 0)
    }

    if ($counts.Count -eq 0) { return $null }
    ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
}


function Get-SingularNoun {
    <#
    .SYNOPSIS
        Cheap English de-pluralisation. Good enough for schema nouns.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Noun
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($Noun)

    if ($Noun.EndsWith('ies'))  { $candidates.Add($Noun.Substring(0, $Noun.Length - 3) + 'y') }
    if ($Noun.EndsWith('sses')) { $candidates.Add($Noun.Substring(0, $Noun.Length - 2)) }
    elseif ($Noun.EndsWith('es')) { $candidates.Add($Noun.Substring(0, $Noun.Length - 2)) }
    if ($Noun.EndsWith('s'))    { $candidates.Add($Noun.Substring(0, $Noun.Length - 1)) }

    $candidates | Select-Object -Unique
}


function Get-IdentityMap {
    <#
    .SYNOPSIS
        Reads resource_identity_schemas into a hashtable of
        resource type -> identifying attribute names. Tier 1.

    .DESCRIPTION
        Null-safe. The key only appears when both the Terraform version
        and the provider support resource identity; absence yields an
        empty map, not an error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Schema
    )

    $map = @{}

    $identities = Get-OptionalProperty -Parent $Schema -Name 'resource_identity_schemas'
    if ($null -eq $identities -or $identities.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $map }

    foreach ($entry in $identities.EnumerateObject()) {
        $attributes = Get-OptionalProperty -Parent $entry.Value -Name 'attributes'
        if ($null -eq $attributes -or $attributes.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }

        $names = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($a in $attributes.EnumerateObject()) {
            $typeElement = Get-OptionalProperty -Parent $a.Value -Name 'type'
            $names.Add([pscustomobject] @{
                name              = $a.Name
                type              = if ($null -ne $typeElement) { Get-TypeSignature -Type $typeElement } else { $null }
                requiredForImport = Get-OptionalBool -Parent $a.Value -Name 'required_for_import'
                optionalForImport = Get-OptionalBool -Parent $a.Value -Name 'optional_for_import'
            })
        }

        $map[$entry.Name] = $names.ToArray()
    }

    $map
}


function Get-InferredEdge {
    <#
    .SYNOPSIS
        Walks every attribute in the flattened types and emits Tier 4
        reference edges from *_id / *_ids attributes to matching resource
        types.

    .DESCRIPTION
        Match order is type signature first, then name:
          1. attribute type must be string, list(string) or set(string)
          2. name must end in _id or _ids
          3. strip the suffix, singularise, prefix with the provider token,
             and look for an existing resource type of that name.

        Corroboration is recorded, never used to drop an edge:
          - target declares a Tier 1 identity
          - target has a computed "id" attribute
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Types,

        [Parameter(Mandatory)]
        [hashtable] $IdentityMap,

        [Parameter()]
        [AllowNull()]
        [string] $Prefix
    )

    $edges = [System.Collections.Generic.List[pscustomobject]]::new()
    if ([string]::IsNullOrEmpty($Prefix)) { return $edges.ToArray() }

    $byId = @{}
    foreach ($t in $Types) { $byId[$t.id] = $t }

    $resourceIds = @{}
    foreach ($t in $Types) {
        if ($t.kind -eq 'resource') { $resourceIds[$t.id] = $true }
    }

    $scalarTypes     = @('string', 'number')
    $collectionTypes = @('list(string)', 'set(string)', 'list(number)', 'set(number)')

    foreach ($t in $Types) {
        # Owner is the top-level resource/data source this record lives under.
        $owner = $t
        while (-not [string]::IsNullOrEmpty($owner.parent)) {
            if (-not $byId.ContainsKey($owner.parent)) {
                throw "Type '$($owner.id)' references parent '$($owner.parent)' which is not in the type set."
            }
            $owner = $byId[$owner.parent]
        }

        foreach ($attr in $t.attributes) {
            if ($null -eq $attr.type) { continue }

            $isScalar     = $attr.type -in $scalarTypes
            $isCollection = $attr.type -in $collectionTypes
            if (-not ($isScalar -or $isCollection)) { continue }

            $noun = $null
            if     ($attr.name -match '^(.+)_ids$') { $noun = $Matches[1] }
            elseif ($attr.name -match '^(.+)_id$')  { $noun = $Matches[1] }
            else   { continue }

            # Plural attribute name on a scalar type (or vice versa) is a weaker signal.
            $shapeAgrees = ($isCollection -and $attr.name.EndsWith('_ids')) -or ($isScalar -and $attr.name.EndsWith('_id'))

            $target = $null
            foreach ($candidate in (Get-SingularNoun -Noun $noun)) {
                $probe = "$Prefix`_$candidate"
                if ($resourceIds.ContainsKey($probe)) { $target = $probe; break }
            }
            if ($null -eq $target) { continue }
            if ($target -eq $owner.id) { continue }   # self-reference, e.g. aws_x.x_id

            $targetType   = $byId[$target]
            $hasIdentity  = $IdentityMap.ContainsKey($target)
            $hasComputedId = [bool] ($targetType.attributes | Where-Object { $_.name -eq 'id' -and $_.computed } | Select-Object -First 1)

            $score = 0
            if ($shapeAgrees)   { $score++ }
            if ($hasIdentity)   { $score++ }
            if ($hasComputedId) { $score++ }

            $edges.Add([pscustomobject] @{
                from        = $owner.id
                fromPath    = $t.id
                attribute   = $attr.name
                to          = $target
                cardinality = if ($isCollection) { 'many' } else { 'one' }
                tier        = 4
                score       = $score
                evidence    = [pscustomobject] @{
                    attributeType    = $attr.type
                    shapeAgrees      = $shapeAgrees
                    targetHasIdentity = $hasIdentity
                    targetHasComputedId = $hasComputedId
                }
            })
        }
    }

    $edges.ToArray()
}


function Write-ProviderLinks {
    <#
    .SYNOPSIS
        Writes providers/<slug>/links.json and returns identity/edge counts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter(Mandatory)]
        [string] $Slug,

        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Schema,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Types,

        [Parameter()]
        [AllowNull()]
        [string] $Prefix,

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]] $DocEdges = @(),

        [Parameter(Mandatory)]
        [string] $ProvidersRoot
    )

    $prefix      = if ([string]::IsNullOrEmpty($Prefix)) { Get-ProviderPrefix -Types $Types } else { $Prefix }
    $identityMap = Get-IdentityMap -Schema $Schema
    $inferred    = @(Get-InferredEdge -Types $Types -IdentityMap $identityMap -Prefix $prefix)

    # An inferred edge that the docs also show gets a corroboration flag.
    $docKeys = @{}
    foreach ($d in $DocEdges) {
        $attrLeaf = ($d.attribute -split '\.')[-1]
        $docKeys["$($d.from)|$attrLeaf|$($d.to)"] = $true
    }
    foreach ($e in $inferred) {
        $corroborated = $docKeys.ContainsKey("$($e.from)|$($e.attribute)|$($e.to)")
        $e.evidence | Add-Member -NotePropertyName 'corroboratedByDocs' -NotePropertyValue $corroborated -Force
        if ($corroborated) { $e.score++ }
    }

    $edges = @($DocEdges) + $inferred

    $identities = foreach ($key in ($identityMap.Keys | Sort-Object)) {
        [pscustomobject] @{
            type       = $key
            tier       = 1
            attributes = $identityMap[$key]
        }
    }

    $payload = [pscustomobject] @{
        address          = $Address
        slug             = $Slug
        prefix           = $prefix
        identityCount    = $identityMap.Count
        edgeCount        = $edges.Count
        docEdgeCount     = @($DocEdges).Count
        inferredEdgeCount = $inferred.Count
        identities       = @($identities)
        edges            = @($edges | Sort-Object tier, from, attribute, to)
    }

    Write-JsonFile -Path (Join-Path $ProvidersRoot $Slug 'links.json') -Depth 6 -Object $payload

    [pscustomobject] @{
        prefix        = $prefix
        identityCount = $identityMap.Count
        edgeCount     = $edges.Count
        edges         = $edges
        identities    = $identityMap
    }
}

#endregion links


#region classify

function Get-CategoryRuleSet {
    <#
    .SYNOPSIS
        Ordered keyword rules for classifying resource types. Tier 4.

    .DESCRIPTION
        Each rule is a category plus a list of tokens. Tokens are matched
        as whole underscore-delimited words in the bare noun (provider
        prefix removed). First rule to match wins, so order matters:
        more specific categories sit above broader ones.

        This is deliberately a plain data structure so it can move to a
        config file later without changing the classifier.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    @(
        [pscustomobject] @{ category = 'identity';      tokens = @('iam','user','users','group','groups','role','roles','policy','policies','permission','permissions','identity','principal','service_account','serviceaccount','access_key','credential','credentials','token','tokens','membership','member','members','team','teams','oauth','saml','sso','entitlement','license','licenses') }
        [pscustomobject] @{ category = 'secrets';       tokens = @('secret','secrets','vault','key_vault','keyvault','kms','key','keys','certificate','certificates','cert','certs','ssh','ssl','tls','password','passwords') }
        [pscustomobject] @{ category = 'networking';    tokens = @('vpc','vnet','network','networks','subnet','subnets','route','routes','route_table','gateway','nat','vpn','peering','endpoint','endpoints','dns','zone','zones','record','load_balancer','lb','alb','nlb','elb','listener','target_group','firewall','security_group','nsg','acl','nacl','ip','eip','cidr','interface','nic','proxy','cdn','distribution','waf','transit','private_link','vlan','port_group','portgroup','switch','dvs') }
        [pscustomobject] @{ category = 'compute';       tokens = @('instance','instances','vm','virtual_machine','host','hosts','server','servers','node','nodes','node_pool','nodepool','launch_template','autoscaling','scale_set','scaleset','image','images','ami','template','templates','snapshot','snapshots','function','functions','lambda','app_service','container','containers','cluster','clusters','pod','deployment','daemonset','statefulset','job','jobs','cronjob','ecs','eks','aks','gke','fargate','batch','datacenter','folder','resource_pool','compute') }
        [pscustomobject] @{ category = 'storage';       tokens = @('bucket','buckets','blob','disk','disks','volume','volumes','datastore','storage','s3','efs','fsx','file_share','fileshare','share','shares','backup','backups','archive') }
        [pscustomobject] @{ category = 'database';      tokens = @('database','databases','db','rds','sql','postgres','postgresql','mysql','mariadb','mongo','mongodb','cosmos','dynamodb','redis','cache','elasticache','memcached','table','tables','schema','schemas','replica','replicas','warehouse','redshift','bigquery','synapse') }
        [pscustomobject] @{ category = 'messaging';     tokens = @('queue','queues','topic','topics','subscription','subscriptions','sns','sqs','kafka','pubsub','event','events','eventbridge','event_hub','eventhub','event_grid','eventgrid','stream','streams','kinesis','bus','notification','notifications','webhook','webhooks') }
        [pscustomobject] @{ category = 'observability'; tokens = @('log','logs','log_group','metric','metrics','alarm','alarms','alert','alerts','monitor','monitors','monitoring','dashboard','dashboards','trace','traces','tracing','apm','synthetic','synthetics','uptime','probe','audit','diagnostic','diagnostics','insight','insights','slo','sli') }
        [pscustomobject] @{ category = 'ci_cd';         tokens = @('pipeline','pipelines','build','builds','build_definition','release','releases','artifact','artifacts','feed','feeds','agent','agent_pool','agentpool','runner','runners','workflow','workflows','action','actions','deploy','environment','environments','stage','stages','variable_group','variable','variables','check','checks','approval','approvals') }
        [pscustomobject] @{ category = 'source_control'; tokens = @('repo','repos','repository','repositories','git','branch','branches','branch_policy','pull_request','pr','commit','commits','tag','tags','file','files','wiki','wikis') }
        [pscustomobject] @{ category = 'project_mgmt';  tokens = @('project','projects','work_item','workitem','workitems','board','boards','iteration','iterations','area','areas','sprint','sprints','issue','issues','epic','epics','label','labels','milestone','milestones') }
        [pscustomobject] @{ category = 'config';        tokens = @('config','configuration','setting','settings','parameter','parameters','feature','features','flag','flags','profile','profiles','tag_policy','quota','quotas','limit','limits') }
        [pscustomobject] @{ category = 'governance';    tokens = @('organization','organisation','org','account','accounts','tenant','tenants','subscription_alias','management_group','billing','budget','budgets','cost','compliance','policy_assignment','lock','locks','resource_group','resourcegroup') }
    )
}


function Get-BareNoun {
    <#
    .SYNOPSIS
        Strips the provider prefix from a resource type name.
        aws_instance -> instance ; azuredevops_git_repository -> git_repository
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TypeName,

        [Parameter()]
        [AllowNull()]
        [string] $Prefix
    )

    if (-not [string]::IsNullOrEmpty($Prefix) -and $TypeName.StartsWith("$Prefix`_")) {
        return $TypeName.Substring($Prefix.Length + 1)
    }
    $TypeName
}


function Get-TypeCategory {
    <#
    .SYNOPSIS
        Classifies one bare noun against the rule set. Returns the matched
        category and token, or 'unclassified' with no token.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $BareNoun,

        [Parameter(Mandatory)]
        [pscustomobject[]] $Rules
    )

    $words = @($BareNoun -split '_')

    foreach ($rule in $Rules) {
        foreach ($token in $rule.tokens) {
            $matched = $false
            if ($token.Contains('_')) {
                # Multi-word token: substring match on the full noun with word boundaries.
                $matched = $BareNoun -match ('(^|_)' + [regex]::Escape($token) + '(_|$)')
            }
            else {
                $matched = $token -in $words
            }

            if ($matched) {
                return [pscustomobject] @{ category = $rule.category; token = $token }
            }
        }
    }

    [pscustomobject] @{ category = 'unclassified'; token = $null }
}


function Write-ProviderCategories {
    <#
    .SYNOPSIS
        Writes providers/<slug>/categories.json for every top-level type,
        and categories.unclassified.json only when the rules missed
        something. Presence of the second file is the worklist signal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Address,

        [Parameter(Mandatory)]
        [string] $Slug,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Types,

        [Parameter()]
        [AllowNull()]
        [string] $Prefix,

        # type name -> frontmatter description from the registry docs.
        # Used only as a fallback when the noun alone matches nothing,
        # which is what rescues glued names like workitemtrackingprocess.
        [Parameter()]
        [hashtable] $Descriptions = @{},

        [Parameter(Mandatory)]
        [string] $ProvidersRoot
    )

    $rules   = Get-CategoryRuleSet
    $records = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($t in $Types) {
        if ($t.kind -notin 'resource', 'data_source', 'ephemeral') { continue }

        $noun   = Get-BareNoun -TypeName $t.name -Prefix $Prefix
        $result = Get-TypeCategory -BareNoun $noun -Rules $rules
        $source = 'noun'

        if ($result.category -eq 'unclassified' -and $Descriptions.ContainsKey($t.id)) {
            # Normalise the sentence to the same underscore-word shape the
            # rules expect, then reuse the classifier untouched.
            $words = @(($Descriptions[$t.id].ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -split '\s+' | Where-Object { $_.Length -gt 0 })
            if ($words.Count -gt 0) {
                $descResult = Get-TypeCategory -BareNoun ($words -join '_') -Rules $rules
                if ($descResult.category -ne 'unclassified') {
                    $result = $descResult
                    $source = 'description'
                }
            }
        }

        $records.Add([pscustomobject] @{
            type          = $t.id
            name          = $t.name
            kind          = $t.kind
            bareNoun      = $noun
            category      = $result.category
            matchedOn     = $result.token
            matchedSource = if ($result.category -eq 'unclassified') { $null } else { $source }
            tier          = 4
        })
    }

    $classified    = @($records | Where-Object { $_.category -ne 'unclassified' })
    $byDescription = @($records | Where-Object { $_.matchedSource -eq 'description' })
    $unclassified  = @($records | Where-Object { $_.category -eq 'unclassified' })

    $summary = @{}
    foreach ($r in $records) { $summary[$r.category] = 1 + ($summary[$r.category] ?? 0) }

    $payload = [pscustomobject] @{
        address              = $Address
        slug                 = $Slug
        prefix               = $Prefix
        method               = 'keyword-rules'
        tier                 = 4
        typeCount            = $records.Count
        classifiedCount      = $classified.Count
        classifiedByNoun     = $classified.Count - $byDescription.Count
        classifiedByDescription = $byDescription.Count
        unclassifiedCount    = $unclassified.Count
        summary              = [pscustomobject] $summary
        types                = @($records | Sort-Object category, type)
    }

    $providerDir      = Join-Path $ProvidersRoot $Slug
    $unclassifiedPath = Join-Path $providerDir 'categories.unclassified.json'

    Write-JsonFile -Path (Join-Path $providerDir 'categories.json') -Depth 6 -Object $payload

    if ($unclassified.Count -gt 0) {
        Write-JsonFile -Path $unclassifiedPath -Depth 6 -Object ([pscustomobject] @{
            address = $Address
            slug    = $Slug
            count   = $unclassified.Count
            types   = @($unclassified | Sort-Object type | ForEach-Object {
                [pscustomobject] @{
                    type        = $_.type
                    name        = $_.name
                    kind        = $_.kind
                    bareNoun    = $_.bareNoun
                    description = if ($Descriptions.ContainsKey($_.type)) { $Descriptions[$_.type] } else { $null }
                }
            })
        })
    }
    elseif (Test-Path -LiteralPath $unclassifiedPath) {
        # Presence is the worklist signal, so a now-clean provider must lose the file.
        Remove-Item -LiteralPath $unclassifiedPath -Force
    }

    [pscustomobject] @{
        classifiedCount    = $classified.Count
        byDescriptionCount = $byDescription.Count
        unclassifiedCount  = $unclassified.Count
        records            = $records.ToArray()
    }
}

#endregion classify


#region graph

function ConvertTo-ConceptKey {
    <#
    .SYNOPSIS
        Normalises a bare noun into a cross-provider concept key.

    .DESCRIPTION
        Collapses trivial spelling differences so aws_instance and
        vsphere_virtual_machine do NOT merge (different nouns) but
        aws_security_group and azurerm_security_group do. Only exact
        noun equality after singularising merges - anything smarter is
        a later, flagged, pass.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $BareNoun
    )

    $words = @($BareNoun -split '_' | Where-Object { $_ })
    if ($words.Count -eq 0) { return $BareNoun }

    # Singularise only the last word; earlier words are modifiers.
    $last = $words[-1]
    $singular = @(Get-SingularNoun -Noun $last)[-1]
    $words[-1] = $singular

    $words -join '_'
}


function Write-OntologyGraph {
    <#
    .SYNOPSIS
        Merges every provider's types, edges and categories into one
        Cytoscape.js elements document at out/terraform/graph.json.

    .DESCRIPTION
        Node kinds:
          provider  - one per harvested provider
          type      - one per top-level resource / data source / ephemeral
          concept   - one per bare noun that appears in two or more
                      providers (Tier 4 name-based merge, flagged)

        Edge kinds:
          declared_by  - type -> provider          (Tier 1: the schema says so)
          references   - type -> type              (Tier 2: from registry doc examples,
                                                    Tier 4: inferred from *_id; see `tier`)
          instance_of  - type -> concept           (Tier 4: name-based merge)

        Every node and edge carries `tier` so a renderer can filter on
        warrant, and `category` so it can filter on domain.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Bundles,

        [Parameter(Mandatory)]
        [string] $GraphPath
    )

    $nodes = [System.Collections.Generic.List[pscustomobject]]::new()
    $edges = [System.Collections.Generic.List[pscustomobject]]::new()

    $categoryByType = @{}
    $conceptMembers = @{}   # conceptKey -> list of { id, provider }

    foreach ($b in $Bundles) {
        $nodes.Add([pscustomobject] @{ data = [pscustomobject] @{
            id       = "provider:$($b.slug)"
            kind     = 'provider'
            label    = $b.slug
            address  = $b.address
            version  = $b.version
            tier     = 1
        }})

        foreach ($c in $b.categories) { $categoryByType[$c.type] = $c }
    }

    foreach ($b in $Bundles) {
        foreach ($t in $b.types) {
            if ($t.kind -notin 'resource', 'data_source', 'ephemeral') { continue }

            $cat        = $categoryByType[$t.id]
            $category   = if ($null -ne $cat) { $cat.category } else { 'unclassified' }
            $bareNoun   = if ($null -ne $cat) { $cat.bareNoun } else { $t.name }
            $conceptKey = ConvertTo-ConceptKey -BareNoun $bareNoun

            $attrCount = @($t.attributes).Count
            $hasIdentity = $b.identities.ContainsKey($t.id)

            $nodes.Add([pscustomobject] @{ data = [pscustomobject] @{
                id             = $t.id
                name           = $t.name
                kind           = 'type'
                typeKind       = $t.kind
                label          = $bareNoun
                provider       = $b.slug
                parent         = "provider:$($b.slug)"
                category       = $category
                concept        = $conceptKey
                attributeCount = $attrCount
                childCount     = @($t.children).Count
                hasIdentity    = $hasIdentity
                deprecated     = $t.deprecated
                tier           = 1
            }})

            $edges.Add([pscustomobject] @{ data = [pscustomobject] @{
                id     = "declared_by:$($t.id)"
                source = $t.id
                target = "provider:$($b.slug)"
                kind   = 'declared_by'
                tier   = 1
            }})

            if (-not $conceptMembers.ContainsKey($conceptKey)) {
                $conceptMembers[$conceptKey] = [System.Collections.Generic.List[pscustomobject]]::new()
            }
            $conceptMembers[$conceptKey].Add([pscustomobject] @{ id = $t.id; provider = $b.slug })
        }

        foreach ($e in $b.edges) {
            $edges.Add([pscustomobject] @{ data = [pscustomobject] @{
                id          = "references:$($e.tier):$($e.from):$($e.attribute):$($e.to)"
                source      = $e.from
                target      = $e.to
                kind        = 'references'
                attribute   = $e.attribute
                cardinality = $e.cardinality
                score       = $e.score
                tier        = $e.tier
                evidence    = Get-ObjectProperty -Object $e.evidence -Name 'source' -Default 'schema-inference'
            }})
        }
    }

    # Concepts only earn a node when the same noun shows up in 2+ providers.
    $conceptCount = 0
    foreach ($key in ($conceptMembers.Keys | Sort-Object)) {
        $members   = $conceptMembers[$key]
        $providers = @($members | ForEach-Object { $_.provider } | Select-Object -Unique)
        if ($providers.Count -lt 2) { continue }

        $conceptCount++
        $conceptId = "concept:$key"

        $nodes.Add([pscustomobject] @{ data = [pscustomobject] @{
            id          = $conceptId
            kind        = 'concept'
            label       = $key
            memberCount = $members.Count
            providers   = $providers
            tier        = 4
        }})

        foreach ($m in $members) {
            $edges.Add([pscustomobject] @{ data = [pscustomobject] @{
                id     = "instance_of:$($m.id)"
                source = $m.id
                target = $conceptId
                kind   = 'instance_of'
                tier   = 4
            }})
        }
    }

    # Drop reference edges whose endpoints are not in the node set (data
    # sources pointing at resources is fine; dangling ids are not).
    $nodeIds = @{}
    foreach ($n in $nodes) { $nodeIds[$n.data.id] = $true }
    $validEdges = @($edges | Where-Object { $nodeIds.ContainsKey($_.data.source) -and $nodeIds.ContainsKey($_.data.target) })

    $payload = [pscustomobject] @{
        format       = 'cytoscape-elements'
        generatedAt  = [System.DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        nodeCount    = $nodes.Count
        edgeCount    = $validEdges.Count
        conceptCount = $conceptCount
        elements     = [pscustomobject] @{
            nodes = $nodes.ToArray()
            edges = $validEdges
        }
    }

    $payload |
        ConvertTo-Json -Depth 8 |
        Format-JsonText |
        Set-Content -LiteralPath $GraphPath -Encoding utf8NoBOM

    [pscustomobject] @{
        nodeCount    = $nodes.Count
        edgeCount    = $validEdges.Count
        conceptCount = $conceptCount
    }
}

#endregion graph

#endregion harvest


#region main

try {

$startedAt = [System.DateTimeOffset]::UtcNow

$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
Write-Verbose "Working directory: $WorkingDirectory"

$terraformDir = Join-Path $WorkingDirectory '.terraform'
if (-not (Test-Path -LiteralPath $terraformDir)) {
    throw "No .terraform directory in $WorkingDirectory. Run 'terraform init' there first."
}

$paths        = Initialize-OutputTree -OutputRoot $OutputRoot -Clean:$Clean
$lockFilePath = Join-Path $WorkingDirectory '.terraform.lock.hcl'

# --- resolve what this run is allowed to skip -------------------------------
$forceSchema = ($From -eq 'harvest')
$docsMode    = 'auto'
if     ($SkipDocs)                         { $docsMode = 'skip'  }
elseif ($ForceDocs -or $From -eq 'docs')   { $docsMode = 'force' }
elseif ($From -eq 'flatten')               { $docsMode = 'skip'  }

Write-Host ('Mode: from={0} schema={1} docs={2}' -f $From, ($forceSchema ? 'force' : 'cache-if-valid'), $docsMode)

$dump       = Get-SchemaDump -WorkingDirectory $WorkingDirectory -Paths $paths -LockFilePath $lockFilePath -Force:$forceSchema
$rawCompact = $dump.compact
$rawSha256  = $dump.sha256
$terraformVersion = $dump.terraformVersion

$readerOptions = [System.Text.Json.JsonDocumentOptions]::new()
$readerOptions.MaxDepth = 4096

$document = [System.Text.Json.JsonDocument]::Parse($rawCompact, $readerOptions)
$entries  = [System.Collections.Generic.List[pscustomobject]]::new()
$bundles  = [System.Collections.Generic.List[pscustomobject]]::new()

try {
    $providerSchemas = [System.Text.Json.JsonElement]::new()
    if (-not $document.RootElement.TryGetProperty('provider_schemas', [ref] $providerSchemas)) {
        throw 'No provider_schemas key in the Terraform output. Nothing to harvest.'
    }

    foreach ($provider in $providerSchemas.EnumerateObject()) {
        $address = $provider.Name
        $version = Get-LockedVersion -LockFilePath $lockFilePath -Address $address

        $result = Write-ProviderRecord `
            -Address       $address `
            -Schema        $provider.Value `
            -ProvidersRoot $paths.Providers `
            -Version       $version `
            -DocsMode      $docsMode `
            -DocThrottleMs $DocThrottleMs

        $entry = $result.entry
        $entries.Add($entry)
        $bundles.Add($result.bundle)

        Write-Host ('  {0,-30} {1,4} res {2,4} data {3,5} types {4,3} ident {5,4} edges ({6} doc) {7,4} unclassified  docs:{8}' -f `
            $entry.slug, $entry.resourceCount, $entry.dataSourceCount, $entry.typeCount, $entry.identityCount, $entry.edgeCount, $entry.docEdgeCount, $entry.unclassifiedCount, ($entry.docsFetchedThisRun ? 'fetched' : $entry.docsSkipReason))
    }
}
finally {
    $document.Dispose()
}

$graph = Write-OntologyGraph -Bundles $bundles.ToArray() -GraphPath $paths.Graph
Write-Host ('Graph: {0} nodes, {1} edges, {2} shared concepts' -f $graph.nodeCount, $graph.edgeCount, $graph.conceptCount)

$index = [pscustomobject] @{
    harvestedAt      = $startedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
    terraformVersion = $terraformVersion
    schemaFromCache  = $dump.fromCache
    rawFile          = 'raw/providers-schema.json'
    rawMetaFile      = 'raw/providers-schema.meta.json'
    rawSha256        = $rawSha256
    graphFile        = 'graph.json'
    graphNodeCount   = $graph.nodeCount
    graphEdgeCount   = $graph.edgeCount
    conceptCount     = $graph.conceptCount
    providerCount    = $entries.Count
    resourceTotal    = ($entries | Measure-Object -Property resourceCount -Sum).Sum
    dataSourceTotal  = ($entries | Measure-Object -Property dataSourceCount -Sum).Sum
    docTotal         = ($entries | Measure-Object -Property docCount -Sum).Sum
    docEdgeTotal     = ($entries | Measure-Object -Property docEdgeCount -Sum).Sum
    docsFetchedThisRun = @($entries | Where-Object docsFetchedThisRun | ForEach-Object slug | Sort-Object)
    docsMissing      = @($entries | Where-Object { $_.docCount -eq 0 } | ForEach-Object slug | Sort-Object)
    unclassifiedTotal = ($entries | Measure-Object -Property unclassifiedCount -Sum).Sum
    needsClassification = @($entries | Where-Object needsClassification | ForEach-Object slug | Sort-Object)
    providers        = @($entries | Sort-Object slug)
}

Write-JsonFile -Path $paths.Index -Depth 8 -Object $index

$elapsed = [System.DateTimeOffset]::UtcNow - $startedAt

Write-Host ''
Write-Host ('Harvested {0} providers, {1} resources, {2} data sources, {3} docs in {4:N1}s' -f `
    $index.providerCount, $index.resourceTotal, $index.dataSourceTotal, $index.docTotal, $elapsed.TotalSeconds)
Write-Host "Output: $($paths.Root)"

}
catch {
    # Surface everything a caller (or an agent) needs to locate the fault
    # without having to re-run under a debugger.
    $record = $_
    Write-Host ''
    Write-Host '=== terraform.schema.build.ps1 FAILED ===' -ForegroundColor Red
    Write-Host ('Message   : {0}' -f $record.Exception.Message)
    Write-Host ('Type      : {0}' -f $record.Exception.GetType().FullName)
    Write-Host ('Category  : {0}' -f $record.CategoryInfo.Category)
    Write-Host ('Target    : {0}' -f $record.TargetObject)
    Write-Host ('Position  : {0}' -f $record.InvocationInfo.PositionMessage.Trim())
    Write-Host 'Stack     :'
    Write-Host ($record.ScriptStackTrace -replace '(?m)^', '    ')
    if ($null -ne $record.Exception.InnerException) {
        Write-Host ('Inner     : {0}' -f $record.Exception.InnerException.Message)
    }
    throw
}

#endregion main