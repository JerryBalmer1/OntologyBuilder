function Invoke-RenderConfigurationConstraint {
    <#
    .SYNOPSIS
        Applies the schema's declared cross-field rules in place.
    .DESCRIPTION
        Single-key validation cannot catch a pair that is individually valid and
        jointly nonsense - a slider whose value sits outside its own range, or a
        panel that starts narrower than it can be dragged. The rules are data;
        see docs/render-architecture.md.
    .PARAMETER Configuration
        The resolved configuration, modified in place.
    .PARAMETER Constraints
        The schema's Constraints array.
    .PARAMETER Entries
        The schema's Entries, for falling back to a declared default.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Configuration,

        [Parameter()]
        [AllowNull()]
        $Constraints,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Entries
    )

    foreach ($constraint in @($Constraints)) {
        if ($null -eq $constraint) { continue }
        $rule = Get-HashtableValue -InputObject $constraint -Key 'Rule'

        switch ($rule) {

            'LessThan' {
                $left = Get-HashtableValue -InputObject $constraint -Key 'Left'
                $right = Get-HashtableValue -InputObject $constraint -Key 'Right'
                if (-not $Configuration.Contains($left) -or -not $Configuration.Contains($right)) { break }
                if ($Configuration[$left] -lt $Configuration[$right]) { break }

                Write-Warning ("$left ($($Configuration[$left])) is not below $right " +
                    "($($Configuration[$right])); using the built-in range.")
                $Configuration[$left] = (Get-HashtableValue -InputObject $Entries -Key $left -Default @{}).Default
                $Configuration[$right] = (Get-HashtableValue -InputObject $Entries -Key $right -Default @{}).Default
            }

            'Between' {
                $value = Get-HashtableValue -InputObject $constraint -Key 'Value'
                $minKey = Get-HashtableValue -InputObject $constraint -Key 'Min'
                $maxKey = Get-HashtableValue -InputObject $constraint -Key 'Max'
                foreach ($k in $value, $minKey, $maxKey) {
                    if (-not $Configuration.Contains($k)) { return }
                }
                $low = $Configuration[$minKey]
                $high = $Configuration[$maxKey]
                if ($Configuration[$value] -ge $low -and $Configuration[$value] -le $high) { break }

                Write-Warning "$value ($($Configuration[$value])) is outside $low..$high; clamping."
                $Configuration[$value] = [Math]::Min([Math]::Max($Configuration[$value], $low), $high)
            }

            'AtLeast' {
                $value = Get-HashtableValue -InputObject $constraint -Key 'Value'
                $floorKey = Get-HashtableValue -InputObject $constraint -Key 'Floor'
                if (-not $Configuration.Contains($value) -or -not $Configuration.Contains($floorKey)) { break }
                if ($Configuration[$value] -ge $Configuration[$floorKey]) { break }

                Write-Warning ("$value ($($Configuration[$value])) is below $floorKey " +
                    "($($Configuration[$floorKey])); using $floorKey.")
                $Configuration[$value] = $Configuration[$floorKey]
            }

            default {
                Write-Warning "Schema declares unknown constraint rule '$rule'; ignored."
            }
        }
    }
}
