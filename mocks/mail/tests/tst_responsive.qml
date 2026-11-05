import QtQuick
import QtTest
import Tacit.Kit as K
import ".." as Mail
import "../mail-store.js" as Store

Item {
    id:fixture
    width:1720;height:972
    Mail.MailState {id:state}
    Mail.MailWorkspace {id:workspace;anchors.fill:parent;controller:state}
    TestCase {
        name:"MailResponsive"
        when:windowShown
        function init(){fixture.width=1720;fixture.height=972;state.data=Store.initial("read");K.Kit.reducedMotion=true;workspace.compactReading=true;wait(40);}
        function item(name){var result=findChild(workspace,name);verify(result!==null,"Missing "+name);return result;}
        function inside(control){var at=control.mapToItem(workspace,0,0);verify(at.x>=-1&&at.y>=-1,control.objectName+" starts outside the window");verify(at.x+control.width<=workspace.width+1&&at.y+control.height<=workspace.height+1,control.objectName+" ends outside the window");}
        function test_sizes_data(){return [
            {tag:"minimum",w:400,h:600},
            {tag:"narrow",w:560,h:500},
            {tag:"short",w:820,h:400},
            {tag:"medium",w:1024,h:768},
            {tag:"wide",w:1720,h:972}
        ];}
        function test_sizes(data){
            fixture.width=data.w;fixture.height=data.h;wait(60);
            inside(item("readerPane"));inside(item("messageSubject"));inside(item("readingScroll"));
            verify(item("readingScroll").height>0,"Reading area must retain visible space");
            var size=item("messageSubject").font.pixelSize;
            compare(size,K.Kit.tokens.size.headline,"Window resizing must not scale typography");
            state.reply("Reply all",false);wait(80);
            inside(item("editorFooter"));inside(item("sendDraft"));inside(item("draftTo"));
            verify(item("draftBody").width>0,"Body editor must have usable width");
            var editor=item("mailEditor"), body=item("draftBody");
            verify(body.width<=editor.width+1,"The body must not exceed its reading column");
            verify(body.input.width<=body.width+1,"Text wrapping must use the actual body width");
        }
        function test_compactNavigation(){
            fixture.width=560;fixture.height=600;wait(50);
            verify(!item("inboxPane").visible);verify(item("readerPane").visible);
            var back=item("backToInbox");mouseClick(back,back.width/2,back.height/2);wait(50);
            verify(item("inboxPane").visible);verify(!item("readerPane").visible);
            inside(item("mailSearch"));inside(item("viewOptions"));
            var list=item("messageList"),row=list.view.itemAtIndex(1);verify(row!==null);
            mouseClick(row,row.width/2,row.height/2);wait(50);
            compare(state.ui.selected,"studio");verify(item("readerPane").visible);verify(!item("inboxPane").visible);
            fixture.width=1720;wait(50);verify(item("inboxPane").visible);verify(item("readerPane").visible);
        }
        function test_composeStartsAtRecipients(){
            fixture.width=560;fixture.height=600;state.act("new");wait(80);
            compare(item("readingScroll").contentY,0);
            inside(item("draftFrom"));inside(item("draftTo"));inside(item("draftSubject"));
        }
        function test_narrowSettingsAndSetup(){
            fixture.width=560;fixture.height=600;state.act("settings");wait(60);
            var columns=item("settingsColumns"), scroll=item("settingsScroll");
            compare(columns.columns,1);compare(scroll.contentWidth,scroll.width);
            var at=columns.mapToItem(workspace,0,0);
            verify(at.x>=0&&at.x+columns.width<=workspace.width+1,"Settings must not overflow horizontally");
            state.act("setup");wait(60);inside(item("provider-Google"));inside(item("provider-Another provider"));
        }
        function test_longSubject(){
            fixture.width=560;fixture.height=600;
            var data=Store.copy(state.data);Store.find(data,"mara").subject="A much longer subject that needs several lines in a narrow window and must never overlap the message toolbar or the thread";state.data=data;wait(60);
            var subject=item("messageSubject"), scroll=item("readingScroll");
            var titleBottom=subject.mapToItem(workspace,0,subject.height).y;
            verify(scroll.mapToItem(workspace,0,0).y>=titleBottom,"Thread must follow the full wrapped subject");
            inside(subject);inside(scroll);
        }
    }
}
