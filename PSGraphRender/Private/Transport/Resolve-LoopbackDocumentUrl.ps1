function Get-LoopbackResponse {
    <#
    .SYNOPSIS
        Issues one GET and reports whether anything answered, with what, and the
        first few characters of the body.
    .DESCRIPTION
        Deliberately distinguishes THREE outcomes, not two. A 404 is a response:
        a server is there and said no. A refused connection or a timeout is not
        a response at all. Collapsing them would make every closed port look
        like a served root that happens not to hold the file, and the probe
        would keep walking ancestors against nothing.

        Uses HttpWebRequest rather than Invoke-WebRequest: it has a real
        connect-and-response timeout, it does not render a progress bar, and it
        behaves the same on Windows PowerShell 5.1 as on 7.
    .PARAMETER Url
        Absolute URL to request.
    .PARAMETER TimeoutMilliseconds
        Applied to both the connection and the read.
    .PARAMETER PrefixLength
        Characters of body to read back. Zero reads none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Url,
        [Parameter(Mandatory)] [int] $TimeoutMilliseconds,
        [Parameter()] [int] $PrefixLength = 0
    )

    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMilliseconds
        $request.ReadWriteTimeout = $TimeoutMilliseconds
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'PSGraphRender'
        # Nothing here is a conversation. A pooled keep-alive connection would
        # hold a socket open against a server we are only looking at.
        $request.KeepAlive = $false

        $response = $request.GetResponse()
        $prefix = ''
        if ($PrefixLength -gt 0) {
            $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
            try {
                $buffer = [char[]]::new($PrefixLength)
                $read = $reader.Read($buffer, 0, $PrefixLength)
                if ($read -gt 0) { $prefix = -join $buffer[0..($read - 1)] }
            }
            finally { $reader.Dispose() }
        }
        [pscustomobject]@{ Answered = $true; Status = [int]$response.StatusCode; Prefix = $prefix }
    }
    catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
        if ($webResponse) {
            [pscustomobject]@{ Answered = $true; Status = [int]$webResponse.StatusCode; Prefix = '' }
        }
        else {
            [pscustomobject]@{ Answered = $false; Status = 0; Prefix = '' }
        }
    }
    catch {
        # A malformed URL, a DNS failure, anything else. Not a server.
        [pscustomobject]@{ Answered = $false; Status = 0; Prefix = '' }
    }
    finally {
        if ($response) { $response.Dispose() }
    }
}

function Resolve-LoopbackDocumentUrl {
    <#
    .SYNOPSIS
        Finds the URL a local static server would serve a given file from, or
        returns nothing.
    .DESCRIPTION
        A static server given a DIRECTORY returns a listing. The report is a
        file, so nothing should ever be pointed at the folder - this works out
        the exact document URL and the caller opens that.

        The second reason matters more than the first. A page opened from
        file:// has no origin a browser policy can match, and Microsoft
        documents AutoLaunchProtocolsFromOrigins as not working as expected
        with file:// wildcards. A page served over http://127.0.0.1:PORT has a
        real, matchable origin, so the report's own editor links can work from
        there when they cannot from disk.

        The served root cannot be asked for, so it is inferred: walk up from the
        file, and for each ancestor request the path the file WOULD have if that
        ancestor were the root. Nearest ancestor first, which finds the deepest
        match and therefore the shortest URL. A 200 alone is not enough - an API
        answering 200 to everything would pass - so the first few characters of
        the body are compared with the file on disk.

        ONLY 127.0.0.1, and only as a literal. Not 'localhost', which can
        resolve to a v6 address a server is not bound to; not 0.0.0.0; not a LAN
        address. An explicit -BaseUrl is the caller's decision and is used as
        given, which is the one way anything else is reached.
    .PARAMETER Path
        The file to find a URL for.
    .PARAMETER BaseUrl
        Probe this origin only, and skip the port scan. For a server on a port
        outside the candidate list, or one that is not local.
    .PARAMETER Port
        Ports to try on 127.0.0.1, in order, stopping at the first hit.
        Ignored when -BaseUrl is given.
    .PARAMETER TimeoutMilliseconds
        Per request. Short on purpose: on loopback a closed port refuses
        immediately and a live one answers immediately, so the timeout is only
        ever paid by something pathological. A long one would make -Show feel
        broken on a machine with no server running.
    .PARAMETER MaxDepth
        How many ancestors to try. Bounds the request count on a deep path.
    .OUTPUTS
        Url, Origin and RelativePath, or nothing at all.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $BaseUrl,
        [Parameter()] [int[]] $Port = @(5500, 3000, 8080, 8000),
        [Parameter()] [int] $TimeoutMilliseconds = 250,
        [Parameter()] [int] $MaxDepth = 12
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath

    # The identity check. 120 characters is past '<!DOCTYPE html>' and into the
    # head, which is enough to tell one document from another and short enough
    # that a server streaming slowly still delivers it inside the timeout.
    $signatureLength = 120
    $signature = ''
    try {
        $reader = [System.IO.StreamReader]::new($full)
        try {
            $buffer = [char[]]::new($signatureLength)
            $read = $reader.Read($buffer, 0, $signatureLength)
            if ($read -gt 0) { $signature = -join $buffer[0..($read - 1)] }
        }
        finally { $reader.Dispose() }
    }
    catch {
        Write-Verbose "Could not read '$full' to identify it: $($_.Exception.Message)"
        return
    }
    if (-not $signature) { return }

    $origins = if ($BaseUrl) { @($BaseUrl.TrimEnd('/')) }
    else { @($Port | ForEach-Object { "http://127.0.0.1:$_" }) }

    $ancestors = @()
    $directory = Split-Path -Path $full -Parent
    while ($directory -and $ancestors.Count -lt $MaxDepth) {
        $ancestors += $directory
        $parent = Split-Path -Path $directory -Parent
        if (-not $parent -or $parent -eq $directory) { break }
        $directory = $parent
    }

    foreach ($origin in $origins) {
        # One cheap question first: is anything listening at all? Without this
        # every closed port would pay for a full ancestor walk.
        $root = Get-LoopbackResponse -Url "$origin/" -TimeoutMilliseconds $TimeoutMilliseconds
        if (-not $root.Answered) {
            Write-Verbose "No server answered at $origin."
            continue
        }

        foreach ($ancestor in $ancestors) {
            $relative = $full.Substring($ancestor.Length).TrimStart('\', '/')
            if (-not $relative) { continue }

            $segments = $relative -split '[\\/]+' | Where-Object { $_ }
            $encoded = ($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            $url = "$origin/$encoded"

            $probe = Get-LoopbackResponse -Url $url -TimeoutMilliseconds $TimeoutMilliseconds -PrefixLength $signatureLength
            if (-not $probe.Answered -or $probe.Status -ne 200) { continue }

            # A 200 says a resource exists there. This says it is OUR resource.
            if (-not $probe.Prefix.StartsWith($signature)) {
                Write-Verbose "$url answered 200 but is not this document."
                continue
            }

            return [pscustomobject]@{
                Url          = $url
                Origin       = $origin
                RelativePath = ($segments -join '/')
            }
        }

        Write-Verbose "A server answered at $origin but does not serve this file."
    }
}
