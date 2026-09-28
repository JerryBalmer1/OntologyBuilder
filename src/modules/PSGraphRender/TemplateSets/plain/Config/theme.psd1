@{
    # Appearance: what it looks like.
    PageBackground     = '#ffffff'
    BodyColor          = '#111111'
    RuleColor          = '#dddddd'
    RowHoverBackground = '#f3f3f3'
    BodyFont           = 'system-ui, -apple-system, Segoe UI, sans-serif'

    # Deliberately no KindColor. This backend renders a table and colours
    # nothing by classification, so a map here would be a value nothing reads -
    # and every backend carrying every other backend's keys is how a config
    # split stops meaning anything.
}
