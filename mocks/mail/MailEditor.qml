import QtQuick
import QtQuick.Layouts
import Tacit.Kit as K

Item {
    id:editor
    required property var controller
    readonly property var draft:controller.draft
    readonly property var t:K.Kit.tokens
    property bool newMessage:false
    property real availableHeight:0
    readonly property real labelWidth:t.space.page+t.space.l
    signal attachRequested()
    implicitHeight:content.implicitHeight+t.space.l
    function focusBody(){if(newMessage&&!draft.to.includes("@"))recipients.focusIn();else body.focusIn();}
    component Label:K.TacitText {Layout.preferredWidth:editor.labelWidth;size:"meta";ink:"meta"}
    ColumnLayout {
        id:content
        width:parent.width;spacing:editor.t.space.m
        ColumnLayout {
            visible:!editor.newMessage
            Layout.fillWidth:true;spacing:editor.t.space.s
            RowLayout {Layout.fillWidth:true
                K.TacitText {Layout.fillWidth:true;wrapMode:Text.Wrap;text:editor.draft?.agent?"Your agent drafted a reply":"Your reply";weight:"strong";color:editor.draft?.agent?editor.controller.agentInk:editor.t.inkMain}
                K.TacitText {text:"Not sent";size:"meta";ink:"meta"}
            }
            RowLayout {Layout.fillWidth:true;spacing:editor.t.space.xxl
                K.TacitText {Layout.fillWidth:true;wrapMode:Text.Wrap;text:editor.draft?.conversation==="mara"?"Why: to answer both of Mara's questions, from your header notes.":"Review your message before sending.";size:"meta";ink:"sec"}
                MailAction {visible:!!editor.draft?.agent;text:"Open notes";onActivated:editor.controller.act("preview",{file:{name:"Header notes.md",path:"fixtures/header-notes.md",content:"Sender and date on one line.\nAttachments below their message."}})}
            }
        }
        ColumnLayout {
            id:fields
            Layout.fillWidth:true;spacing:editor.t.space.s
            RowLayout {
                Layout.fillWidth:true;spacing:editor.t.space.l
                Label {text:"From"}
                MailAction {
                    objectName:"draftFrom"
                    text:{const a=editor.controller.accounts.find(a=>a.name===editor.draft?.account);return a?(editor.width<editor.t.width.panel+editor.t.space.page?a.name:a.name+", "+a.email)+"  ⌄":"";}
                    onActivated:accountMenu.openAt(this,0,height)
                }
                Item {Layout.fillWidth:true}
                MailAction {visible:!editor.newMessage;text:(editor.draft?.mode ?? "Reply")+"  ⌄";onActivated:modeMenu.openAt(this,width-modeMenu.implicitWidth,height)}
            }
            RowLayout {
                Layout.fillWidth:true;spacing:editor.t.space.l
                Label {text:"To"}
                K.Field {
                    id:recipients;objectName:"draftTo"
                    Layout.fillWidth:true;Layout.minimumWidth:0
                    label:"To recipients";hint:"Name or email address";text:editor.draft?.to ?? ""
                    error:!input.activeFocus&&text!==""&&!editor.controller.addressesValid(text)
                    onEdited:editor.controller.act("draft",{to:text})
                }
                RowLayout {spacing:editor.t.space.xxl
                    MailAction {text:"Cc";onActivated:editor.controller.act("draft",{showCc:!editor.draft.ccExpanded,ccExpanded:!editor.draft.ccExpanded})}
                    MailAction {text:"Bcc";onActivated:editor.controller.act("draft",{showBcc:!editor.draft.showBcc})}
                }
            }
            Column {
                visible:recipients.input.activeFocus&&recipients.text.toLowerCase().includes("anna")&&!recipients.text.includes("@")
                Layout.fillWidth:true;Layout.leftMargin:editor.labelWidth+editor.t.space.l
                Repeater {
                    model:[{name:"Anna Richter",email:"anna.richter@example.net",account:"Personal"},{name:"Anna Richter",email:"a.richter@moss.example",account:"Work"}]
                    delegate:K.ListRow {
                        required property var modelData
                        width:parent.width;height:editor.t.height.richRow;name:"";facts:[]
                        Accessible.name:modelData.name+", "+modelData.email
                        onClicked:{editor.controller.act("draft",{to:modelData.email});body.focusIn();}
                        onActivated:{editor.controller.act("draft",{to:modelData.email});body.focusIn();}
                        ColumnLayout {anchors.fill:parent;anchors.margins:editor.t.space.s;spacing:editor.t.space.xs
                            K.TacitText {Layout.fillWidth:true;text:modelData.name+" · "+modelData.account;size:"meta";weight:"medium";elide:Text.ElideRight}
                            K.TacitText {Layout.fillWidth:true;text:modelData.email;size:"meta";ink:"meta";elide:Text.ElideRight}
                        }
                    }
                }
            }
            RowLayout {
                visible:(editor.draft?.showCc ?? false)&&(editor.draft?.ccExpanded ?? false)
                Layout.fillWidth:true;spacing:editor.t.space.l
                Label {text:"Cc"}
                K.Field {Layout.fillWidth:true;Layout.minimumWidth:0;label:"Cc recipients";text:editor.draft?.cc ?? "";onEdited:editor.controller.act("draft",{cc:text})}
            }
            RowLayout {
                visible:editor.draft?.showBcc ?? false
                Layout.fillWidth:true;spacing:editor.t.space.l
                Label {text:"Bcc"}
                K.Field {Layout.fillWidth:true;Layout.minimumWidth:0;label:"Bcc recipients";text:editor.draft?.bcc ?? "";onEdited:editor.controller.act("draft",{bcc:text})}
            }
            RowLayout {
                Layout.fillWidth:true;spacing:editor.t.space.l
                Label {text:"Subject"}
                K.Field {objectName:"draftSubject";Layout.fillWidth:true;Layout.minimumWidth:0;label:"Message subject";hint:"Add a subject";text:editor.draft?.subject ?? "";onEdited:editor.controller.act("draft",{subject:text})}
            }
        }
        K.TextArea {
            id:body;objectName:"draftBody"
            Layout.fillWidth:true;Layout.topMargin:editor.t.space.l
            label:"Message body";hint:"Write your message";maxLines:40
            text:editor.draft?.body ?? ""
            onEdited:{const value=text;const id=editor.controller.ui.draftId;const c=editor.controller;Qt.callLater(function(){if(id&&c.draft?.id===id)c.act("draft",{body:value});});}
            onSubmitted:if(editor.controller.canSend)editor.controller.act("send")
            onDismissed:editor.controller.act("keepDraft")
        }
        Repeater {
            model:editor.draft?.files ?? []
            delegate:RowLayout {
                required property var modelData
                Layout.fillWidth:true;spacing:editor.t.space.xxl
                K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;text:modelData.name;elide:Text.ElideRight}
                MailAction {text:"Remove";onActivated:editor.controller.act("detach",{id:modelData.id})}
            }
        }
    }
    K.Menu {id:accountMenu;items:editor.controller.accounts.map(a=>({label:a.name+", "+a.email,checked:a.name===editor.draft?.account}));onPicked:i=>editor.controller.act("draft",{account:editor.controller.accounts[i].name})}
    K.Menu {id:modeMenu;items:[{label:"Reply"},{label:"Reply all"},{label:"Forward"}];onPicked:i=>editor.controller.act("mode",{value:items[i].label})}
}
