function Import-RenderDataFile {
    <#
    .SYNOPSIS
        Reads one configuration data file, returning an empty table on failure.
    .DESCRIPTION
        Restricted-mode parse; never dot-sourced or Invoke-Expression'd.

        -ErrorAction Stop is load-bearing: a .psd1 that will not parse raises a
        NON-terminating error, so without it the catch never runs and a broken
        file falls back in total silence.
    .PARAMETER Path
        Full path of the .psd1 to read.
    .PARAMETER Label
        Name used in the warning when the file cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Label
    )

    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $data) { return @{} }
        return $data
    }
    catch {
        Write-Warning ("Could not read $Label from '$Path': $($_.Exception.Message). " +
            'Falling back to built-in values.')
        return @{}
    }
}
