    // ---- node context menu -----------------------------------------------
    // Actions are a registry, not hardcoded markup: a new entry here is the
    // whole change. Each one declares whether it applies to the node under the
    // cursor and why not, so an inapplicable action greys out with a reason
    // instead of silently vanishing.
    //
    //   id       stable key, used for nothing yet but worth having
    //   label    menu text, or a function of the node returning it
    //   check    returns null when applicable, or the reason it is not
    //   href     returns a URI; the item renders as a real link
    //   run      performs the action for that node; the item renders as a button
    //
    // Prefer href over run for anything that hands a URI to another
    // application. Assigning window.location to a custom scheme is silently
    // discarded - no navigation, no error, nothing in the console - while a
    // link the user actually clicked is the supported route.


    var NODE_ACTIONS = [
        {
            id: 'open-in-vscode',
            // An invented node has no definition in the payload, so the path
            // recorded against it is where it was REFERENCED FROM. Opening that
            // is still useful, but labelling it "file location" would be a lie
            // about what the page knows - the definition is precisely the thing
            // the producer could not resolve.
            //
            // "Reference site", not "call site". Whether the reference is a
            // call is the producer's business, and this renderer is not told.
            label: function (node) {
                return node.data('kind') === 'External'
                    ? str('MenuOpenCallSite') : str('MenuOpenFileLocation');
            },
            check: function (node) {
                var reason = editorLinkCheck(node);
                if (reason) { return reason; }
                if (isEmbeddedContext()) {
                    return str('ReasonEmbedded');
                }
                return null;
            },
            href: vsCodeUriFor,
            // The navigation itself reports nothing either way, so the click
            // starts a watch for the one observable signal there is.
            afterClick: function (node) {
                attemptEditorLaunch(vsCodeUriFor(node), reportNoLaunch);
            }
        },
        {
            id: 'copy-editor-link',
            label: str('MenuCopyEditorLink'),
            // Deliberately without the embedded check: pasting the URI into the
            // Run dialog, Spotlight or a terminal opens the file whatever the
            // browser is or is not willing to do.
            check: editorLinkCheck,
            run: function (node) {
                copyText(vsCodeUriFor(node));
            }
        },
        {
            id: 'copy-path',
            label: str('MenuCopyPath'),
            check: function (node) {
                if (!node.data('path')) { return str('ReasonNoFile'); }
                return null;
            },
            run: function (node) {
                copyText(absolutePathFor(node) || node.data('path'));
            }
        },
        {
            id: 'diagnostics',
            label: str('MenuDiagnostics'),
            check: function () { return null; },
            run: function (node) {
                showInfoPanel('Diagnostics', diagnosticsFor(node));
            }
        }
    ];

    var menuEl = document.getElementById('node-menu');
    var menuNode = null;

    function closeNodeMenu() {
        menuEl.classList.remove('open');
        menuEl.setAttribute('aria-hidden', 'true');
        menuNode = null;
    }

    function openNodeMenu(node, clientX, clientY) {
        menuNode = node;
        menuEl.textContent = '';

        var title = document.createElement('div');
        title.className = 'menu-title';
        title.textContent = node.data('name');
        menuEl.appendChild(title);

        NODE_ACTIONS.forEach(function (action) {
            var reason = action.check ? action.check(node) : null;
            var label = (typeof action.label === 'function') ? action.label(node) : action.label;
            var item;

            if (action.href && !reason) {
                // A real link, not a scripted navigation - see the note on the
                // registry above. There is no disabled state for an anchor, so
                // an inapplicable action falls through to a disabled button.
                item = document.createElement('a');
                item.href = action.href(node);
                item.addEventListener('click', function () {
                    closeNodeMenu();
                    // No preventDefault: the anchor's own navigation is what
                    // carries the user activation, and a scripted assignment to
                    // window.location for a custom scheme is discarded.
                    if (action.afterClick) { action.afterClick(node); }
                });
            }
            else {
                item = document.createElement('button');
                item.type = 'button';
                item.disabled = !!reason;
                if (!reason && action.run) {
                    item.addEventListener('click', function () {
                        closeNodeMenu();
                        action.run(node);
                    });
                }
            }

            item.setAttribute('role', 'menuitem');
            item.textContent = reason ? label + str('MenuReasonSeparator') + reason : label;
            menuEl.appendChild(item);
        });

        // Show before measuring; a display:none element has no dimensions.
        menuEl.classList.add('open');
        menuEl.setAttribute('aria-hidden', 'false');
        var box = menuEl.getBoundingClientRect();
        // Flip rather than clamp: a menu pinned to the edge under the cursor
        // covers the node that was right-clicked.
        var x = (clientX + box.width > window.innerWidth) ? clientX - box.width : clientX;
        var y = (clientY + box.height > window.innerHeight) ? clientY - box.height : clientY;
        menuEl.style.left = Math.max(0, x) + 'px';
        menuEl.style.top = Math.max(0, y) + 'px';

        // Anchors as well as buttons now, or the first item goes unfocused
        // whenever the top action happens to be a link.
        var first = menuEl.querySelector('a[href], button:not(:disabled)');
        if (first) { first.focus(); }
    }

    cy.on('cxttap', 'node', function (evt) {
        var oe = evt.originalEvent;
        if (oe && oe.preventDefault) { oe.preventDefault(); }
        openNodeMenu(evt.target, oe ? oe.clientX : 0, oe ? oe.clientY : 0);
    });

    // Right-clicking the background closes it; so does anything else that moves
    // the view out from under it.
    cy.on('cxttap', function (evt) {
        if (evt.target === cy) { closeNodeMenu(); }
    });
    cy.on('tap zoom pan', closeNodeMenu);

    // The browser menu would otherwise appear on top of ours.
    document.getElementById('cy').addEventListener('contextmenu', function (ev) {
        ev.preventDefault();
    });

    document.addEventListener('mousedown', function (ev) {
        if (menuEl.classList.contains('open') && !menuEl.contains(ev.target)) {
            closeNodeMenu();
        }
    });
    document.addEventListener('keydown', function (ev) {
        if (ev.key === 'Escape') { closeNodeMenu(); hideInfoPanel(); }
    });
    window.addEventListener('blur', closeNodeMenu);
