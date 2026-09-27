function New-RenderDocument {
    <#
    .SYNOPSIS
        The seam. Takes a view model and returns a finished document.
    .DESCRIPTION
        See docs/render-architecture.md. This is the only function a producer
        needs to call, and it is deliberately the only one that knows the
        substitution contract exists.

        Before it, a producer had to escape its own JSON, escape its own title,
        resolve strings and configuration itself, ask for a template and then
        make four [string]::Replace calls against markers it had to know the
        names of. Every one of those was a chance to get the escaping wrong in a
        way nothing would report, and a producer written in another language had
        to reimplement all of it before it could render anything. "Any producer
        can drive this renderer" was not true while that was the interface.

        Nothing here knows what the nodes are. ViewModel and Meta are passed
        through the escaper and embedded; no field is read, no shape is checked
        beyond being serialisable.
    .PARAMETER ViewModel
        The payload. Whatever the backend's scripts expect to find - nodes,
        links, rows, anything. Serialised and embedded as-is.
    .PARAMETER Meta
        Provenance and summary: who generated it, when, and any headline
        figures. Serialised and embedded as-is.
    .PARAMETER Strings
        Caller-supplied strings, merged over the backend's strings.psd1 and
        substituted into every string as {token}.

        This is where the seam is paid for. A producer hands down the name of
        its own command as a value; the renderer interpolates a string it was
        given and learns nothing. Only caller tokens are filled here - anything
        the browser knows at display time is left as written for the page.
    .PARAMETER Title
        Page title. Escaped as text, not as JSON.
    .PARAMETER TemplateSet
        A backend shipped with the module, by directory name. Defaults to
        whatever TemplateSets/index.psd1 names.
    .PARAMETER TemplateSetPath
        A backend directory of the caller's own. Takes precedence over
        -TemplateSet, and is what makes a backend that does not ship here
        possible at all.
    .PARAMETER SkipValidation
        Render without checking the payload against
        contract/viewmodel.schema.json. For a caller deliberately exercising a
        shape the contract does not describe yet - which is a proposal, not a
        habit.
    .OUTPUTS
        System.String - the whole document.
    .EXAMPLE
        New-RenderDocument -ViewModel $vm -Meta $meta -Title 'Everything'
    .EXAMPLE
        New-RenderDocument -ViewModel $vm -Meta $meta -Title 'Everything' -TemplateSet plain
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true, Position = 0)]
        [ValidateNotNull()]
        $ViewModel,

        [Parameter()]
        $Meta,

        [Parameter()]
        [ValidateNotNull()]
        [hashtable] $Strings = @{},

        [Parameter()]
        [string] $Title,

        [Parameter()]
        [string] $TemplateSet,

        [Parameter()]
        [string] $TemplateSetPath,

        [Parameter()]
        [switch] $SkipValidation
    )

    process {
        # A rename never deletes: read the current names, fall back to the ones
        # they replaced, warn once naming both. See NAMING.md in PSModuleGraph,
        # which this contract follows.
        $resolvedMeta = Resolve-RenderMeta -Meta $Meta

        # Refused by name, not rendered on a guess. A renderer that quietly
        # tolerates a payload it does not understand teaches producers to emit
        # payloads nobody understands.
        Assert-RenderContractVersion -Meta $resolvedMeta

        if (-not $SkipValidation) {
            # This is the answer to a shape assumption living in a backend
            # script. `plain` reads DATA.nodes and DATA.links directly, and that
            # is only safe because the contract requires them - checked here,
            # once, at the seam, rather than by every backend separately.
            $check = Test-RenderViewModel -InputObject ([pscustomobject]@{
                    meta = [pscustomobject]$resolvedMeta
                    data = $ViewModel
                })

            if ($check.IsValid -eq $false) {
                throw ("View model does not satisfy contract/viewmodel.schema.json: $($check.Reason) " +
                    'Pass -SkipValidation to render it anyway.')
            }
            if ($null -eq $check.IsValid) {
                # NOT $true. "Could not check" and "checked and passed" are
                # different facts, and returning the second for the first is how
                # an invalid payload reaches a reader.
                Write-Verbose "View model not validated: $($check.Reason)"
            }
        }
        # One path, resolved once, handed to all three consumers. The location
        # of a backend is stated in Resolve-RenderTemplateSetPath and nowhere
        # else; see the comment there for what three copies of it cost.
        $setPath = if ($TemplateSetPath) { $TemplateSetPath }
        else { Resolve-RenderTemplateSetPath -Name $TemplateSet }

        $template = Get-RenderTemplateSet -Path $setPath
        $config = Resolve-RenderConfiguration -TemplateSetPath $setPath
        $resolvedStrings = Resolve-RenderString -TemplateSetPath $setPath -Value $Strings

        # [string]::Replace, never the -replace operator. -replace is regex: the
        # JSON and the CSS both contain '$' and '\', which the regex engine
        # treats as substitution patterns and silently eats. The result would be
        # corrupted output rather than an error. See docs/development.md.
        $document = $template.Replace('/*__DATA__*/ null', (ConvertTo-EscapedHtmlJson -InputObject $ViewModel))
        $document = $document.Replace('/*__META__*/ null', (ConvertTo-EscapedHtmlJson -InputObject $resolvedMeta))
        $document = $document.Replace('/*__CONFIG__*/ null', (ConvertTo-EscapedHtmlJson -InputObject $config))
        $document = $document.Replace('/*__STRINGS__*/ null', (ConvertTo-EscapedHtmlJson -InputObject $resolvedStrings))
        $document = $document.Replace('__PAGE_TITLE__', (ConvertTo-EscapedHtmlText -Text $Title))

        $document
    }
}
