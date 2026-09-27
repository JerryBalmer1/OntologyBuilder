function Get-RenderAsset {
    <#
    .SYNOPSIS
        Returns the raw text of an asset shipped alongside the module.
    .DESCRIPTION
        Path resolution and its error message live in Get-RenderAssetPath,
        shared with the assets that are parsed rather than read as text.

        Assets are UTF-8 and are read verbatim with -Raw.
    .PARAMETER Name
        Asset path relative to the module root, e.g.
        'TemplateSets/<name>/layout.html'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    Get-Content -LiteralPath (Get-RenderAssetPath -Name $Name) -Raw -Encoding UTF8
}
