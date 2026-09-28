function Show-RenderDocument {
    <#
    .SYNOPSIS
        Opens a generated document with the OS default handler, which for .html is
        the default browser - over http when a local server is serving it.
    .DESCRIPTION
        The report ALWAYS opens in the default browser, never in the editor, even
        when the session is running inside VS Code.

        That is deliberate, and it is the entire justification for this function's
        behaviour. Opening the file in VS Code shows the HTML source, so the user
        reaches for a preview extension - Live Preview, Simple Browser, or
        similar. Every one of those is a webview, and a webview sandboxes
        custom-scheme navigation: a vscode://file/... URI never reaches the OS
        from inside one. The page's own "Open File Location" action, which jumps
        from a node to its definition, is dead in exactly that environment.
        Routing the report into the editor would therefore hand the user a page
        whose most useful feature cannot work.

        This reverses an earlier implementation that preferred the editor. Do not
        restore it.

        Get-VSCodeLauncher is still consulted, but only to decide whether to print
        a hint naming the command that would open the source instead. It never
        launches anything.

        On Linux, xdg-open is frequently absent in headless containers and in WSL.
        That is a warning with the path, not an error: the file is already written
        and the user can open it themselves.

        THE DOCUMENT, NEVER THE DIRECTORY. Before falling back to the file, a
        loopback probe works out whether a static server is already serving this
        exact file and, if so, hands the browser that URL. Two things come from
        it: the user lands on the report rather than on a directory listing they
        then have to click through, and the page arrives on an origin a browser
        policy can match - which is what makes its own vscode:// links able to
        work at all. See Resolve-LoopbackDocumentUrl.
    .PARAMETER Path
        Path of the file to open.
    .PARAMETER BaseUrl
        Skip the port scan and use this origin.
    .PARAMETER Port
        Ports to probe on 127.0.0.1. Defaults to the candidate list in
        Resolve-LoopbackDocumentUrl.
    .PARAMETER NoServe
        Skip the probe entirely and always open the file from disk.
    .PARAMETER EditorLinkHelpCommand
        Command to name when the report opened from disk and its editor links
        may therefore be blocked. Supplied by the caller rather than known here:
        it is vocabulary belonging to whatever program generated the report,
        which is the same reason the renderer is handed editorLinkHelpCommand
        instead of holding it. See docs/render-architecture.md.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $BaseUrl,

        [Parameter()]
        [int[]] $Port,

        [Parameter()]
        [switch] $NoServe,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $EditorLinkHelpCommand
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot open '$Path': file not found."
    }

    # Resolved before ShouldProcess so -WhatIf names the URL that would actually
    # be opened rather than the file it was derived from.
    $served = $null
    if (-not $NoServe) {
        $probe = @{ Path = $Path }
        if ($BaseUrl) { $probe['BaseUrl'] = $BaseUrl }
        if ($Port) { $probe['Port'] = $Port }
        $served = Resolve-LoopbackDocumentUrl @probe
    }

    $target = if ($served) { $served.Url } else { $Path }

    if (-not $PSCmdlet.ShouldProcess($target, 'Open in default application')) {
        return
    }

    # $IsWindows does not exist on Windows PowerShell 5.1, where Desktop always
    # means Windows.
    $onWindows = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
        $IsWindows
    }
    else {
        $PSVersionTable.PSEdition -eq 'Desktop'
    }

    $onMacOS = (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS
    $onLinux = (Get-Variable -Name IsLinux -ErrorAction SilentlyContinue) -and $IsLinux

    # Chained so the hint below runs once, after a successful open. The two
    # warning branches return without reaching it: nothing was opened, so there
    # is nothing to add a footnote to.
    # Start-Process on every platform, rather than the call operator on two of
    # them. One seam is one thing a test can intercept: the macOS and Linux
    # branches used `& $opener` and so could not be mocked, and the suite
    # LAUNCHED xdg-open on the CI runner - a unit test starting a real process,
    # discovered the first time these tests ran anywhere but Windows.
    if ($onWindows) {
        Start-Process -FilePath $target
    }
    elseif ($onMacOS) {
        Start-Process -FilePath '/usr/bin/open' -ArgumentList $target
    }
    elseif ($onLinux) {
        $opener = Get-Command -Name 'xdg-open' -ErrorAction SilentlyContinue
        if (-not $opener) {
            Write-Warning ("Cannot open a browser automatically: xdg-open is not installed. " +
                "The report is at: $Path")
            return
        }
        Start-Process -FilePath $opener.Source -ArgumentList $target
    }
    else {
        Write-Warning "Unrecognised platform; could not open automatically. The report is at: $Path"
        return
    }

    # Which route was taken is invisible otherwise, and it decides whether the
    # page's own editor links can work. Say it either way.
    if ($served) {
        Write-Verbose "Opened $($served.Url) - served over $($served.Origin) (editor links will work)."
    }
    else {
        $hint = if ($EditorLinkHelpCommand) { " See $EditorLinkHelpCommand." } else { '' }
        Write-Verbose "Opened $Path from disk (editor links may be blocked).$hint"
    }

    # Inside VS Code, name the command that opens the source - do not run it.
    # See the note in .DESCRIPTION: the rendered report has to stay out of the
    # editor, or its own click-to-source stops working.
    if (Get-VSCodeLauncher) {
        Write-Verbose ("Opened in the default browser. To view the source instead: " +
            "code --reuse-window `"$Path`"")
    }
}
