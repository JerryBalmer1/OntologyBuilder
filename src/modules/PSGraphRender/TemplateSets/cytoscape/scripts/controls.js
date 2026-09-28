    function clearFocus() {
        focused = null;
        clearFocusStyling();
        cy.nodes().removeClass('selected-node');
        document.getElementById('focus-controls').hidden = true;
        document.getElementById('focus-hint').textContent = str('FocusHintEmpty');
        document.getElementById('details-list').hidden = true;
        document.getElementById('details-empty').hidden = false;
    }

    // Which view the report opens in is a data decision, so the markup carries
    // no checked attribute. An unrecognised value leaves nothing checked, and
    // currentFlow() falls back to the same default rather than to whichever
    // radio happens to be first.
    var startFlow = document.querySelector('input[name="flow"][value="' + cfgText('DefaultFlow', 'foundation') + '"]');
    if (startFlow) { startFlow.checked = true; }

    depthEl.value = String(cfg('FocusDepth', 2));
    depthVal.textContent = depthEl.value;
    depthEl.addEventListener('input', function () {
        depthVal.textContent = depthEl.value;
        reapplyFocus();
    });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="dir"]'), function (r) {
        r.addEventListener('change', reapplyFocus);
    });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="flow"]'), function (r) {
        r.addEventListener('change', function () { runLayout(); fitVisible(); });
    });
    document.getElementById('clear-focus').addEventListener('click', clearFocus);
    document.getElementById('fit').addEventListener('click', function () {
        runLayout();
        fitVisible();
    });

    // Wheel sensitivity lives on the renderer and is read at event time, so it
    // can be changed live. It is not part of Cytoscape's public API, hence the
    // guard: if a future version moves it, the slider goes inert rather than
    // throwing and taking the page down with it.
    var zoomSpeedEl = document.getElementById('zoom-speed');
    var zoomSpeedVal = document.getElementById('zoom-speed-val');

    function applyZoomSpeed() {
        var value = parseFloat(zoomSpeedEl.value);
        if (isNaN(value)) { return; }
        zoomSpeedVal.textContent = value + str('ZoomSpeedSuffix');
        var renderer = cy._private && cy._private.renderer;
        if (renderer && 'wheelSensitivity' in renderer) {
            renderer.wheelSensitivity = value;
        }
    }

    // Range as well as starting value, so the .psd1 is the whole story for this
    // control and the markup's attributes stay placeholders.
    zoomSpeedEl.min = String(cfg('ZoomSpeedMin', 0.25));
    zoomSpeedEl.max = String(cfg('ZoomSpeedMax', 5));
    zoomSpeedEl.step = String(cfg('ZoomSpeedStep', 0.25));
    zoomSpeedEl.value = String(ZOOM_SPEED_DEFAULT);
    zoomSpeedEl.addEventListener('input', applyZoomSpeed);
    applyZoomSpeed();
