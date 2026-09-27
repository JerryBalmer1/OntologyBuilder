function Resolve-RenderConfiguration {
    <#
    .SYNOPSIS
        Merges and validates the report renderer's configuration.
    .DESCRIPTION
        See docs/render-architecture.md. Reads settings.schema.psd1 for types,
        defaults and constraints, then settings.psd1 and theme.psd1 for values.
        Validation is dispatched from each entry's Type, so adding a setting is
        a data change.

        Anything missing, mistyped, out of range, or misplaced falls back with a
        warning naming the key: one bad edit degrades one setting rather than
        failing the export. A file that will not parse at all warns and falls
        back whole.
    .PARAMETER TemplateSetPath
        The backend directory. Its Config/ is where the three data files live,
        appended here rather than passed in, so a caller states a backend's
        location once and every consumer derives its own part of it.
    .PARAMETER Name
        A backend shipped with the module, by directory name. Defaults to
        whatever TemplateSets/index.psd1 names. Ignored when -TemplateSetPath is
        given.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()]
        [string] $TemplateSetPath,

        [Parameter()]
        [string] $Name
    )

    if (-not $TemplateSetPath) { $TemplateSetPath = Resolve-RenderTemplateSetPath -Name $Name }
    $ConfigPath = Join-Path $TemplateSetPath 'Config'

    $schema = Import-RenderDataFile -Path (Join-Path $ConfigPath 'settings.schema.psd1') -Label 'schema'
    $entries = Get-HashtableValue -InputObject $schema -Key 'Entries' -Default @{}
    if (-not $entries.Keys.Count) {
        throw "No settings schema found at '$(Join-Path $ConfigPath 'settings.schema.psd1')'."
    }

    $values = [ordered]@{}
    $origin = @{}
    foreach ($file in @{ Name = 'settings.psd1'; In = 'Settings' }, @{ Name = 'theme.psd1'; In = 'Theme' }) {
        $supplied = Import-RenderDataFile -Path (Join-Path $ConfigPath $file.Name) -Label $file.Name
        foreach ($key in $supplied.Keys) {
            $values[$key] = $supplied[$key]
            $origin[$key] = $file.In
        }
    }

    $resolved = [ordered]@{}
    foreach ($key in ($entries.Keys | Sort-Object)) {
        $entry = $entries[$key]
        $default = Get-HashtableValue -InputObject $entry -Key 'Default'

        if (-not $values.Contains($key)) {
            $resolved[$key] = $default
            continue
        }

        $expectedIn = Get-HashtableValue -InputObject $entry -Key 'In'
        if ($expectedIn -and $origin[$key] -ne $expectedIn) {
            Write-Warning ("Setting '$key' belongs in the $expectedIn file but was found in the " +
                "$($origin[$key]) file. Applying it anyway.")
        }

        $result = Test-RenderSettingValue -Value $values[$key] -Entry $entry
        if ($result.IsValid) {
            $resolved[$key] = $result.Value
        }
        else {
            Write-Warning "Setting '$key': $($result.Reason). Using $default."
            $resolved[$key] = $default
        }
    }

    foreach ($key in $values.Keys) {
        if (-not $entries.Contains($key)) {
            Write-Warning "Unknown setting '$key' was ignored. It is not in settings.schema.psd1."
        }
    }

    $constraints = Get-HashtableValue -InputObject $schema -Key 'Constraints' -Default @()
    Invoke-RenderConfigurationConstraint -Configuration $resolved -Constraints $constraints -Entries $entries

    $resolved
}
