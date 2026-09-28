function Test-RenderSettingValue {
    <#
    .SYNOPSIS
        Validates one configuration value against its schema entry.
    .DESCRIPTION
        One validator per type, dispatched from the entry's Type. See
        docs/render-architecture.md.
    .PARAMETER Value
        The value as read from the data file.
    .PARAMETER Entry
        The schema entry: Type, and whichever of Min, Max and Values apply.
    .OUTPUTS
        A record with IsValid, Value (coerced) and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Entry
    )

    function New-Result {
        param([bool] $Ok, $Coerced, [string] $Why)
        [pscustomobject]@{ IsValid = $Ok; Value = $Coerced; Reason = $Why }
    }

    $type = Get-HashtableValue -InputObject $Entry -Key 'Type' -Default 'Number'
    $min = Get-HashtableValue -InputObject $Entry -Key 'Min'
    $max = Get-HashtableValue -InputObject $Entry -Key 'Max'

    switch ($type) {

        { $_ -in 'Number', 'Integer' } {
            $number = $Value -as [double]
            if ($null -eq $number) {
                return New-Result $false $null "'$Value' is not a number"
            }
            if ($type -eq 'Integer' -and [Math]::Floor($number) -ne $number) {
                return New-Result $false $null "$number is not a whole number"
            }
            if ($null -ne $min -and $number -lt $min) {
                return New-Result $false $null "$number is below the minimum of $min"
            }
            if ($null -ne $max -and $number -gt $max) {
                return New-Result $false $null "$number is above the maximum of $max"
            }
            return New-Result $true $(if ($type -eq 'Integer') { [int]$number } else { $number }) ''
        }

        'Boolean' {
            if ($Value -is [bool]) { return New-Result $true $Value '' }
            return New-Result $false $null "'$Value' is not `$true or `$false"
        }

        'String' {
            if ($Value -is [string]) { return New-Result $true $Value '' }
            return New-Result $false $null "'$Value' is not a string"
        }

        'Color' {
            # Hex only. A named colour or a CSS function would have to be
            # validated against a list this file has no business carrying.
            if ($Value -is [string] -and $Value -match '^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$') {
                return New-Result $true $Value ''
            }
            return New-Result $false $null "'$Value' is not a hex colour such as #4da3ff"
        }

        'ColorList' {
            # A ramp is one decision, not five, so it is one entry. Adding a
            # TYPE is a schema extension and needs a validator here; adding a
            # SETTING must not, and still does not. The distinction matters:
            # the rule in docs/render-architecture.md is that a new value is a
            # data change, and every type in this switch was added the same way.
            #
            # MinCount rather than an exact length: a two-stop ramp and a
            # nine-stop ramp are both legitimate, and pinning the count would
            # make the number of colours a code change.
            $minCount = Get-HashtableValue -InputObject $Entry -Key 'MinCount' -Default 2
            $items = @($Value)
            if ($items.Count -lt $minCount) {
                return New-Result $false $null "expected at least $minCount colours, got $($items.Count)"
            }
            foreach ($item in $items) {
                if (-not ($item -is [string] -and $item -match '^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$')) {
                    return New-Result $false $null "'$item' is not a hex colour such as #4da3ff"
                }
            }
            return New-Result $true ([string[]]$items) ''
        }

        'ColorMap' {
            # An arbitrary key to hex colour map. Added as a TYPE because a
            # backend colouring by classification cannot know the
            # classifications: they come from whatever produced the payload, so
            # neither the keys nor their number can live in a schema entry.
            #
            # This exists because bootstrap.js held
            #   KIND_HEX = { Function: ..., Class: ..., Enum: ..., Script: ... }
            # which is a hardcoded list of one producer's node kinds inside a
            # renderer that must not have one. No key is validated - validating
            # them would put the list back.
            if (-not ($Value -is [System.Collections.IDictionary])) {
                return New-Result $false $null 'expected a map of name to colour'
            }
            $map = [ordered]@{}
            foreach ($key in ($Value.Keys | Sort-Object)) {
                $colour = $Value[$key]
                if (-not ($colour -is [string] -and $colour -match '^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$')) {
                    return New-Result $false $null "'$key' is '$colour', not a hex colour such as #4da3ff"
                }
                $map[[string]$key] = [string]$colour
            }
            return New-Result $true $map ''
        }

        'StyleMap' {
            # An arbitrary key to a small style descriptor, and the same
            # argument as ColorMap one step further: a backend drawing a
            # classification differently cannot know the classifications. They
            # come from whatever produced the payload.
            #
            # The KEYS are never validated - validating them would put the
            # producer's vocabulary back into the renderer, which is the whole
            # thing this type exists to prevent. The PROPERTY NAMES are, and
            # that is not the same rule: LineStyle and Opacity are this
            # renderer's own words for how a line looks, so a typo in one is a
            # mistake and must say so rather than quietly drawing nothing.
            if (-not ($Value -is [System.Collections.IDictionary])) {
                return New-Result $false $null 'expected a map of name to style'
            }
            $lineStyles = @('solid', 'dashed', 'dotted')
            $map = [ordered]@{}
            foreach ($key in ($Value.Keys | Sort-Object)) {
                $style = $Value[$key]
                if (-not ($style -is [System.Collections.IDictionary])) {
                    return New-Result $false $null "'$key' is not a style map such as @{ LineStyle = 'dashed'; Opacity = 0.5 }"
                }
                $out = [ordered]@{}
                foreach ($prop in ($style.Keys | Sort-Object)) {
                    switch ([string]$prop) {
                        'LineStyle' {
                            $v = [string]$style[$prop]
                            if ($lineStyles -notcontains $v) {
                                return New-Result $false $null "'$key' has LineStyle '$v', not one of: $($lineStyles -join ', ')"
                            }
                            $out['LineStyle'] = $v
                        }
                        'Opacity' {
                            $v = $style[$prop] -as [double]
                            if ($null -eq $v -or $v -lt 0 -or $v -gt 1) {
                                return New-Result $false $null "'$key' has Opacity '$($style[$prop])', which is not a number from 0 to 1"
                            }
                            $out['Opacity'] = $v
                        }
                        default {
                            return New-Result $false $null "'$key' names style property '$prop'; this renderer draws LineStyle and Opacity"
                        }
                    }
                }
                $map[[string]$key] = $out
            }
            return New-Result $true $map ''
        }

        'Enum' {
            $allowed = @(Get-HashtableValue -InputObject $Entry -Key 'Values' -Default @())
            if ($allowed -contains $Value) { return New-Result $true $Value '' }
            return New-Result $false $null "'$Value' is not one of: $($allowed -join ', ')"
        }

        default {
            return New-Result $false $null "schema declares unknown type '$type'"
        }
    }
}
