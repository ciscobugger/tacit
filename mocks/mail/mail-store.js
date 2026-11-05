// Local, deterministic frontend state. No sockets, provider calls or credentials.
function copy(value) { return JSON.parse(JSON.stringify(value)); }
function message(id, from, subject, body, account, day, time, unread) {
    return {id:id, from:from, address:from.toLowerCase().replace(/[^a-z]/g, ".")+"@example.com", subject:subject, body:body, account:account, day:day, time:time, unread:!!unread, starred:false, folder:"Inbox", files:[], replies:[], generated:false};
}
function initial(surface) {
    var messages = [
        message("mara","Mara Klein","The Dusk and Moss pass","Hi Lorenz,\n\nThe final design review is ready. I have attached our notes on the Dusk and Moss palettes.\n\nCould you take a look at the navigation and the message header before Thursday? The interface should stay quiet, with the content doing most of the talking.\n\nThanks,\nMara","Work","Today","09:42",false),
        message("studio","Tactical Studio","Monday notes, prototype review","Good morning,\n\nThe prototype is ready for a short review. We have updated the keyboard map and the spacing in the header, as discussed on Monday.\n\nCould you try it this week and tell us what still feels slow?\n\nBest,\nTactical Studio","Work","Today","08:15",true),
        message("nils","Nils Berger","Train details for Friday","Hi Lorenz,\n\nThe train leaves at 08:34 from platform 7. Our seats are in carriage 24. The ticket is attached.\n\nSee you on Friday,\nNils","Work","Yesterday","18:20",false),
        message("quiet","Quiet Hours","Your weekly summary","You made room for three focused sessions and kept two evenings free.\n\nTake a little time for yourself this week.","Personal","Yesterday","07:00",false),
        message("newsletter","Studio Newsletter","A few things worth reading","Quieter interfaces, thoughtful tools, and making software feel calm.\n\nThis week's reading list is ready.","Personal","Monday","16:02",true),
        message("anna","Anna Richter","A small question about Tuesday","Hi Lorenz,\n\nWould Tuesday still work for you? I can make either 11:00 or 14:30.\n\nAnna","Personal","Monday","11:47",true),
        message("lea","Lea Hoffmann","Feedback on the reading view","The denser overview is much easier to scan. A little more room around the sender would help.\n\nThanks for sharing it!","Personal","Monday","09:30",true),
        message("book","Bookshop","Your reservation is ready","The book you asked us to set aside has arrived.\n\nYou can collect it any time this week.","Personal","Sunday","18:40",false),
        message("felix","Felix Braun","Photos from the weekend","Here are a few pictures from our walk. The light by the lake was lovely.","Personal","Sunday","12:05",false),
        message("lena","Lena Fischer","Re: The Dusk and Moss pass","Here are the two palettes as we left them on Friday.","Work","Monday","10:05",false),
        message("colour","Studio Newsletter","Colour for calm software","Three palettes that stay quiet on dark grounds.","Personal","12 Oct","12:00",false)
    ];
    messages[0].files=[{id:"review",name:"Review summary.pdf",path:"fixtures/review-summary.pdf",detail:"6 pages, 180 kB",kind:"document",content:"Design review\n\nDusk and Moss palettes\n\nKeep the navigation quiet. Give the sender and date one line. Put attachments with the message they belong to.\n\nKeyboard review\nTab moves between controls. Escape returns to the inbox. Every action has a keyboard equivalent."}];
    messages[0].history=[{id:"lena-first",from:"Lena Fischer",date:"Monday",body:"Here are the two palettes as we left them on Friday.",expanded:false},{id:"nils-first",from:"Nils Berger",date:"Yesterday",body:"The moss reads well on dark. The header spacing still feels tight.",expanded:false}];
    messages[0].cc="nils.berger@example.com, lena.fischer@example.com";
    messages[2].starred=true;messages[2].files=[{id:"ticket",name:"Train ticket.pdf",path:"fixtures/train-ticket.pdf",detail:"1 page, 94 kB",kind:"document",content:"Friday\nDeparture 08:34 · Platform 7\nCarriage 24 · Seat 42"}];
    messages[7].category="Receipts";messages[5].category="Family";messages[1].category="Clients";messages[9].folder="Archive";messages[10].folder="Archive";
    var s={messages:messages,accounts:[{name:"Personal",email:"lorenz@example.com",provider:"Google"},{name:"Work",email:"lorenz@moss.example",provider:"Fastmail"}],drafts:[],jobs:[],sequence:0,settings:{agentDrafts:true,agentSort:false,agentScope:"Work only",undoSeconds:10,workSignature:"Lorenz\nMoss Studio",personalSignature:"Lorenz",pictures:"Ask first",notifications:"From people only",reducedMotion:false},ui:{view:"read",selected:"mara",folder:"Inbox",account:"All accounts",rail:false,query:"",searching:false,filter:"All mail",sort:"Newest first",draftId:"",notice:"",undo:null,notification:false,provider:"",providerEmail:"lorenz@example.com",imported:0,online:true,attachment:null},now:0};
    var d=makeDraft(s,"mara","Reply all",true);s.drafts.push(d);
    if(surface==="switch")s.ui.rail=true;
    if(surface==="plain"){s.ui.selected="studio";messages[1].unread=false;}
    if(surface==="draft"){s.ui.view="draft";s.ui.draftId=d.id;}
    if(surface==="compose"){var n=makeDraft(s,"","New message",false);n.to="Anna Ri";s.drafts.push(n);s.ui.draftId=n.id;s.ui.view="compose";}
    if(surface==="search"){s.ui.query="palettes";s.ui.searching=true;}
    if(surface==="empty"){s.ui.folder="Later";s.ui.selected="";}
    if(surface==="setup"||surface==="settings")s.ui.view=surface;

    if(surface==="importing"){s.ui.view="importing";s.ui.imported=1240;}
    if(surface==="notify"){s.ui.view="read";s.ui.selected="anna";}
    if(surface==="sent"||surface==="offline"){s.ui.draftId=d.id;s.ui.online=surface!=="offline";s=reduce(s,"send",{now:0});s.ui.notice="";}
    return s;
}
function find(s,id){return s.messages.find(function(m){return m.id===id;})||null;}
function current(s){return find(s,s.ui.selected);}
function draft(s){return s.drafts.find(function(d){return d.id===s.ui.draftId;})||null;}
function agentDraft(s,id){return s.drafts.find(function(d){return d.conversation===id&&d.agent;})||null;}
function makeDraft(s,conversation,mode,agent){
    var m=find(s,conversation),account=m?m.account:(s.ui.account==="All accounts"?"Personal":s.ui.account);
    var signature=account==="Work"?s.settings.workSignature:s.settings.personalSignature;
    return {id:"draft-"+(++s.sequence),conversation:conversation,mode:mode,account:account,to:m&&mode!=="Forward"?m.address:"",cc:m&&mode==="Reply all"?(m.cc||""):"",bcc:"",showCc:mode==="Reply all",showBcc:false,subject:m?(mode==="Forward"?"Fwd: ":"Re: ")+m.subject:"",body:agent&&m?(m.id==="mara"?"Hi Mara,\n\nThanks, this reads well. Two notes on the header: the sender and the date could share one line, and the attachment should sit right under the text it belongs to.\n\nI will send the rest by Wednesday, a day before your Thursday deadline.\n\n"+signature:"Hi "+m.from.split(" ")[0]+",\n\nThank you for your message. I will get back to you shortly.\n\n"+signature):mode==="Forward"&&m?"\n\n---------- Forwarded message ----------\nFrom: "+m.from+" <"+m.address+">\nSubject: "+m.subject+"\n\n"+m.body:"",files:mode==="Forward"&&m?copy(m.files):[],agent:!!agent,edited:false};
}
function emails(value){return String(value||"").split(/[,;]/).map(function(v){return v.trim();}).filter(Boolean);}
function validRecipients(value){var all=emails(value);return all.length>0&&all.every(function(v){return /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(v);});}
function canSend(d){return !!d&&validRecipients(d.to)&&(!d.cc||validRecipients(d.cc))&&(!d.bcc||validRecipients(d.bcc))&&(d.body.trim()!==""||d.files.length>0);}
function results(s){
    if(s.ui.folder==="Drafts"&&!s.ui.searching)return s.drafts.filter(function(d){return s.ui.account==="All accounts"||d.account===s.ui.account;}).map(function(d){return {id:d.id,draft:true,from:d.agent?"Your agent":"You",subject:d.subject||"No subject",body:d.body,account:d.account,day:"Drafts",time:"Not sent",unread:false,files:d.files};});
    var q=s.ui.query.toLowerCase().trim();var list=s.messages.filter(function(m){
        if(s.ui.searching){if(m.folder==="Trash"||m.folder==="Junk")return false;return (m.from+" "+m.address+" "+m.subject+" "+m.body+" "+m.files.map(function(f){return f.name;}).join(" ")).toLowerCase().includes(q);}
        if(s.ui.account!=="All accounts"&&m.account!==s.ui.account)return false;
        if(s.ui.folder==="Starred"){if(!m.starred||m.folder==="Trash")return false;}
        else if(s.ui.folder==="Sent"){if(!m.replies.some(function(r){return r.status==="sent";})&&m.folder!=="Sent")return false;}
        else if(["Family","Receipts","Clients","Invoices"].includes(s.ui.folder)){if(m.category!==s.ui.folder)return false;}
        else if(m.folder!==s.ui.folder)return false;
        if(s.ui.filter==="Unread"&&!m.unread)return false;if(s.ui.filter==="With attachments"&&m.files.length===0)return false;if(s.ui.filter==="Starred"&&!m.starred)return false;
        return true;
    });
    if(s.ui.sort==="Oldest first")list.reverse();
    if(s.ui.sort==="Sender")list.sort(function(a,b){return a.from.localeCompare(b.from);});
    if(s.ui.sort==="Unread first")list.sort(function(a,b){return Number(b.unread)-Number(a.unread);});
    return list;
}
function folderCount(s,folder,account){var c=copy(s);c.ui.searching=false;c.ui.filter="All mail";c.ui.folder=folder;c.ui.account=account||"All accounts";var rows=results(c);return folder==="Inbox"?rows.filter(function(m){return m.unread;}).length:rows.length;}
function remember(s){s.ui.undo={messages:copy(s.messages),drafts:copy(s.drafts),jobs:copy(s.jobs),accounts:copy(s.accounts),selected:s.ui.selected};}
function restoreJob(s,job){var m=find(s,job.conversation);if(m)m.replies=m.replies.filter(function(r){return r.id!==job.id;});if(!s.drafts.some(function(d){return d.id===job.draft.id;}))s.drafts.push(copy(job.draft));s.ui.draftId=job.draft.id;s.ui.selected=job.conversation;s.ui.view=job.draft.conversation?"draft":"compose";s.jobs=s.jobs.filter(function(j){return j.id!==job.id;});if(job.created){s.messages=s.messages.filter(function(m){return m.id!==job.conversation;});s.ui.selected="";}}
function reduce(previous,action,p){
    p=p||{};var s=copy(previous),u=s.ui,m=current(s),d=draft(s);s.now=p.now===undefined?s.now:p.now;
    switch(action){
    case "select":
        var chosen=s.drafts.find(function(x){return x.id===p.id;});
        if(chosen){u.draftId=chosen.id;u.selected=chosen.conversation;u.view=chosen.conversation?"draft":"compose";}else{u.selected=p.id;u.view="read";var selected=find(s,p.id);if(selected)selected.unread=false;}break;
    case "folder":u.folder=p.folder;u.account=p.account||"All accounts";u.searching=false;u.query="";u.view="read";u.selected="";var next=results(s)[0];if(next){if(next.draft){u.draftId=next.id;u.view=next.id&&next.id.indexOf("draft-")===0?"compose":"read";var dd=s.drafts.find(function(x){return x.id===next.id;});u.selected=dd.conversation;u.view=dd.conversation?"draft":"compose";}else{u.selected=next.id;find(s,next.id).unread=false;}}break;
    case "rail":u.rail=!u.rail;break;
    case "search":u.query=p.text;u.searching=true;u.view="read";break;
    case "closeSearch":u.query="";u.searching=false;break;
    case "filter":u.filter=p.value;break;
    case "sort":u.sort=p.value;break;
    case "new":var fresh=makeDraft(s,"","New message",false);s.drafts.push(fresh);u.draftId=fresh.id;u.view="compose";break;
    case "reply":
        if(!m)break;if(p.agent&&s.settings.agentScope!=="All accounts"&&s.settings.agentScope!==m.account+" only"){u.notice="This account is outside your agent’s allowed mail. Change it in Settings.";break;}var mode=p.mode||"Reply";var existing=p.agent?agentDraft(s,m.id):null;var reply=existing||makeDraft(s,m.id,mode,!!p.agent);if(!existing)s.drafts.push(reply);u.draftId=reply.id;u.view="draft";break;
    case "mode":if(d){var source=find(s,d.conversation);d.mode=p.value;if(source){d.to=p.value==="Forward"?"":source.address;d.cc=p.value==="Reply all"?(source.cc||""):"";d.showCc=p.value==="Reply all";d.subject=(p.value==="Forward"?"Fwd: ":"Re: ")+source.subject;}}break;
    case "later":if(m){remember(s);m.folder="Later";m.returnAt=s.now+p.delay;u.notice="Moved to Later";var available=results(s);u.selected=available.length?available[0].id:"";}break;
    case "draft":if(d){Object.keys(p).forEach(function(key){if(key!=="now")d[key]=p[key];});d.edited=p.edited===undefined?true:p.edited;}break;
    case "keepDraft":u.view="read";u.notice="Draft kept. Nothing was sent.";break;
    case "discard":if(d){remember(s);s.drafts=s.drafts.filter(function(x){return x.id!==d.id;});u.draftId="";u.view="read";u.notice="Draft moved to Trash";}break;
    case "attach":if(d){d.files.push({id:"local-"+(++s.sequence),name:p.name||"Notes.md",detail:p.url?"Local file":"Preview attachment",kind:"document",url:p.url||"",content:p.url?"A local file chosen for this draft.":"# Notes\n\nA local mock attachment. No file was uploaded."});u.notice="Attached "+(p.name||"Notes.md");}break;
    case "detach":if(d)d.files=d.files.filter(function(f){return f.id!==p.id;});break;
    case "send":
        if(!canSend(d)){u.notice="Add valid recipients and a message or attachment.";break;}
        var originalDraft=copy(d);var created=!d.conversation;if(created){var own=message("sent-"+(++s.sequence),"You",d.subject||"No subject",d.body,d.account,"Today","Now",false);own.folder="Sent";own.outgoing=true;own.address=d.to;own.files=[];s.messages.unshift(own);d.conversation=own.id;u.selected=own.id;m=own;}else m=find(s,d.conversation);
        var sendId="send-"+(++s.sequence),expires=s.now+s.settings.undoSeconds*1000;var sent={id:sendId,body:d.body,to:d.to,cc:d.cc,files:copy(d.files),agent:d.agent,edited:d.edited,status:u.online?"sending":"queued",date:"Now"};m.replies.push(sent);s.jobs.push({id:sendId,conversation:m.id,draft:originalDraft,expires:expires,created:created});s.drafts=s.drafts.filter(function(x){return x.id!==d.id;});u.view="read";u.notice=u.online?"Sending · you can still undo":"No connection. Your message is waiting safely.";u.undo=null;break;
    case "tick":
        s.messages.forEach(function(mail){if(mail.folder==="Later"&&mail.returnAt&&s.now>=mail.returnAt){mail.folder="Inbox";delete mail.returnAt;mail.unread=true;u.notice="A message returned from Later";}});
        s.jobs=s.jobs.filter(function(j){if(s.now<j.expires||!u.online)return true;var thread=find(s,j.conversation);if(thread){var r=thread.replies.find(function(x){return x.id===j.id;});if(r)r.status="sent";}u.notice="Message sent (local preview)";return false;});
        if(u.view==="importing"){u.imported=Math.min(8600,u.imported+1240);if(u.imported===8600){u.view="read";u.account="All accounts";u.selected="studio";s.messages[1].unread=false;u.notice="Your mail is ready (local preview)";}}break;
    case "undoSend":if(s.jobs.length){var last=s.jobs[s.jobs.length-1];if(s.now<=last.expires||!u.online){restoreJob(s,last);u.notice="Sending cancelled. Your draft is ready.";}}break;
    case "editQueued":var j=s.jobs.find(function(x){return x.conversation===u.selected;});if(j)restoreJob(s,j);break;
    case "retry":if(u.online){s.jobs.forEach(function(j){if(j.conversation===u.selected)j.expires=s.now;});return reduce(s,"tick",{now:s.now});}u.notice="Still offline. Your message remains queued.";break;
    case "online":u.online=p.value===undefined?!u.online:!!p.value;s.jobs.forEach(function(j){var mail=find(s,j.conversation);var reply=mail&&mail.replies.find(function(r){return r.id===j.id;});if(reply)reply.status=u.online?"sending":"queued";});u.notice=u.online?"Back online (local preview)":"Working offline";break;
    case "move":if(m){remember(s);m.folder=p.folder;u.notice="Moved to "+p.folder;var rows=results(s);if(!rows.some(function(x){return x.id===m.id;}))u.selected=rows.length?rows[0].id:"";}break;
    case "star":if(m){m.starred=!m.starred;u.notice=m.starred?"Starred":"Star removed";}break;
    case "unread":if(m){m.unread=p.value===undefined?!m.unread:!!p.value;u.notice=m.unread?"Marked unread":"Marked read";}break;
    case "undo":if(u.undo){s.messages=u.undo.messages;s.drafts=u.undo.drafts;s.jobs=u.undo.jobs;s.accounts=u.undo.accounts;u.selected=u.undo.selected;u.undo=null;u.view="read";u.notice="Undone";}break;
    case "expand":if(m){var h=(m.history||[]).find(function(x){return x.id===p.id;});if(h)h.expanded=!h.expanded;}break;
    case "preview":u.attachment=p.file;break;
    case "closePreview":u.attachment=null;break;
    case "saveAttachment":u.notice="Save to Files requested for "+p.name+" (local preview)";break;
    case "settings":u.view="settings";u.rail=false;break;
    case "setting":s.settings[p.key]=p.value;break;
    case "back":u.view="read";u.provider="";u.attachment=null;break;
    case "setup":u.view="setup";u.provider="";u.rail=false;break;
    case "provider":u.provider=p.name;break;
    case "providerEmail":u.providerEmail=p.text;break;
    case "connect":
        if(!validRecipients(u.providerEmail)){u.notice="Enter a valid email address for the preview.";break;}
        if(!s.accounts.some(function(a){return a.email===u.providerEmail;}))s.accounts.push({name:u.providerEmail.split("@")[0],email:u.providerEmail,provider:u.provider||"Another provider"});u.provider="";u.view="importing";u.imported=0;u.notice="Connecting locally · no sign-in or network request";break;
    case "removeAccount":
        if(s.accounts.length<=1){u.notice="Keep one account in this preview.";break;}var account=s.accounts.find(function(a){return a.email===p.email;});if(account){remember(s);s.accounts=s.accounts.filter(function(a){return a.email!==p.email;});s.messages=s.messages.filter(function(x){return x.account!==account.name;});s.drafts=s.drafts.filter(function(x){return x.account!==account.name;});u.notice="Account removed from this preview";}break;
    case "notify":u.notification=s.settings.notifications!=="Off";if(!find(s,"anna-notification")){var incoming=message("anna-notification","Anna Richter","A small question about Tuesday","Hi Lorenz,\n\nWould Tuesday still work for you? I can make either 11:00 or 14:30.\n\nAnna","Personal","Today","Now",true);if(s.settings.agentSort)incoming.category="Family";s.messages.unshift(incoming);if(s.settings.agentDrafts&&(s.settings.agentScope==="All accounts"||s.settings.agentScope==="Personal only"))s.drafts.push(makeDraft(s,incoming.id,"Reply",true));}else find(s,"anna-notification").unread=true;break;
    case "openNotification":u.notification=false;u.view="read";u.folder="Inbox";u.account="All accounts";u.selected=find(s,"anna-notification")?"anna-notification":"anna";find(s,u.selected).unread=false;if(p.reply||p.agent)return reduce(s,"reply",{mode:"Reply",agent:!!p.agent});break;
    case "readNotification":var n=find(s,"anna-notification")||find(s,"anna");n.unread=false;u.notification=false;break;
    case "dismissNotification":u.notification=false;if(u.view==="notification")u.view="read";break;
    case "notice":u.notice=p.text;break;
    case "clearNotice":u.notice="";u.undo=null;break;
    case "escape":if(u.attachment)u.attachment=null;else if(u.view==="draft"||u.view==="compose")u.view="read";else if(u.view!=="read")u.view="read";else if(u.searching){u.searching=false;u.query="";}else if(u.rail)u.rail=false;else u.selected="";break;
    case "reset":return initial("read");
    }
    return s;
}

function highlight(text,query){
    var safe=String(text).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
    var q=String(query||"").trim().replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
    if(q)safe=safe.replace(new RegExp(q,"gi"),function(m){return "<b>"+m+"</b>";});
    return safe.replace(/\n/g,"<br>");
}
