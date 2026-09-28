function Get-VSCodeLauncher {
    <#
    .SYNOPSIS
        Path to the VS Code CLI when the session is running inside VS Code, else $null.
    .DESCRIPTION
        Both conditions have to hold. Being able to find the 'code' executable
        only means VS Code is installed somewhere; it does not mean the user is
        sitting in it. Opening an editor window at someone running from a plain
        console would be worse than opening their browser.

        Detection markers, any of which is enough:
          TERM_PROGRAM=vscode      the integrated terminal sets this
          VSCODE_PID               set inside the extension host
          VSCODE_GIT_IPC_HANDLE    set when VS Code's git integration is live
          VSCODE_INJECTION         set by shell integration injection

        Note the VS Code CLI has no --command or --uri flag, so nothing here can
        open a rendered preview pane; only the file itself can be opened. See
        Show-RenderDocument.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $inVSCode = (
        $env:TERM_PROGRAM -eq 'vscode' -or
        [bool]$env:VSCODE_PID -or
        [bool]$env:VSCODE_GIT_IPC_HANDLE -or
        [bool]$env:VSCODE_INJECTION
    )

    if (-not $inVSCode) {
        return $null
    }

    $cli = Get-Command -Name 'code' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $cli) {
        return $null
    }

    $cli.Source
}
