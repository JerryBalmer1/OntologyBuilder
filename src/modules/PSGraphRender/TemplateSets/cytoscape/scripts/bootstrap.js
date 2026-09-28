const DATA = /*__DATA__*/ null;
const META = /*__META__*/ null;
const CONFIG = /*__CONFIG__*/ null;
const STRINGS = /*__STRINGS__*/ null;

(function () {
    'use strict';

    // The library is embedded in this document, so this is no longer a network
    // failure and the CDN guard that used to say so is gone. What survives is
    // the half of that message still capable of being true: the page went
    // blank and here is why, rather than the page went blank.
    if (typeof cytoscape === 'undefined') {
        var fatal = document.createElement('div');
        fatal.className = 'fatal';
        var heading = document.createElement('h2');
        heading.textContent = str('LibraryMissingHeading');
        var body = document.createElement('p');
        body.textContent = str('LibraryMissingBody');
        fatal.appendChild(heading);
        fatal.appendChild(body);
        document.body.appendChild(fatal);
        return;
    }

    // Opened as a raw template rather than a generated report.
    if (!DATA) {
        document.getElementById('template-notice').hidden = false;
        return;
    }

    document.getElementById('app').hidden = false;

    // Starting values come from this template set's Config/, substituted above.
    // PowerShell validates and fills every key before it gets here, so the
    // fallbacks below are only ever reached by someone opening the raw
    // template - which bails out earlier anyway. They exist so a missing key
    // can never yield NaN and silently collapse the layout.
    function cfg(key, fallback) {
        var v = CONFIG ? CONFIG[key] : null;
        return (typeof v === 'number' && isFinite(v)) ? v : fallback;
    }

    // cfg() is numeric only, so a string or enum setting needs its own reader:
    // a perfectly valid value would otherwise fail the isFinite test and fall
    // back to the default every time.
    function cfgText(key, fallback) {
        var v = CONFIG ? CONFIG[key] : null;
        return (typeof v === 'string' && v.length) ? v : fallback;
    }

    // Same reason again for a list setting. A heat ramp is one decision, so it
    // is one entry rather than five numbered ones - which means a reader that
    // handles only scalars cannot see it.
    function cfgList(key, fallback) {
        var v = CONFIG ? CONFIG[key] : null;
        return (Object.prototype.toString.call(v) === '[object Array]' && v.length) ? v : fallback;
    }

    // User-visible text comes from this set's Config/strings.psd1, substituted
    // above. A missing key renders as its own name in brackets rather than as
    // nothing: a silently blank label is the one failure mode nobody notices.
    function str(key) {
        var v = STRINGS ? STRINGS[key] : null;
        return (typeof v === 'string' && v.length) ? v : '[' + key + ']';
    }

    // Whether a key was actually supplied, as opposed to defaulting. Used for
    // the values the caller passes through config, which may legitimately be
    // absent - str() alone cannot tell absent from present-and-bracketed.
    function hasStr(key) {
        var v = STRINGS ? STRINGS[key] : null;
        return typeof v === 'string' && v.length > 0;
    }

    // {token} substitution for the values only the browser knows at display
    // time. Deliberately not a template language: an unfilled token is left as
    // written, so it shows up rather than disappearing.
    function fmt(key, values) {
        return str(key).replace(/\{(\w+)\}/g, function (match, name) {
            return Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : match;
        });
    }

    // Same reason again for a map setting: a classification-to-colour map is
    // one decision and one entry, and a reader that handles only scalars
    // cannot see it.
    function cfgMap(key) {
        var v = CONFIG ? CONFIG[key] : null;
        return (v && typeof v === 'object' && Object.prototype.toString.call(v) !== '[object Array]') ? v : {};
    }

    var NODE_LIMIT = cfg('NodeLimit', 400);
    var ZOOM_SPEED_DEFAULT = cfg('ZoomSpeed', 1.25);

    // From theme.psd1. This was a literal here until v0.3.0 -
    //   KIND_HEX = { Function: ..., Class: ..., Enum: ..., Script: ... }
    // which is a hardcoded list of one producer's node kinds inside a renderer
    // that must not have one. There is no fallback map: an empty one and the
    // fallback colour render every node in KIND_FALLBACK, which is visibly
    // wrong rather than quietly PowerShell-shaped.
    var KIND_HEX = cfgMap('KindColor');
    var KIND_FALLBACK = cfgText('KindColorFallback', '#8895a7');

    // The colour of a node this renderer invented, which is not a
    // classification anything sent. See theme.psd1.
    var UNRESOLVED_COLOR = cfgText('UnresolvedColor', '#ff7043');

    // Link classifications, same story. render.js used to carry
    //   edge[kind = "Inherits"]  with a literal colour
    // which is a producer's word in a renderer that must not have one.
    var LINK_HEX = cfgMap('LinkColor');
    var EDGE_COLOR = cfgText('EdgeColor', '#6b7785');

    // How a link is drawn for each value of links[].resolution, from
    // theme.psd1. The renderer knows none of the values; it looks up whatever
    // the payload states, exactly as KIND_HEX looks up a node classification.
    // An empty map draws every link alike, which is what a payload that states
    // nothing deserves.
    var EDGE_RESOLUTION_STYLE = cfgMap('EdgeResolutionStyle');

    var meta = META || {};
    var data = DATA;
    var COLOR_BY = cfgText('ColorBy', 'structure');
    var nodes = DATA.nodes || [];
    var links = DATA.links || [];
    var unresolved = DATA.unresolved || [];

    function uniq(arr) {
        return arr.filter(function (v, i, a) { return a.indexOf(v) === i; });
    }

    function escapeHtml(s) {
        return String(s === null || s === undefined ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

/*__SLOT_SCRIPT_ORDER__*/
    // ---- header ----------------------------------------------------------
    document.getElementById('hdr-version').textContent =
        (meta.version ? str('HeaderVersionPrefix') + meta.version : '') +
        (meta.generatedAt ? str('HeaderGeneratedPrefix') + meta.generatedAt : '');
    document.getElementById('c-nodes').textContent = nodes.length;
    document.getElementById('c-edges').textContent = links.length;
    document.getElementById('c-steps').textContent = stepCount;

/*__SLOT_SCRIPT_ELEMENTS__*/
/*__SLOT_SCRIPT_RENDER__*/
/*__SLOT_SCRIPT_FOUNDATION__*/
/*__SLOT_SCRIPT_SIDEBAR__*/
/*__SLOT_SCRIPT_FILTERS__*/
/*__SLOT_SCRIPT_FOCUS__*/
/*__SLOT_SCRIPT_EDITOR_LINK__*/
/*__SLOT_SCRIPT_DIAGNOSTICS__*/
/*__SLOT_SCRIPT_SELECTION__*/
/*__SLOT_SCRIPT_MENU__*/
/*__SLOT_SCRIPT_CONTROLS__*/
    // ---- sidebar splitter ------------------------------------------------
    // Cytoscape only notices a container size change when it is told, so every
    // width change ends in cy.resize(). The layout is deliberately NOT re-run:
    // re-ranking mid-drag would move the nodes the user is reading.
    var splitterEl = document.getElementById('splitter');
    var sidebarEl = document.getElementById('sidebar');
    var SIDEBAR_MIN = cfg('SidebarMinWidth', 200);
    var SIDEBAR_DEFAULT = cfg('SidebarWidth', 300);
    var CANVAS_MIN = cfg('CanvasMinWidth', 320);
    var resizeFrame = null;

    function setSidebarWidth(px) {
        // Never let the drag squeeze the graph out of existence, and never let
        // the clamp itself push the sidebar below its own minimum.
        var max = Math.max(SIDEBAR_MIN, window.innerWidth - CANVAS_MIN);
        var w = Math.round(Math.min(Math.max(px, SIDEBAR_MIN), max));
        sidebarEl.style.flexBasis = w + 'px';
        sidebarEl.style.width = w + 'px';
        splitterEl.setAttribute('aria-valuenow', String(w));
        // Coalesce to one resize per frame; pointermove fires far faster.
        if (resizeFrame !== null) { return; }
        resizeFrame = requestAnimationFrame(function () {
            resizeFrame = null;
            cy.resize();
        });
    }

    splitterEl.addEventListener('pointerdown', function (ev) {
        // Pointer capture keeps the drag alive over the canvas, where
        // Cytoscape would otherwise swallow the move events.
        ev.preventDefault();
        splitterEl.setPointerCapture(ev.pointerId);
        splitterEl.classList.add('dragging');
        document.body.classList.add('resizing');
    });

    splitterEl.addEventListener('pointermove', function (ev) {
        if (!splitterEl.classList.contains('dragging')) { return; }
        setSidebarWidth(ev.clientX - sidebarEl.getBoundingClientRect().left);
    });

    function endResize(ev) {
        if (!splitterEl.classList.contains('dragging')) { return; }
        splitterEl.classList.remove('dragging');
        document.body.classList.remove('resizing');
        try { splitterEl.releasePointerCapture(ev.pointerId); } catch (err) { /* already gone */ }
        cy.resize();
    }
    splitterEl.addEventListener('pointerup', endResize);
    splitterEl.addEventListener('pointercancel', endResize);

    splitterEl.addEventListener('dblclick', function () {
        setSidebarWidth(SIDEBAR_DEFAULT);
    });

    splitterEl.addEventListener('keydown', function (ev) {
        var step = ev.shiftKey ? 40 : 10;
        var current = sidebarEl.getBoundingClientRect().width;
        if (ev.key === 'ArrowLeft') { setSidebarWidth(current - step); }
        else if (ev.key === 'ArrowRight') { setSidebarWidth(current + step); }
        else if (ev.key === 'Home') { setSidebarWidth(SIDEBAR_DEFAULT); }
        else { return; }
        ev.preventDefault();
    });

    // A window narrow enough to violate the clamp has to be re-clamped, or the
    // sidebar keeps a width that leaves no canvas at all.
    window.addEventListener('resize', function () {
        setSidebarWidth(sidebarEl.getBoundingClientRect().width);
    });

    setSidebarWidth(SIDEBAR_DEFAULT);

    // ---- banner ----------------------------------------------------------
    // One banner, several possible messages. Appending rather than assigning is
    // the point: a second condition used to overwrite the first, so whichever
    // guard ran last was the only one the user ever saw.
    var banner = document.getElementById('banner');
    var bannerMessages = [];
    var bannerCopyEl = document.getElementById('banner-copy');
    var bannerCopyValue = null;
    bannerCopyEl.addEventListener('click', function () {
        if (bannerCopyValue) { copyText(bannerCopyValue); }
    });
    document.getElementById('banner-close').addEventListener('click', function () {
        banner.style.display = 'none';
    });

    // copyValue is optional: a message that names something worth pasting
    // elsewhere gets a button, and the rest do not. The button is the whole
    // point of the no-launch message - a user reading it cannot click a link
    // that has just been shown not to work.
    //
    // copyLabelKey travels with it. Two different messages now want a copy
    // button for two different things - a command, and this page's own URL -
    // and a fixed 'Copy command' label on a button that copies a URL is a
    // message that lies.
    function showBanner(text, copyValue, copyLabelKey) {
        bannerMessages.push(text);
        document.getElementById('banner-text').textContent = bannerMessages.join(' ');
        if (copyValue) {
            bannerCopyValue = copyValue;
            bannerCopyEl.textContent = str(copyLabelKey || 'BannerCopyLabel');
            bannerCopyEl.hidden = false;
        }
        banner.style.display = 'flex';
    }

    // ---- scale guard -----------------------------------------------------
    if (nodes.length > NODE_LIMIT) {
        exportedOnlyEl.checked = true;
        showBanner(fmt('ScaleGuard', { count: nodes.length, limit: NODE_LIMIT }));
    }

    // ---- embedded viewer guard -------------------------------------------
    // Said on load, not only in the context menu: a user who never right-clicks
    // would otherwise never learn the page is running degraded.
    //
    // "Re-open this report in a real browser" leaves the reader to work out
    // WHERE. The page is sitting on the answer, so it shows it with a copy
    // button - the same mechanism, and the same reason, as the command button
    // on the no-launch message. A file:// document has an address worth
    // pasting too, so this is not limited to the served case.
    if (isEmbeddedContext()) {
        if (location.href) {
            showBanner(fmt('EmbeddedViewerUrl', { url: location.href }), location.href, 'BannerCopyUrlLabel');
        }
        else {
            showBanner(str('EmbeddedViewer'));
        }
    }

    // First paint. Filters run before the first layout, so nodes that start
    // hidden - unresolved externals are off by default - never occupy space in
    // it. Cytoscape excludes display:none elements from layouts.
    //
    // Filter, lay out, fit is one act and not three: every later change to the
    // visible set does the same three things in the same order, so they are
    // one call. When they were three, this was the only place all three ran.
    renderOrder();
    applyStructuralFilters();
}());