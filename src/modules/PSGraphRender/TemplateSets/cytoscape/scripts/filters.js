    // ---- filtering -------------------------------------------------------
    var searchEl = document.getElementById('search');
    var exportedOnlyEl = document.getElementById('exported-only');
    var showUnresolvedEl = document.getElementById('show-unresolved');

    function applyFilters() {
        var term = searchEl.value.trim().toLowerCase();
        var exportedOnly = exportedOnlyEl.checked;
        var showUnres = showUnresolvedEl.checked;
        var enabled = {};
        kinds.forEach(function (k) {
            var box = document.getElementById('kind-' + k);
            enabled[k] = !box || box.checked;
        });

        // TWO CLASSES, BECAUSE THERE ARE TWO REASONS AND THEY ARE NOT THE SAME
        // REASON. `not-in-set` means the reader has said this node is not part
        // of the drawing - a kind unticked, exported-only, unresolved off.
        // `hidden` means it is not on the screen right now, which `not-in-set`
        // implies and a search miss also causes.
        //
        // The layout takes the SET and not the screen. A search narrows what is
        // shown; it does not change what the drawing is of, so a node searched
        // away keeps its place and comes back to it. When the layout followed
        // the screen, a checkbox ticked while a search was active laid out
        // without the searched-away nodes, and clearing the search brought them
        // back to positions no layout had given them - which is 0013-t1, and
        // the placement harness names it: seven visible nodes on six positions.
        //
        // `.hidden` is the only one of the two with a style rule. `not-in-set`
        // carries no appearance at all; it is bookkeeping the layout reads.
        cy.batch(function () {
            cy.nodes().forEach(function (n) {
                var kind = n.data('kind');
                var inSet;
                if (kind === 'External') {
                    inSet = showUnres;
                } else {
                    inSet = !!enabled[kind];
                    if (inSet && exportedOnly && !n.data('isExported')) { inSet = false; }
                }
                var found = !term || n.data('name').toLowerCase().indexOf(term) !== -1;
                n.toggleClass('not-in-set', !inSet);
                n.toggleClass('hidden', !(inSet && found));
            });
            cy.edges().forEach(function (e) {
                e.toggleClass('not-in-set',
                    e.source().hasClass('not-in-set') || e.target().hasClass('not-in-set'));
                e.toggleClass('hidden',
                    e.source().hasClass('hidden') || e.target().hasClass('hidden'));
            });
        });
        reapplyFocus();
    }

    // A node the reader can see needs a position from a layout that included
    // it. foundationPositions() places the VISIBLE set - see foundation.js -
    // so a node hidden when the layout last ran has never been placed at all
    // and sits at the origin, which is where the top-left node of the drawing
    // already is.
    //
    // That one fact produced three separate ledger threads, none of which
    // named it: an invented node drawn on top of a real one (0008-t1), two
    // unresolved targets drawn as one node (0010-t3 - they are two nodes with
    // two ids, stacked), and unchecking "Exported only" moving nothing
    // (0010-t2, where 371 of SqlServerDsc's nodes arrived in the same corner).
    //
    // The checkboxes relayout and the search box does not. A checkbox is a
    // decision about which nodes belong on the page and is worth redrawing
    // for; the search box fires on every keystroke, and a graph that
    // rearranges itself mid-word is worse than the defect. Search is also
    // safe: it can only hide nodes a layout has already placed, so it cannot
    // strand one at the origin.
    function applyStructuralFilters() {
        applyFilters();
        runLayout();
        fitVisible();
    }

    searchEl.addEventListener('input', applyFilters);
    exportedOnlyEl.addEventListener('change', applyStructuralFilters);
    showUnresolvedEl.addEventListener('change', applyStructuralFilters);
