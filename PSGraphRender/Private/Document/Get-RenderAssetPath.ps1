function Get-RenderAssetPath {
    <#
    .SYNOPSIS
        Resolves the full path of a file shipped alongside the module.
    .DESCRIPTION
        Resolves against $script:ModuleRoot, which both the dev loader and the
        generated .psm1 set at import time. Never use $PSScriptRoot here: it is
        per-file, so it points at Private/Html under the dev loader but at the
        module root in the built module. One of those would silently be wrong.

        Split out from Get-RenderAsset so that assets which are parsed
        rather than read as text - the .psd1 config files go through
        Import-PowerShellDataFile, which needs a path - share exactly one copy
        of this resolution and one error message.
    .PARAMETER Name
        Asset path relative to the module root, e.g.
        'TemplateSets/<name>/Config/theme.psd1' or 'TemplateSets'.
    .PARAMETER PathType
        Whether Name is expected to be a file or a directory. Template sets are
        directories, so both are legitimate here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter()]
        [ValidateSet('Leaf', 'Container')]
        [string] $PathType = 'Leaf'
    )

    if (-not (Get-Variable -Name ModuleRoot -Scope Script -ErrorAction SilentlyContinue) -or
        -not $script:ModuleRoot) {
        throw '$script:ModuleRoot is not set. Both PSGraphRender.psm1 loaders must set it at import time.'
    }

    $assetPath = Join-Path $script:ModuleRoot $Name

    if (-not (Test-Path -LiteralPath $assetPath -PathType $PathType)) {
        throw ("Asset '$Name' not found at '$assetPath'. " +
            'The most likely cause is a stale or incomplete build that did not copy the ' +
            'TemplateSets directory into the module output. Re-run ./build.ps1.')
    }

    $assetPath
}
