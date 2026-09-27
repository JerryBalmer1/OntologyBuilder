function Get-HashtableValue {
    <#
    .SYNOPSIS
        Reads a key/property under Set-StrictMode without throwing when missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Key,

        [Parameter()]
        [AllowNull()]
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Key)) {
            return $InputObject[$Key]
        }

        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Key]
    if ($null -ne $property) {
        return $property.Value
    }

    return $Default
}
