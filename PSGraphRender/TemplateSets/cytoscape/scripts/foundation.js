    // ---- foundation layout -----------------------------------------------
    // A layered drawing, built the usual way: assign layers, reduce crossings
    // between adjacent layers, then place. dagre does all three and is used for
    // the other two views - but none of its rankers can bound how wide a layer
    // gets. longest-path pins every node with no dependencies to one extreme
    // layer, which on this module put 29 of 62 nodes in a single row and drew
    // the graph at 11:1. Nothing readable survives being fitted to a screen at
    // that shape.
    //
    // Bounding the layer width and letting the layer count grow instead is the
    // standard answer (Coffman-Graham with a layer capacity, used iteratively
    // to hit an aspect ratio). Measured on the same graph it comes out near
    // 2:1. See the gravity rule in CLAUDE.md.

    // Enough passes to settle, few enough to stay instant. The median heuristic
    // converges fast and alternating direction is what stops it oscillating.
    var CROSSING_SWEEPS = 4;

    // Layer 0 is the foundation and is drawn at the bottom. A node goes in the
    // lowest layer that sits above every one of its dependencies and is not yet
    // full; when that layer is full it rises, and that is the whole width bound.
    function assignLayers(ids, deps, capacity) {
        var layer = {};
        var fill = {};
        var remaining = ids.slice();
        var guard = 0;

        while (remaining.length && guard++ <= ids.length + 1) {
            var next = [];
            remaining.forEach(function (id) {
                var floor = 0;
                var ready = true;
                deps[id].forEach(function (d) {
                    if (!(d in layer)) { ready = false; return; }
                    if (layer[d] + 1 > floor) { floor = layer[d] + 1; }
                });
                if (!ready) { next.push(id); return; }

                var target = floor;
                while ((fill[target] || 0) >= capacity) { target++; }
                layer[id] = target;
                fill[target] = (fill[target] || 0) + 1;
            });

            // Nothing became placeable, so what is left is in a cycle. Stack it
            // above everything already placed rather than spinning: a cycle has
            // no valid layering and dropping the nodes would hide them.
            if (next.length === remaining.length) {
                var top = 0;
                Object.keys(layer).forEach(function (id) {
                    if (layer[id] + 1 > top) { top = layer[id] + 1; }
                });
                next.forEach(function (id) {
                    var target = top;
                    while ((fill[target] || 0) >= capacity) { target++; }
                    layer[id] = target;
                    fill[target] = (fill[target] || 0) + 1;
                });
                return layer;
            }
            remaining = next;
        }
        return layer;
    }

    // Median heuristic, swept up and then down. A node moves to the median
    // position of its neighbours in the layer being swept against, which is the
    // cheap standard first choice for crossing reduction.
    function reduceCrossings(layers, deps, dependents) {
        function medianKey(id, reference, relation, fallback) {
            var positions = [];
            relation[id].forEach(function (other) {
                var at = reference.indexOf(other);
                if (at >= 0) { positions.push(at); }
            });
            if (!positions.length) { return fallback; }
            positions.sort(function (a, b) { return a - b; });
            return positions[Math.floor(positions.length / 2)];
        }

        for (var sweep = 0; sweep < CROSSING_SWEEPS; sweep++) {
            var upward = (sweep % 2) === 0;
            for (var step = 1; step < layers.length; step++) {
                var index = upward ? step : layers.length - 1 - step;
                var referenceIndex = upward ? index - 1 : index + 1;
                if (referenceIndex < 0 || referenceIndex >= layers.length) { continue; }

                // A layer's dependencies are below it and its dependents above,
                // so which relation points at the reference layer depends on
                // which way the sweep is going.
                var reference = layers[referenceIndex];
                var relation = upward ? deps : dependents;
                var keys = {};
                layers[index].forEach(function (id, at) {
                    keys[id] = medianKey(id, reference, relation, at);
                });
                // Array.prototype.sort is stable, so a node with no neighbour in
                // the reference layer keeps its place instead of drifting.
                layers[index] = layers[index].slice().sort(function (a, b) {
                    return keys[a] - keys[b];
                });
            }
        }
        return layers;
    }

    // Solve the capacity that lands the drawing on the container's own aspect.
    // Width is capacity * stepX and height is (count / capacity) * stepY, so
    // setting their ratio to the container's and rearranging gives the root
    // below. A pinned setting wins; deriving it is what keeps the result
    // readable on a laptop and on a wall display without a second setting.
    function foundationCapacity(count, stepX, stepY) {
        var pinned = cfg('FoundationLayerCapacity', 0);
        if (pinned >= 1) { return Math.max(1, Math.round(pinned)); }

        var box = cy.container().getBoundingClientRect();
        var aspect = (box.width > 0 && box.height > 0) ? (box.width / box.height) : (16 / 9);
        var derived = Math.sqrt((aspect * count * stepY) / stepX);
        return Math.max(3, Math.min(count, Math.round(derived)));
    }

    // Positions for every node IN THE SET, keyed by id. A node the reader has
    // filtered out is left out deliberately: it is not part of the drawing and
    // would otherwise reserve width it does not occupy.
    //
    // The set, not the screen. A node hidden only by the search box is still
    // part of the drawing and is placed here, so it keeps its slot while
    // somebody types and returns to it when they stop. See filters.js - the
    // version that read `.hidden` laid out without the searched-away nodes and
    // left them stale, which is 0013-t1.
    function foundationPositions() {
        var inSet = cy.nodes().filter(function (n) { return !n.hasClass('not-in-set'); });
        var ids = inSet.map(function (n) { return n.id(); });
        var known = {};
        ids.forEach(function (id) { known[id] = true; });

        var deps = {};
        var dependents = {};
        ids.forEach(function (id) { deps[id] = []; dependents[id] = []; });

        cy.edges().forEach(function (e) {
            // `not-in-set` for the same reason the nodes use it: an edge whose
            // ends are both in the drawing still constrains the layering while
            // a search happens to be hiding one of them.
            if (e.hasClass('not-in-set')) { return; }
            var from = e.source().id();
            var to = e.target().id();
            // An edge source -> target means source depends on target, so the
            // target belongs below. Self-calls are not a dependency.
            if (from === to || !known[from] || !known[to]) { return; }
            if (deps[from].indexOf(to) === -1) { deps[from].push(to); }
            if (dependents[to].indexOf(from) === -1) { dependents[to].push(from); }
        });

        var stepX = NODE_WIDTH + cfg('NodeSep', 14);
        var stepY = NODE_HEIGHT + cfg('RankSep', 80);
        var capacity = foundationCapacity(ids.length, stepX, stepY);
        var layer = assignLayers(ids, deps, capacity);

        var layers = [];
        ids.forEach(function (id) {
            var at = layer[id] || 0;
            while (layers.length <= at) { layers.push([]); }
            layers[at].push(id);
        });
        layers = reduceCrossings(layers, deps, dependents);

        var widest = 0;
        layers.forEach(function (row) { if (row.length > widest) { widest = row.length; } });

        var positions = {};
        layers.forEach(function (row, at) {
            // Rows are centred on each other, and layer 0 takes the largest y.
            // Cytoscape's y grows downward, so that is the bottom of the page:
            // what everything rests on is what the reader starts from.
            var offset = ((widest - row.length) * stepX) / 2;
            var y = (layers.length - 1 - at) * stepY;
            row.forEach(function (id, column) {
                positions[id] = { x: offset + (column * stepX), y: y };
            });
        });

        document.documentElement.setAttribute('data-foundation-capacity', String(capacity));
        document.documentElement.setAttribute('data-foundation-layers', String(layers.length));
        return positions;
    }
