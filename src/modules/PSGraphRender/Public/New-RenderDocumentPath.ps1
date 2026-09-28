function New-RenderDocumentPath {
    <#
    .SYNOPSIS
        Returns the default path for a generated report, under output/reports.
    .DESCRIPTION
        Replaces the temp-directory path used up to v0.4.0. A report in the
        system temp directory can never be served: a local static server serves
        a workspace, so the file has to live inside one for the report to have
        an http origin at all. output/ is already the place generated things
        live, already gitignored, and already wiped by the Clean task.

        The name carries a timestamp, so runs accumulate rather than overwrite.
        That is a deliberate trade and it costs something: the previous stable
        name meant an already-open browser tab only needed a refresh, and a
        timestamped one opens a new tab every run. Older reports are purged
        after 24 hours so the directory cannot grow without bound.

        Nothing is deleted after opening. The browser may not have read the file
        when the pipeline returns, and a cleanup racing it is a bug generator.
    .PARAMETER Name
        Used as the file name stem, with anything outside [A-Za-z0-9._-]
        replaced. What the name means is the caller's business.
    .PARAMETER BasePath
        Directory the output/reports tree hangs off. The caller passes the
        session's current filesystem location; the tests pass a temp directory.
    .PARAMETER Timestamp
        Overrides the clock, so a test can assert an exact path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BasePath,

        [Parameter()]
        [string] $Timestamp
    )

    $safeName = if ($Name) { $Name -replace '[^A-Za-z0-9._-]', '_' } else { 'report' }
    $stamp = if ($Timestamp) { $Timestamp } else { (Get-Date).ToString('yyyyMMdd-HHmmss') }

    # [System.IO.Directory]::CreateDirectory, not New-Item. New-Item supports
    # ShouldProcess, so under -WhatIf - or a session with $WhatIfPreference set -
    # it declines to create the directory while the write that follows, which
    # has no ShouldProcess of its own, goes ahead anyway and fails on a missing
    # path. Gating half of a two-step operation turns a preview into a hard
    # error. The open IS gated, in Show-RenderDocument, which is the step a
    # -WhatIf is actually asking about.
    $root = Join-Path (Join-Path $BasePath 'output') 'reports'
    [System.IO.Directory]::CreateDirectory($root) | Out-Null

    $target = Join-Path $root ("{0}-{1}.html" -f $safeName, $stamp)

    $cutoff = (Get-Date).AddHours(-24)
    Get-ChildItem -Path $root -Filter '*.html' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $target -and $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            }
            catch {
                # A file still open in a browser is not worth failing an export over.
                Write-Verbose "Could not purge '$($_.FullName)': $($_.Exception.Message)"
            }
        }

    $target
}
