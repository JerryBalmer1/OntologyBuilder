    // ---- selection -------------------------------------------------------
    // Shift-click or shift-drag builds a selection; two or more selected items
    // open the panel. Facts and actions are registries for the same reason the
    // context menu's are: adding one is a single entry, and a reader can see the
    // whole vocabulary in one place.
    //
    // Both take the selected collection, not one item, because the interesting
    // questions about several things are the ones a single item cannot answer -
    // what do these all rest on, what would they break between them.

    // Edges point caller -> callee, so successors() is everything a node rests
    // on and predecessors() is everything resting on it, transitively.
    function selectionDependencies(selected) {
        return selected.successors().nodes().difference(selected);
    }

    function selectionDependents(selected) {
        return selected.predecessors().nodes().difference(selected);
    }

    // What every selected item rests on, however indirectly. The gravity
    // question asked of more than one thing at a time: change any of this and
    // you change all of them.
    function sharedFoundation(selected) {
        var shared = null;
        selected.forEach(function (n) {
            var reach = n.successors().nodes();
            shared = (shared === null) ? reach : shared.intersection(reach);
        });
        return (shared === null) ? cy.collection() : shared.difference(selected);
    }

    function nameList(collection) {
        var names = collection.map(function (n) { return n.data('name'); }).sort();
        var shown = names.slice(0, SELECTION_NAME_LIMIT);
        if (names.length > shown.length) {
            shown.push(fmt('SelectionMore', { count: names.length - shown.length }));
        }
        return shown.join(', ');
    }

    var SELECTION_NAME_LIMIT = 6;

    var SELECTION_FACTS = [
        {
            id: 'count',
            label: function () { return str('SelectionCount'); },
            value: function (selected) {
                var kinds = {};
                selected.forEach(function (n) {
                    var k = n.data('kind');
                    kinds[k] = (kinds[k] || 0) + 1;
                });
                var parts = Object.keys(kinds).sort().map(function (k) {
                    return kinds[k] + ' ' + k;
                });
                return selected.length + ' (' + parts.join(', ') + ')';
            }
        },
        {
            id: 'shared-foundation',
            label: function () { return str('SelectionSharedFoundation'); },
            value: function (selected) {
                var shared = sharedFoundation(selected);
                if (shared.empty()) { return str('SelectionNoneShared'); }
                return shared.length + ' - ' + nameList(shared);
            }
        },
        {
            id: 'internal-links',
            label: function () { return str('SelectionInternalLinks'); },
            value: function (selected) {
                // Edges with both ends inside the selection: whether these are
                // one cluster or several unrelated things picked together.
                return String(selected.edgesWith(selected).length);
            }
        },
        {
            id: 'dependencies',
            label: function () { return str('SelectionDependencies'); },
            value: function (selected) { return String(selectionDependencies(selected).length); }
        },
        {
            id: 'dependents',
            label: function () { return str('SelectionDependents'); },
            value: function (selected) { return String(selectionDependents(selected).length); }
        },
        {
            id: 'test-steps',
            label: function () { return str('SelectionTestSteps'); },
            value: function (selected) {
                var levels = [];
                selected.forEach(function (n) {
                    var lvl = n.data('level');
                    if (lvl !== null && lvl !== undefined) { levels.push(lvl + 1); }
                });
                if (!levels.length) { return str('ValueNotApplicable'); }
                levels.sort(function (a, b) { return a - b; });
                var low = levels[0];
                var high = levels[levels.length - 1];
                return (low === high) ? String(low) : (low + '-' + high);
            }
        }
    ];

    // check returns null when the action applies, or the reason it does not -
    // the same contract the context menu uses, so an inapplicable action greys
    // out with its reason rather than vanishing.
    var SELECTION_ACTIONS = [
        {
            id: 'select-shared-foundation',
            label: function () { return str('SelectionActionSelectFoundation'); },
            check: function (selected) {
                if (sharedFoundation(selected).empty()) { return str('SelectionNoneShared'); }
                return null;
            },
            run: function (selected) { sharedFoundation(selected).select(); }
        },
        {
            id: 'copy-names',
            label: function () { return str('SelectionActionCopyNames'); },
            check: function () { return null; },
            run: function (selected) {
                copyText(selected.map(function (n) { return n.data('name'); }).sort().join('\n'));
            }
        },
        {
            id: 'copy-paths',
            label: function () { return str('SelectionActionCopyPaths'); },
            check: function (selected) {
                if (selected.filter(function (n) { return !!n.data('path'); }).empty()) {
                    return str('ReasonNoFile');
                }
                return null;
            },
            run: function (selected) {
                var paths = [];
                selected.forEach(function (n) {
                    if (n.data('path')) { paths.push(absolutePathFor(n) || n.data('path')); }
                });
                copyText(paths.sort().join('\n'));
            }
        },
        {
            id: 'copy-editor-links',
            label: function () { return str('SelectionActionCopyLinks'); },
            check: function (selected) {
                if (selected.filter(function (n) { return !editorLinkCheck(n); }).empty()) {
                    return str('ReasonNoFile');
                }
                return null;
            },
            run: function (selected) {
                var uris = [];
                selected.forEach(function (n) {
                    if (!editorLinkCheck(n)) { uris.push(vsCodeUriFor(n)); }
                });
                copyText(uris.join('\n'));
            }
        },
        {
            id: 'clear',
            label: function () { return str('SelectionActionClear'); },
            check: function () { return null; },
            run: function (selected) { selected.unselect(); }
        }
    ];

    function renderSelection() {
        var selected = cy.nodes(':selected').filter(function (n) { return !n.hasClass('hidden'); });

        // One item is the Details panel's job; the panel is for the questions
        // that only arise once there is more than one.
        if (selected.length < 2) {
            if (panelOwner === 'selection') { hideInfoPanel(); }
            return;
        }

        var rows = SELECTION_FACTS.map(function (fact) {
            return [fact.label(), fact.value(selected)];
        });

        var actions = SELECTION_ACTIONS.map(function (action) {
            var reason = action.check ? action.check(selected) : null;
            return {
                label: action.label(),
                reason: reason,
                run: function () { action.run(selected); }
            };
        });

        showInfoPanel(fmt('SelectionTitle', { count: selected.length }), null, {
            rows: rows,
            actions: actions,
            owner: 'selection'
        });
    }

    // Re-rendered rather than patched: an action may change the selection it was
    // computed from, and every fact is cheap on a graph this size.
    cy.on('select unselect', 'node', renderSelection);
