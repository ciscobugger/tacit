import QtQuick
import QtTest
import Tacit.Kit as K
import ".." as Mail
import "../mail-store.js" as Store

Item {
    width:1720;height:972
    Mail.MailState {id:state}
    Mail.MailWorkspace {id:workspace;anchors.fill:parent;controller:state}
    TestCase {
        name:"MailFrontend"
        when:windowShown
        function init(){state.data=Store.initial("read");K.Kit.reducedMotion=true;wait(30);}
        function keyClicks(text){for(var i=0;i<text.length;i++)keyClick(text[i]);}
        function button(name){var found=findChild(workspace,name);verify(found!==null,"Missing "+name);return found;}
        function click(name){var b=button(name);mouseClick(b,b.width/2,b.height/2);wait(30);}
        function test_selectMessage(){var list=button("messageList");var row=list.view.itemAtIndex(1);verify(row!==null);mouseClick(row,row.width/2,row.height/2);compare(state.ui.selected,"studio");compare(state.selected.unread,false);}
        function test_replyKeepsDraft(){click("replyAll");compare(state.ui.view,"draft");verify(state.draft.showCc);click("keepDraft");compare(state.ui.view,"read");verify(state.data.drafts.length>=2);}
        function test_newMessageTyping(){click("newMessage");compare(state.ui.view,"compose");var to=button("draftTo");to.input.forceActiveFocus();keyClicks("anna.richter@example.net");compare(state.draft.to,"anna.richter@example.net");var body=button("draftBody");body.input.forceActiveFocus();keyClicks("A local message");compare(state.draft.body,"A local message");verify(state.canSend);click("sendDraft");compare(state.data.jobs.length,1);state.act("undoSend");compare(state.ui.view,"compose");compare(state.draft.body,"A local message");}
        function test_archiveAndUndo(){click("archive");compare(Store.find(state.data,"mara").folder,"Archive");state.act("undo");compare(Store.find(state.data,"mara").folder,"Inbox");}
        function test_search(){var search=button("mailSearch");search.forceActiveFocus();keyClicks("palettes");compare(state.ui.query,"palettes");compare(state.rows.length,3);}
        function test_keyboardSelection(){var list=button("messageList");list.cursor=-1;list.forceActiveFocus();keyClick(Qt.Key_Down);wait(30);compare(state.ui.selected,"mara");keyClick(Qt.Key_Down);wait(30);compare(state.ui.selected,"studio");}
        function test_expandHistory(){click("history-lena-first");verify(state.selected.history[0].expanded);click("history-lena-first");verify(!state.selected.history[0].expanded);}
        function test_historyMotionAndDivider(){
            K.Kit.reducedMotion=false;
            var body=button("historyBody-lena-first");
            compare(body.height,0);
            state.act("expand",{id:"lena-first"});
            wait(80);
            compare(button("historyBody-lena-first"),body,"Expanding must preserve the message item");
            verify(body.height>0,"The body should expand during the arrive motion");
            var halfway=body.height;
            wait(K.Kit.motion("arriveSmall").ms);
            verify(body.height>halfway,"Expansion must move through intermediate heights");
            var divider=button("historyDivider-lena-first");
            verify(divider.y>=body.y+body.height,"The hairline must follow the whole message");
            state.act("expand",{id:"lena-first"});
            wait(60);verify(body.height>0,"Content must remain visible during leave");
            wait(K.Kit.motion("leave").ms);compare(body.height,0);
            K.Kit.reducedMotion=true;
        }
        function test_latestMessageToggle(){
            var body=button("messageBody-mara");verify(body.height>0);
            click("messageHeader-mara");compare(body.height,0);
            click("messageHeader-mara");verify(body.height>0);
            click("openAttachment");compare(state.ui.attachment.id,"review");
        }
        function test_sentMessageToggle(){
            state.reply("Reply",false);state.act("draft",{body:"A local reply"});state.act("send");wait(30);
            var id=state.selected.replies[0].id;
            var body=button("messageBody-"+id), header=button("messageHeader-"+id);
            verify(body.height>0);header.forceActiveFocus();keyClick(Qt.Key_Return);wait(30);compare(body.height,0);
            keyClick(Qt.Key_Return);wait(30);verify(body.height>0);
        }
        function test_headerFocusRoom(){
            var scroll=button("readingScroll"), row=button("messageHeader-mara");
            var room=K.Kit.tokens.state.focusGap+K.Kit.tokens.state.focusRing;
            var at=row.mapToItem(scroll,0,0);
            verify(at.x>=room,"The full left focus ring must fit inside the scroll viewport");
            verify(at.x+row.width+room<=scroll.width,"The full right focus ring must fit inside the scroll viewport");
            var first=button("history-lena-first").mapToItem(scroll,0,0);
            verify(first.y>=room,"The top focus ring must fit inside the scroll viewport");
            var title=button("folderMenu"), caption=button("mailboxCaption");
            var titleAt=title.mapToItem(workspace,0,0), captionAt=caption.mapToItem(workspace,0,0);
            verify(captionAt.y>=titleAt.y+title.height+room,"Caption must clear the title's focus ring");
        }
        function test_attachmentPreview(){click("openAttachment");compare(state.ui.attachment.id,"review");verify(state.ui.attachment.path.endsWith(".pdf"));}
        function test_filterMenuKeyboard(){click("viewOptions");wait(200);keyClick(Qt.Key_Down);keyClick(Qt.Key_Down);keyClick(Qt.Key_Return);wait(30);compare(state.ui.filter,"Unread");verify(state.rows.every(function(m){return m.unread;}));}
        function test_editorFooterStaysVisible(){
            click("replyAll");
            var send=button("sendDraft"), body=button("draftBody"), scroll=button("readingScroll");
            var before=send.mapToItem(workspace,0,0);
            verify(before.y>=0 && before.y+send.height<=workspace.height,"Send must remain inside the window");
            scroll.contentY=30;
            var after=send.mapToItem(workspace,0,0);
            compare(after.y,before.y,"Scrolling the document must not move Send");
            verify(body.width<=scroll.width,"The editor must fit the reading column");
        }
        function test_sidebar(){click("folderMenu");compare(state.ui.rail,true);verify(button("mailboxes").visible);}
    }
}
