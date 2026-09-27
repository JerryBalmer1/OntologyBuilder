@{
    # Provenance for every third-party file in this directory. DATA, read with
    # Import-PowerShellDataFile and never executed.
    #
    # A vendored blob with no provenance is worse than a CDN link: the link at
    # least says where it came from. Each entry records the exact URL the file
    # was fetched from, the version that URL pins, and the Subresource Integrity
    # hash it was verified against - the same hashes the <script integrity=...>
    # attributes carried before v0.5.0, so this is a continuation of that check
    # rather than a new claim.
    #
    # To update one of these: fetch Url, compute
    #     'sha384-' + [Convert]::ToBase64String(
    #         [Security.Cryptography.SHA384]::Create().ComputeHash(
    #             [IO.File]::ReadAllBytes($path)))
    # and compare with Integrity BEFORE replacing the file. Then change Version,
    # Url and Integrity here in the same commit. tests/Vendor.Tests.ps1 verifies
    # every file against its recorded hash on every run, so a file replaced
    # without updating this manifest fails the build by name.
    #
    # The files are byte-identical to what the hash covers and are NEVER edited.
    # cytoscape-dagre.min.js ends with a sourceMappingURL comment naming a .map
    # file that is not vendored; it is relative, it is fetched only when
    # developer tools are open, and removing it would invalidate the hash, which
    # is a worse trade.

    Files = @(
        @{
            Name      = 'cytoscape.min.js'
            Package   = 'cytoscape'
            Version   = '3.34.2'
            Url       = 'https://cdn.jsdelivr.net/npm/cytoscape@3.34.2/dist/cytoscape.min.js'
            Integrity = 'sha384-BSWdCKSCDnBW0jqCFJdI+wvv6v62CWMcVb9LSwnq973ykOGAzHY5tQMOjvOTJNpj'
            License   = 'MIT'
        }
        @{
            # Bundles its own dagre and graphlib, which is why there is no third
            # file here. Verified by inspection of the built bundle, not assumed
            # from the package name.
            Name      = 'cytoscape-dagre.min.js'
            Package   = 'cytoscape-dagre'
            Version   = '4.0.0'
            Url       = 'https://cdn.jsdelivr.net/npm/cytoscape-dagre@4.0.0/dist/cytoscape-dagre.min.js'
            Integrity = 'sha384-ZB0G8+HSDcFhSFvwJP3rhJhh2sU/lJrfRrhqis4Gg7pP/CQ2IUzl86Gdlu3S17UF'
            License   = 'MIT'
        }
    )
}
