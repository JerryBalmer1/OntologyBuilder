    // ---- focus mode ------------------------------------------------------
    var focused = null;
    var depthEl = document.getElementById('depth');
    var depthVal = document.getElementById('depth-val');

    // Expands one hop at a time with incomers()/outgoers() and unions the result.
    // Cytoscape collections dedupe, so a cycle between two private helpers
    // terminates on its own without any visited-set bookkeeping.
    //
    // hops records the distance each node was first reached at. Because the
    // frontier only ever carries nodes not already in acc, the first time a
    // node appears is its shortest distance - so a node reachable both directly
    // and round a longer path shades by the short one.
    function neighbourhood(node, depth, direction) {
        var acc = node;
        var frontier = node;
        var hops = {};
        hops[node.id()] = 0;
        for (var i = 0; i < depth; i++) {
            var next = cy.collection();
            if (direction === 'dependents' || direction === 'both') {
                next = next.union(frontier.incomers());
            }
            if (direction === 'dependencies' || direction === 'both') {
                next = next.union(frontier.outgoers());
            }
            next = next.filter(function (e) { return !e.hasClass('hidden'); });
            var fresh = next.nodes().difference(acc);
            fresh.forEach(function (n) { hops[n.id()] = i + 1; });
            acc = acc.union(next);
            if (fresh.empty()) { break; }
            frontier = fresh;
        }
        return { elements: acc, hops: hops };
    }

    // 'both' already covers everything, so it has no opposite to show.
    function oppositeDirection(direction) {
        if (direction === 'dependents') { return 'dependencies'; }
        if (direction === 'dependencies') { return 'dependents'; }
        return null;
    }

    function currentDirection() {
        var checked = document.querySelector('input[name="dir"]:checked');
        return checked ? checked.value : 'dependents';
    }

    function reapplyFocus() {
        if (!focused || focused.removed() || focused.hasClass('hidden')) {
            clearFocusStyling();
            return;
        }
        var depth = parseInt(depthEl.value, 10);
        var found = neighbourhood(focused, depth, currentDirection());
        var keep = found.elements;

        // The same walk the other way round. Those nodes are not the answer to
        // the question asked, but they are still connected, so they get their
        // own tier rather than being lumped in with the unrelated.
        var opposite = oppositeDirection(currentDirection());
        var other = opposite ? neighbourhood(focused, depth, opposite) : null;

        cy.batch(function () {
            cy.elements().addClass('dimmed');
            cy.edges().removeClass('focus-edge').removeClass('related-edge');
            cy.nodes().removeClass('related');
            // Reset every node, not just the kept ones: a node that was in the
            // previous focus and is not in this one would keep its old shade.
            cy.nodes().data('focusBlacken', 0);

            keep.removeClass('dimmed');
            // The selected node keeps its full colour and each hop away is a
            // step darker, so the chain reads as a sequence rather than as one
            // flat blob of blue.
            keep.nodes().forEach(function (n) {
                var hop = found.hops[n.id()] || 0;
                n.data('focusBlacken', Math.min(FOCUS_SHADE_MAX, FOCUS_SHADE_STEP * hop));
            });

            if (other) {
                var related = other.elements.nodes().difference(keep.nodes());
                related.removeClass('dimmed').addClass('related');
                // Shading continues past where the chain stops, so the two
                // tiers cannot be confused for each other at a glance.
                related.forEach(function (n) {
                    var hop = other.hops[n.id()] || 1;
                    n.data('focusBlacken', Math.min(
                        RELATED_SHADE_MAX, RELATED_SHADE_BASE + FOCUS_SHADE_STEP * (hop - 1)));
                });
                var reachable = keep.nodes().union(related);
                other.elements.edges().filter(function (e) {
                    return reachable.contains(e.source()) && reachable.contains(e.target());
                }).removeClass('dimmed').addClass('related-edge');
            }

            // Edges with both ends inside the neighbourhood are the connections
            // the user clicked to see, so they are highlighted rather than just
            // left undimmed. An edge with one end outside stays dimmed: drawing
            // it bright would imply a link to something not in the answer.
            // Applied last so it wins over related-edge on any shared edge.
            keep.connectedEdges().filter(function (e) {
                return keep.contains(e.source()) && keep.contains(e.target());
            }).removeClass('dimmed').removeClass('related-edge').addClass('focus-edge');
        });
    }

    function clearFocusStyling() {
        cy.elements().removeClass('dimmed');
        cy.edges().removeClass('focus-edge').removeClass('related-edge');
        cy.nodes().removeClass('related');
        cy.nodes().data('focusBlacken', 0);
    }

    function showDetails(n) {
        var lvl = n.data('level');
        var rows = [
            [str('DetailName'), escapeHtml(n.data('name'))],
            [str('DetailKind'), escapeHtml(n.data('kind'))],
            [str('DetailExported'), n.data('kind') === 'External'
                ? str('ValueNotApplicable')
                : (n.data('isExported') ? str('ValueYes') : str('ValueNo'))]
        ];
        if (n.data('kind') !== 'External') {
            rows.push([str('DetailTestStep'), lvl === null
                ? str('ValueInCycle')
                : fmt('DetailTestStepValue', { step: lvl + 1, total: stepCount })]);
            rows.push([str('DetailDependents'), String(n.data('dependents'))]);
            rows.push([str('DetailDependencies'), String(n.data('dependencies'))]);
            // The transitive pair. Colour is ranked rather than proportional,
            // so the raw number has to be readable somewhere - this is where.
            var m = n.data('metrics') || {};
            if (typeof m.blastRadius === 'number') {
                rows.push([str('DetailBlastRadius'), String(m.blastRadius)]);
            }
            if (typeof m.reach === 'number') {
                rows.push([str('DetailReach'), String(m.reach)]);
            }
        }
        // How many of this node's links the payload declined to tie to one
        // target. Counted from links[].resolution alone: the number of
        // CANDIDATES an ambiguous link has is a fact the producer holds and the
        // contract does not carry, so it is not shown rather than guessed.
        //
        // The row is absent when nothing is styled, which is the same rule as
        // the metrics above - a payload that states nothing says nothing here.
        var touching = n.connectedEdges();
        var uncertain = touching.filter(function (e) {
            var r = e.data('resolution');
            return r && Object.prototype.hasOwnProperty.call(EDGE_RESOLUTION_STYLE, r);
        });
        if (uncertain.length) {
            rows.push([str('DetailUncertainLinks'),
                fmt('DetailUncertainLinksValue', { count: uncertain.length, total: touching.length })]);
        }

        if (n.data('startLine')) { rows.push([str('DetailLine'), String(n.data('startLine'))]); }

        var html = rows.map(function (r) {
            return '<dt>' + escapeHtml(r[0]) + '</dt><dd>' + r[1] + '</dd>';
        }).join('');
        if (n.data('path')) {
            // Plain selectable text, deliberately not a link: a file:// href to a
            // local path does not reliably open from a browser, and a dead link
            // is worse than text you can copy.
            html += '<dt>' + escapeHtml(str('DetailPath')) + '</dt><dd><span class="path">' +
                escapeHtml(n.data('path')) + '</span></dd>';
        }
        var list = document.getElementById('details-list');
        list.innerHTML = html;
        list.hidden = false;
        document.getElementById('details-empty').hidden = true;
    }

    cy.on('tap', 'node', function (evt) {
        cy.nodes().removeClass('selected-node');
        focused = evt.target;
        focused.addClass('selected-node');
        document.getElementById('focus-controls').hidden = false;
        document.getElementById('focus-hint').textContent =
            fmt('FocusHintSelected', { name: focused.data('name') });
        showDetails(focused);
        reapplyFocus();
    });

    cy.on('tap', function (evt) {
        if (evt.target === cy) { clearFocus(); }
    });
