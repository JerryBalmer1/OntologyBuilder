@{
    # Declared assembly order for one template set. A caller supplies its own
    # directory containing a file like this one; nothing here is specific to any
    # one report. See docs/render-architecture.md.
    Layout = 'layout.html'

    # Slot name -> ordered list of files whose contents replace it. Slots may
    # appear inside partials as well as in the layout; substitution repeats
    # until none are left.
    Slots  = @{
        STYLES           = @('styles/base.css', 'styles/overlays.css', 'styles/components.css')
        HEADER           = @('partials/header.html')
        SIDEBAR          = @('partials/sidebar.html')
        DETAILS          = @('partials/details-panel.html')
        CANVAS           = @('partials/canvas.html')
        BANNER           = @('partials/banner.html')
        CONTEXT_MENU     = @('partials/context-menu.html')
        INFO_PANEL       = @('partials/info-panel.html')
        TEMPLATE_NOTICE  = @('partials/template-notice.html')

        # Third-party libraries, inlined so the page is one file that needs
        # nothing. They are assets of THIS backend, not of the module: a
        # backend needing a different library brings its own vendor/ and
        # nothing above this file has to know. See vendor/vendor.psd1 for where
        # each came from and the hash it was verified against.
        VENDOR           = @('vendor/cytoscape.min.js', 'vendor/cytoscape-dagre.min.js')

        SCRIPT           = @('scripts/bootstrap.js')
        SCRIPT_ORDER     = @('scripts/order.js')
        SCRIPT_ELEMENTS  = @('scripts/elements.js')
        SCRIPT_RENDER    = @('scripts/render.js')
        SCRIPT_FOUNDATION = @('scripts/foundation.js')
        SCRIPT_SIDEBAR   = @('scripts/sidebar.js')
        SCRIPT_FILTERS   = @('scripts/filters.js')
        SCRIPT_FOCUS     = @('scripts/focus.js')
        SCRIPT_EDITOR_LINK = @('scripts/editor-link.js')
        SCRIPT_DIAGNOSTICS = @('scripts/diagnostics.js')
        SCRIPT_SELECTION = @('scripts/selection.js')
        SCRIPT_MENU      = @('scripts/menu.js')
        SCRIPT_CONTROLS  = @('scripts/controls.js')
    }
    # What "this page came alive" means for THIS backend, as data. The headless
    # harness in tests/browser/ reads it and knows nothing else about any
    # backend - a harness naming '#c-nodes' would be a second place this
    # backend's shape is written down, somewhere other than this backend.
    #
    # A value names a payload collection, and the assertion is against its count.
    Smoke  = @{
        # Selector -> its text must be the count of that collection.
        Text               = @{ '#c-nodes' = 'nodes'; '#c-edges' = 'links' }

        # Selector -> the number of elements matching it must be that count.
        Elements           = @{}

        # Selectors that must match at least one element.
        Present            = @('#cy canvas')

        # Selector -> how many times larger a screenshot of it must be than the
        # same selector in this backend's render of an EMPTY payload.
        #
        # This view draws into a canvas, so every DOM assertion above passes
        # just as happily over a blank rectangle - which is exactly the failure
        # a smoke test exists to catch.
        #
        # A ratio rather than a byte count, because a byte count cannot survive
        # the move to another machine: viewport, device pixel ratio, available
        # fonts and Chromium version all change how many bytes a drawn canvas
        # compresses to. The harness measures the empty render itself, in the
        # same run, so the floor comes from the machine doing the checking.
        #
        # Measured at v0.5.0: 53,971 bytes drawn against 4,413 empty, a ratio of
        # 12.2. Four is not a marginal call.
        CanvasGrowth       = @{ '#cy' = 4 }
    }

    # What has to remain true of the DRAWING once a control has been used, as
    # data, for the same reason Smoke is data: a harness naming '#show-unresolved'
    # would be a second place this backend's shape is written down.
    #
    # The invariant is fixed and is not declared here, because it is a property
    # of drawings rather than of this backend: NO TWO VISIBLE NODES SHARE A
    # POSITION. What a backend declares is where its graph lives and which
    # sequences of control use are worth asserting it after.
    #
    # Every one of these is a defect this repository shipped. See 0013.
    Placement = @{
        # Cytoscape registers itself on its own container element as
        # `_cyreg.cy`. The page is one IIFE and holds `cy` in a closure, so
        # there is nothing on `window` to find - and `window.cy` resolves to
        # the div, which is the trap that made an earlier probe report success
        # while reading a DOM node.
        Container = '#cy'

        # One mechanism, not a list of clicks beside a list of sequences: a
        # single click is a one-step sequence. Each runs on its own page load
        # and the invariant is asserted after the load and after every step, so
        # the step that broke it is the step that gets named.
        Sequences = @(
            @{
                # 0008-t1 and 0010-t3. Every unresolved node starts hidden, so
                # none of them had ever been through a layout; revealing them
                # put all of them, and whatever real node was nearest the
                # corner, on the same coordinates.
                Id    = 'reveal-unresolved'
                Steps = @(
                    @{ Click = '#show-unresolved' }
                )
            }
            @{
                # 0010-t2. On a payload past NodeLimit the view opens filtered,
                # so unchecking it revealed 371 nodes that no layout had placed.
                Id    = 'lift-the-node-limit'
                Steps = @(
                    @{ Click = '#exported-only' }
                )
            }
            @{
                # 0013-t1. The layout runs over the visible set, and search
                # hides without relaying out - so a box ticked while a search is
                # active lays out without the searched-away nodes, and clearing
                # the search brings them back to positions from a layout that
                # excluded them.
                Id    = 'search-then-reveal-then-clear'
                Steps = @(
                    @{ Fill = '#search'; Value = 'a' }
                    @{ Click = '#show-unresolved' }
                    @{ Fill = '#search'; Value = '' }
                )
            }
            @{
                # The same question asked of the other layout engine. Foundation
                # places the set itself; dagre is handed a collection and
                # decides. Whether the defect class exists on both sides is not
                # something reading either would settle.
                Id    = 'other-flow-then-reveal'
                Steps = @(
                    @{ Click = 'input[name="flow"][value="testorder"]' }
                    @{ Click = '#show-unresolved' }
                )
            }
            @{
                # And 0013-t1 under dagre. `cy.layout()` excludes display:none
                # elements, so the defect was the same on both sides and needed
                # the same answer stated twice - once as a filter in
                # foundation.js and once as an `eles` collection in render.js.
                Id    = 'other-flow-search-then-reveal-then-clear'
                Steps = @(
                    @{ Click = 'input[name="flow"][value="testorder"]' }
                    @{ Fill = '#search'; Value = 'a' }
                    @{ Click = '#show-unresolved' }
                    @{ Fill = '#search'; Value = '' }
                )
            }
        )
    }
}