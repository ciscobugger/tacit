import QtQuick
import "mail-store.js" as Store

QtObject {
    id: state
    property color agentInk
    property string initialScreen: "read"
    property var data: Store.initial(initialScreen)
    readonly property var ui: data.ui
    readonly property var selected: Store.current(data)
    readonly property var draft: Store.draft(data)
    property var rows: []
    onDataChanged: {var next=Store.results(data);if(JSON.stringify(next)!==JSON.stringify(rows))rows=next;}
    readonly property var settings: data.settings
    readonly property var accounts: data.accounts
    readonly property bool canSend: Store.canSend(draft)
    readonly property bool hasPending: data.jobs.length > 0
    readonly property bool undoAvailable: hasPending && (data.now <= data.jobs[data.jobs.length-1].expires || !ui.online)
    // These are requests to the future system integration, not app-owned surfaces.
    signal authorizationRequested(string provider)
    signal notificationRequested(var message)
    signal sendStatusChanged(var status)
    function completeAuthorization(email){act("providerEmail",{text:email});act("connect");}
    function notificationAction(action){
        if(action==="markRead")act("readNotification");
        else if(action==="dismiss")act("dismissNotification");
        else act("openNotification",{reply:action==="reply",agent:action==="agentReply"});
    }
    signal editorRequested()
    signal saveRequested(var file)
    function saveAttachment(file){saveRequested(file);}
    function act(action, payload) {
        var p=payload || {};
        if(action==="draft") {var d=Store.draft(data);if(d&&Object.keys(p).every(function(k){return d[k]===p[k];}))return;}
        if(action==="setting"&&data.settings[p.key]===p.value)return;
        const previousJobs=JSON.stringify(data.jobs);
        p.now=Date.now();var next=Store.reduce(data,action,p);
        const jobsChanged=JSON.stringify(next.jobs)!==previousJobs;
        // Sending/Undo is reported to the system, not duplicated as an app toast.
        if(jobsChanged&&["send","tick","undoSend","retry"].includes(action))next.ui.notice="";
        data=next;
        if(action==="provider")authorizationRequested(ui.provider);
        if(action==="notify"&&ui.notification)notificationRequested(Store.find(data,"anna-notification"));
        if(jobsChanged)sendStatusChanged({pending:Store.copy(data.jobs),undoAvailable:undoAvailable});
    }
    function count(folder,account) { return Store.folderCount(data,folder,account); }
    function highlight(text){return Store.highlight(String(text),ui.searching?ui.query:"");}
    function names(addresses){return String(addresses).split(",").map(function(a){return a.trim().split("@")[0].split(/[._]/).map(function(s){return s?s[0].toUpperCase()+s.slice(1):s;}).join(" ");}).join(", ");}
    function addressesValid(value){return Store.validRecipients(value);}
    function agentDraft(id) { return Store.agentDraft(data,id); }
    function reply(mode,agent) { act("reply",{mode:mode,agent:!!agent}); editorRequested(); }
    property Timer clock: Timer { interval: 500; repeat: true; running: state.hasPending || state.ui.view === "importing" || state.data.messages.some(m=>!!m.returnAt); onTriggered: state.act("tick") }
    Component.onCompleted: {
        // Surface fixtures use a zero clock so their pending send also starts at launch.
        var next=Store.copy(data);next.now=Date.now();next.jobs.forEach(function(j){j.expires=next.now+next.settings.undoSeconds*1000;});data=next;rows=Store.results(data);
    }
}
