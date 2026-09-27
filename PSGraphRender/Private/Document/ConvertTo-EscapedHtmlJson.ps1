function ConvertTo-EscapedHtmlJson {
    <#
    .SYNOPSIS
        Serialises to JSON safe for embedding inside a script block.
    .DESCRIPTION
        Escapes every '<' as the JSON unicode escape for '<'. A literal
        </script> sequence anywhere in the data - most plausibly inside a file
        path or a captured extent - would terminate the script block and break
        the page. The escape is valid JSON and parses back to '<', so the
        payload is identical from the consumer's point of view.
    #>
    param($InputObject)

    $json = $InputObject | ConvertTo-Json -Depth 12
    $json.Replace('<', '\u003c')
}
