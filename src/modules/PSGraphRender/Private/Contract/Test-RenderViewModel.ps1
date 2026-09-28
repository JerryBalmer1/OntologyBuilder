function Get-RenderContractPath {
    <#
    .SYNOPSIS
        Where contract/viewmodel.schema.json is, wherever the module is loaded
        from.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Get-RenderAssetPath -Name 'contract/viewmodel.schema.json'
}

function Get-RenderContractVersion {
    <#
    .SYNOPSIS
        The contract version this renderer implements.
    .DESCRIPTION
        Read out of the schema's own $id or its version property rather than
        written here, so there is one place the number lives. The contract
        versions independently of the module: 1.0.0 while PSGraphRender is
        0.3.0, because the contract is the product and the module is one
        implementation of it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Get-Variable, not a bare read. Set-StrictMode -Version Latest THROWS on an
    # unset $script: variable rather than yielding $null, so the obvious cache
    # check fails on the first call every time.
    $cached = Get-Variable -Name RenderContractVersion -Scope Script -ErrorAction SilentlyContinue
    if (-not $cached -or -not $cached.Value) {
        $schema = Get-Content -LiteralPath (Get-RenderContractPath) -Raw | ConvertFrom-Json
        $version = Get-HashtableValue -InputObject $schema -Key 'version'
        if (-not $version) { $version = '1.0.0' }
        $script:RenderContractVersion = [string]$version
    }

    $script:RenderContractVersion
}

function Test-RenderViewModel {
    <#
    .SYNOPSIS
        Checks a view model against contract/viewmodel.schema.json.
    .DESCRIPTION
        The answer to a shape assumption living in a backend script. `plain`
        reads DATA.nodes and DATA.links directly; that is only safe if something
        guarantees they are there, and this is that something.

        THREE outcomes, not two. Test-Json gained -SchemaFile in PowerShell 6,
        so on Windows PowerShell 5.1 there is no schema validation in the box
        and this reports IsValid as $null with the reason. "Could not check" and
        "checked and passed" are different facts, and returning the second for
        the first is how an invalid payload reaches a reader. The same call was
        made in PSModuleGraph's Test-KnowledgeDocument, for the same reason.
    .PARAMETER InputObject
        A view model document: an object with meta and data.
    .PARAMETER SchemaPath
        Defaults to the shipped contract.
    .OUTPUTS
        IsValid as $true, $false, or $null when validation was unavailable.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $InputObject,

        [Parameter()]
        [string] $SchemaPath
    )

    if (-not $SchemaPath) { $SchemaPath = Get-RenderContractPath }

    if (-not (Test-Path -LiteralPath $SchemaPath)) {
        return [pscustomobject]@{ IsValid = $null; Reason = "no schema at '$SchemaPath'" }
    }

    $testJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if (-not $testJson -or -not $testJson.Parameters.ContainsKey('SchemaFile')) {
        return [pscustomobject]@{
            IsValid = $null
            Reason  = 'Test-Json has no -SchemaFile on this host; schema validation needs PowerShell 6 or later'
        }
    }

    try {
        $json = $InputObject | ConvertTo-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ IsValid = $false; Reason = "could not serialise: $($_.Exception.Message)" }
    }

    try {
        $json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop | Out-Null
        [pscustomobject]@{ IsValid = $true; Reason = $null }
    }
    catch {
        [pscustomobject]@{ IsValid = $false; Reason = $_.Exception.Message }
    }
}

function Resolve-RenderMeta {
    <#
    .SYNOPSIS
        Reads the current meta field names, falling back to the ones they
        replaced, and warns once naming both.
    .DESCRIPTION
        NAMING.md's one rule: a rename never deletes. A payload written against
        an older contract keeps working, and the reader is told what to change
        rather than discovering it when a heading goes blank.

        Warns ONCE per render, listing every field at once. One warning per
        field would be four lines for one out-of-date producer, which is how a
        warning becomes noise and then becomes ignored.
    .PARAMETER Meta
        The caller's meta block. May be $null.
    .OUTPUTS
        An ordered dictionary using the current names.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()]
        $Meta
    )

    # current name -> the name it replaced, and when.
    $renamed = [ordered]@{
        title    = @{ Was = 'moduleName'; Since = '1.0.0' }
        version  = @{ Was = 'moduleVersion'; Since = '1.0.0' }
        rootPath = @{ Was = 'moduleRoot'; Since = '1.0.0' }
    }

    # A dictionary and a PSCustomObject are BOTH ordinary things for a caller to
    # hand over, and they enumerate differently. Reading .PSObject.Properties off
    # an [ordered]@{} yields Count, Keys, Values and IsReadOnly - the dictionary's
    # own members, not its entries - and the render succeeds with all four
    # embedded in meta. It did, for exactly one build.
    $resolved = [ordered]@{}
    if ($null -ne $Meta) {
        if ($Meta -is [System.Collections.IDictionary]) {
            foreach ($key in $Meta.Keys) { $resolved[[string]$key] = $Meta[$key] }
        }
        else {
            foreach ($property in $Meta.PSObject.Properties) {
                $resolved[$property.Name] = $property.Value
            }
        }
    }

    $stale = @()
    foreach ($current in $renamed.Keys) {
        $old = $renamed[$current].Was

        $hasCurrent = $resolved.Contains($current) -and $null -ne $resolved[$current] -and "$($resolved[$current])".Length
        $hasOld = $resolved.Contains($old) -and $null -ne $resolved[$old] -and "$($resolved[$old])".Length

        if (-not $hasCurrent -and $hasOld) {
            $resolved[$current] = $resolved[$old]
            $stale += "$old -> $current (since $($renamed[$current].Since))"
        }

        # The old name travels no further than here. It stays valid on the way
        # IN, which is what the rule requires; carrying it into the document as
        # well would mean every backend still has to know both.
        if ($resolved.Contains($old)) { $resolved.Remove($old) }
    }

    if ($stale.Count) {
        Write-Warning ("View model uses field names replaced in the contract: $($stale -join '; '). " +
            'They still work and will keep working. See contract/viewmodel.schema.json.')
    }

    $resolved
}

function Assert-RenderContractVersion {
    <#
    .SYNOPSIS
        Refuses a payload declaring a contract major this renderer does not
        implement, by name.
    .DESCRIPTION
        A renderer that quietly tolerates a payload it does not understand
        teaches producers to emit payloads nobody understands. A missing
        contractVersion is treated as the version before the field existed and
        warned about, not refused - refusing it would break every payload
        written before the contract did.
    .PARAMETER Meta
        Resolved meta block.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Meta
    )

    $implemented = Get-RenderContractVersion
    $implementedMajor = [int]($implemented -split '\.')[0]

    $declared = $null
    if ($null -ne $Meta) { $declared = Get-HashtableValue -InputObject $Meta -Key 'contractVersion' }

    if (-not $declared) {
        Write-Warning ("View model declares no meta.contractVersion. Rendering it as $implemented. " +
            'A payload that does not say which contract it was written against cannot be refused when it is wrong.')
        return
    }

    if ($declared -notmatch '^\d+\.\d+\.\d+$') {
        throw "meta.contractVersion is '$declared', which is not a version. Expected something like '$implemented'."
    }

    $declaredMajor = [int]($declared -split '\.')[0]
    if ($declaredMajor -ne $implementedMajor) {
        throw ("View model declares contract $declared and this renderer implements $implemented. " +
            "Major $declaredMajor is not major $implementedMajor, so the shapes are not the same shape. " +
            'Refusing rather than rendering on a guess.')
    }
}
