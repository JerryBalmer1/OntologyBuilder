function Resolve-RenderTemplateSetPath {
    <#
    .SYNOPSIS
        The one place that answers "where does backend N live".
    .DESCRIPTION
        Three functions used to hardcode `TemplateSets/cytoscape` and
        `TemplateSets/cytoscape/Config` independently, and nothing made them
        agree. That was invisible while Config/ and Templates/ were siblings and
        configuration was module-level; making configuration per-backend made a
        second backend three .ps1 edits, which is the rule that pays for the
        config split, failing.

        A backend's location is stated here and nowhere else. Everything that
        needs a part of one derives it from what this returns.

        Discovery is enumerating directories under TemplateSets/ that contain a
        templateset.psd1. There is no registry to add to: a backend is a
        directory. The default name comes from TemplateSets/index.psd1, so
        changing it is a data edit.
    .PARAMETER Name
        Backend directory name. Defaults to whatever index.psd1 names.
    .OUTPUTS
        The full path of the backend directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string] $Name
    )

    $root = Get-RenderAssetPath -Name 'TemplateSets' -PathType Container

    if (-not $Name) {
        $index = Import-RenderDataFile -Path (Join-Path $root 'index.psd1') -Label 'index.psd1'
        $Name = [string](Get-HashtableValue -InputObject $index -Key 'Default')
        if (-not $Name) {
            throw ("No default template set. '$(Join-Path $root 'index.psd1')' must name one as " +
                "Default, or the caller must pass -Name.")
        }
    }

    $candidate = Join-Path $root $Name
    if (Test-Path -LiteralPath (Join-Path $candidate 'templateset.psd1') -PathType Leaf) {
        return $candidate
    }

    # Name what is actually available rather than only what was asked for. A
    # missing backend is nearly always a typo or a build that did not copy the
    # directory, and both are answered by the list.
    $available = @(Get-RenderTemplateSetName -Root $root)
    $known = if ($available.Count) { $available -join ', ' } else { '(none found)' }
    throw ("Template set '$Name' not found under '$root'. A template set is a directory " +
        "containing templateset.psd1. Available: $known.")
}

function Get-RenderTemplateSetName {
    <#
    .SYNOPSIS
        The backends that exist, discovered rather than registered.
    .PARAMETER Root
        The TemplateSets directory. Defaults to the module's own.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [string] $Root
    )

    if (-not $Root) { $Root = Get-RenderAssetPath -Name 'TemplateSets' -PathType Container }

    @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'templateset.psd1') -PathType Leaf } |
            Select-Object -ExpandProperty Name |
            Sort-Object)
}
