#Requires -Version 7.4
Param(
)

Register-ArgumentCompleter -CommandName Invoke-Build.ps1 -ParameterName Task -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $boundParameters)

    (Invoke-Build -Task ?? -File ($boundParameters['File'])).get_Keys() -like "$wordToComplete*" | .{process{
        New-Object System.Management.Automation.CompletionResult $_, $_, 'ParameterValue', $_
    }}
}

Register-ArgumentCompleter -CommandName Invoke-Build.ps1 -ParameterName File -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $boundParameters)

    Get-ChildItem -Directory -Name "$wordToComplete*" | .{process{
        New-Object System.Management.Automation.CompletionResult $_, $_, 'ProviderContainer', $_
    }}

    if (!($boundParameters['Task'] -eq '**')) {
        Get-ChildItem -File -Name "$wordToComplete*.ps1" | .{process{
            New-Object System.Management.Automation.CompletionResult $_, $_, 'Command', $_
        }}
    }
}

task TerraformInit {

    try {

        push-location sources/terraform

        terraform init

    }
    catch {
        Write-Error $_
    }
    finally {
        if ((Get-Location).Path -like "*sources/terraform*") {
            pop-location
        }
    }
}

task TerraformScript {

    try {

        push-location sources/terraform

        .\terraform.schema.build.ps1

    }
    catch {
        Write-Error $_
    }
    finally {
        if ((Get-Location).Path -like "*sources/terraform*") {
            pop-location
        }
    }

}

# System.Text.Json node -> plain PowerShell values (ordered hashtables, arrays,
# scalars) so New-RenderDocument can serialise it. Arrays are returned with the
# unary comma so the pipeline does not unroll them.
function ConvertFrom-JsonNodeValue {
    param($Node)

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Text.Json.Nodes.JsonObject]) {
        $result = [ordered]@{}
        foreach ($property in $Node) {
            $result[$property.Key] = ConvertFrom-JsonNodeValue -Node $property.Value
        }
        return $result
    }

    if ($Node -is [System.Text.Json.Nodes.JsonArray]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Node) { $items.Add((ConvertFrom-JsonNodeValue -Node $item)) }
        return , $items.ToArray()
    }

    switch ($Node.GetValueKind()) {
        'String' { return $Node.GetValue[string]() }
        'Number' {
            [long] $whole = 0
            if ($Node.TryGetValue([ref] $whole)) { return $whole }
            return $Node.GetValue[double]()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

# Cytoscape entry { data: { ... } } -> the flat object inside it. PSGraphRender's
# cytoscape backend reads n.id / l.source / l.target directly and builds the
# { data } wrapper itself (TemplateSets/cytoscape/scripts/elements.js).
function ConvertFrom-CytoscapeEntry {
    param(
        [System.Text.Json.Nodes.JsonNode] $Entries,
        [string] $Label
    )

    $flat = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($entry in $Entries) {
        $data = $entry['data']
        if ($null -eq $data) {
            throw "graph.json elements.$Label[$index] has no 'data' object."
        }
        $flat.Add((ConvertFrom-JsonNodeValue -Node $data))
        $index++
    }
    , $flat.ToArray()
}

task RenderGraph {

    try {

        Import-Module ./src/modules/PSGraphRender/PSGraphRender.psd1 -Force

        push-location sources/terraform/out/terraform

        # graph.json stays as the harvester writes it: Cytoscape-shaped
        # elements.nodes / elements.edges, each entry { data: { ... } }. The
        # renderer's contract wants flat data.nodes and data.links, so the view
        # model is adapted here, in memory, and never written to disk.
        $graph = [System.Text.Json.Nodes.JsonNode]::Parse([System.IO.File]::ReadAllText((Join-Path (Get-Location).Path 'graph.json')))

        $elements = $graph['elements']
        if ($null -eq $elements) {
            throw "graph.json has no top-level 'elements'. Top-level keys: $(@($graph.AsObject() | ForEach-Object Key) -join ', ')"
        }
        foreach ($required in 'nodes', 'edges') {
            if ($null -eq $elements[$required]) {
                throw "graph.json has no 'elements.$required'. Keys under elements: $(@($elements.AsObject() | ForEach-Object Key) -join ', ')"
            }
        }

        $viewModel = [ordered]@{
            nodes = ConvertFrom-CytoscapeEntry -Entries $elements['nodes'] -Label 'nodes'
            links = ConvertFrom-CytoscapeEntry -Entries $elements['edges'] -Label 'edges'
        }
        $meta = [ordered]@{
            contractVersion = '1.1.0'
        }

        New-RenderDocument -ViewModel $viewModel -Meta $meta -Title 'Terraform graph' |
            Set-Content -Path graph.html -Encoding utf8NoBOM

    }
    catch {
        throw
    }
    finally {
        if ((Get-Location).Path -like "*sources*terraform*out*terraform*") {
            pop-location
        }
    }

}

task . TerraformScript
