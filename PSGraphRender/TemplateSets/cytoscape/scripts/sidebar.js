    // ---- telling two nodes with one label apart --------------------------
    // A label is not an identity. Two nodes can carry the same name and mean
    // different things - the `ambiguous` fixture has two definitions of
    // `restart` in two files, and SqlServerDsc has 234 of its 532 nodes in a
    // group that shares a name, one of them 32 deep. The lists below showed
    // names, so `restart` in one test step and `restart` in the next read as
    // one node listed twice rather than two nodes listed once each. 0008-t2.
    //
    // Only an ambiguous name is qualified. Qualifying all 532 would push the
    // useful part of the list off the side of the sidebar to solve a problem
    // 54 names have.
    //
    // The qualifier is the SHORTEST TRAILING RUN of path segments that
    // separates one member of the group from the others - the file name alone
    // where that is enough, more when it is not. A whole path would be up to
    // 148 characters of shared prefix for one distinguishing segment, and the
    // shared prefix is the part that says nothing. The id is the fallback: it
    // is unique by contract, so it always terminates, which a path scheme
    // alone cannot promise.
    function pathSegments(value) {
        return String(value || '').split(/[\\/]/).filter(function (s) { return s; });
    }

    // Two vendored copies of one file can agree for four segments and differ
    // only at a version directory, which makes the shortest unique run five
    // segments and sixty characters - three wrapped lines of qualifier under a
    // one-line name. The middle of that run is the part that says nothing, so
    // past three segments it is elided.
    //
    // Elision can collide where the full run did not, so the elided forms are
    // checked and the full run kept when they do. A qualifier that no longer
    // qualifies is worse than a long one.
    var QUALIFIER_SEGMENT_LIMIT = 3;

    function elideRun(segments) {
        if (segments.length <= QUALIFIER_SEGMENT_LIMIT) { return segments.join('/'); }
        return segments[0] + '/…/' + segments[segments.length - 1];
    }

    function allDistinct(values) {
        return values.every(function (v, at) {
            return values.indexOf(v) === at && values.lastIndexOf(v) === at;
        });
    }

    var duplicateQualifier = (function () {
        var byName = {};
        internal.forEach(function (n) {
            if (!byName[n.name]) { byName[n.name] = []; }
            byName[n.name].push(n);
        });

        var qualifier = {};
        Object.keys(byName).forEach(function (name) {
            var group = byName[name];
            if (group.length < 2) { return; }

            var parts = group.map(function (n) { return pathSegments(n.path); });
            var deepest = 0;
            parts.forEach(function (p) { if (p.length > deepest) { deepest = p.length; } });

            for (var take = 1; take <= deepest; take++) {
                var runs = parts.map(function (p) { return p.slice(-take); });
                if (!allDistinct(runs.map(function (r) { return r.join('/'); }))) { continue; }

                var shown = runs.map(elideRun);
                if (!allDistinct(shown)) { shown = runs.map(function (r) { return r.join('/'); }); }
                group.forEach(function (n, at) { qualifier[n.id] = shown[at]; });
                return;
            }
            // No depth of path separates them, or they carry no path at all.
            group.forEach(function (n) { qualifier[n.id] = n.id; });
        });
        return qualifier;
    })();

    // ---- test order list -------------------------------------------------
    function renderOrder() {
        var byLevel = [];
        var i;
        for (i = 0; i < stepCount; i++) { byLevel.push([]); }

        internal.forEach(function (n) {
            var lvl = order.level[n.id];
            if (lvl === undefined) { return; }
            byLevel[lvl].push(n);
        });

        var html = byLevel.map(function (group, index) {
            group.sort(function (a, b) { return a.name.localeCompare(b.name); });
            var names = group.map(function (n) {
                var qualifier = duplicateQualifier[n.id];
                return '<span class="' + (n.isExported ? 'exp' : 'priv') + '">' +
                       escapeHtml(n.name) + '</span>' +
                       (qualifier ? '<span class="qual">' + escapeHtml(qualifier) + '</span>' : '');
            }).join(', ');
            return '<div class="order-step"><span class="lvl">' + (index + 1) + '</span>' +
                   '<span class="names">' + names + '</span></div>';
        }).join('');

        document.getElementById('order-list').innerHTML = html;
        document.getElementById('order-intro').textContent = str('OrderIntro');

        var cycleBox = document.getElementById('order-cycle');
        if (order.cyclic.length > 0) {
            // Plain text here rather than the span the step list uses: this
            // box is one interpolated string, and strings.psd1 holds no markup
            // so the whole of it is escaped as one blob.
            var byId = {};
            internal.forEach(function (n) {
                var qualifier = duplicateQualifier[n.id];
                byId[n.id] = qualifier ? n.name + ' (' + qualifier + ')' : n.name;
            });
            var names = order.cyclic.map(function (id) { return byId[id] || id; }).sort().join(', ');
            // The emphasis is the page's, not the string's: strings.psd1 holds
            // no markup, so a message can never inject an element.
            cycleBox.innerHTML = '<b>' +
                escapeHtml(fmt('OrderCycleHeading', { count: order.cyclic.length })) + '</b> ' +
                escapeHtml(fmt('OrderCycleBody', { names: names }));
            cycleBox.hidden = false;
        } else {
            cycleBox.hidden = true;
        }
    }

    // ---- kind checkboxes, generated from the data ------------------------
    var kindCounts = {};
    cy.nodes().forEach(function (n) {
        var k = n.data('kind');
        kindCounts[k] = (kindCounts[k] || 0) + 1;
    });
    var kinds = Object.keys(kindCounts).filter(function (k) { return k !== 'External'; }).sort();

    var kindBox = document.getElementById('kind-filters');
    kinds.forEach(function (k) {
        var id = 'kind-' + k;
        var label = document.createElement('label');
        label.className = 'check';
        label.innerHTML =
            '<input type="checkbox" id="' + id + '" data-kind="' + k + '" checked>' +
            '<span class="swatch" style="background:' + (KIND_HEX[k] || KIND_FALLBACK) + '"></span>' +
            '<span>' + k + '</span><span class="count">' + kindCounts[k] + '</span>';
        kindBox.appendChild(label);
        // Structural, like the two boxes under Filters: ticking a kind back on
        // reveals nodes, and a revealed node needs a layout that included it.
        label.querySelector('input').addEventListener('change', applyStructuralFilters);
    });

    if (unresolved.length > 0) {
        document.getElementById('unresolved-wrap').hidden = false;
    }

    // ---- colour by -------------------------------------------------------
    // One radio per option, built from the metric ids the PAYLOAD carries plus
    // 'structure'. Adding a metric is a change in the producer, a value in the
    // ColorBy enum, and two strings - no branch here. Same shape as
    // NODE_ACTIONS and FLOW_LAYOUT, and for the same reason.
    //
    // Metric label and hint keys are mechanical: 'Metric' + the id, capitalised.
    function metricStringKey(id, suffix) {
        return 'Metric' + id.charAt(0).toUpperCase() + id.slice(1) + (suffix || '');
    }

    var colorByOptions = [{
        id: 'structure',
        label: str('ColorByStructure'),
        hint: str('ColorByStructureHint')
    }].concat(METRIC_IDS.map(function (id) {
        return { id: id, label: str(metricStringKey(id)), hint: str(metricStringKey(id, 'Hint')) };
    }));

    document.getElementById('colorby-heading').textContent = str('ColorByHeading');
    document.getElementById('colorby-encoding').textContent = str('ColorByEncoding');
    document.getElementById('colorby-options').innerHTML = colorByOptions.map(function (o) {
        // Checked is set from config, never from markup - a checked attribute
        // in the partial would make editing settings.psd1 silently do nothing.
        return '<label><input type="radio" name="colorby" value="' + escapeHtml(o.id) + '"' +
            (o.id === COLOR_BY ? ' checked' : '') + '> ' + escapeHtml(o.label) +
            ' <span class="hint">(' + escapeHtml(o.hint) + ')</span></label>';
    }).join('');

    function applyColorBy(choice) {
        COLOR_BY = choice;
        cy.batch(function () {
            nodes.forEach(function (n) {
                var el = cy.getElementById(n.id);
                if (el && el.length) { el.data('color', fillFor(n, choice)); }
            });
        });
        renderLegend();
    }

    Array.prototype.forEach.call(
        document.querySelectorAll('input[name="colorby"]'),
        function (input) {
            input.addEventListener('change', function () {
                if (input.checked) { applyColorBy(input.value); }
            });
        });

    // ---- legend ----------------------------------------------------------
    // Redrawn on every colour-by change: a legend that keeps showing kind
    // swatches while the canvas is painted by blast radius is a legend that
    // lies, which this subsystem already rules worse than no legend at all.
    var legend = document.getElementById('legend');

    function heatLegendRows(metricId) {
        var values = nodes.map(function (n) {
            var m = n.metrics || {};
            return typeof m[metricId] === 'number' ? m[metricId] : 0;
        });
        var low = values.length ? Math.min.apply(null, values) : 0;
        var high = values.length ? Math.max.apply(null, values) : 0;

        var strip = HEAT_RAMP.map(function (c) {
            return '<span class="chip" style="background:' + c + ';border-radius:0"></span>';
        }).join('');

        // The range moved off the line under the strip and onto the line that
        // says the strip is not an axis. Beside the swatches it read as one.
        return [
            '<div class="row">' + strip + '</div>',
            '<div class="row"><span class="hint">' +
            escapeHtml(fmt('LegendHeatScale', { metric: str(metricStringKey(metricId)) })) +
            '</span></div>',
            '<div class="row"><span class="hint">' +
            escapeHtml(fmt('LegendHeatRank', { low: low, high: high })) + '</span></div>'
        ];
    }

    function renderLegend() {
        var legendRows;
        if (METRIC_IDS.indexOf(COLOR_BY) === -1) {
            legendRows = kinds.map(function (k) {
                return '<div class="row"><span class="chip" style="background:' + (KIND_HEX[k] || KIND_FALLBACK) + '"></span>' + k + '</div>';
            });
        }
        else {
            legendRows = heatLegendRows(COLOR_BY);
        }
        legendRows.push('<div class="row"><span class="chip" style="background:#4da3ff;border:2px solid #fff"></span>' + escapeHtml(str('LegendExported')) + '</div>');
        legendRows.push('<div class="row"><span class="chip" style="background:#4da3ff;border:5px solid #0b0f14"></span>' + escapeHtml(str('LegendBorderWidth')) + '</div>');
        legendRows.push('<div class="row"><span class="line" style="border-top:2px solid ' + EDGE_COLOR + '"></span>' + escapeHtml(str('LegendCalls')) + '</div>');

        // One row per link classification the theme names, in the theme's
        // order. The label comes from strings.psd1 under 'LegendLink' + kind
        // and falls back to the kind itself, so a producer that ships neither
        // still gets a legend that says something true.
        Object.keys(LINK_HEX).forEach(function (kind) {
            var key = 'LegendLink' + kind;
            var label = hasStr(key) ? str(key) : kind;
            legendRows.push('<div class="row"><span class="line" style="border-top:2px dashed ' +
                LINK_HEX[kind] + '"></span>' + escapeHtml(label) + '</div>');
        });

        if (unresolved.length > 0) {
            legendRows.push('<div class="row"><span class="line" style="border-top:2px dotted ' + UNRESOLVED_COLOR + '"></span>' + escapeHtml(str('LegendUnresolved')) + '</div>');
        }
        legend.innerHTML = legendRows.join('');
    }

    renderLegend();
