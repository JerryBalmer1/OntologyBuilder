function Resolve-RenderString {
    <#
    .SYNOPSIS
        Loads the renderer's user-visible strings and fills caller-supplied tokens.
    .DESCRIPTION
        See docs/render-architecture.md. strings.psd1 is the fourth data file and
        is deliberately outside settings.schema.psd1: the schema exists to type
        and range-check values, and a schema entry per string would hold a
        Default that is a second copy of the string itself.

        Caller-supplied values are merged over the file and then substituted
        into every string as {token}. Only caller tokens are filled here.
        Anything the browser knows at display time - a count, a name - is left
        as written for the page to fill, and a token nobody fills stays visible
        rather than collapsing to nothing.

        This is where the seam is paid for: the name of a command belonging to
        whatever program generated the report arrives as a value, so nothing
        below the seam has to know what that program is.
    .PARAMETER TemplateSetPath
        The backend directory. Its Config/ is where strings.psd1 lives, appended
        here rather than passed in, so a caller states a backend's location once
        and every consumer derives its own part of it.
    .PARAMETER Name
        A backend shipped with the module, by directory name. Defaults to
        whatever TemplateSets/index.psd1 names. Ignored when -TemplateSetPath is
        given.
    .PARAMETER Value
        Caller-supplied strings, merged over the file and substituted as tokens.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()]
        [string] $TemplateSetPath,

        [Parameter()]
        [string] $Name,

        [Parameter()]
        [ValidateNotNull()]
        [hashtable] $Value = @{}
    )

    if (-not $TemplateSetPath) { $TemplateSetPath = Resolve-RenderTemplateSetPath -Name $Name }
    $ConfigPath = Join-Path $TemplateSetPath 'Config'

    $supplied = Import-RenderDataFile -Path (Join-Path $ConfigPath 'strings.psd1') -Label 'strings.psd1'

    $merged = [ordered]@{}
    foreach ($key in ($supplied.Keys | Sort-Object)) { $merged[$key] = [string]$supplied[$key] }
    foreach ($key in ($Value.Keys | Sort-Object)) { $merged[$key] = [string]$Value[$key] }

    $resolved = [ordered]@{}
    foreach ($key in $merged.Keys) {
        $text = $merged[$key]
        foreach ($token in $Value.Keys) {
            # [string]::Replace, never the -replace operator. -replace is regex,
            # and a string may carry '$' or '\' that the engine would treat as a
            # substitution pattern and eat. See docs/development.md.
            $text = $text.Replace('{' + $token + '}', [string]$Value[$token])
        }
        $resolved[$key] = $text
    }

    $resolved
}
