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
        raw/providers-schema.json
        providers/<slug>/schema.json
        providers/<slug>/types.json
        providers/<slug>/links.json

    Provider slug rule:
        Full provider source address
          -> drop the "registry.terraform.io/" prefix
          -> replace remaining "/" with "_"
          -> lowercase
        e.g. registry.terraform.io/hashicorp/aws -> hashicorp_aws
             registry.terraform.io/vmware/vsphere -> vmware_vsphere
             registry.terraform.io/DataDog/datadog -> datadog_datadog
        A non-default registry host becomes the first segment with "." -> "-".

    The output root is deleted and recreated on every run. This is intended to
    be run over and over while the layout is being worked out.

.NOTES
    Runs locally for now. Terraform init is expected to have already been run
    in the working directory. Moves into the container once the shape settles.
#>

[CmdletBinding()]
param(
    # Directory containing main.tf and an initialised .terraform directory.
    [Parameter()]
    [string] $WorkingDirectory = $PSScriptRoot,

    # Root of the harvest output tree. Deleted and recreated on every run.
    [Parameter()]
    [string] $OutputRoot = (Join-Path $PSScriptRoot 'out' 'terraform')
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
        Deletes and recreates the output root. Destructive on purpose.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $OutputRoot
    )

    if (Test-Path -LiteralPath $OutputRoot) {
        if ($PSCmdlet.ShouldProcess($OutputRoot, 'Remove existing output tree')) {
            Write-Verbose "Removing existing output tree at $OutputRoot"
            Remove-Item -LiteralPath $OutputRoot -Recurse -Force
        }
    }

    $paths = @{
        Root      = $OutputRoot
        Raw       = Join-Path $OutputRoot 'raw'
        Providers = Join-Path $OutputRoot 'providers'
        Index     = Join-Path $OutputRoot 'index.json'
    }

    foreach ($key in 'Root', 'Raw', 'Providers') {
        $null = New-Item -Path $paths[$key] -ItemType Directory -Force
    }

    $paths
}


function Write-ProviderRecord {
    <#
    .SYNOPSIS
        Writes one provider's schema.json and returns its index entry.
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
        [string] $Version
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

    $types = Write-ProviderTypes -Address $Address -Slug $slug -Schema $Schema -ProvidersRoot $ProvidersRoot
    $links = Write-ProviderLinks -Address $Address -Slug $slug -Schema $Schema -Types $types -ProvidersRoot $ProvidersRoot

    [pscustomobject] @{
        address            = $Address
        slug               = $slug
        version            = $Version
        file               = "providers/$slug/schema.json"
        typesFile          = "providers/$slug/types.json"
        typeCount          = $types.Count
        linksFile          = "providers/$slug/links.json"
        identityCount      = $links.identityCount
        edgeCount          = $links.edgeCount
        sha256             = $hash
        resourceCount      = Get-ElementPropertyCount -Parent $Schema -Name 'resource_schemas'
        dataSourceCount    = Get-ElementPropertyCount -Parent $Schema -Name 'data_source_schemas'
        functionCount      = Get-ElementPropertyCount -Parent $Schema -Name 'functions'
        ephemeralCount     = Get-ElementPropertyCount -Parent $Schema -Name 'ephemeral_resource_schemas'
        identitySchemaCount = Get-ElementPropertyCount -Parent $Schema -Name 'resource_identity_schemas'
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
        nestedType  = $NestedTypeId
        required    = Get-OptionalBool -Parent $Attribute -Name 'required'
        optional    = Get-OptionalBool -Parent $Attribute -Name 'optional'
        computed    = Get-OptionalBool -Parent $Attribute -Name 'computed'
        sensitive   = Get-OptionalBool -Parent $Attribute -Name 'sensitive'
        deprecated  = Get-OptionalBool -Parent $Attribute -Name 'deprecated'
        description = Get-OptionalString -Parent $Attribute -Name 'description'
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
        aws_instance/root_block_device/tags.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

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
                -Kind        'block' `
                -Block       $childBlock `
                -Parent      $Id `
                -NestingMode (Get-OptionalString -Parent $property.Value -Name 'nesting_mode')

            foreach ($r in $childRecords) { $records.Add($r) }
        }
    }

    $self = [pscustomobject] @{
        id          = $Id
        kind        = $Kind
        parent      = $Parent
        nestingMode = $NestingMode
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

        $flat = ConvertTo-FlatType -Id $entry.Name -Kind $Kind -Block $block -Parent $null -NestingMode $null
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
        $token = ($t.id -split '_')[0]
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
        while ($null -ne $owner.parent) { $owner = $byId[$owner.parent] }

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

        [Parameter(Mandatory)]
        [string] $ProvidersRoot
    )

    $prefix      = Get-ProviderPrefix -Types $Types
    $identityMap = Get-IdentityMap -Schema $Schema
    $edges       = Get-InferredEdge -Types $Types -IdentityMap $identityMap -Prefix $prefix

    $identities = foreach ($key in ($identityMap.Keys | Sort-Object)) {
        [pscustomobject] @{
            type       = $key
            tier       = 1
            attributes = $identityMap[$key]
        }
    }

    $payload = [pscustomobject] @{
        address       = $Address
        slug          = $Slug
        prefix        = $prefix
        identityCount = $identityMap.Count
        edgeCount     = $edges.Count
        identities    = @($identities)
        edges         = @($edges | Sort-Object from, attribute)
    }

    $linksPath = Join-Path $ProvidersRoot $Slug 'links.json'

    $payload |
        ConvertTo-Json -Depth 6 |
        Format-JsonText |
        Set-Content -LiteralPath $linksPath -Encoding utf8NoBOM

    [pscustomobject] @{
        identityCount = $identityMap.Count
        edgeCount     = $edges.Count
    }
}

#endregion links

#endregion harvest


#region main

$startedAt = [System.DateTimeOffset]::UtcNow

$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
Write-Verbose "Working directory: $WorkingDirectory"

$terraformDir = Join-Path $WorkingDirectory '.terraform'
if (-not (Test-Path -LiteralPath $terraformDir)) {
    throw "No .terraform directory in $WorkingDirectory. Run 'terraform init' there first."
}

$paths = Initialize-OutputTree -OutputRoot $OutputRoot

Write-Host 'Running terraform providers schema -json ...'
$rawCompact = Get-TerraformSchemaJson -WorkingDirectory $WorkingDirectory
$rawSha256  = Get-Sha256Hex -Text $rawCompact

Write-Host ('Raw dump: {0:N1} MB, sha256 {1}' -f ($rawCompact.Length / 1MB), $rawSha256.Substring(0, 16))

$rawPath = Join-Path $paths.Raw 'providers-schema.json'
$rawCompact | Format-JsonText | Set-Content -LiteralPath $rawPath -Encoding utf8NoBOM

$lockFilePath    = Join-Path $WorkingDirectory '.terraform.lock.hcl'
$terraformVersion = Get-TerraformVersion -WorkingDirectory $WorkingDirectory

$readerOptions = [System.Text.Json.JsonDocumentOptions]::new()
$readerOptions.MaxDepth = 4096

$document = [System.Text.Json.JsonDocument]::Parse($rawCompact, $readerOptions)
$entries  = [System.Collections.Generic.List[pscustomobject]]::new()

try {
    $providerSchemas = [System.Text.Json.JsonElement]::new()
    if (-not $document.RootElement.TryGetProperty('provider_schemas', [ref] $providerSchemas)) {
        throw 'No provider_schemas key in the Terraform output. Nothing to harvest.'
    }

    foreach ($provider in $providerSchemas.EnumerateObject()) {
        $address = $provider.Name
        $version = Get-LockedVersion -LockFilePath $lockFilePath -Address $address

        $entry = Write-ProviderRecord `
            -Address       $address `
            -Schema        $provider.Value `
            -ProvidersRoot $paths.Providers `
            -Version       $version

        $entries.Add($entry)

        Write-Host ('  {0,-36} {1,5} res {2,5} data {3,6} types {4,4} ident {5,5} edges' -f $entry.slug, $entry.resourceCount, $entry.dataSourceCount, $entry.typeCount, $entry.identityCount, $entry.edgeCount)
    }
}
finally {
    $document.Dispose()
}

$index = [pscustomobject] @{
    harvestedAt      = $startedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
    terraformVersion = $terraformVersion
    rawFile          = 'raw/providers-schema.json'
    rawSha256        = $rawSha256
    providerCount    = $entries.Count
    resourceTotal    = ($entries | Measure-Object -Property resourceCount -Sum).Sum
    dataSourceTotal  = ($entries | Measure-Object -Property dataSourceCount -Sum).Sum
    providers        = @($entries | Sort-Object slug)
}

$index |
    ConvertTo-Json -Depth 8 |
    Format-JsonText |
    Set-Content -LiteralPath $paths.Index -Encoding utf8NoBOM

$elapsed = [System.DateTimeOffset]::UtcNow - $startedAt

Write-Host ''
Write-Host ('Harvested {0} providers, {1} resources, {2} data sources in {3:N1}s' -f `
    $index.providerCount, $index.resourceTotal, $index.dataSourceTotal, $elapsed.TotalSeconds)
Write-Host "Output: $($paths.Root)"

#endregion main