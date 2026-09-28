@{
    RootModule           = 'PSGraphRender.psm1'
    ModuleVersion        = '0.13.2'
    GUID                 = '3f9b1c47-58ad-4c2e-b0d6-9e14a7c82f35'
    Author               = 'Jerry Balmer'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 Jerry Balmer. MIT License.'
    Description          = 'Renders a view model as a single self-contained interactive HTML page. It does not know what the nodes represent; any producer, in any language, can drive it.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # Explicit, never derived. Public/ is not enumerated recursively and a new
    # file that is not added here builds clean and is unavailable at runtime,
    # which is the failure this list exists to make loud.
    FunctionsToExport    = @(
        'Get-RenderTemplateSet'
        'New-RenderDocument'
        'New-RenderDocumentPath'
        'Show-RenderDocument'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Html', 'Report', 'Graph', 'Visualisation', 'Renderer', 'PowerShell')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/JerryBalmer1/PSGraphRender'
            ReleaseNotes = 'contract/viewmodel.schema.json is the boundary, versioned independently at 1.0.0. Payload fields renamed: meta.title, meta.version, meta.rootPath. Old names still read, with a warning.'
        }
    }
}
