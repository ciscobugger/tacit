import QtQuick
import QtQuick.Layouts
import Tacit.Kit as K

Item {
    id:reader
    required property var controller
    readonly property var t:K.Kit.tokens
    readonly property var message:controller.selected
    readonly property bool composing:controller.ui.view==="compose"
    readonly property bool editing:controller.ui.view==="draft"||composing
    property bool compact:false
    signal backRequested()
    readonly property real pageMargin:width>t.width.list?t.space.page:t.space.l
    readonly property real columnWidth:Math.max(0,Math.min(width-pageMargin*2,t.width.list-t.space.l-t.space.xs))
    readonly property real focusRoom:t.state.focusGap+t.state.focusRing
    readonly property real textInset:width<t.width.panel+t.space.page*2?t.space.xl:t.space.page
    readonly property real textWidth:columnWidth-textInset
    readonly property real columnX:(width-columnWidth)/2
    readonly property real textX:columnX+textInset
    readonly property bool queued:!!message?.replies.some(r=>r.status==="queued")
    property string shownMessage:message?.id ?? ""
    property var collapsedMessages:({})
    function isExpanded(id){return !collapsedMessages[id];}
    function toggleMessage(id){var next=Object.assign({},collapsedMessages);next[id]=!next[id];collapsedMessages=next;}
    signal attachRequested()
    onShownMessageChanged:{paper.contentY=0;collapsedMessages=({});}
    onEditingChanged:if(editing)focusEditor();else paper.contentY=0
    Component.onCompleted:if(editing)focusEditor()
    function focusEditor(){Qt.callLater(function(){if(!editor.visible)return;thread.forceLayout();scrollTo.stop();scrollState.origin=paper.contentY;scrollState.progress=0;scrollTo.start();editor.focusBody();});}
    Connections {target:reader.controller;function onEditorRequested(){reader.focusEditor();}}
    component Rule:Rectangle {height:1;color:Qt.alpha(reader.t.inkMain,reader.t.wash.hover+0.02)}
    component Mark:Rectangle {width:reader.t.space.l+reader.t.space.xs/4;height:1;color:reader.t.inkMain}

    component MessageBody:Item {
        id:body
        property bool expanded:true
        default property alias contents:content.data
        width:parent.width;height:expanded?content.height:0
        visible:height>0;clip:true
        Behavior on height {
            NumberAnimation {
                duration:K.Kit.ms(body.expanded?K.Kit.motion("arriveSmall").ms:K.Kit.motion("leave").ms)
                easing.type:Easing.BezierSpline
                easing.bezierCurve:body.expanded?K.Kit.motion("arriveSmall").curve:K.Kit.motion("leave").curve
            }
        }
        Column {id:content;width:parent.width;spacing:0}
    }

    ColumnLayout {
        id:readingLayout
        x:reader.columnX-reader.focusRoom;y:reader.pageMargin
        width:reader.columnWidth+reader.focusRoom*2;height:Math.max(0,reader.height-y-reader.t.space.l)
        spacing:reader.t.space.l
        GridLayout {
            objectName:"messageToolbar"
            Layout.fillWidth:true;Layout.minimumWidth:0;Layout.leftMargin:reader.textInset+reader.focusRoom;Layout.rightMargin:reader.focusRoom
            columns:reader.textWidth>=reader.t.width.panel+reader.t.space.page*3?3:1
            columnSpacing:reader.t.space.xxl;rowSpacing:reader.t.space.s
            RowLayout {spacing:reader.t.space.xxl
            MailAction {objectName:"backToInbox";visible:reader.compact;text:"Inbox";onActivated:reader.backRequested()}
            MailAction {objectName:"reply";visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;text:"Reply";onActivated:reader.controller.reply("Reply",false)}
            MailAction {objectName:"replyAll";visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;text:"Reply all";onActivated:reader.controller.reply("Reply all",false)}
            MailAction {objectName:"forward";visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;text:"Forward";onActivated:reader.controller.reply("Forward",false)}
            MailAction {objectName:"keepDraft";visible:reader.editing;text:"Close, keep the draft";onActivated:reader.controller.act("keepDraft")}
            MailAction {visible:!!reader.controller.ui.attachment;text:"Back to message";onActivated:reader.controller.act("closePreview")}
            }
            Item {visible:parent.columns===3;Layout.fillWidth:true}
            RowLayout {visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;Layout.alignment:Qt.AlignRight;spacing:reader.t.space.xxl
            MailAction {objectName:"archive";visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;text:"Archive";onActivated:reader.controller.act("move",{folder:"Archive"})}
            MailAction {visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;text:"Later";onActivated:laterMenu.openAt(this,width-laterMenu.implicitWidth,height)}
            MailAction {objectName:"messageMore";visible:!!reader.message&&!reader.editing&&!reader.controller.ui.attachment;text:"More";onActivated:more.openAt(this,width-more.implicitWidth,height)}
            }
        }
        Rule {Layout.fillWidth:true;Layout.leftMargin:reader.textInset+reader.focusRoom;Layout.rightMargin:reader.focusRoom}
        K.TacitText {
            objectName:"messageSubject"
            Layout.fillWidth:true;Layout.leftMargin:reader.textInset+reader.focusRoom;Layout.rightMargin:reader.focusRoom
            size:"headline";weight:"strong";cut:"display";wrapMode:Text.Wrap
            text:reader.controller.ui.attachment?reader.controller.ui.attachment.name:reader.composing?"New message":reader.message?.subject ?? "Choose a message"
        }
        K.TacitText {
            visible:!!reader.message&&!reader.composing&&!reader.controller.ui.attachment
            Layout.fillWidth:true;Layout.leftMargin:reader.textInset+reader.focusRoom;Layout.rightMargin:reader.focusRoom
            readonly property int count:(reader.message?.history?.length ?? 0)+(reader.message?.outgoing?0:1)+(reader.message?.replies?.length ?? 0)
            text:count+" message"+(count===1?"":"s")+"  ·  "+(reader.message?.account ?? "");size:"meta";ink:"meta"
        }
    Item {
        Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumHeight:0
    Flickable {
        id:paper;objectName:"readingScroll"
        anchors.fill:parent
        contentWidth:width;contentHeight:thread.y+thread.height+reader.t.space.l;clip:true;boundsBehavior:Flickable.StopAtBounds
        Column {
            id:thread
            x:reader.focusRoom;y:reader.focusRoom;width:reader.columnWidth;spacing:0
            Column {
                visible:!!reader.controller.ui.attachment
                x:reader.textInset;width:reader.textWidth;spacing:reader.t.space.xl
                K.TacitText {text:reader.controller.ui.attachment?.detail ?? "";size:"meta";ink:"meta"}
                Image {visible:/\.(png|jpg|jpeg|webp|gif)$/i.test(reader.controller.ui.attachment?.name ?? "");source:visible?(reader.controller.ui.attachment?.url ?? ""):"";width:parent.width;height:reader.t.width.panel;fillMode:Image.PreserveAspectFit}
                K.TacitText {width:parent.width;wrapMode:Text.Wrap;size:"body";text:reader.controller.ui.attachment?.content ?? "Local attachment"}
                MailAction {visible:!!reader.controller.ui.attachment?.url||!!reader.controller.ui.attachment?.path;text:"Open with default app";onActivated:Qt.openUrlExternally(reader.controller.ui.attachment.url||Qt.resolvedUrl(reader.controller.ui.attachment.path))}
                MailAction {text:"Save to Files";onActivated:reader.controller.saveAttachment(reader.controller.ui.attachment)}
            }
            Item {
                visible:!!reader.message&&!reader.composing&&!reader.controller.ui.attachment
                width:parent.width;height:messageBlocks.height
                Rectangle {visible:!!reader.message?.history?.length;x:reader.t.space.l;y:reader.t.space.xl-1;width:1;height:Math.max(0,messageBlocks.height-y-reader.t.space.page);color:Qt.alpha(reader.t.inkMain,reader.t.wash.current+0.04)}
                Column {
                    id:messageBlocks;width:parent.width;spacing:0
                    Rule {visible:!!reader.message?.history?.length;x:reader.textInset;width:reader.textWidth}
                    Repeater {
                        model:reader.message?.history?.length ?? 0
                        delegate:Column {
                            required property int index
                            readonly property var modelData:reader.message?.history[index] ?? ({})
                            width:parent.width;spacing:0
                            K.ListRow {
                                objectName:"history-"+modelData.id
                                width:parent.width;height:reader.t.space.page;name:"";facts:[]
                                Accessible.name:modelData.from+", "+modelData.date
                                onClicked:reader.controller.act("expand",{id:modelData.id});onActivated:reader.controller.act("expand",{id:modelData.id})
                                Mark {x:reader.t.space.m;y:reader.t.space.xl-1;width:reader.t.space.s+1;color:Qt.alpha(reader.t.inkMain,reader.t.wash.currentHover+0.21)}
                                RowLayout {
                                    anchors.fill:parent;anchors.leftMargin:reader.textInset;anchors.rightMargin:reader.t.space.s
                                    spacing:reader.t.space.m
                                    K.TacitText {Layout.preferredWidth:Math.min(reader.t.width.rail/2-reader.t.space.l,reader.textWidth/3);Layout.minimumWidth:0;text:modelData.from;weight:"medium";ink:"sec";elide:Text.ElideRight}
                                    K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;text:modelData.expanded?"":reader.controller.highlight(modelData.body);textFormat:Text.StyledText;elide:Text.ElideRight;ink:"meta"}
                                    K.TacitText {text:modelData.date;size:"meta";ink:"meta"}
                                    K.Symbol {text:modelData.expanded?"expand_less":"expand_more";size:reader.t.icon.rail;color:reader.t.inkMeta}
                                }
                            }
                            Item {
                                id:historyBody
                                objectName:"historyBody-"+modelData.id
                                x:reader.textInset;width:reader.textWidth
                                height:modelData.expanded?historyText.implicitHeight:0
                                visible:height>0;clip:true
                                readonly property string entryId:modelData.id ?? ""
                                property bool animate:false
                                onEntryIdChanged:{animate=false;Qt.callLater(function(){historyBody.animate=true;});}
                                Component.onCompleted:Qt.callLater(function(){historyBody.animate=true;})
                                Behavior on height {
                                    enabled:historyBody.animate
                                    NumberAnimation {
                                        duration:K.Kit.ms(modelData.expanded?K.Kit.motion("arriveSmall").ms:K.Kit.motion("leave").ms)
                                        easing.type:Easing.BezierSpline
                                        easing.bezierCurve:modelData.expanded?K.Kit.motion("arriveSmall").curve:K.Kit.motion("leave").curve
                                    }
                                }
                                K.TacitText {id:historyText;width:parent.width;topPadding:reader.t.space.l;bottomPadding:reader.t.space.l;text:modelData.body ?? "";size:"body";wrapMode:Text.Wrap;lineHeight:1.3}
                            }
                            Rule {objectName:"historyDivider-"+modelData.id;x:reader.textInset;width:reader.textWidth}
                        }
                    }
                    Column {
                        visible:(reader.editing||reader.queued)&&!!reader.message?.history?.length
                        width:parent.width;spacing:0
                        K.ListRow {
                            objectName:"contextHeader-"+(reader.message?.id ?? "")
                            width:parent.width;height:reader.t.space.page;name:"";facts:[]
                            Accessible.name:(reader.isExpanded(reader.message?.id)?"Collapse ":"Expand ")+(reader.message?.from ?? "message")
                            onClicked:reader.toggleMessage(reader.message.id)
                            onActivated:reader.toggleMessage(reader.message.id)
                            Mark {x:reader.t.space.m;y:reader.t.space.xl-1;width:reader.t.space.s+1;color:reader.t.inkMeta}
                            K.TacitText {x:reader.textInset;y:reader.t.space.m+reader.t.space.xs/2;width:Math.max(0,parent.width-reader.textInset-reader.t.width.rail/2);elide:Text.ElideRight;text:reader.message?.from ?? "";weight:"medium";ink:"sec"}
                            K.TacitText {anchors.right:parent.right;anchors.rightMargin:reader.t.space.xl;y:reader.t.space.m+reader.t.space.xs/2;text:"Today "+(reader.message?.time ?? "");size:"meta";ink:"meta"}
                            K.Symbol {anchors.right:parent.right;y:reader.t.space.m+reader.t.space.xs/2;text:reader.isExpanded(reader.message?.id)?"expand_less":"expand_more";size:reader.t.icon.rail;color:reader.t.inkMeta}
                        }
                        MessageBody {
                            expanded:reader.isExpanded(reader.message?.id)&&!reader.queued
                            K.TacitText {x:reader.textInset;width:reader.textWidth-reader.t.height.action;bottomPadding:reader.t.space.l+reader.t.space.xs;wrapMode:Text.Wrap;size:"body";lineHeight:1.3;ink:"sec";text:reader.message?.id==="mara"?"Could you take a look at the navigation and the message header before Thursday? The interface should stay quiet, with the content doing most of the talking.":reader.message?.body ?? ""}
                        }
                        Rule {x:reader.textInset;width:reader.textWidth}
                    }
                    Item {width:1;height:reader.message?.history?.length?reader.t.space.xl+reader.t.space.xs/2:reader.t.space.s+reader.t.space.xs/2}
                    Column {
                        visible:!reader.editing&&!reader.queued&&!reader.message?.outgoing
                        width:parent.width;spacing:0
                        K.ListRow {
                            width:parent.width;height:reader.t.space.page+reader.t.space.xs
                            objectName:"messageHeader-"+(reader.message?.id ?? "")
                            name:"";facts:[]
                            Accessible.name:(reader.isExpanded(reader.message?.id)?"Collapse ":"Expand ")+(reader.message?.from ?? "message")
                            onClicked:reader.toggleMessage(reader.message.id)
                            onActivated:reader.toggleMessage(reader.message.id)
                            K.Symbol {anchors.right:parent.right;y:reader.t.space.s+reader.t.space.xs/2;text:reader.isExpanded(reader.message?.id)?"expand_less":"expand_more";size:reader.t.icon.rail;color:reader.t.inkMeta}
                            Mark {x:reader.t.space.s;y:reader.t.space.l+reader.t.space.xs/2}
                            K.TacitText {x:reader.textInset;y:reader.t.space.s;width:Math.max(0,parent.width-reader.textInset-reader.t.width.rail/2);elide:Text.ElideRight;text:reader.message?.from ?? "";weight:"strong"}
                            K.TacitText {x:reader.textInset;y:reader.t.space.xxl-reader.t.space.xs/2;width:reader.textWidth;elide:Text.ElideRight;text:"To you"+(reader.message?.cc?", Nils Berger and Lena Fischer":"");size:"meta";ink:"sec"}
                            K.TacitText {anchors.right:parent.right;anchors.rightMargin:reader.t.space.xl;y:reader.t.space.s+reader.t.space.xs/2;text:(reader.message?.day ?? "")+" "+(reader.message?.time ?? "");size:"meta";ink:"meta"}
                        }
                        MessageBody {
                            objectName:"messageBody-"+(reader.message?.id ?? "")
                            expanded:reader.isExpanded(reader.message?.id)
                        Item {width:1;height:reader.t.space.l+reader.t.space.xs/2}
                        Column {
                            x:reader.textInset;width:reader.textWidth;spacing:reader.t.space.m+reader.t.space.xs/2
                            Repeater {model:(reader.message?.body ?? "").split("\n\n");delegate:K.TacitText {required property string modelData;width:parent.width;text:reader.controller.highlight(modelData);textFormat:Text.StyledText;size:"body";wrapMode:Text.Wrap;lineHeight:1.3}}
                        }
                        Item {width:1;height:reader.t.space.l+reader.t.space.xs/2}
                        Repeater {
                            model:reader.message?.files ?? []
                            delegate:Item {
                                required property var modelData
                                x:reader.textInset;width:reader.textWidth;height:attachmentFlow.implicitHeight
                                Flow {
                                    id:attachmentFlow;width:parent.width;spacing:reader.t.space.xxl
                                    RowLayout {width:Math.min(implicitWidth,attachmentFlow.width);height:reader.t.height.action;spacing:reader.t.space.m
                                        K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;text:modelData.name;weight:"medium";elide:Text.ElideRight}
                                        K.TacitText {text:modelData.detail;size:"meta";ink:"meta"}
                                    }
                                    MailAction {objectName:"openAttachment";text:"Open";onActivated:reader.controller.act("preview",{file:modelData})}
                                    MailAction {text:"Save to Files";onActivated:reader.controller.saveAttachment(modelData)}
                                }
                            }
                        }
                        Item {width:1;height:reader.t.space.xl+reader.t.space.xs/2}
                        }
                    }
                    Repeater {
                        model:reader.editing?0:(reader.message?.replies?.length ?? 0)
                        delegate:Column {
                            required property int index
                            readonly property var modelData:reader.message?.replies[index] ?? ({})
                            width:parent.width;spacing:0
                            Rule {x:reader.textInset;width:reader.textWidth}
                            K.ListRow {width:parent.width;height:reader.t.height.header+reader.t.space.xs
                                objectName:"messageHeader-"+modelData.id
                                name:"";facts:[]
                                Accessible.name:(reader.isExpanded(modelData.id)?"Collapse":"Expand")+" your message"
                                onClicked:reader.toggleMessage(modelData.id)
                                onActivated:reader.toggleMessage(modelData.id)
                                K.Symbol {anchors.right:parent.right;y:reader.t.space.l+reader.t.space.xs;text:reader.isExpanded(modelData.id)?"expand_less":"expand_more";size:reader.t.icon.rail;color:reader.t.inkMeta}
                                Mark {x:reader.t.space.s;y:reader.t.space.xl+reader.t.space.s}
                                K.TacitText {x:reader.textInset;y:reader.t.space.l+reader.t.space.xs;text:"You";weight:"strong"}
                                K.TacitText {x:reader.textInset;y:reader.t.height.action+reader.t.space.xs/2;text:"To "+reader.controller.names(modelData.to+(modelData.cc?", "+modelData.cc:""));size:"meta";ink:"sec";width:reader.textWidth;elide:Text.ElideRight}
                                K.TacitText {anchors.right:parent.right;anchors.rightMargin:reader.t.space.xl;y:reader.t.space.l+reader.t.space.xs;text:modelData.status==="sent"?"Sent":modelData.status==="queued"?"Not sent":"Sending";size:"meta";ink:"meta"}
                            }
                            MessageBody {
                                objectName:"messageBody-"+modelData.id
                                expanded:reader.isExpanded(modelData.id)
                            Column {x:reader.textInset;width:reader.textWidth;spacing:reader.t.space.m;Repeater {model:modelData.body.split("\n\n");delegate:K.TacitText {required property string modelData;width:parent.width;text:modelData;size:"body";wrapMode:Text.Wrap;lineHeight:1.3}}}
                            K.TacitText {visible:modelData.agent;x:reader.textInset;topPadding:reader.t.space.l;bottomPadding:reader.t.space.l;text:modelData.edited?"↳ Drafted by your agent, edited by you":"↳ Drafted by your agent";size:"meta";color:reader.controller.agentInk}
                            Repeater {model:modelData.files;delegate:MailAction {required property var modelData;x:reader.textInset;text:modelData.name;onActivated:reader.controller.act("preview",{file:modelData})}}
                            Column {visible:modelData.status==="queued";x:reader.textInset;width:reader.textWidth;spacing:reader.t.space.s
                                K.TacitText {width:parent.width;wrapMode:Text.Wrap;ink:"sec";text:"No connection. Mail sends it as soon as you are back online; nothing was lost."}
                                Row {spacing:reader.t.space.xl
                                    MailAction {text:"Try now";onActivated:reader.controller.act("retry")}
                                    MailAction {text:"Edit";onActivated:reader.controller.act("editQueued")}
                                    MailAction {text:"Keep it in Drafts";onActivated:{reader.controller.act("editQueued");reader.controller.act("keepDraft");}}
                                }
                            }
                        }
                        }
                    }
                    Item {
                        visible:!!reader.controller.agentDraft(reader.message?.id ?? "")&&!reader.editing
                        width:parent.width;height:agentLayout.implicitHeight+reader.t.space.l
                        Rectangle {x:reader.t.space.s;y:reader.t.space.xl+reader.t.space.s;width:reader.t.space.l+1;height:reader.t.state.focusRing;color:reader.controller.agentInk}
                        ColumnLayout {
                            id:agentLayout
                            x:reader.textInset;width:reader.textWidth;spacing:reader.t.space.s
                            Rule {Layout.fillWidth:true}
                            RowLayout {Layout.fillWidth:true;Layout.topMargin:reader.t.space.l
                                K.TacitText {Layout.fillWidth:true;wrapMode:Text.Wrap;text:"Your agent drafted a reply";weight:"strong";color:reader.controller.agentInk}
                                K.TacitText {text:"Not sent";size:"meta";ink:"meta"}
                            }
                            RowLayout {Layout.fillWidth:true;spacing:reader.t.space.xxl
                                K.TacitText {Layout.fillWidth:true;wrapMode:Text.Wrap;text:reader.message?.id==="mara"?"Why: to answer both of Mara's questions, from your header notes.":"Why: to acknowledge this message, for you to review.";size:"meta";ink:"sec"}
                                MailAction {text:"Open notes";onActivated:reader.controller.act("preview",{file:{name:"Header notes.md",path:"fixtures/header-notes.md",content:"Sender and date on one line.\nAttachments immediately below the message."}})}
                            }
                            K.Slab {tone:"default";objectName:"reviewReply";text:"Review reply";onActivated:reader.controller.reply("Reply all",true)}
                        }
                    }
                }
            }
            Item {visible:reader.editing&&!reader.composing&&!reader.controller.ui.attachment;x:reader.textInset;width:reader.textWidth;height:0;Rule {y:-reader.t.space.xl}}
            MailEditor {
                id:editor;objectName:"mailEditor"
                visible:reader.editing&&!reader.controller.ui.attachment
                x:reader.textInset;width:reader.textWidth;controller:reader.controller;newMessage:reader.composing
                availableHeight:0
                height:implicitHeight
                onAttachRequested:reader.attachRequested()
            }
        }
    }
    K.Glide {view:paper}
    K.ScrollBar {view:paper;anchors.fill:paper}
    }
    ColumnLayout {
        objectName:"editorFooter"
        visible:reader.editing&&!reader.controller.ui.attachment
        Layout.fillWidth:true;Layout.leftMargin:reader.textInset+reader.focusRoom;Layout.rightMargin:reader.focusRoom
        spacing:reader.t.space.s
        Rule {Layout.fillWidth:true;visible:!reader.composing}
        GridLayout {
            Layout.fillWidth:true;Layout.minimumWidth:0
            columns:reader.textWidth>=reader.t.width.panel+reader.t.space.page*4?3:1
            columnSpacing:reader.t.space.xxl;rowSpacing:reader.t.space.s
            RowLayout {spacing:reader.t.space.xxl
            MailAction {objectName:"attachFile";text:"Attach a file";onActivated:reader.attachRequested()}
            MailAction {visible:reader.composing&&!reader.controller.draft?.agent;text:"Ask your agent to draft it";onActivated:{if(!reader.controller.draft.to.trim()){reader.controller.act("notice",{text:"Add a recipient first."});return;}reader.controller.act("draft",{agent:true,edited:false,body:"Hello,\n\nThank you for your time. I would like to follow up with you.\n\n"+(reader.controller.draft.account==="Work"?reader.controller.settings.workSignature:reader.controller.settings.personalSignature)});}}
            }
            Item {visible:parent.columns===3;Layout.fillWidth:true}
            RowLayout {Layout.alignment:Qt.AlignRight;spacing:reader.t.space.xxl
            MailAction {objectName:"discardDraft";text:"Move draft to Trash";onActivated:reader.controller.act("discard")}
            K.Slab {tone:"default";objectName:"sendDraft";text:"Send";waiting:!reader.controller.canSend;onActivated:reader.controller.act("send")}
            }
        }
    }
    }
    K.Menu {id:laterMenu;items:[{label:"This evening"},{label:"Tomorrow morning"},{label:"Next week"}];onPicked:i=>reader.controller.act("later",{delay:[4*60*60*1000,24*60*60*1000,7*24*60*60*1000][i]})}
    K.Menu {id:more;items:[{label:reader.message?.unread?"Mark read":"Mark unread"},{label:reader.message?.starred?"Remove star":"Star"},{label:"Move to Inbox"},{label:"Move to Junk"},{rule:true},{label:"Move to Trash",risk:true}];onPicked:i=>{if(i===0)reader.controller.act("unread");else if(i===1)reader.controller.act("star");else if(i===2)reader.controller.act("move",{folder:"Inbox"});else if(i===3)reader.controller.act("move",{folder:"Junk"});else if(i===5)reader.controller.act("move",{folder:"Trash"});}}
    QtObject {
        id:scrollState
        property real origin:0
        property real progress:0
        onProgressChanged:{const limit=Math.max(0,paper.contentHeight-paper.height);const end=reader.composing?Math.max(0,editor.y-reader.t.space.l):Math.max(0,Math.min(limit,editor.y+editor.height-paper.height+reader.t.space.xl));paper.contentY=Math.max(0,Math.min(limit,origin+(end-origin)*progress));}
    }
    NumberAnimation {id:scrollTo;target:scrollState;property:"progress";from:0;to:1;duration:K.Kit.ms(K.Kit.motion("arrive").ms);easing.type:Easing.BezierSpline;easing.bezierCurve:K.Kit.motion("arrive").curve}
}
