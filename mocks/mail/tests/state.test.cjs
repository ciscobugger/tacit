const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const context=vm.createContext({});vm.runInContext(fs.readFileSync(require('node:path').join(__dirname,'../mail-store.js'),'utf8'),context);
const {initial,reduce,results,draft,canSend,current,folderCount}=context;
let s=initial('read');assert.equal(results(s).length,9);assert.equal(folderCount(s,'Inbox'),4);
s=reduce(s,'select',{id:'studio'});assert.equal(current(s).unread,false);assert.equal(folderCount(s,'Inbox'),3);
s=reduce(s,'search',{text:'palettes'});assert.equal(results(s).length,3);s=reduce(s,'closeSearch');
s=reduce(s,'folder',{folder:'Later'});assert.equal(results(s).length,0);
s=reduce(s,'folder',{folder:'Inbox'});s=reduce(s,'select',{id:'mara'});s=reduce(s,'move',{folder:'Archive'});assert(!results(s).some(x=>x.id==='mara'));s=reduce(s,'undo');assert(results(s).some(x=>x.id==='mara'));
s=reduce(s,'reply',{mode:'Reply all',agent:true});assert(draft(s).agent);s=reduce(s,'draft',{body:'Edited by me'});assert.equal(draft(s).body,'Edited by me');s=reduce(s,'keepDraft');s=reduce(s,'reply',{agent:true});assert.equal(draft(s).body,'Edited by me');
s=reduce(s,'send',{now:100});assert.equal(current(s).replies[0].status,'sending');s=reduce(s,'undoSend',{now:200});assert.equal(draft(s).body,'Edited by me');assert.equal(current(s).replies.length,0);
s=reduce(s,'online',{value:false});s=reduce(s,'send',{now:300});s=reduce(s,'tick',{now:30000});assert.equal(current(s).replies[0].status,'queued');s=reduce(s,'retry',{now:30001});assert.equal(s.jobs.length,1);s=reduce(s,'online',{value:true});s=reduce(s,'retry',{now:30002});assert.equal(s.jobs.length,0);assert.equal(current(s).replies[0].status,'sent');
s=reduce(s,'new');assert(!canSend(draft(s)));s=reduce(s,'draft',{to:'invalid',body:'Hi'});assert(!canSend(draft(s)));s=reduce(s,'draft',{to:'anna.richter@example.net',subject:'Hello'});assert(canSend(draft(s)));s=reduce(s,'attach',{name:'Notes.md'});assert.equal(draft(s).files.length,1);s=reduce(s,'keepDraft');s=reduce(s,'folder',{folder:'Drafts'});assert(results(s).some(x=>x.subject==='Hello'));
s=reduce(s,'setting',{key:'agentScope',value:'All accounts'});s=reduce(s,'notify');assert.equal(s.messages[0].id,'anna-notification');s=reduce(s,'openNotification',{reply:true});assert.equal(current(s).id,'anna-notification');assert.equal(draft(s).to,'anna.richter@example.com');
s=reduce(s,'setup');s=reduce(s,'provider',{name:'Microsoft'});s=reduce(s,'providerEmail',{text:'new@example.com'});s=reduce(s,'connect');assert.equal(s.ui.view,'importing');for(let i=0;i<7;i++)s=reduce(s,'tick');assert.equal(s.ui.view,'read');assert(s.accounts.some(a=>a.email==='new@example.com'));

let n=initial('read');n=reduce(n,'new');n=reduce(n,'draft',{to:'a@example.com',body:'A new message'});n=reduce(n,'send',{now:10});n=reduce(n,'undoSend',{now:11});assert.equal(draft(n).conversation,'');n=reduce(n,'send',{now:12});assert.equal(n.jobs.length,1);n=reduce(n,'tick',{now:20000});assert.equal(n.jobs.length,0);assert.equal(current(n).replies[0].status,'sent');

let later=initial('read');later=reduce(later,'later',{delay:1000,now:1});assert.equal(context.find(later,'mara').folder,'Later');later=reduce(later,'tick',{now:1002});assert.equal(context.find(later,'mara').folder,'Inbox');
let scope=initial('read');scope=reduce(scope,'select',{id:'anna'});scope=reduce(scope,'reply',{agent:true});assert.equal(scope.ui.view,'read');assert(scope.ui.notice.includes('allowed'));
let settings=initial('read');settings=reduce(settings,'setting',{key:'notifications',value:'Off'});settings=reduce(settings,'notify');assert.equal(settings.ui.notification,false);

console.log('Frontend state: all workflow checks passed');
