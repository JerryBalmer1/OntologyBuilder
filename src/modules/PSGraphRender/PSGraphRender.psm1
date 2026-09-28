# Read by Get-RenderAssetPath to locate TemplateSets/ and contract/. Must be set
# before any function runs.
$script:ModuleRoot = $PSScriptRoot

# Private first so Public functions can call helpers at load time.
# Private is enumerated recursively (Config/, Contract/, Document/, Transport/);
# Public is top level only, matching FunctionsToExport in the manifest.
$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter *.ps1 -File -Recurse)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter *.ps1 -File)

foreach ($file in @($private) + @($public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $public.BaseName
