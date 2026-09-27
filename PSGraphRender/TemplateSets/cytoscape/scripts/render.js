    // ---- cytoscape -------------------------------------------------------
    if (typeof cytoscapeDagre !== 'undefined' && cytoscape.use) {
        try { cytoscape.use(cytoscapeDagre); } catch (e) { /* already registered */ }
    }

    // One rule pair per link classification the theme names, generated rather
    // than written. WHICH kinds exist is the payload's business; that a named
    // kind is drawn dashed is the renderer's, and that stays here.
    //
    // Spliced in below rather than appended: these must lose to .dimmed and
    // .focus-edge, which are declared after them and win by declaration order.
    var LINK_KIND_STYLE = [];
    Object.keys(LINK_HEX).forEach(function (kind) {
        var colour = LINK_HEX[kind];
        LINK_KIND_STYLE.push({
            selector: 'edge[kind = "' + kind + '"]',
            style: {
                'line-color': colour, 'target-arrow-color': colour,
                'line-style': 'dashed', 'width': 2
            }
        });
        LINK_KIND_STYLE.push({
            selector: 'edge[kind = "' + kind + '"].flip',
            style: { 'source-arrow-color': colour }
        });
    });

    // One rule per resolution the theme names, generated the same way
    // LINK_KIND_STYLE is. WHICH values exist is the payload's business; that a
    // named one is drawn in the style the theme gives it is the renderer's.
    //
    // Spliced in after LINK_KIND_STYLE so a link that is both classified and
    // uncertain reads as uncertain: the two rules set different properties
    // except line-style, and later wins.
    var EDGE_RESOLUTION_RULES = [];
    Object.keys(EDGE_RESOLUTION_STYLE).forEach(function (value) {
        var style = EDGE_RESOLUTION_STYLE[value] || {};
        var css = {};
        if (style.LineStyle) { css['line-style'] = style.LineStyle; }
        if (typeof style.Opacity === 'number') { css.opacity = style.Opacity; }
        if (!Object.keys(css).length) { return; }
        EDGE_RESOLUTION_RULES.push({
            selector: 'edge[resolution = "' + value + '"]',
            style: css
        });
    });

    var STYLE = [
            {
                // The name sits inside the box. A circle with the label
                // underneath cost roughly double the space and put the text
                // where it could collide with the next node.
                //
                // Every box is the same size - the widest label in the dataset
                // - rather than sized to its own label, so the nodes read as a
                // consistent grid. font-family is pinned because the width was
                // measured with it: letting it fall back to the Cytoscape
                // default would measure in one font and render in another.
                selector: 'node',
                style: {
                    'shape': 'round-rectangle',
                    'background-color': 'data(color)',
                    'label': 'data(name)',
                    'color': '#0b0f14',
                    'font-size': NODE_FONT_SIZE,
                    'font-weight': NODE_FONT_WEIGHT,
                    'font-family': NODE_FONT_FAMILY,
                    'text-valign': 'center',
                    'text-halign': 'center',
                    'text-wrap': 'ellipsis',
                    'text-max-width': NODE_WIDTH - NODE_PAD * 2,
                    'width': NODE_WIDTH,
                    'height': NODE_HEIGHT,
                    'padding': NODE_PAD,
                    'border-width': 'data(border)',
                    'border-color': '#0b0f14',
                    // Hop distance from the focused node, darkest furthest away.
                    // Blacken rather than a fixed palette of blues, so a class
                    // or an enum shades through its own colour instead of being
                    // recoloured as if it were a function. Zero when nothing is
                    // focused, which is a no-op.
                    'background-blacken': 'data(focusBlacken)'
                }
            },
            {
                // Export status is border colour, blast radius is border width.
                // Neither is a fill, so both survive greyscale.
                selector: 'node[?isExported]',
                style: { 'border-color': '#ffffff' }
            },
            { selector: 'node.unresolved', style: { 'border-style': 'dashed', 'border-color': '#7a2f14' } },
            {
                selector: 'edge',
                style: {
                    'width': EDGE_WIDTH,
                    'line-color': EDGE_COLOR,
                    'target-arrow-color': EDGE_COLOR,
                    'target-arrow-shape': 'triangle',
                    'arrow-scale': 0.9,
                    'curve-style': 'bezier'
                }
            },
            // 'Unresolved' is this renderer's own word for an edge it
            // invented; no producer sends it. See elements.js.
            { selector: 'edge[kind = "Unresolved"]', style: { 'line-color': UNRESOLVED_COLOR, 'target-arrow-color': UNRESOLVED_COLOR, 'line-style': 'dotted' } },
            // Test order ranks right-to-left so the page reads left-to-right in
            // the order to test. The arrowhead has to follow: pointing at the
            // callee would point backwards through that reading order. Flipped
            // to the source end, an arrow means "test this one first, then the
            // one it points at". Call flow keeps the arrow on the callee.
            { selector: 'edge.flip', style: { 'target-arrow-shape': 'none', 'source-arrow-shape': 'triangle', 'source-arrow-color': EDGE_COLOR } },
            { selector: 'edge[kind = "Unresolved"].flip', style: { 'source-arrow-color': UNRESOLVED_COLOR } },
            // LINK_KIND_STYLE is spliced in here, after the base edge rules and
            // before .dimmed - see above. EDGE_RESOLUTION_RULES follows it so
            // an uncertain link reads as uncertain whatever else classifies it.
            ].concat(LINK_KIND_STYLE).concat(EDGE_RESOLUTION_RULES).concat([
            // Out-of-focus nodes stay readable. Hiding them, or fading the
            // label to nothing, loses the context that makes a focused
            // neighbourhood mean anything - you cannot see what it sits among.
            // Muted fill with a light label rather than low opacity, because a
            // dark label on a faded box goes unreadable long before the box
            // stops drawing attention.
            {
                selector: 'node.dimmed',
                style: {
                    'background-color': '#232c38',
                    'border-color': '#2b3340',
                    'color': '#8b97a8',
                    'opacity': 1,
                    'text-opacity': 1
                }
            },
            { selector: 'edge.dimmed', style: { 'opacity': 0.12 } },
            // Connected to the focus, but the other way round from the chosen
            // direction - a dependency when asking about dependents, or the
            // reverse. Related is not the same as irrelevant, so these keep
            // their kind colour, darkened well past the chain, instead of
            // dropping into the grey used for genuinely unconnected nodes. The
            // label goes light because a dark label on a dark fill is a label
            // nobody can read.
            {
                selector: 'node.related',
                style: {
                    'color': '#c6d4e6',
                    'border-color': '#2b3340',
                    'opacity': 1,
                    'text-opacity': 1
                }
            },
            { selector: 'edge.related-edge', style: { 'opacity': 0.45 } },
            // The connections inside a focused neighbourhood are the reason the
            // node was clicked, so they brighten and thicken rather than merely
            // failing to dim. Declared after the kind rules and after .dimmed so
            // it wins on all three arrow colours; z-index lifts it clear of the
            // dimmed edges it crosses.
            {
                selector: 'edge.focus-edge',
                style: {
                    'width': FOCUS_EDGE_WIDTH,
                    'line-color': '#cfe6ff',
                    'target-arrow-color': '#cfe6ff',
                    'source-arrow-color': '#cfe6ff',
                    'arrow-scale': 1.05,
                    'opacity': 1,
                    'z-index': 20
                }
            },
            { selector: 'node.selected-node', style: { 'border-color': '#4da3ff' } },
            { selector: '.hidden', style: { 'display': 'none' } }
    ]);

    var cy = cytoscape({
        container: document.getElementById('cy'),
        elements: els,
        wheelSensitivity: ZOOM_SPEED_DEFAULT,
        style: STYLE
    });

    // Gravity. Edges point caller -> callee, and dagre gives a target a higher
    // rank than its source, so rankDir 'TB' sinks the callees - the things
    // everything else rests on - to the foot of the page. longest-path makes a
    // node's rank equal the test level computed above, so a row IS a test step.
    //
    // The arrowhead follows the reading direction in every view. Read bottom to
    // top and an arrow means "this comes first, then the one it points at",
    // which is the source end - the same flip test order uses. Call flow reads
    // the other way and keeps the arrow on the callee.
    var FLOW_LAYOUT = {
        foundation: { layout: 'foundation', flip: true },
        testorder: { rankDir: 'RL', ranker: 'longest-path', flip: true },
        callflow: { rankDir: 'LR', ranker: 'network-simplex', flip: false }
    };

    function currentFlow() {
        var checked = document.querySelector('input[name="flow"]:checked');
        return checked ? checked.value : cfgText('DefaultFlow', 'foundation');
    }

    function runLayout() {
        var flow = FLOW_LAYOUT[currentFlow()] || FLOW_LAYOUT.foundation;
        cy.edges().toggleClass('flip', flow.flip);

        // Foundation is laid out here rather than by dagre: it needs a bound on
        // layer width, and no dagre ranker has one. See foundation.js.
        if (flow.layout === 'foundation') {
            var placed = foundationPositions();
            cy.layout({
                name: 'preset',
                positions: function (n) { return placed[n.id()] || { x: 0, y: 0 }; },
                fit: false,
                animate: false
            }).run();
            document.documentElement.setAttribute('data-layout', 'foundation');
            return 'foundation';
        }

        var name = 'dagre';
        var opts = {
            name: 'dagre',
            rankDir: flow.rankDir,
            ranker: flow.ranker,
            nodeDimensionsIncludeLabels: true,
            nodeSep: cfg('NodeSep', 14),
            rankSep: cfg('RankSep', 80),
            animate: false,
            // The SET, not the screen, exactly as foundation.js takes it.
            // `cy.layout()` excludes display:none elements, so a layout run
            // while a search was active placed only what the search had left
            // and stranded the rest. Naming the collection is how dagre is told
            // the same thing foundationPositions() decides for itself.
            eles: cy.elements().filter(function (el) { return !el.hasClass('not-in-set'); })
        };
        try {
            cy.layout(opts).run();
        } catch (e) {
            // Falling back is better than an empty canvas, but record why so the
            // failure is diagnosable instead of just looking like a bad layout.
            name = 'cose';
            document.documentElement.setAttribute('data-layout-error', String(e && e.message));
            cy.layout({ name: 'cose', animate: false }).run();
        }
        document.documentElement.setAttribute('data-layout', name);
        return name;
    }

    function fitVisible() {
        // Fit to visible elements only. Hidden nodes are excluded from the
        // layout but keep a position at the origin, and a bare cy.fit() would
        // include them, shrinking the real graph into a corner.
        var vis = cy.elements(':visible');
        cy.fit(vis.empty() ? undefined : vis, 30);

        // Fitting a large graph to the window is what turns labels into dashes.
        // Past a floor the view stops shrinking and the reader pans instead - a
        // legible part of the graph beats an illegible whole of it. Foundation
        // opens at the bottom, because that is where reading starts.
        var floor = cfg('MinReadableZoom', 0.45);
        if (cy.zoom() >= floor || vis.empty()) { return; }

        cy.zoom(floor);
        var box = vis.boundingBox();
        if (currentFlow() === 'foundation') {
            cy.pan({
                x: (cy.width() / 2) - ((box.x1 + box.x2) / 2) * floor,
                y: cy.height() - 40 - (box.y2 * floor)
            });
        }
        else {
            cy.center(vis);
        }
    }
