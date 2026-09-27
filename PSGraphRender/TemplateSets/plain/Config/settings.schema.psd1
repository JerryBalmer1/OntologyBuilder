@{
    # Every value this backend ships must have an entry here, or it warns at the
    # user. The schema types and range-checks; it does not hold current values.
    Entries = @{
        PageBackground     = @{ Type = 'Color'; Default = '#ffffff'; In = 'Theme'
            Description = 'Page background.' }
        BodyColor          = @{ Type = 'Color'; Default = '#111111'; In = 'Theme'
            Description = 'Body text.' }
        RuleColor          = @{ Type = 'Color'; Default = '#dddddd'; In = 'Theme'
            Description = 'Rule below each table row.' }
        RowHoverBackground = @{ Type = 'Color'; Default = '#f3f3f3'; In = 'Theme'
            Description = 'Row background under the pointer.' }
        BodyFont           = @{ Type = 'String'; Default = 'system-ui, sans-serif'; In = 'Theme'
            Description = 'Font stack for the whole document.' }
    }

    # Cross-setting rules. This backend has none; the key exists so the shape is
    # the same as every other backend's and a reader is not left wondering.
    Constraints = @()
}
