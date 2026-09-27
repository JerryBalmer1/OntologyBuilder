function ConvertTo-EscapedHtmlText {
    <#
    .SYNOPSIS
        Escapes text for interpolation into HTML markup.
    #>
    param([string] $Text)

    if (-not $Text) { return '' }

    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}
