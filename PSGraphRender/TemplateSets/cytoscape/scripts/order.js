    // ---- test order ------------------------------------------------------
    // An edge source -> target means source calls target, so source DEPENDS ON
    // target. Anything that depends on nothing can be tested in isolation, so it
    // goes first; everything else waits for what it rests on. Test in this order
    // and the first failure is the cause, not an echo of something earlier.
    //
    //   level(n) = 0                        if n depends on nothing internal
    //   level(n) = 1 + max(level(deps(n)))  otherwise
    //
    // Kahn's algorithm, so a cycle cannot spin forever: anything still
    // unassigned when the queue drains is part of one, and gets reported rather
    // than given a fake position in the order.
    function computeTestOrder(nodeList, edgeList) {
        var ids = nodeList.map(function (n) { return n.id; });
        var known = {};
        ids.forEach(function (id) { known[id] = true; });

        var deps = {};
        var dependents = {};
        ids.forEach(function (id) { deps[id] = []; dependents[id] = []; });

        edgeList.forEach(function (e) {
            if (e.source === e.target) { return; }   // self-call is not a dependency
            if (!known[e.source] || !known[e.target]) { return; }
            deps[e.source].push(e.target);
            dependents[e.target].push(e.source);
        });

        // Parallel edges would otherwise decrement the in-degree more than once.
        ids.forEach(function (id) {
            deps[id] = uniq(deps[id]);
            dependents[id] = uniq(dependents[id]);
        });

        var remaining = {};
        var level = {};
        var queue = [];
        ids.forEach(function (id) {
            remaining[id] = deps[id].length;
            if (remaining[id] === 0) { level[id] = 0; queue.push(id); }
        });

        for (var head = 0; head < queue.length; head++) {
            var current = queue[head];
            dependents[current].forEach(function (d) {
                if (level[d] !== undefined) { return; }
                remaining[d] -= 1;
                if (remaining[d] > 0) { return; }
                var max = -1;
                deps[d].forEach(function (x) {
                    if (level[x] !== undefined && level[x] > max) { max = level[x]; }
                });
                level[d] = max + 1;
                queue.push(d);
            });
        }

        var cyclic = ids.filter(function (id) { return level[id] === undefined; });
        return { level: level, deps: deps, dependents: dependents, cyclic: cyclic };
    }

    var internal = nodes.filter(function (n) { return n.kind !== 'External'; });
    var order = computeTestOrder(internal, links);

    var maxLevel = -1;
    Object.keys(order.level).forEach(function (id) {
        if (order.level[id] > maxLevel) { maxLevel = order.level[id]; }
    });
    var stepCount = maxLevel + 1;
