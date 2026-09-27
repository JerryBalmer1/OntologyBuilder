    // Every input the launch depends on, in one copyable block. The point is
    // that a failure here is reported rather than reasoned about.
    function diagnosticsFor(node) {
        var rows = [
            ['node.data(path)', node.data('path')],
            ['meta.rootPath', meta.rootPath],
            ['absolutePathFor', absolutePathFor(node)],
            ['vsCodeUriFor', vsCodeUriFor(node)],
            ['node.data(startLine)', node.data('startLine')],
            ['location.protocol', location.protocol],
            ['location.href', location.href],
            ['window.top === window.self', window.top === window.self],
            ['isEmbeddedContext()', isEmbeddedContext()],
            ['navigator.userAgent', navigator.userAgent]
        ];
        return rows.map(function (r) {
            return r[0] + ': ' + (r[1] === undefined ? str('DiagnosticsUndefined') : r[1]);
        }).join('\n');
    }

    // One overlay, several occupants. It takes a title plus any of: a block of
    // preformatted text, a list of label/value rows, and a row of actions.
    // Diagnostics uses the text; the selection panel uses rows and actions. A
    // third caller should need no markup either - see the kaizen note in
    // docs/render-architecture.md.
    var infoPanel = document.getElementById('info-panel');
    var infoBody = document.getElementById('info-body');
    var infoRows = document.getElementById('info-rows');
    var infoActions = document.getElementById('info-actions');
    var panelOwner = null;
    var panelCopyText = '';

    function hideInfoPanel() {
        infoPanel.hidden = true;
        panelOwner = null;
    }

    function showInfoPanel(title, text, options) {
        var opts = options || {};
        document.getElementById('info-title').textContent = title;
        panelOwner = opts.owner || null;

        infoBody.textContent = text || '';
        infoBody.hidden = !text;

        infoRows.textContent = '';
        infoRows.hidden = !opts.rows || !opts.rows.length;
        (opts.rows || []).forEach(function (row) {
            var dt = document.createElement('dt');
            dt.textContent = row[0];
            var dd = document.createElement('dd');
            dd.textContent = row[1];
            infoRows.appendChild(dt);
            infoRows.appendChild(dd);
        });

        infoActions.textContent = '';
        infoActions.hidden = !opts.actions || !opts.actions.length;
        (opts.actions || []).forEach(function (action) {
            var button = document.createElement('button');
            button.type = 'button';
            button.disabled = !!action.reason;
            button.textContent = action.reason
                ? action.label + str('MenuReasonSeparator') + action.reason
                : action.label;
            if (!action.reason) { button.addEventListener('click', action.run); }
            infoActions.appendChild(button);
        });

        // Whatever is on screen is what Copy hands over, rows included.
        panelCopyText = text || (opts.rows || []).map(function (row) {
            return row[0] + ': ' + row[1];
        }).join('\n');

        infoPanel.hidden = false;
    }

    document.getElementById('info-close').addEventListener('click', hideInfoPanel);
    document.getElementById('info-copy').addEventListener('click', function () {
        copyText(panelCopyText);
    });

    // A custom-scheme navigation reports nothing on failure - no error, no
    // console entry, no callback. Losing OS focus is the only observable signal
    // that the URI actually reached an application.
    //
    // A user who declines the browser's own prompt also produces no blur, so
    // this cannot tell "declined" from "no handler". It does not need to: both
    // end at the same fallback.
    var LAUNCH_WATCH_MS = 1200;

    // onNoLaunch is a parameter rather than a hardcoded call so the watcher can
    // be exercised without the banner, and so a second caller could report
    // differently.
    function attemptEditorLaunch(uri, onNoLaunch) {
        var launched = false;
        function onBlur() { launched = true; }

        // Additive: the menu's own blur handler stays registered and still
        // runs. Two listeners on the same event do not displace each other, so
        // closing the menu cannot eat this signal.
        window.addEventListener('blur', onBlur);

        window.setTimeout(function () {
            window.removeEventListener('blur', onBlur);
            if (!launched) { onNoLaunch(uri); }
        }, LAUNCH_WATCH_MS);
    }

    // The uri is part of the reporter contract and another reporter may want
    // it; this one deliberately does not repeat it. What the user needs is the
    // command that unblocks the link, on a button, because the link itself has
    // just been shown not to work.
    //
    // The command name is supplied by whatever generated the report. Without
    // one there is nothing to run, so the message says so rather than reading
    // "Run  in PowerShell".
    // An http origin is one a browser policy can match, and the page knows its
    // own. Offering the command already scoped to it removes the step where the
    // reader edits a generic command to insert a port they have to go and read
    // off the address bar. A file:// document has no origin worth naming, so it
    // gets the generic form.
    function servedOrigin() {
        if (location.protocol !== 'http:' && location.protocol !== 'https:') { return null; }
        return location.origin || null;
    }

    function reportNoLaunch(uri) {
        var origin = servedOrigin();
        if (origin && hasStr('editorLinkHelpCommandForOrigin')) {
            // {editorLinkHelpCommandForOrigin} inside the message was already
            // substituted in PowerShell, because it is a caller token. What is
            // left in both places is {origin}, which only the browser knows.
            var command = fmt('editorLinkHelpCommandForOrigin', { origin: origin });
            showBanner(fmt('EditorLinkNoLaunchOrigin', { origin: origin }), command);
            return;
        }
        if (hasStr('editorLinkHelpCommand')) {
            showBanner(str('EditorLinkNoLaunch'), str('editorLinkHelpCommand'));
            return;
        }
        showBanner(str('EditorLinkNoLaunchNoCommand'));
    }

    function copyText(text) {
        // The textarea route, not navigator.clipboard. Not because the async
        // API is missing - file:// counts as potentially trustworthy in Chrome
        // and Firefox, so it is normally present - but because it is the one
        // path that works everywhere this page gets opened, including framed in
        // a viewer where clipboard permission is not granted to the frame.
        try {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'fixed';
            ta.style.top = '-1000px';
            document.body.appendChild(ta);
            ta.select();
            document.execCommand('copy');
            document.body.removeChild(ta);
        }
        catch (err) {
            // Nothing useful to fall back to, and no way to surface it from a
            // menu that has already closed.
        }
    }