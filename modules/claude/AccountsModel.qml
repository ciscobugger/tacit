import QtQuick
import Quickshell
import qs.services

/**
 * Accounts as agent-host keeps them (praxis-composer-accounts-plan §3.2): which agents are
 * installed, each agent's accounts and their state, keys by their last four, folder defaults, the
 * models and commands each account offers, and the sign-in or install in progress. A view of the
 * host shared by Praxis and Settings, so it references no shell-only singleton; it keeps no secret.
 * The state is the host's last word: read it together with `available`.
 */
Item {
    id: acc

    property var host: null            // a Host; when null this makes its own (no roster)
    readonly property var link: acc.host ?? own.item
    readonly property bool available: !!acc.link && acc.link.connected && (acc.link.features ?? []).includes("accounts")

    // the host's state (the `accounts` reply and push)
    property var agents: ({})          // { claude|codex|pi|opencode: { installed, version, route } }
    property bool node: true
    property var accounts: []          // [{ id, agent, label, personal, default, use, key?, state, email?, plan?, since?, reason?, providers?, folders }]
    property var keys: []              // [{ id, provider, label, last4, use, state, checked?, models? }]
    property var found: []
    property var providers: []         // [{ id, name, env }]
    property var defaults: ({})
    property string keyring: ""        // open | locked | absent
    // the newest sign-in and install; one that ended (done, failed, cancelled, busy, needsNode) is
    // kept until the next one starts or `cancel` dismisses it, so a view can still say how it ended
    property var signin: null          // { account, provider?, step, url?, userCode?, holder?, message?, who? }
    property var install: null         // { agent, step, line?, version? }
    // a state push came after the install's done: the agent is installed as far as the host can tell
    property bool installSeen: false
    property var catalogs: ({})        // "agent|account|cwd" -> the host's catalog reply

    readonly property var agentOrder: ["claude", "codex", "pi", "opencode"]
    readonly property var readyAgents: acc.agentOrder.filter(a => acc.agents[a]?.installed && acc.defaultAccount(a)?.state === "ready")
    readonly property bool anyReady: acc.readyAgents.length > 0
    // every account (or agent with none) that needs a step before it can start a session
    readonly property var needs: {
        const out = [];
        for (const a of acc.agentOrder) {
            if (!acc.agents[a]) continue;
            const list = acc.accountsOf(a);
            for (const x of (list.length ? list : [{ id: "" }])) {
                const step = acc.stepOf(a, x.id);
                if (acc.stepWord(step) || step === "locked") out.push({ agent: a, account: x.id, step: step });
            }
        }
        return out;
    }
    readonly property string summary: {
        if (!acc.available) return "";
        const n = acc.readyAgents.map(a => acc.agentName(a));
        if (!n.length) return "No agent is ready";
        return (n.length > 1 ? n.slice(0, -1).join(", ") + " and " + n[n.length - 1] : n[0]) + " ready";
    }

    Loader {
        id: own
        active: acc.host === null
        sourceComponent: Component { Host { roster: false } }
    }

    property var asked: ({})           // catalog keys asked for on this connection
    onAvailableChanged: {
        acc.asked = ({});
        if (acc.available) {
            acc.watch();
        } else {
            // a sign-in or install runs in the host and ends with it
            acc.signin = null;
            acc.install = null;
        }
    }
    Component.onCompleted: if (acc.available) acc.watch()
    Connections {
        target: acc.link
        function onPushed(m) { acc.absorb(m); }
    }

    function watch() {
        acc.link.request({ op: "accounts", watch: true }, r => acc.absorb(r));
    }
    // An unchanged value keeps its object: a new one rebuilds every row bound to it.
    function put(name, value) {
        if (JSON.stringify(acc[name]) !== JSON.stringify(value)) acc[name] = value;
    }
    function ended(step) { return ["done", "failed", "cancelled", "busy", "needsNode"].includes(step); }
    function absorb(m) {
        switch (m.ev) {
        case "accounts": {
            acc.put("agents", m.agents ?? ({}));
            acc.node = m.node !== false;
            acc.put("accounts", m.accounts ?? []);
            acc.put("keys", m.keys ?? []);
            acc.put("found", m.found ?? []);
            acc.put("providers", m.providers ?? []);
            acc.put("defaults", m.defaults ?? ({}));
            acc.keyring = m.keyring ?? "";
            // the state holds what is in progress; how one ended comes from its own push
            if (m.signin && !acc.ended(m.signin.step)) acc.put("signin", m.signin);
            else if (acc.signin && !acc.ended(acc.signin.step)) acc.signin = null;
            if (m.install && !acc.ended(m.install.step)) acc.put("install", m.install);
            else if (acc.install && !acc.ended(acc.install.step)) acc.install = null;
            if (acc.install?.step === "done") acc.installSeen = true;
            break;
        }
        case "signin": {
            const s = Object.assign({}, m);
            delete s.ev;
            acc.signin = s;
            break;
        }
        case "install": {
            const s = Object.assign({}, m);
            delete s.ev;
            acc.installSeen = false;
            acc.install = s;
            break;
        }
        case "catalog":
            acc.storeCatalog(m, "");
            break;
        }
    }

    // ── reading ──────────────────────────────────────────────────────────────
    function accountsOf(agent) { return acc.accounts.filter(a => a.agent === agent); }
    function defaultAccount(agent) {
        const l = acc.accountsOf(agent);
        return l.find(a => a.default) ?? l.find(a => a.personal) ?? l[0] ?? null;
    }
    function account(id) { return acc.accounts.find(a => a.id === id) ?? null; }
    function agentName(agent) {
        return ({ claude: "Claude Code", codex: "Codex", pi: "pi", opencode: "opencode" })[agent] ?? agent;
    }
    function providerName(id) {
        const p = acc.providers.find(x => x.id === id);
        if (p?.name) return p.name;
        return ({ anthropic: "Anthropic", openai: "OpenAI", "openai-codex": "ChatGPT", "github-copilot": "GitHub Copilot",
                  openrouter: "OpenRouter", google: "Google", opencode: "OpenCode Zen" })[id] ?? id;
    }
    // the provider an account's key is for, or the agent's own
    function keyProvider(a) {
        const k = acc.keys.find(x => x.id === a?.key);
        return k?.provider ?? ({ claude: "anthropic", codex: "openai" })[a?.agent] ?? "";
    }

    // What stands between an account (or the agent's default one, id "") and a session:
    // installing | needsNode | notInstalled, else the account's state (ready, signedOut, expired,
    // noKey, keyRefused, noProvider, locked, checking, signingIn); "" when the host has not said.
    // An install that is done still reads installing until the state push that follows it.
    function stepOf(agent, id) {
        const ag = acc.agents[agent];
        const inst = acc.install?.agent === agent ? acc.install.step : "";
        if (inst === "running" || (inst === "done" && !acc.installSeen && ag?.installed === false)) return "installing";
        if (ag && ag.installed === false)
            return agent !== "claude" && (!acc.node || inst === "needsNode") ? "needsNode" : "notInstalled";
        const a = id ? acc.account(id) : acc.defaultAccount(agent);
        return a?.state ?? "";
    }
    // the word on a row whose account needs a step, or ""
    function stepWord(step) {
        return ({ signedOut: "Sign in", expired: "Sign in", noProvider: "Set up", notInstalled: "Install",
                  needsNode: "Install", noKey: "Replace key", keyRefused: "Replace key" })[step] ?? "";
    }
    // a row's facts: plan · email when ready, else the state in words
    function factsOf(agent, id) {
        const step = acc.stepOf(agent, id);
        const a = id ? acc.account(id) : acc.defaultAccount(agent);
        switch (step) {
        case "ready": return acc.planWords(a);
        case "signedOut": return (agent === "pi" || agent === "opencode") ? "Needs a provider" : "Not signed in";
        case "expired": return a?.since ? `Signed out on ${Qt.formatDate(new Date(a.since), "d MMM")}` : "Signed out";
        case "noKey": return `No ${acc.providerName(acc.keyProvider(a))} key`;
        case "keyRefused": return `The ${acc.providerName(acc.keyProvider(a))} key was refused`;
        case "noProvider": return "Needs a provider";
        case "locked": return "The keyring is locked";
        case "checking": return "Checking…";
        case "signingIn": return "Signing in…";
        case "notInstalled": return "Not installed";
        case "needsNode": return "Needs one more install";
        case "installing": return "Installing…";
        }
        return "";
    }
    function planWords(a) {
        if (!a) return "";
        const cap = s => s ? s.charAt(0).toUpperCase() + s.slice(1) : "";
        let what = "";
        if (a.use === "key") {
            const k = acc.keys.find(x => x.id === a.key);
            what = `${acc.providerName(acc.keyProvider(a))} key` + (k?.last4 ? ` ••••${k.last4}` : "");
        } else if (a.agent === "claude") {
            what = a.plan ? `${cap(a.plan)} plan` : a.use === "console" ? "Console" : "";
        } else if (a.agent === "codex") {
            what = "ChatGPT" + (a.plan ? ` · ${cap(a.plan)}` : "");
        } else {
            what = (a.providers ?? []).filter(p => !p.state || p.state === "ready").map(p => acc.providerName(p.id)).join(", ");
        }
        return [what, a.email ?? ""].filter(s => s.length).join(" · ");
    }

    // The models and commands an account offers in a folder: the copy held here (null until the
    // host answers), asked for once per connection, or again with `refresh`.
    function catalogKey(agent, account, cwd) { return `${agent}|${account ?? ""}|${cwd ?? ""}`; }
    function catalog(agent, account, cwd, refresh) {
        const id = account || acc.defaultAccount(agent)?.id || "";
        const key = acc.catalogKey(agent, id, cwd);
        if (acc.available && (refresh || !acc.asked[key])) {
            acc.asked[key] = true;
            const req = { op: "catalog", agent: agent };
            if (id) req.account = id;
            if (cwd) req.cwd = cwd;
            if (refresh) req.refresh = true;
            acc.link.request(req, r => {
                if (r.ev === "catalog") acc.storeCatalog(r, key);
                else delete acc.asked[key];   // an error reply (or a lost connection): the next read asks again
            });
        }
        return acc.catalogs[key] ?? null;
    }
    // Models belong to the account and commands to the account in a folder, so a fresh read's
    // models reach every folder's copy of that account. A catalog's `cwd` is the folder its
    // commands are for (none: $HOME); a reply without one is for the folder it was asked for.
    function storeCatalog(m, askedKey) {
        const c = Object.assign({}, m);
        delete c.ev;
        delete c.tag;
        const all = Object.assign({}, acc.catalogs);
        const cwd = c.cwd ?? (askedKey ? askedKey.split("|").slice(2).join("|") : "");
        const own = acc.catalogKey(c.agent, c.account, cwd);
        for (const k in all) {
            const [ag, ac] = k.split("|");
            if (ag === c.agent && ac === (c.account ?? "") && k !== own)
                all[k] = Object.assign({}, all[k], { models: c.models, at: c.at, stale: c.stale });
        }
        all[own] = c;
        if (askedKey) all[askedKey] = c;
        acc.catalogs = all;
    }

    // ── model rows as the menus show them ───────────────────────────────────
    // A name a person can read for an id: "claude-opus-4-1" is "Opus 4.1"; other ids stay as they are.
    function plainId(id) {
        const t = String(id ?? "");
        const long = /\[1m\]$/i.test(t);
        let s = t.replace(/\[.*\]$/, "");
        if (/^[a-z]+$/.test(s)) s = s.charAt(0).toUpperCase() + s.slice(1);
        else if (s.startsWith("claude-")) {
            const out = [];
            for (const p of s.slice(7).replace(/-\d{8}$/, "").split("-")) {
                if (/^\d+$/.test(p) && out.length && /^\d+(\.\d+)*$/.test(out[out.length - 1])) out[out.length - 1] += "." + p;
                else out.push(/^\d/.test(p) ? p : p.charAt(0).toUpperCase() + p.slice(1));
            }
            s = out.join(" ");
        }
        return long ? s + " with long memory" : s;
    }
    // The host's rows, tidied once for every menu that lists them: the default row folds into the
    // model it runs (that row is `rec`, keeps id "default" and lists the folded id in `aliases`), a
    // variant says what it is in words ("long memory"), a "maker/name" label loses its maker, and an
    // agent with no default row gets one. `variant`: the row varies a model; `plainDefault`: the
    // added row.
    function shapeModels(ms) {
        if (!ms || !ms.length) return [];
        const rows = ms.map(m => {
            const r = Object.assign({}, m);
            if (m.id !== "default" && m.detail) {
                const long = /\[1m\]$/i.test(m.id) || /^\d+\s*[mk]$/i.test(m.detail);
                r.label = long ? `${m.label} with long memory` : `${m.label} ${m.detail}`;
                r.detail = "";
                r.variant = true;
            } else if (String(m.label).includes("/")) {
                const parts = String(m.label).split("/");
                r.vendor = parts[0].replace(/^~/, "");
                r.label = parts[parts.length - 1].replace(/^~/, "").replace(/:free$/, " free");
            }
            return r;
        });
        // one name under two makers: the maker tells them apart
        const count = {};
        for (const r of rows) count[`${r.group}|${r.label}`] = (count[`${r.group}|${r.label}`] ?? 0) + 1;
        for (const r of rows) if (r.vendor && count[`${r.group}|${r.label}`] > 1) r.detail = r.vendor;
        const di = rows.findIndex(r => r.id === "default");
        if (di < 0) {
            rows.forEach(r => { if (r.isDefault) r.rec = true; });
            if (!rows.some(r => r.rec))
                rows.unshift({ id: "default", label: "Default", detail: "Agent decides", efforts: [], group: "", plainDefault: true });
            return rows;
        }
        const d = rows[di];
        const ti = rows.findIndex(o => o.id !== "default" && !o.variant && d.resolved && (o.id === d.resolved || o.resolved === d.resolved));
        const t = ti >= 0 ? rows[ti] : null;
        const folded = Object.assign({}, d, { label: t ? t.label : (d.detail || "Default"), about: t?.about ?? d.about, aliases: t ? [t.id] : [], rec: true, detail: "" });
        const out = [];
        rows.forEach((r, i) => { if (i !== ti) out.push(i === di ? folded : r); });
        return out;
    }
    // the row an id stands for: the id itself, a folded alias, the full model a session reports, or
    // the default row for "" and "default"
    function modelRowOf(rows, id) {
        const c = id ?? "";
        return rows.find(m => m.id === c) ?? rows.find(m => m.aliases?.includes(c))
            ?? (c ? rows.find(m => !m.variant && m.resolved === c) : null)
            ?? (c === "" || c === "default" ? rows.find(m => m.rec) ?? rows.find(m => m.id === "default") ?? null : null) ?? null;
    }

    // ── asking the host ──────────────────────────────────────────────────────
    // Each takes an optional callback with the host's reply; with no host that can, it answers
    // an error at once.
    function send(obj, cb) {
        if (!acc.available) {
            if (cb) cb({ ev: "error", message: "The background service here does not manage accounts.", unavailable: true });
            return;
        }
        acc.link.request(obj, r => { acc.absorb(r); if (cb) cb(r); });
    }
    function resolve(cwd, agent, cb) {
        const req = { op: "resolve", cwd: cwd };
        if (agent) req.agent = agent;
        acc.send(req, r => cb(r.ev === "resolved" ? r : null));
    }
    // scope: "everywhere" or a folder's absolute path; fields: { agent?, mode?, run? }, null clears one
    function setDefaults(scope, fields, cb) { acc.send(Object.assign({ op: "defaults_set", scope: scope }, fields), cb); }
    function addAccount(agent, label, use, key, cb) {
        const req = { op: "account_add", agent: agent, label: label, use: use };
        if (key) req.key = key;
        acc.send(req, cb);
    }
    // method: browser | device | console; provider: pi's and opencode's (openai-codex, github-copilot, …)
    function login(account, method, provider, cb) {
        acc.signin = null;
        const req = { op: "account_login", account: account };
        if (method) req.method = method;
        if (provider) req.provider = provider;
        acc.send(req, cb);
    }
    function code(account, text, cb) { acc.send({ op: "account_code", account: account, code: text }, cb); }
    // A sign-in that has ended has nothing left to cancel in the host: it is only put away.
    function cancel(account, cb) {
        if (acc.signin?.account === account) {
            const over = acc.ended(acc.signin.step);
            acc.signin = null;
            if (over) {
                if (cb) cb({ ev: "ok" });
                return;
            }
        }
        acc.send({ op: "account_cancel", account: account }, cb);
    }
    function logout(account, provider, cb) {
        const req = { op: "account_logout", account: account };
        if (provider) req.provider = provider;
        acc.send(req, cb);
    }
    function remove(account, cb) { acc.send({ op: "account_remove", account: account }, cb); }
    function rename(account, label, cb) { acc.send({ op: "account_set", account: account, label: label }, cb); }
    function makeDefault(account, cb) { acc.send({ op: "account_set", account: account, default: true }, cb); }
    function useKey(id, agent, on, cb) { acc.send({ op: "key_use", id: id, agent: agent, on: on }, cb); }
    function checkKey(id, cb) { acc.send({ op: "key_check", id: id }, cb); }
    function removeKey(id, force, cb) {
        const req = { op: "key_remove", id: id };
        if (force) req.force = true;
        acc.send(req, cb);
    }
    // The secret goes out in this request and nowhere else: the reply carries only its last four.
    function setKey(provider, label, secret, cb) {
        const req = { op: "key_set", provider: provider, secret: secret };
        if (label) req.label = label;
        acc.send(req, cb);
    }
    // `install` is the progress above, so the verb has its own name
    function installAgent(agent, withNode, cb) {
        acc.install = null;
        acc.installSeen = false;
        const req = { op: "install", agent: agent };
        if (withNode) req.node = true;
        acc.send(req, cb);
    }
    function cancelInstall(agent, cb) { acc.send({ op: "install_cancel", agent: agent }, cb); }
    // anchor: the part after the page key, e.g. "keys:openai"
    function openSettings(anchor) { SettingsApp.open("accounts" + (anchor ? ":" + anchor : "")); }
}
