@{
    # Every user-visible string in the template scripts. Behaviour lives in
    # settings.psd1, appearance in theme.psd1. See docs/render-architecture.md.
    #
    # This file is DATA, read with Import-PowerShellDataFile and never executed.
    # Expressions, variables and commands will not run here.
    #
    # {token} placeholders are filled in one of two places:
    #   - by the caller, at render time, for values it supplies as configuration
    #   - by the page, at display time, for values only the browser knows
    # A token nobody fills is left as written, which is visible rather than blank.
    #
    # Markup does not belong here. Where a message needs emphasis the page wraps
    # it, so a string can never inject an element.

    # -- Fatal ---------------------------------------------------------------
    # Shown when the embedded library is not there after the document loaded.
    # Before v0.5.0 this was a CDN guard telling the reader to reconnect; the
    # library ships in the file now, so the remaining causes are a truncated
    # document or a content policy blocking scripts. A blank page with no
    # explanation is the failure this exists to prevent, and that has not
    # changed.
    LibraryMissingHeading         = 'The graph library did not load'
    LibraryMissingBody            = 'This report has the library it needs embedded in it, so this is not a network problem. The file may be truncated, or a content security policy may be blocking scripts inside the page. Generating the report again is the first thing to try.'

    # -- Banner ------------------------------------------------------------
    # editorLinkHelpCommand is deliberately absent: it is vocabulary belonging
    # to whatever program generated the report, and the renderer is handed it
    # rather than knowing it. When nothing supplies it the page uses the second
    # message below, so the sentence never reads "Run  in PowerShell".
    EditorLinkNoLaunch            = 'Nothing opened. Your browser is blocking vscode:// links. Run {editorLinkHelpCommand} in PowerShell, restart your browser, and try again. Or use Copy Editor Link and paste it into the Run dialog.'
    EditorLinkNoLaunchNoCommand   = 'Nothing opened. Your browser is blocking vscode:// links. Use Copy Editor Link and paste it into the Run dialog.'
    # Used instead of the above when the page is on an http origin a browser
    # policy can actually match. {origin} is filled by the page: only the
    # browser knows where the report was served from. A command the reader has
    # to edit is a step that did not need to exist.
    EditorLinkNoLaunchOrigin      = 'Nothing opened. Your browser is blocking vscode:// links from {origin}. Run {editorLinkHelpCommandForOrigin} in PowerShell, restart your browser, and try again.'
    BannerCopyLabel               = 'Copy command'
    BannerCopyUrlLabel            = 'Copy URL'
    EmbeddedViewer                = 'Opened in an embedded viewer, which cannot hand a vscode:// link to the operating system - no prompt appears and nothing reports the failure. Open File Location is disabled here. Re-open this report in a real browser, or use Copy Editor Link and paste the URI into the Run dialog.'
    # Shown instead of the above when the page knows its own address, which is
    # every case except a file:// document. The reader should not have to
    # reconstruct a URL the page is already sitting on.
    EmbeddedViewerUrl             = 'Opened in an embedded viewer, which cannot hand a vscode:// link to the operating system - no prompt appears and nothing reports the failure. Open File Location is disabled here. Re-open this report at {url} in a real browser, or use Copy Editor Link and paste the URI into the Run dialog.'
    # Said no producer word and promised no view the page will not give. It used
    # to open "This module has" and offer to "see everything" - the first is
    # vocabulary this renderer is not allowed to have, and the second is a
    # promise MinReadableZoom refuses to keep: past a floor the drawing stops
    # shrinking and the reader pans instead. Both survived every check because
    # nothing has ever read a value in this file. See 0013-t1.
    ScaleGuard                    = 'This graph has {count} nodes. Above ~{limit} the drawing stops being readable, so the view opens filtered to the ones the payload marks exported. Unchecking "Exported only" draws the rest - past this size the page stops zooming out, so expect to pan.'

    # -- Header ------------------------------------------------------------
    HeaderVersionPrefix           = 'v'
    HeaderGeneratedPrefix         = '  ·  generated '

    # -- Test order --------------------------------------------------------
    OrderIntro                    = 'Test step 1 first. Nothing in a step depends on anything in a later step, so the first failure is the cause rather than an echo of it.'
    OrderCycleHeading             = '{count} in a dependency cycle.'
    OrderCycleBody                = 'These have no valid order, because each waits on the other: {names}'

    # -- Colour by ---------------------------------------------------------
    # A facet classifies and a metric measures. Metric labels are keyed
    # 'Metric' + the id the payload carries, so adding a metric adds strings
    # here and nothing in a script.
    ColorByHeading                = 'Colour by'
    # Sits under the radios, not in the legend. The legend has said colour is
    # rank since before v0.1.0 and nobody has read it, because it is the last
    # block of a sidebar that scrolls and the choice that needs the caveat is
    # made eight blocks above it. 0012-t1 was raised as "the legend does not say
    # this"; the legend says it, out of reach.
    ColorByEncoding               = 'A kind gets a colour. A metric gets a rank - the bands hold equal numbers of the values that occur, not equal slices of the range - so colour orders the nodes and the number in Details measures them.'
    ColorByStructure              = 'Kind'
    ColorByStructureHint          = 'one colour per kind'
    # 'depend on', not 'call'. An edge is a link the payload declared and this
    # renderer has no idea what the relationship is - saying "call" here is the
    # same assumption LegendCalls carried and elements.js dropped when it
    # stopped defaulting a link's kind. 0013-t3.
    MetricDependents              = 'Dependents'
    MetricDependentsHint          = 'things that depend on this directly'
    MetricBlastRadius             = 'Blast radius'
    MetricBlastRadiusHint         = 'everything that breaks if this changes'
    MetricDependencies            = 'Dependencies'
    MetricDependenciesHint        = 'things this depends on directly'
    MetricReach                   = 'Reach'
    MetricReachHint               = 'everything this rests on, transitively'

    # -- Legend ------------------------------------------------------------
    LegendExported                = 'exported'
    LegendBorderWidth             = 'thicker border = more direct dependents'
    # Not '{metric}: {low} to {high}'. Under a five-band strip that reads as the
    # strip's axis, which is the one thing the ramp is not - and the line below
    # then contradicts it.
    LegendHeatScale               = '{metric}, coldest to hottest'
    LegendHeatRank                = 'equal bands of rank, not of value; the range is {low} to {high} and one node''s number is in Details'
    # The base edge rule, which draws a link the theme names no style for. It
    # used to say 'calls' - one producer's word for one kind of relationship,
    # applied to every producer's unlabelled edges, which is the same mistake
    # elements.js already stopped making when it dropped CommandReference as a
    # default kind.
    LegendCalls                   = 'unclassified link'
    # 'LegendLink' + the link classification. The key names a producer's word
    # because this file is DATA - a producer describing Terraform ships its own
    # strings.psd1 with LegendLinkReferences instead. sidebar.js falls back to
    # the classification itself when no key matches, so a producer that ships
    # neither still gets a legend that says something true.
    LegendLinkInherits            = 'inherits'
    LegendUnresolved              = 'unresolved'

    # -- Focus and details -------------------------------------------------
    FocusHintEmpty                = 'Select a node to focus its neighbourhood. Shift-click, or shift-drag a box, to select several.'
    FocusHintSelected             = 'Focused: {name}'
    DetailName                    = 'Name'
    DetailKind                    = 'Kind'
    DetailExported                = 'Exported'
    DetailTestStep                = 'Test step'
    DetailTestStepValue           = '{step} of {total}'
    DetailDependents              = 'Dependents'
    DetailDependencies            = 'Dependencies'
    DetailBlastRadius             = 'Blast radius'
    DetailReach                   = 'Reach'
    # Shown only when at least one link touching the selection carries a
    # resolution the theme draws differently - so a payload that states nothing
    # never shows an empty row saying zero.
    DetailUncertainLinks          = 'Uncertain links'
    DetailUncertainLinksValue     = '{count} of {total}'
    DetailLine                    = 'Line'
    DetailPath                    = 'Path'
    ValueNotApplicable            = 'n/a'
    ValueYes                      = 'yes'
    ValueNo                       = 'no'
    ValueInCycle                  = 'in a cycle'

    # -- Context menu ------------------------------------------------------
    MenuOpenFileLocation          = 'Open File Location'
    MenuOpenCallSite              = 'Open Reference Site'
    MenuCopyEditorLink            = 'Copy Editor Link'
    MenuCopyPath                  = 'Copy Path'
    MenuDiagnostics               = 'Diagnostics'
    # Sits between an action and the reason it is unavailable.
    MenuReasonSeparator           = ' — '
    ReasonNoFile                  = 'no file recorded'
    ReasonNoRootPath              = 'root path unknown'
    ReasonEmbedded                = 'not available in an embedded viewer, open the report in a browser'

    # -- Selection ---------------------------------------------------------
    SelectionTitle                = '{count} selected'
    SelectionCount                = 'Selected'
    SelectionSharedFoundation     = 'Shared foundation'
    SelectionNoneShared           = 'nothing in common'
    SelectionInternalLinks        = 'Links between them'
    SelectionDependencies         = 'Depend on, in total'
    SelectionDependents           = 'Depended on by, in total'
    SelectionTestSteps            = 'Test steps'
    SelectionMore                 = 'and {count} more'
    SelectionActionSelectFoundation = 'Select shared foundation'
    SelectionActionCopyNames      = 'Copy names'
    SelectionActionCopyPaths      = 'Copy paths'
    SelectionActionCopyLinks      = 'Copy editor links'
    SelectionActionClear          = 'Clear selection'

    # -- Controls ----------------------------------------------------------
    ZoomSpeedSuffix               = 'x'

    # -- Diagnostics -------------------------------------------------------
    # The row labels in the diagnostics block are names of expressions, not
    # prose, and are left in the script: a label that no longer matches the code
    # it reports on is worse than one that cannot be translated.
    DiagnosticsUndefined          = '(undefined)'
}
