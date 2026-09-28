@{
    # Schema for the report renderer's configuration. Data only - see
    # docs/render-architecture.md. Adding a setting means adding an entry here and
    # a value in settings.psd1 or theme.psd1, and nothing else.
    #
    # Entry fields:
    #   Type        Number | Integer | Boolean | String | Color | ColorList | Enum
    #   Default     used when the value is absent, wrong, or out of range
    #   Min / Max   Number and Integer only
    #   Values      Enum only
    #   MinCount    ColorList only; defaults to 2
    #   In          Settings (behaviour) or Theme (appearance) - which file the
    #               value belongs in. A value in the wrong file still applies,
    #               but is reported.
    #   Group       for grouping in any future settings UI
    #   Description one line, for the same

    Entries     = @{

        # -- Interaction ---------------------------------------------------
        ZoomSpeed        = @{
            Type = 'Number'; Default = 1.25; Min = 0.05; Max = 20
            In = 'Settings'; Group = 'Interaction'
            Description = 'Mouse wheel zoom sensitivity. 1 is the Cytoscape default.'
        }
        ZoomSpeedMin     = @{
            Type = 'Number'; Default = 0.25; Min = 0.05; Max = 20
            In = 'Settings'; Group = 'Interaction'
            Description = 'Lower end of the zoom speed slider.'
        }
        ZoomSpeedMax     = @{
            Type = 'Number'; Default = 5; Min = 0.05; Max = 20
            In = 'Settings'; Group = 'Interaction'
            Description = 'Upper end of the zoom speed slider.'
        }
        ZoomSpeedStep    = @{
            Type = 'Number'; Default = 0.25; Min = 0.01; Max = 5
            In = 'Settings'; Group = 'Interaction'
            Description = 'Increment of the zoom speed slider.'
        }
        FocusDepth       = @{
            Type = 'Integer'; Default = 2; Min = 1; Max = 20
            In = 'Settings'; Group = 'Interaction'
            Description = 'Hops from the selected item included when focusing.'
        }

        # -- Layout --------------------------------------------------------
        DefaultFlow      = @{
            Type = 'Enum'; Default = 'foundation'
            Values = @('foundation', 'testorder', 'callflow')
            In = 'Settings'; Group = 'Layout'
            Description = 'View the report opens in. foundation is vertical and sinks what everything rests on to the bottom.'
        }

        ColorBy          = @{
            Type = 'Enum'; Default = 'structure'
            Values = @('structure', 'dependents', 'blastRadius', 'dependencies', 'reach')
            In = 'Settings'; Group = 'Layout'
            Description = 'What node fill means. structure is one colour per kind; a metric id is a heat scale over that measure.'
        }

        HeatRamp         = @{
            Type = 'ColorList'; MinCount = 2
            Default = @('#6e7d8c', '#a8756e', '#d1665a', '#f05340', '#ff3b2f')
            In = 'Theme'; Group = 'Appearance'
            Description = 'Node fill from coldest to hottest when ColorBy names a metric. Any number of stops from two up.'
        }

        KindColor        = @{
            Type = 'ColorMap'
            Default = @{}
            In = 'Theme'; Group = 'Appearance'
            Description = 'One colour per classification when ColorBy is structure. The keys are whatever the payload carries; the renderer does not know them and must not.'
        }
        KindColorFallback = @{
            Type = 'Color'; Default = '#8895a7'
            In = 'Theme'; Group = 'Appearance'
            Description = 'Fill for a classification KindColor does not name. A producer may send anything, so there is always an unlisted case.'
        }
        LinkColor        = @{
            Type = 'ColorMap'
            Default = @{}
            In = 'Theme'; Group = 'Appearance'
            Description = 'One colour per link classification. A kind named here is drawn dashed in its colour; anything else is solid in EdgeColor.'
        }
        EdgeResolutionStyle = @{
            Type = 'StyleMap'
            Default = @{}
            In = 'Theme'; Group = 'Appearance'
            Description = 'How a link is drawn for each value of links[].resolution, contract 1.1.0. A value named here is drawn in that style; one that is not, and a link that states none, is drawn normally. The keys are the producer''s words and are never validated.'
        }
        EdgeColor        = @{
            Type = 'Color'; Default = '#6b7785'
            In = 'Theme'; Group = 'Appearance'
            Description = 'Line and arrowhead for a link whose classification LinkColor does not name.'
        }
        UnresolvedColor  = @{
            Type = 'Color'; Default = '#ff7043'
            In = 'Theme'; Group = 'Appearance'
            Description = 'Fill for a node the renderer invented for a target the payload names but does not contain. Not a classification: no producer sends it.'
        }

        FoundationLayerCapacity = @{
            Type = 'Integer'; Default = 0; Min = 0; Max = 500
            In = 'Settings'; Group = 'Layout'
            Description = 'Most items per layer in the foundation view. 0 derives it from the window shape.'
        }
        MinReadableZoom  = @{
            Type = 'Number'; Default = 0.45; Min = 0.05; Max = 4
            In = 'Settings'; Group = 'Layout'
            Description = 'Zoom the opening view will not go below, however large the graph. Pan instead of squinting.'
        }

        # -- Scale ---------------------------------------------------------
        NodeLimit        = @{
            Type = 'Integer'; Default = 400; Min = 1; Max = 100000
            In = 'Settings'; Group = 'Scale'
            Description = 'Above this many items the view opens filtered, behind a banner.'
        }

        # -- Typography and item geometry ----------------------------------
        NodeFontSize     = @{
            Type = 'Number'; Default = 10; Min = 4; Max = 40
            In = 'Theme'; Group = 'Typography'
            Description = 'Label type size, in pixels.'
        }
        NodeHeight       = @{
            Type = 'Number'; Default = 24; Min = 10; Max = 200
            In = 'Theme'; Group = 'Geometry'
            Description = 'Height of every item box, in pixels.'
        }
        NodePadding      = @{
            Type = 'Number'; Default = 7; Min = 0; Max = 60
            In = 'Theme'; Group = 'Geometry'
            Description = 'Padding inside an item box, in pixels.'
        }
        NodeMaxWidth     = @{
            Type = 'Number'; Default = 340; Min = 60; Max = 2000
            In = 'Theme'; Group = 'Geometry'
            Description = 'Ceiling on the uniform item width; longer labels ellipsise.'
        }

        # -- Layout spacing ------------------------------------------------
        NodeSep          = @{
            Type = 'Number'; Default = 14; Min = 0; Max = 400
            In = 'Theme'; Group = 'Spacing'
            Description = 'Gap between items within one rank.'
        }
        RankSep          = @{
            Type = 'Number'; Default = 80; Min = 0; Max = 1000
            In = 'Theme'; Group = 'Spacing'
            Description = 'Gap between ranks.'
        }

        # -- Connectors ----------------------------------------------------
        EdgeWidth        = @{
            Type = 'Number'; Default = 1.4; Min = 0.2; Max = 20
            In = 'Theme'; Group = 'Connectors'
            Description = 'Connector thickness, in pixels.'
        }
        FocusEdgeWidth   = @{
            Type = 'Number'; Default = 2.6; Min = 0.2; Max = 30
            In = 'Theme'; Group = 'Connectors'
            Description = 'Connector thickness inside a focused neighbourhood.'
        }

        # -- Focus shading -------------------------------------------------
        FocusShadeStep   = @{
            Type = 'Number'; Default = 0.2; Min = 0; Max = 1
            In = 'Theme'; Group = 'Shading'
            Description = 'Darkening applied per hop from the selected item.'
        }
        FocusShadeMax    = @{
            Type = 'Number'; Default = 0.6; Min = 0; Max = 1
            In = 'Theme'; Group = 'Shading'
            Description = 'Ceiling on that darkening.'
        }
        RelatedShadeBase = @{
            Type = 'Number'; Default = 0.62; Min = 0; Max = 1
            In = 'Theme'; Group = 'Shading'
            Description = 'Darkening for items connected the opposite way round.'
        }
        RelatedShadeMax  = @{
            Type = 'Number'; Default = 0.78; Min = 0; Max = 1
            In = 'Theme'; Group = 'Shading'
            Description = 'Ceiling on that darkening.'
        }

        # -- Chrome geometry -----------------------------------------------
        SidebarWidth     = @{
            Type = 'Number'; Default = 300; Min = 120; Max = 2000
            In = 'Theme'; Group = 'Chrome'
            Description = 'Starting sidebar width, in pixels.'
        }
        SidebarMinWidth  = @{
            Type = 'Number'; Default = 200; Min = 80; Max = 2000
            In = 'Theme'; Group = 'Chrome'
            Description = 'Narrowest the sidebar may be dragged.'
        }
        CanvasMinWidth   = @{
            Type = 'Number'; Default = 320; Min = 80; Max = 4000
            In = 'Theme'; Group = 'Chrome'
            Description = 'Width the canvas may never be squeezed below.'
        }
    }

    # Cross-field rules. Declared here rather than hardcoded in the resolver, so
    # a new rule is a data change like any other.
    #   LessThan     Left must be below Right, or both reset to their defaults
    #   Between      Value is clamped into Min..Max, both naming other keys
    #   AtLeast      Value is raised to Floor, naming another key
    Constraints = @(
        @{ Rule = 'LessThan'; Left = 'ZoomSpeedMin'; Right = 'ZoomSpeedMax' }
        @{ Rule = 'Between'; Value = 'ZoomSpeed'; Min = 'ZoomSpeedMin'; Max = 'ZoomSpeedMax' }
        @{ Rule = 'AtLeast'; Value = 'SidebarWidth'; Floor = 'SidebarMinWidth' }
    )
}
