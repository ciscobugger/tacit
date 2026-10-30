pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import qs
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * Provides extra features not in Quickshell.Services.Notifications:
 *  - Persistent storage
 *  - Popup notifications, with timeout
 *  - Notification groups by app
 */
Singleton {
	id: root
    component Notif: QtObject {
        id: wrapper
        required property int notificationId // Could just be `id` but it conflicts with the default prop in QtObject
        property Notification notification
        property list<var> actions: notification?.actions.map((action) => ({
            "identifier": action.identifier,
            "text": action.text,
        })) ?? []
        property bool popup: false
        property bool leaving: false   // popup on its way out: the row slides off, then popup drops
        property bool replyActive: false   // its reply field has the keyboard: the popup stays
        property bool isTransient: notification?.hints.transient ?? false
        property string category: notification?.hints.category ?? ""   // "im.received", "email.arrived", ...
        property string appIcon: notification?.appIcon ?? ""
        property string appName: notification?.appName ?? ""
        property string desktopEntry: notification?.desktopEntry ?? ""
        property bool hasInlineReply: notification?.hasInlineReply ?? false
        property string inlineReplyPlaceholder: notification?.inlineReplyPlaceholder ?? ""
        function reply(text) {
            if (notification && notification.hasInlineReply)
                notification.sendInlineReply(text);
        }
        property string body: notification?.body ?? ""
        property string image: notification?.image ?? ""
        property string summary: notification?.summary ?? ""
        property double time
        property string urgency: notification?.urgency.toString() ?? "normal"
        property Timer timer
        // A phone notification, from KDE Connect's own record of it (scripts/notifications/phone-icon.py): what its
        // picture is ("glyph": the app's one-colour icon; "picture": a colour icon, a photo, art), a person's
        // conversation, posted silently on the phone. image then holds the picture's cached file.
        property string iconKind: ""
        property bool conversation: false
        property bool quiet: false
        property int popupWaiting: -1   // a phone notification's popup, held for its record: the timeout it will use

        // Gone from the list only when the app takes it back (the phone dismissed it). The object also goes null when
        // the shell reloads, which removed every live notification from the history on each reload.
        readonly property Connections closing: Connections {
            target: wrapper.notification
            function onClosed(reason) {
                if (reason === NotificationCloseReason.CloseRequested)
                    root.discardNotification(wrapper.notificationId);
            }
        }
    }

    function notifToJSON(notif) {
        return {
            "notificationId": notif.notificationId,
            "actions": notif.actions,
            "appIcon": notif.appIcon,
            "appName": notif.appName,
            "body": notif.body,
            // A pixmap notification's image is an image:// handle owned by this process:
            // persisting it would restore a dead handle next run.
            "image": /^image:\/\//.test(notif.image ?? "") ? "" : notif.image,
            "summary": notif.summary,
            "category": notif.category,
            "time": notif.time,
            "urgency": notif.urgency,
            "iconKind": notif.iconKind,
            "conversation": notif.conversation,
            "quiet": notif.quiet,
        }
    }
    function notifToString(notif) {
        return JSON.stringify(notifToJSON(notif), null, 2);
    }

    component NotifTimer: Timer {
        required property int notificationId
        interval: 7000
        running: true
        onTriggered: () => {
            const index = root.list.findIndex((notif) => notif.notificationId === notificationId);
            const notifObject = root.list[index];
            if (!notifObject) {   // dismissed before its time was up
                destroy();
                return;
            }
            print("[Notifications] Notification timer triggered for ID: " + notificationId + ", transient: " + notifObject.isTransient);
            if (notifObject.isTransient) root.discardNotification(notificationId);
            else root.timeoutNotification(notificationId);
            destroy()
        }
    }

    property bool silent: false
    property int unread: 0
    property var filePath: Directories.notificationsPath
    property list<Notif> list: []
    property var popupList: list.filter((notif) => notif.popup);
    property bool popupInhibited: silent
    property var latestTimeForApp: ({})
    Component {
        id: notifComponent
        Notif {}
    }
    Component {
        id: notifTimerComponent
        NotifTimer {}
    }

    function stringifyList(list) {
        return JSON.stringify(list.map((notif) => notifToJSON(notif)), null, 2);
    }
    
    onListChanged: {
        // Update latest time for each app
        root.list.forEach((notif) => {
            if (!root.latestTimeForApp[notif.appName] || notif.time > root.latestTimeForApp[notif.appName]) {
                root.latestTimeForApp[notif.appName] = Math.max(root.latestTimeForApp[notif.appName] || 0, notif.time);
            }
        });
        // Remove apps that no longer have notifications
        Object.keys(root.latestTimeForApp).forEach((appName) => {
            if (!root.list.some((notif) => notif.appName === appName)) {
                delete root.latestTimeForApp[appName];
            }
        });
    }

    // The centre as Android orders it: people first, then the rest, then what the phone posted silently; newest first
    // within each. Popups keep arrival order.
    function rankOf(group) {
        const ns = group.notifications;
        if (ns.some(n => n.conversation || n.hasInlineReply || (n.category ?? "").startsWith("im")))
            return 0;
        return ns.every(n => n.quiet) ? 2 : 1;
    }
    function appNameListForGroups(groups, ranked) {
        return Object.keys(groups).sort((a, b) => (ranked ? root.rankOf(groups[a]) - root.rankOf(groups[b]) : 0) || groups[b].time - groups[a].time);
    }

    function groupsForList(list) {
        const groups = {};
        list.forEach((notif) => {
            if (!groups[notif.appName]) {
                groups[notif.appName] = {
                    appName: notif.appName,
                    appIcon: notif.appIcon,
                    notifications: [],
                    time: 0
                };
            }
            groups[notif.appName].notifications.push(notif);
            // Always set to the latest time in the group
            groups[notif.appName].time = latestTimeForApp[notif.appName] || notif.time;
        });
        return groups;
    }

    property var groupsByAppName: groupsForList(root.list)
    property var popupGroupsByAppName: groupsForList(root.popupList)
    property list<string> appNameList: appNameListForGroups(root.groupsByAppName, true)
    property list<string> popupAppNameList: appNameListForGroups(root.popupGroupsByAppName, false)
    // each app's one-colour icon, wherever it was last seen: a stack of several, a photo's badge, a row whose own
    // picture was a photo
    property var phoneGlyphs: ({})    // app -> glyph, from what the phone held at startup
    readonly property var appGlyphs: {
        const g = Object.assign({}, root.phoneGlyphs);
        for (const n of root.list)
            if (n.iconKind === "glyph" && n.image !== "")
                g[n.appName] = n.image;
        return g;
    }

    // ---- a phone notification's real icon. The server gets its picture as pixels only, which the history cannot
    // keep, so every phone app fell back to KDE Connect's phone. One lookup at a time: a reconnect sends 17 at once.
    property var phoneQueue: []       // [{ id, tries }]
    function lookPhone(id, tries) {
        root.phoneQueue = root.phoneQueue.concat([{ "id": id, "tries": tries }]);
        if (!phoneLookup.running)
            root.nextPhone();
    }
    function nextPhone() {
        while (root.phoneQueue.length) {
            const q = root.phoneQueue[0];
            root.phoneQueue = root.phoneQueue.slice(1);
            const n = root.list.find(x => x.notificationId === q.id);
            if (!n)
                continue;
            phoneLookup.current = q;
            phoneLookup.command = ["python3", "-I", `${FileUtils.trimFileProtocol(Directories.scriptPath)}/notifications/phone-icon.py`,
                n.appName, n.summary, n.body, `${FileUtils.trimFileProtocol(Directories.cache)}/notifications/icons`];
            phoneLookup.running = true;
            return;
        }
    }
    function popUp(n, interval) {
        n.popup = true;
        if (interval != 0)
            n.timer = notifTimerComponent.createObject(root, { "notificationId": n.notificationId, "interval": interval });
    }
    // a held popup shows once its record is in, unless the phone posted it silently
    function settlePopup(n) {
        if (n.popupWaiting < 0)
            return;
        const interval = n.popupWaiting;
        n.popupWaiting = -1;
        if (!n.quiet)
            root.popUp(n, interval);
    }
    // a record that never comes (KDE Connect gone, the helper failing) must not swallow the popup
    Timer {
        id: popupDeadline
        interval: 400
        repeat: true
        onTriggered: {
            let waiting = false;
            for (const n of root.list) {
                if (n.popupWaiting < 0)
                    continue;
                if (Date.now() - n.time > 1200)
                    root.settlePopup(n);
                else
                    waiting = true;
            }
            if (!waiting)
                stop();
        }
    }
    function phoneResult(q, text) {
        let r = {};
        try { r = JSON.parse(text || "{}"); } catch (e) {}
        const n = root.list.find(x => x.notificationId === q?.id);
        if (!n)
            return;
        if (!Object.keys(r).length) {
            root.settlePopup(n);
            // KDE Connect may list it a moment after showing it
            if (q.tries < 1) {
                phoneRetry.ids = phoneRetry.ids.concat([q.id]);
                phoneRetry.restart();
            }
            return;
        }
        if (r.path) {
            n.image = r.path;
            n.iconKind = r.kind ?? "";
        }
        n.conversation = !!r.conversation;
        n.quiet = !!r.silent;
        root.settlePopup(n);
        root.save();
    }
    Process {
        id: phoneLookup
        property var current: null
        stdout: StdioCollector {
            onStreamFinished: root.phoneResult(phoneLookup.current, this.text)
        }
        onExited: Qt.callLater(root.nextPhone)
    }
    // At startup: what the phone still holds gives the history its real icons (rows saved before icons were kept, or
    // while the shell was down), then the cache drops icons nothing refers to any more.
    readonly property string phoneScript: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/notifications/phone-icon.py`
    readonly property string iconCache: `${FileUtils.trimFileProtocol(Directories.cache)}/notifications/icons`
    function backfillPhone() {
        phoneAll.running = true;
    }
    Process {
        id: phoneAll
        command: ["python3", "-I", root.phoneScript, "--all", root.iconCache]
        stdout: StdioCollector {
            onStreamFinished: {
                let recs = [];
                try { recs = JSON.parse(this.text || "[]"); } catch (e) {}
                const norm = t => String(t ?? "").replace(/\s+/g, " ").trim().toLowerCase();
                const glyphs = {};
                let changed = false;
                for (const r of recs) {
                    if (r.kind === "glyph" && r.path && !glyphs[r.app])
                        glyphs[r.app] = r.path;
                    for (const n of root.list) {
                        if (n.iconKind !== "" || norm(n.appName) !== norm(r.app))
                            continue;
                        if (!((r.text && norm(n.body) === norm(r.text)) || (r.title && norm(n.summary) === norm(r.title))))
                            continue;
                        if (r.path) {
                            n.image = r.path;
                            n.iconKind = r.kind ?? "";
                        }
                        n.conversation = !!r.conversation;
                        n.quiet = !!r.silent;
                        changed = true;
                    }
                }
                root.phoneGlyphs = glyphs;
                if (changed)
                    root.save();
                const keep = root.list.map(n => n.image).concat(Object.values(glyphs)).filter(i => i.startsWith(root.iconCache + "/"));
                phonePrune.command = ["python3", "-I", root.phoneScript, "--prune", root.iconCache].concat(keep);
                phonePrune.running = true;
            }
        }
    }
    Process { id: phonePrune }
    Timer {
        id: phoneRetry
        property var ids: []
        interval: 900
        onTriggered: {
            const ids = phoneRetry.ids;
            phoneRetry.ids = [];
            for (const id of ids)
                root.lookPhone(id, 1);
        }
    }

    // Quickshell's notification IDs starts at 1 on each run, while saved notifications
    // can already contain higher IDs. This is for avoiding id collisions
    property int idOffset
    signal initDone();
    signal notify(notification: var);
    signal discard(id: int);
    signal discardAll();
    signal timeout(id: var);

	NotificationServer {
        id: notifServer
        // actionIconsSupported: true
        actionsSupported: true
        inlineReplySupported: true   // apps only offer a reply field when the server says it can show one
        bodyHyperlinksSupported: true
        bodyImagesSupported: true
        bodyMarkupSupported: true
        bodySupported: true
        imageSupported: true
        keepOnReload: false
        persistenceSupported: true

        onNotification: (notification) => {
            notification.tracked = true
            const newNotifObject = notifComponent.createObject(root, {
                "notificationId": notification.id + root.idOffset,
                "notification": notification,
                "time": Date.now(),
            });
            // KDE Connect relays the phone. A plain phone notification arrives under the phone
            // app's own name (Pixel Weather). A chat with a reply arrives as "KDE Connect" with
            // the app in the summary and "Sender: text" in the body: present the app as the
            // app and the sender as the name, so WhatsApp groups as WhatsApp and reads as a
            // message. desktop-entry stays org.kde.kdeconnect.daemon: that is how a row knows
            // it came from the phone.
            if ((notification.appName ?? "") === "KDE Connect" && (notification.summary ?? "").length > 0) {
                // "Received file IMG_2201.jpg from Pixel 10 Pro": the file lands in Downloads a
                // moment later; tell Origins whose it is before the watcher sees it.
                const recv = /received file (.+?) from (.+)$/i.exec(`${notification.summary} ${notification.body ?? ""}`.replace(/\s+/g, " "));
                if (recv)
                    Origins.hint(recv[1].trim(), { "kind": "phone", "device": recv[2].trim() });
                const m = /^([^:\n]{1,48}):\s+([\s\S]+)$/.exec(notification.body ?? "");
                newNotifObject.appName = notification.summary;
                if (m) {
                    newNotifObject.summary = m[1];
                    newNotifObject.body = m[2];
                }
            }
            // KDE Connect's battery warning names itself "Pixel 10 Pro: Low Battery": the phone is the sender
            const lowBattery = /^(.+?):\s*low battery$/i.exec(notification.appName ?? "");
            if (lowBattery) {
                newNotifObject.appName = lowBattery[1];
                if (/low battery$/i.test(newNotifObject.summary))
                    newNotifObject.summary = "Low battery";
            }
            // The same notification again within a day - the phone re-sends what it still holds on every reconnect (17 Gmail
            // in 2 s), its battery warning came 4 times - takes the earlier one's place and time: no popup, not unread
            // again, not a second row. The earlier one is only forgotten, not dismissed: a dismissal would clear it on the phone.
            // Only the phone gets the day: from any other app the same words again are a new message (a second "ok" in a
            // chat was swallowed), so only an exact repeat within 10 s, an app sending twice, folds into the first.
            const sameKey = n => `${n.appName}\n${n.summary}\n${NotificationUtils.tidyBody(n.body)}`;
            const key = sameKey(newNotifObject);
            const within = (notification.desktopEntry ?? "") === "org.kde.kdeconnect.daemon" ? 86400000 : 10000;
            const at = root.list.findIndex(n => Date.now() - n.time < within && sameKey(n) === key);
            const earlier = at >= 0 ? root.list[at] : null;
            const showing = !!earlier && earlier.popup && !earlier.leaving;   // a double send while the first is still up
            if (earlier) {
                newNotifObject.time = earlier.time;
                if (earlier.iconKind !== "") {
                    newNotifObject.image = earlier.image;
                    newNotifObject.iconKind = earlier.iconKind;
                    newNotifObject.conversation = earlier.conversation;
                    newNotifObject.quiet = earlier.quiet;
                }
                const l = root.list.slice();
                l[at] = newNotifObject;
                root.list = l;
                root.dropNotif(earlier);
            } else {
                root.list = [...root.list, newNotifObject];
            }
            // Unread counts every arrival: a silent or muted notification is the one
            // the user has not seen, so it is exactly what the badge has to report. A transient
            // one removes itself when it times out, so it is never left to read.
            if (!newNotifObject.isTransient && !earlier)
                root.unread++;

            // Popup - unless the app is muted (then it only lands in the centre, unread)
            const muted = (Persistent.states.notifications.mutedApps ?? []).some(a => a.toLowerCase() === (notification.appName ?? "").toLowerCase());
            const fromPhone = (notification.desktopEntry ?? "") === "org.kde.kdeconnect.daemon";
            // a critical one stays until it is dealt with (as the spec says), whatever timeout the sender gave
            const interval = notification.urgency === NotificationUrgency.Critical || notification.expireTimeout == 0 ? 0 : notification.expireTimeout < 0 ? (Config?.options.notifications.timeout ?? 7000) : notification.expireTimeout;
            if (!root.popupInhibited && !muted && (!earlier || showing) && !newNotifObject.quiet) {
                // A phone notification waits for its record, a fraction of a second: what the phone posted silently (a
                // "For you" from YouTube) goes to the centre without a popup, as it does on the phone.
                if (fromPhone && newNotifObject.iconKind === "" && !showing) {
                    newNotifObject.popupWaiting = interval;
                    popupDeadline.start();
                } else {
                    root.popUp(newNotifObject, interval);
                }
            }
            if (!earlier)
                root.notify(newNotifObject);
            if (fromPhone && newNotifObject.iconKind === "")
                root.lookPhone(newNotifObject.notificationId, 0);
            // console.log(notifToString(newNotifObject));
            root.save();
        }
    }

    // ---- the sender's window: the "go to it" of a notification with no action of its own
    // A body's link: xdg-open hands it to the browser without an activation token, so the
    // tab would open behind the focused window. Bring the browser forward after a moment.
    property string browserId: ""
    Process {
        command: ["sh", "-c", "xdg-settings get default-web-browser 2>/dev/null"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.browserId = text.trim().replace(/\.desktop$/, "").toLowerCase()
        }
    }
    Timer {
        id: browserFocus
        interval: 400
        onTriggered: {
            if (root.browserId)
                root.focusApp({ appName: root.browserId });
        }
    }
    function linkFor(notif) {
        return NotificationUtils.firstLink(notif?.body);
    }
    function openLink(url) {
        Qt.openUrlExternally(url);
        browserFocus.restart();
    }
    // A download's file: the notification names it, Recents (which watches the downloads folder)
    // knows where it is. Also screenshots.
    function fileFor(notif) {
        const text = `${notif?.summary ?? ""} ${notif?.body ?? ""}`;
        const hit = Recents.items.find(i => (i.kind === "download" || i.kind === "screenshot") && i.text && text.includes(i.text));
        return hit ? hit.path : "";
    }
    function openFile(path) {
        Quickshell.execDetached(["xdg-open", path]);
    }
    function revealFile(path) {
        Files.reveal(path);
    }
    // What a click on the row does when the app gave it no action: open its file, else its
    // link, else go to the app. True when something happened.
    function open(notif) {
        const file = fileFor(notif);
        if (file) {
            openFile(file);
            return true;
        }
        const link = linkFor(notif);
        if (link) {
            openLink(link);
            return true;
        }
        return bringForward(notif);
    }
    // The app's window forward, else the app itself when it has none open (Discord in the tray): a click on its
    // notification did nothing (Discord, 2026-10-20). Phone notifications have no app here.
    function bringForward(notif) {
        if (focusApp(notif))
            return true;
        const id = notif?.desktopEntry ?? "";
        if (id.length === 0 || id === "org.kde.kdeconnect.daemon")
            return false;
        const entry = DesktopEntries.byId(id) ?? DesktopEntries.heuristicLookup(id);
        if (!entry)
            return false;
        AppScope.launch(entry);
        return true;
    }
    function windowFor(notif) {
        if (!notif)
            return null;
        // A phone notification has no window here (its desktop entry is KDE Connect's daemon), and a window id inside
        // a key (an empty one is inside every key) matched any notification: a reply that went to an unrelated window.
        if ((notif.desktopEntry ?? "") === "org.kde.kdeconnect.daemon")
            return null;
        const keys = [notif.desktopEntry, notif.appName].map(k => (k ?? "").toLowerCase()).filter(k => k.length > 0);
        if (keys.length === 0)
            return null;
        return ToplevelManager.toplevels.values.find(t => {
            const id = (t.appId ?? "").toLowerCase();
            return id.length > 0 && keys.some(k => id === k || id.includes(k));
        }) ?? null;
    }
    function focusApp(notif) {
        const t = windowFor(notif);
        if (!t)
            return false;
        const a = t.HyprlandToplevel?.address;
        if (a)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:0x${a}" })`);
        else
            t.activate();
        return true;
    }
    function isMuted(appName) {
        return (Persistent.states.notifications.mutedApps ?? []).some(a => a.toLowerCase() === (appName ?? "").toLowerCase());
    }
    function toggleMute(appName) {
        const list = (Persistent.states.notifications.mutedApps ?? []).slice();
        const i = list.findIndex(a => a.toLowerCase() === (appName ?? "").toLowerCase());
        if (i >= 0)
            list.splice(i, 1);
        else
            list.push(appName);
        Persistent.states.notifications.mutedApps = list;
    }

    // True for the length of one row expand: the containers above the row (group, panel)
    // follow instantly then, so exactly one height animates at a time.
    property bool expanding: false
    Timer {
        id: expandingTimer
        interval: 400
        repeat: false
        onTriggered: root.expanding = false
    }
    // `notifications expand <app>`: unfold that app's group wherever it is shown (keyboard
    // flows, scripts, and looking at a row without a pointer).
    signal expandRequested(string appName)
    function bumpExpanding() {
        root.expanding = true;
        expandingTimer.restart();
    }

    function markAllRead() {
        root.unread = 0;
    }

    function discardNotification(id) {
        console.log("[Notifications] Discarding notification with ID: " + id);
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        const notifServerIndex = notifServer.trackedNotifications.values.findIndex((notif) => notif.id + root.idOffset === id);
        if (index !== -1) {
            const dropped = root.list[index];
            root.list.splice(index, 1);
            // a handled one is no longer waiting to be read: the dot and count never outnumber what is left
            root.unread = Math.min(root.unread, root.list.length);
            root.save();
            triggerListChange()
            root.dropNotif(dropped);
        }
        if (notifServerIndex !== -1) {
            notifServer.trackedNotifications.values[notifServerIndex].dismiss()
        }
        root.discard(id); // Emit signal
    }
    // The list forgetting a notification is not the object going away: without this every
    // notification ever received stayed in memory with its server object and timer.
    function dropNotif(notif) {
        if (!notif)
            return;
        if (notif.timer)
            notif.timer.destroy();
        Qt.callLater(() => notif.destroy());
    }

    function discardAllNotifications() {
        const dropped = root.list.slice();
        root.list = []
        root.unread = 0;
        dropped.forEach(n => root.dropNotif(n));
        triggerListChange()
        root.save();
        notifServer.trackedNotifications.values.forEach((notif) => {
            notif.dismiss()
        })
        root.discardAll();
    }

    function cancelTimeout(id) {
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        if (root.list[index]?.timer)   // gone once fired, or never made for a no-expiry notification
            root.list[index].timer.stop();
    }

    function timeoutNotification(id) {
        const index = root.list.findIndex((notif) => notif.notificationId === id);
        const notif = root.list[index];
        if (notif != null && notif.popup && !notif.leaving && !notif.replyActive) {
            notif.leaving = true;
            leaveTimerComponent.createObject(root, { "notificationId": id });
        }
        root.timeout(id);
    }
    component LeaveTimer: Timer {
        required property int notificationId
        interval: Appearance.animation.elementMove.duration
        running: true
        onTriggered: {
            const notif = root.list.find((n) => n.notificationId === notificationId);
            if (notif != null) {
                notif.popup = false;
                notif.leaving = false;
            }
            destroy();
        }
    }
    Component {
        id: leaveTimerComponent
        LeaveTimer {}
    }

    function timeoutAll() {
        root.popupList.forEach((notif) => {
            root.timeout(notif.notificationId);
        })
        root.popupList.forEach((notif) => {
            notif.popup = false;
        });
    }

    function attemptInvokeAction(id, notifIdentifier) {
        console.log("[Notifications] Attempting to invoke action with identifier: " + notifIdentifier + " for notification ID: " + id);
        const notifServerIndex = notifServer.trackedNotifications.values.findIndex((notif) => notif.id + root.idOffset === id);
        console.log("Notification server index: " + notifServerIndex);
        if (notifServerIndex !== -1) {
            const notifServerNotif = notifServer.trackedNotifications.values[notifServerIndex];
            const action = notifServerNotif.actions.find((action) => action.identifier === notifIdentifier);
            // console.log("Action found: " + JSON.stringify(action));
            action.invoke()
        } 
        else {
            console.log("Notification not found in server: " + id)
        }
        root.discardNotification(id);
    }

    function triggerListChange() {
        root.list = root.list.slice(0)
    }

    // A file that did not parse may still hold history: it is never written over.
    property bool broken: false

    function save() {
        if (root.broken) {
            console.log("[Notifications] Not saving: " + root.filePath + " did not parse")
            return
        }
        notifFileView.setText(stringifyList(root.list));
    }

    function refresh() {
        notifFileView.reload()
    }

    Component.onCompleted: {
        refresh()
    }

    FileView {
        id: notifFileView
        path: Qt.resolvedUrl(filePath)
        // Messages are in here: owner-only, whatever the umask made it
        onSaved: Quickshell.execDetached(["bash", "-c", "chmod 700 \"$(dirname \"$1\")\"; chmod 600 \"$1\"", "_", root.filePath])
        onLoaded: {
            const fileContents = notifFileView.text()
            try {
                root.list = JSON.parse(fileContents).map((notif) => {
                    return notifComponent.createObject(root, {
                        "notificationId": notif.notificationId,
                        "actions": [], // Notification actions are meaningless if they're not tracked by the server or the sender is dead
                        "appIcon": notif.appIcon,
                        // saved before the phone's battery warning was named after the phone (onNotification)
                        "appName": /^(.+?):\s*low battery$/i.exec(notif.appName ?? "")?.[1] ?? notif.appName,
                        "body": notif.body,
                        "image": notif.image,
                        "summary": /^.+?:\s*low battery$/i.test(notif.summary ?? "") ? "Low battery" : notif.summary,
                        "category": notif.category ?? "",
                        "time": notif.time,
                        "urgency": notif.urgency,
                        "iconKind": notif.iconKind ?? "",
                        "conversation": notif.conversation ?? false,
                        "quiet": notif.quiet ?? false,
                    });
                });
                root.broken = false
            } catch (e) {
                root.broken = true
                root.list = []
                console.log("[Notifications] Cannot read the file, history is kept as it is: " + e)
            }
            // Find largest notificationId
            let maxId = 0
            root.list.forEach((notif) => {
                maxId = Math.max(maxId, notif.notificationId)
            })

            console.log("[Notifications] File loaded")
            root.idOffset = maxId
            root.initDone()
            root.backfillPhone()
        }
        onLoadFailed: (error) => {
            if(error == FileViewError.FileNotFound) {
                console.log("[Notifications] File not found, creating new file.")
                root.list = []
                notifFileView.setText(stringifyList(root.list));
            } else {
                console.log("[Notifications] Error loading file: " + error)
            }
        }
    }
}
