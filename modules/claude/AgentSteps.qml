import QtQuick
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The step an agent's account needs before it can start a session (praxis-composer-accounts-plan
 * §2.4), drawn under its row in the agent cove: the ways to sign in, the sign-in in progress, a
 * device code, an install. Everything goes through `model` (AccountsModel). Keys are never typed
 * here: key methods ask for Settings. Nothing shows while the account is ready.
 */
Item {
    id: steps
    property var model: null           // AccountsModel
    property string agent: ""
    property string account: ""        // an account id; "" is the agent's default account
    property bool setup: false         // the first-run form (§2.15); the steps read the same in it
    property real inset: 12            // where the text starts, as in the rows above
    signal done()                      // the account became ready here; the cove closes
    signal settingsRequested(string anchor)

    readonly property string accountId: steps.account || (steps.model?.defaultAccount(steps.agent)?.id ?? "")
    readonly property var acct: steps.model?.account(steps.accountId) ?? null
    readonly property var flow: steps.accountId && steps.model?.signin?.account === steps.accountId ? steps.model.signin : null
    readonly property string standing: steps.model ? steps.model.stepOf(steps.agent, steps.accountId) : ""
    property bool codeOpen: false      // "I have a code" was chosen
    property bool finishing: false     // the 1.2 s of facts and a check before done()
    property bool copied: false
    // how the last sign-in from here began, for Try again
    property string method: ""
    property string provider: ""
    // a sign-in or install asked for here that the host has not reported on yet: "signin" | "install"
    property string pending: ""
    // the host's error reply to a request from here: { kind: "signin" | "install" | "code", message }
    property var refusal: null

    // signedOut, noProvider, starting, signingIn, code, device, busy, expired, noKey, keyRefused,
    // locked, notInstalled, installing, needsNode, failed, done, checking, ready or ""
    readonly property string shown: {
        if (steps.finishing) return "done";
        const f = steps.flow?.step ?? "";
        if (f === "busy" || f === "failed" || f === "device") return f;
        if (f === "waiting" || f === "code" || steps.standing === "signingIn")
            return f === "code" || steps.codeOpen ? "code" : "signingIn";
        if (steps.pending === "signin" && steps.standing !== "ready") return "starting";
        if (steps.pending === "install" && (steps.standing === "notInstalled" || steps.standing === "needsNode")) return "installing";
        if (steps.refusal?.kind === "signin" && steps.standing !== "ready") return "failed";
        // pi and opencode sign in per provider: signed out means no provider yet
        if (steps.standing === "signedOut" && (steps.agent === "pi" || steps.agent === "opencode")) return "noProvider";
        return steps.standing;
    }
    // this view has shown a step: the account turning ready ends it with done()
    property bool owed: false
    function owes(s) { return !["", "ready", "done", "checking"].includes(s); }
    Component.onCompleted: steps.owed = steps.owes(steps.shown)
    // on `standing`, not `shown`: `finishing` feeds `shown`, so setting it from shown's own change
    // is a binding loop
    onStandingChanged: if (steps.standing === "ready" && steps.owed && !steps.finishing) steps.finish()
    onShownChanged: {
        if (steps.owes(steps.shown)) steps.owed = true;
        if (steps.shown !== "code") {
            field.text = "";
            if (steps.shown !== "signingIn") steps.codeOpen = false;
        } else {
            Qt.callLater(() => field.forceActiveFocus());
        }
        steps.pick = -1;
        swap.restart();
    }
    onFlowChanged: {
        if (steps.flow && steps.pending === "signin") steps.pending = "";
        if (steps.flow?.step === "done") steps.finish();
    }
    Connections {
        target: steps.model
        function onInstallChanged() {
            if (steps.model.install?.agent === steps.agent && steps.pending === "install") steps.pending = "";
        }
    }
    function finish() {
        steps.owed = false;
        steps.finishing = true;
        finishTimer.restart();
    }
    Timer {
        id: finishTimer
        interval: 1200
        onTriggered: {
            steps.finishing = false;
            steps.done();
        }
    }
    Timer { id: copiedReset; interval: 1500; onTriggered: steps.copied = false }

    // An error reply is the host refusing to start: shown as a failed sign-in or install.
    function refused(kind) {
        return r => {
            if (r.ev !== "error") return;
            if (steps.pending === kind) steps.pending = "";
            steps.refusal = { kind: kind, message: r.message ?? "" };
        };
    }
    function signIn(method, provider) {
        steps.method = method;
        steps.provider = provider;
        steps.refusal = null;
        steps.pending = "signin";
        steps.model.login(steps.accountId, method, provider, steps.refused("signin"));
    }
    function install(withNode) {
        steps.refusal = null;
        steps.pending = "install";
        steps.model.installAgent(steps.agent, withNode, steps.refused("install"));
    }
    // Cancel on a sign-in: the host's, or only the refusal shown here
    function cancelSignIn() {
        steps.pending = "";
        if (steps.refusal && !steps.flow) steps.refusal = null;
        else steps.model.cancel(steps.accountId);
    }
    function again() {
        const p = steps.provider || steps.flow?.provider || (steps.acct?.providers ?? []).find(x => x.state === "expired")?.id || "";
        steps.signIn(steps.method || (p ? "" : steps.acct?.use === "console" ? "console" : "browser"), p);
    }
    // Settings' deep link to the key this account signs in with: keys:<provider>:<account id>
    function keyAnchor(provider) { return `keys:${provider}` + (steps.accountId ? `:${steps.accountId}` : ""); }
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

    function signInMethods() {
        if (steps.agent === "claude") return [
            { title: "Your Claude plan", hint: "opens your browser", run: () => steps.signIn("browser", "") },
            { title: "A Console account", hint: "opens your browser", run: () => steps.signIn("console", "") },
            { title: "An Anthropic key", hint: "in Settings", out: true, run: () => steps.settingsRequested(steps.keyAnchor("anthropic")) }
        ];
        if (steps.agent === "codex") return [
            { title: "ChatGPT", hint: "opens your browser", run: () => steps.signIn("browser", "") },
            { title: "A code on another device", run: () => steps.signIn("device", "") },
            { title: "An OpenAI key", hint: "in Settings", out: true, run: () => steps.settingsRequested(steps.keyAnchor("openai")) }
        ];
        return [{ title: "Sign in", hint: "opens your browser", run: () => steps.signIn("browser", "") }];
    }
    // pi's and opencode's own provider ids
    function providerMethods() {
        const oc = steps.agent === "opencode";
        return [
            { title: "ChatGPT plan", run: () => steps.signIn("", oc ? "openai" : "openai-codex") },
            { title: "GitHub Copilot", run: () => steps.signIn("", "github-copilot") }
        ].concat(oc ? [{ title: "OpenCode Zen", run: () => steps.signIn("", "opencode") }] : [], [
            { title: "A key", hint: "in Settings", out: true, run: () => steps.settingsRequested("keys") },
            { title: "More in Settings", out: true, run: () => steps.settingsRequested("") }
        ]);
    }

    // What a state draws: method rows, or a line (with a Spinner or a check before it, a sub and
    // an output line under it, or the code field), then action words.
    readonly property var view: {
        const m = steps.model;
        if (!m) return ({});
        const name = m.agentName(steps.agent);
        const cancel = { word: "Cancel", run: () => steps.cancelSignIn() };
        // why the last install did not happen: the host's refusal, or the install's failed step
        const instFail = steps.refusal?.kind === "install" ? steps.refusal.message
            : m.install?.agent === steps.agent && m.install.step === "failed" ? (m.install.line ?? "") : null;
        switch (steps.shown) {
        case "signedOut":
            return { methods: steps.signInMethods() };
        case "noProvider":
            return { methods: steps.providerMethods() };
        case "signingIn":
            return { spin: true, line: "Finish signing in in your browser", actions: [
                steps.flow?.url ? { word: "Open it again", run: () => Qt.openUrlExternally(steps.flow.url) } : null,
                steps.agent === "claude" ? { word: "I have a code", run: () => { steps.codeOpen = true; } } : null,
                cancel
            ].filter(x => x) };
        case "starting":
            return { spin: true, line: "Starting the sign-in…", actions: [cancel] };
        case "code":
            return { field: true, sub: steps.refusal?.kind === "code" ? `The code didn't go through: ${steps.refusal.message}` : "", actions: [cancel] };
        case "device": {
            const where = (steps.flow?.url ?? "").replace(/^https?:\/\//, "");
            return { rich: true,
                     line: `Enter <span style="font-family:'Tacit Mono'">${steps.esc(steps.flow?.userCode ?? "")}</span> at ${steps.esc(where)}`,
                     actions: [{ word: "Copy", glyph: steps.copied ? "check" : "content_copy", run: () => {
                         Quickshell.clipboardText = steps.flow?.userCode ?? "";
                         steps.copied = true;
                         copiedReset.restart();
                     } }, cancel] };
        }
        case "busy": {
            // the holder: one of the host's sign-ins (an account id or an agent), else whatever
            // the host could name, else nothing (a sign-in outside the host)
            const h = steps.flow?.holder ?? "";
            const held = m.account(h) ?? m.accounts.find(a => a.agent === h && a.state === "signingIn") ?? null;
            const who = held ? m.agentName(held.agent) : h ? m.agentName(h) : "";
            return { line: "Another ChatGPT sign-in is open" + (who ? ` (${who})` : ""), actions: [
                held ? { word: "Cancel it", run: () => { m.cancel(held.id); m.cancel(steps.accountId); } }
                     : { word: "Try again", run: () => steps.again() },
                steps.agent === "codex" ? { word: "Use a code instead", run: () => steps.signIn("device", "") } : null,
                cancel
            ].filter(x => x) };
        }
        case "failed": {
            const why = steps.flow?.message ?? (steps.flow ? "" : steps.refusal?.message ?? "");
            return { line: "Sign-in didn't finish" + (why ? `: ${why}` : ""),
                     actions: [{ word: "Try again", run: () => steps.again() }, cancel] };
        }
        case "expired":
            return { line: m.factsOf(steps.agent, steps.accountId), actions: [{ word: "Sign in again", run: () => steps.again() }] };
        case "noKey":
        case "keyRefused": {
            const p = m.keyProvider(steps.acct);
            const label = steps.acct?.label ?? "";
            return { line: steps.shown === "keyRefused" ? `The ${m.providerName(p)} key for ${label} was refused`
                                                        : `There is no ${m.providerName(p)} key for ${label}`,
                     actions: [{ word: "Replace in Settings", out: true, run: () => steps.settingsRequested(steps.keyAnchor(p)) }] };
        }
        case "locked":
            return { line: "The keyring is locked",
                     sub: Config.options.lock.security.unlockKeyring ? "It opens when you unlock the screen"
                                                                      : "Lock & sleep in Settings can open it when you unlock" };
        case "notInstalled":
            return { line: "Not installed", sub: instFail !== null ? "The install didn't finish" : "", mono: instFail ?? "",
                     actions: [{ word: "Install", run: () => steps.install(false) }] };
        case "installing":
            return { spin: true, lineMono: true, line: m.install?.step === "running" && m.install.line || `Installing ${name}…`,
                     actions: [{ word: "Cancel", run: () => { steps.pending = ""; m.cancelInstall(steps.agent); } }] };
        case "needsNode":
            return { line: `${name} needs one more install first. Installing both asks for your password.`,
                     sub: instFail !== null ? "The install didn't finish" : "", mono: instFail ?? "",
                     actions: [{ word: "Install both", run: () => steps.install(true) }] };
        case "done": {
            const a = Object.assign({}, steps.acct ?? {}, steps.flow?.who ?? {});
            return { check: true, line: steps.standing === "ready" ? m.factsOf(steps.agent, steps.accountId) : (m.planWords(a) || "Signed in") };
        }
        case "checking":
            return { spin: true, line: "Checking…" };
        }
        return ({});
    }

    // the keyboard (the cove's keys drive it): methods, then action words, as one list
    readonly property var choices: (steps.view.methods ?? []).concat(steps.view.actions ?? [])
    property int pick: -1
    // false when the move leaves the list, so the cove moves its own cursor instead
    function move(d) {
        const n = steps.choices.length;
        const next = steps.pick < 0 ? (d > 0 ? 0 : n - 1) : steps.pick + d;
        if (!n || next < 0 || next >= n) {
            steps.pick = -1;
            return false;
        }
        steps.pick = next;
        return true;
    }
    function activate() {
        const c = steps.choices[steps.pick];
        if (!c) return false;
        c.run();
        return true;
    }

    implicitHeight: body.implicitHeight > 0 ? body.implicitHeight + 10 : 0
    clip: true

    NumberAnimation { id: swap; target: body; property: "opacity"; from: 0; to: 1; duration: 140 }

    Column {
        id: body
        width: parent.width
        spacing: 4

        Column {
            width: parent.width
            visible: (steps.view.methods ?? []).length > 0
            // two or more ways: what they are ways to do
            StyledText {
                visible: (steps.view.methods ?? []).length > 1
                x: steps.inset
                height: 26
                verticalAlignment: Text.AlignVCenter
                text: "Sign in with"
                font.pixelSize: 13
                font.weight: Font.Medium
                color: Appearance.colors.colInkSecondary
            }
            Repeater {
                model: steps.view.methods ?? []
                delegate: Rectangle {
                    id: mRow
                    required property var modelData
                    required property int index
                    width: body.width
                    height: 36
                    radius: Appearance.rounding.chip
                    color: steps.pick === mRow.index ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
                        : mArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
                    Behavior on color { ColorAnimation { duration: 90 } }
                    StyledText {
                        id: mTitle
                        x: steps.inset
                        anchors.verticalCenter: parent.verticalCenter
                        text: mRow.modelData.title
                        font.pixelSize: Appearance.font.pixelSize.smallish
                        color: Appearance.colors.colInkMain
                    }
                    StyledText {
                        id: mHint
                        visible: text.length > 0
                        anchors { left: mTitle.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        text: mRow.modelData.hint ?? ""
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colInkSecondary
                    }
                    MaterialSymbol {
                        visible: mRow.modelData.out ?? false
                        anchors { left: mHint.visible ? mHint.right : mTitle.right; leftMargin: mHint.visible ? 4 : 6; verticalCenter: parent.verticalCenter }
                        text: "open_in_new"
                        iconSize: 14
                        color: Appearance.colors.colInkSecondary
                    }
                    MouseArea { id: mArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: mRow.modelData.run() }
                }
            }
        }

        Item {
            width: parent.width
            visible: (steps.view.line ?? "").length > 0
            implicitHeight: lineText.implicitHeight + 6
            Spinner {
                visible: steps.view.spin ?? false
                rests: true
                x: steps.inset
                y: 6 + (Math.min(lineText.implicitHeight, 22) - height) / 2
                implicitSize: 14
                colShape: Appearance.colors.colPrimary
            }
            MaterialSymbol {
                visible: steps.view.check ?? false
                x: steps.inset - 1
                y: 6 + (Math.min(lineText.implicitHeight, 22) - height) / 2
                text: "check"
                iconSize: 16
                color: Appearance.colors.colInkMain
            }
            StyledText {
                id: lineText
                readonly property bool mono: steps.view.lineMono ?? false
                x: steps.inset + ((steps.view.spin || steps.view.check) ? 22 : 0)
                y: 6
                width: parent.width - x - steps.inset
                text: steps.view.line ?? ""
                textFormat: (steps.view.rich ?? false) ? Text.RichText : Text.PlainText
                wrapMode: lineText.mono ? Text.NoWrap : Text.Wrap
                elide: lineText.mono ? Text.ElideMiddle : Text.ElideNone
                font.family: lineText.mono ? "Tacit Mono" : Appearance.font.family.main
                font.pixelSize: lineText.mono ? Appearance.font.pixelSize.tiny : Appearance.font.pixelSize.smallish
                color: lineText.mono ? Appearance.colors.colInkMeta : Appearance.colors.colInkMain
            }
        }
        StyledText {
            visible: text.length > 0
            x: steps.inset
            width: parent.width - 2 * steps.inset
            text: steps.view.sub ?? ""
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colInkSecondary
        }
        StyledText {
            visible: text.length > 0
            x: steps.inset
            width: parent.width - 2 * steps.inset
            text: steps.view.mono ?? ""
            elide: Text.ElideMiddle
            font.family: "Tacit Mono"
            font.pixelSize: Appearance.font.pixelSize.tiny
            color: Appearance.colors.colInkMeta
        }

        // the code a sign-in page shows: its own field, never the message box
        Rectangle {
            visible: steps.view.field ?? false
            x: steps.inset - 4
            width: parent.width - 2 * (steps.inset - 4)
            height: 36
            radius: Appearance.rounding.chip
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
            StyledTextInput {
                id: field
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                font.family: "Tacit Mono"
                font.pixelSize: Appearance.font.pixelSize.smallish
                color: Appearance.colors.colInkMain
                function submit() {
                    const c = field.text.trim();
                    if (c.length) {
                        steps.refusal = null;
                        steps.model.code(steps.accountId, c, steps.refused("code"));
                    }
                    field.text = "";
                }
                Keys.onReturnPressed: field.submit()
                Keys.onEnterPressed: field.submit()
                Keys.onEscapePressed: event => {
                    if (steps.codeOpen && steps.flow?.step !== "code") steps.codeOpen = false;
                    else event.accepted = false;
                }
            }
            StyledText {
                visible: field.text.length === 0
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                text: "Paste the code the page shows"
                font.pixelSize: Appearance.font.pixelSize.smallish
                color: Appearance.colors.colInkMeta
            }
        }

        Row {
            visible: (steps.view.actions ?? []).length > 0
            x: steps.inset
            height: 26
            Repeater {
                model: steps.view.actions ?? []
                delegate: Row {
                    id: aRow
                    required property var modelData
                    required property int index
                    readonly property bool lit: aArea.containsMouse || steps.pick === (steps.view.methods ?? []).length + aRow.index
                    height: 26
                    StyledText {
                        visible: aRow.index > 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: "  ·  "
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colInkMeta
                    }
                    Item {
                        implicitWidth: aWord.implicitWidth + (aGlyph.visible ? aGlyph.width + 4 : 0) + (aOut.visible ? aOut.width + 4 : 0)
                        height: 26
                        MaterialSymbol {
                            id: aGlyph
                            visible: !!aRow.modelData.glyph
                            anchors.verticalCenter: parent.verticalCenter
                            text: aRow.modelData.glyph ?? ""
                            iconSize: 14
                            color: aWord.color
                        }
                        StyledText {
                            id: aWord
                            anchors { left: aGlyph.visible ? aGlyph.right : parent.left; leftMargin: aGlyph.visible ? 4 : 0; verticalCenter: parent.verticalCenter }
                            text: aRow.modelData.word
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            font.weight: Font.Medium
                            color: aRow.lit ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                            Behavior on color { ColorAnimation { duration: 90 } }
                        }
                        MaterialSymbol {
                            id: aOut
                            visible: aRow.modelData.out ?? false
                            anchors { left: aWord.right; leftMargin: 4; verticalCenter: parent.verticalCenter }
                            text: "open_in_new"
                            iconSize: 14
                            color: aWord.color
                        }
                        MouseArea { id: aArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: aRow.modelData.run() }
                    }
                }
            }
        }
    }
}
