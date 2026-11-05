import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore
import Tacit.Kit as K

FocusScope {
    id: workspace
    required property var controller
    readonly property var t:K.Kit.tokens
    readonly property real listMinimum:t.width.rail+t.space.xl
    readonly property real readerMinimum:t.width.panel+t.space.page*2
    readonly property bool compact:width<listMinimum+readerMinimum
    readonly property bool railFits:width>=listMinimum+readerMinimum+t.width.rail
    readonly property real railWidth:controller.ui.rail&&railFits?t.width.rail-t.space.xl-t.space.l:0
    readonly property real listWidth:t.width.panel+t.space.page+t.space.m
    readonly property bool fullPage:["setup","settings"].includes(controller.ui.view)
    property bool compactReading:true
    property string selection:controller.ui.selected
    property string activeView:controller.ui.view
    onSelectionChanged:if(selection)compactReading=true
    onActiveViewChanged:if(["draft","compose","importing"].includes(activeView))compactReading=true
    function openMessage(id){compactReading=true;controller.act("select",{id:id});}
    function showMailboxes(){if(compact||!railFits)folderPicker.openAt(folderTitle,0,folderTitle.height);else controller.act("rail");}
    focus:true
    component Rule:Rectangle {height:1;color:K.Kit.tokens.hairline}
    FileDialog {
        id:files
        title:"Attach files to this local draft";fileMode:FileDialog.OpenFiles
        onAccepted: {for(var url of selectedFiles){var path=String(url);workspace.controller.act("attach",{url:path,name:decodeURIComponent(path.split("/").pop())});}}
    }
    FileDialog {
        id:saveFile
        property var attachment
        title:"Save attachment";fileMode:FileDialog.SaveFile
        currentFolder:StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        onAccepted: {
            const source=attachment.url||Qt.resolvedUrl(attachment.path||"");
            if(typeof previewFiles!=="undefined"&&previewFiles.copy(source,selectedFile))workspace.controller.act("notice",{text:"Saved "+attachment.name});
            else workspace.controller.act("notice",{text:typeof previewFiles!=="undefined"?previewFiles.error:"Open the attachment in its default app to save a copy."});
        }
    }
    Connections {
        target:workspace.controller
        function onSaveRequested(file){
            if(!file.url&&!file.path){workspace.controller.act("notice",{text:"This sample has no file bytes to save."});return;}
            saveFile.attachment=file;saveFile.selectedFile=String(saveFile.currentFolder)+"/"+encodeURIComponent(file.name);saveFile.open();
        }
    }
    Shortcut {sequences:[StandardKey.New];onActivated:workspace.controller.act("new")}
    Shortcut {sequences:[StandardKey.Find];onActivated:{workspace.compactReading=false;search.forceActiveFocus();}}
    Shortcut {sequence:"Ctrl+Return";enabled:workspace.controller.canSend;onActivated:workspace.controller.act("send")}
    Shortcut {sequence:"Meta+Return";enabled:workspace.controller.canSend;onActivated:workspace.controller.act("send")}
    Shortcut {sequences:[StandardKey.Undo];enabled:!["draft","compose"].includes(workspace.controller.ui.view)&&(workspace.controller.undoAvailable||!!workspace.controller.ui.undo);onActivated:workspace.controller.undoAvailable?workspace.controller.act("undoSend"):workspace.controller.act("undo")}
    Shortcut {sequence:"Ctrl+,";onActivated:workspace.controller.act("settings")}
    Shortcut {sequence:"Meta+,";onActivated:workspace.controller.act("settings")}
    Keys.onEscapePressed:workspace.controller.act("escape")

    RowLayout {
        anchors.fill:parent;spacing:0
        visible:!workspace.fullPage

    K.Rail {
        id:rail
        objectName:"mailboxes"
        visible:workspace.railWidth>0
        Layout.preferredWidth:workspace.railWidth;Layout.fillHeight:true
        onToggle:workspace.controller.act("rail")
        K.RailSection {text:"All accounts"}
        Repeater {
            model:["Inbox","Later","Starred","Drafts","Sent","Archive","Junk","Trash"]
            delegate:K.RailRow {
                required property string modelData
                label:modelData;glyph:"";current:workspace.controller.ui.folder===modelData&&workspace.controller.ui.account==="All accounts"
                context:{var n=workspace.controller.count(modelData);return n?String(n):"";}
                onPicked:workspace.controller.act("folder",{folder:modelData})
            }
        }
        Repeater {
            model:workspace.controller.accounts
            delegate:Column {
                required property var modelData
                width:rail.width
                K.RailSection {text:parent.modelData.name}
                K.TacitText {x:workspace.t.space.l;size:"meta";ink:"meta";text:parent.modelData.email;width:parent.width-workspace.t.space.xl;elide:Text.ElideRight}
                Repeater {
                    model:["Inbox"].concat(modelData.name==="Personal"?["Family","Receipts"]:modelData.name==="Work"?["Clients","Invoices"]:[])
                    delegate:K.RailRow {
                        required property string modelData
                        readonly property string accountName:parent.modelData.name
                        label:modelData;glyph:"";current:workspace.controller.ui.folder===modelData&&workspace.controller.ui.account===accountName
                        context:{var n=workspace.controller.count(modelData,accountName);return n?String(n):"";}
                        onPicked:workspace.controller.act("folder",{folder:modelData,account:accountName})
                    }
                }
            }
        }
        foot:[
            K.RailRow {label:"Add account";glyph:"";onPicked:workspace.controller.act("setup")},
            K.RailRow {label:"Settings";glyph:"";onPicked:workspace.controller.act("settings")}
        ]
    }
    Item {
        id:inbox
        objectName:"inboxPane"
        visible:!workspace.compact||!workspace.compactReading
        Layout.fillHeight:true;Layout.fillWidth:true
        Layout.minimumWidth:workspace.compact?0:workspace.listMinimum
        Layout.preferredWidth:workspace.listWidth
        Layout.maximumWidth:workspace.compact?Infinity:workspace.listWidth
        Rectangle {anchors.fill:parent;color:workspace.t.windowGround;opacity:workspace.t.wash.action}
        Rule {x:parent.width-1;width:1;height:parent.height}
        ColumnLayout {
            anchors.fill:parent;spacing:workspace.t.space.s
            Item {Layout.preferredHeight:workspace.t.space.page-workspace.t.space.xs}
            RowLayout {
                Layout.fillWidth:true;Layout.leftMargin:workspace.t.space.xxl;Layout.rightMargin:workspace.t.space.xxl
                spacing:workspace.t.space.xxl
                Item {
                    id:folderTitle
                    Layout.preferredWidth:folderTitleContent.implicitWidth;Layout.preferredHeight:workspace.t.height.field
                    MailAction {objectName:"folderMenu";anchors.fill:parent;text:"";Accessible.name:workspace.controller.ui.folder+" mailboxes";onActivated:workspace.showMailboxes()}
                    RowLayout {id:folderTitleContent;anchors.verticalCenter:parent.verticalCenter;spacing:workspace.t.space.xs
                        K.TacitText {text:workspace.controller.ui.searching?"Search":workspace.controller.ui.folder;size:"section";weight:"strong";cut:"display"}
                        K.Symbol {visible:!workspace.controller.ui.searching;text:workspace.controller.ui.rail?"expand_less":"expand_more";size:workspace.t.icon.row;color:workspace.t.inkSec}
                    }
                }
                Item {Layout.fillWidth:true}
                MailAction {
                    objectName:"newMessage"
                    text:workspace.controller.ui.searching?"Close search":"New message"
                    onActivated:{workspace.compactReading=true;workspace.controller.ui.searching?workspace.controller.act("closeSearch"):workspace.controller.act("new");}
                }
            }
            K.TacitText {
                objectName:"mailboxCaption"
                Layout.fillWidth:true;Layout.leftMargin:workspace.t.space.xxl;Layout.rightMargin:workspace.t.space.xxl
                size:"meta";ink:"meta";wrapMode:Text.Wrap
                text:workspace.controller.ui.searching?workspace.controller.rows.length+" results in every account and mailbox":workspace.controller.ui.account+(workspace.controller.ui.folder==="Inbox"?"  ·  "+workspace.controller.count("Inbox",workspace.controller.ui.account)+" unread":"")
            }
            GridLayout {
                Layout.fillWidth:true;Layout.leftMargin:workspace.t.space.xxl;Layout.rightMargin:workspace.t.space.xxl
                columns:width>=workspace.t.height.header*2+sortMenu.implicitWidth+columnSpacing?2:1
                columnSpacing:workspace.t.space.xxl;rowSpacing:workspace.t.space.s
                Item {
                    Layout.fillWidth:true;Layout.minimumWidth:0;implicitWidth:workspace.t.height.header*2;implicitHeight:workspace.t.height.action
                K.SearchField {
                    id:search;objectName:"mailSearch"
                    anchors.fill:parent
                    scope:"all mail";fieldWidth:parent.width;text:workspace.controller.ui.query
                    onTextChanged:if(text!==workspace.controller.ui.query)workspace.controller.act("search",{text:text})
                    onAccepted:workspace.controller.act("search",{text:text})
                    onDismissed:workspace.controller.act("closeSearch")
                    onDown:mailList.forceActiveFocus()
                }
                }
                Item {
                    id:sortMenu
                    visible:!workspace.controller.ui.searching&&workspace.controller.ui.folder!=="Later"
                    implicitWidth:sortWords.implicitWidth+workspace.t.icon.rail+workspace.t.space.xs;implicitHeight:workspace.t.height.action
                    Layout.alignment:Qt.AlignRight
                    MailAction {objectName:"viewOptions";anchors.fill:parent;text:"";Accessible.name:"Filter and sort mail";onActivated:viewMenu.openAt(this,width-viewMenu.implicitWidth,height)}
                    RowLayout {anchors.verticalCenter:parent.verticalCenter;spacing:workspace.t.space.xs
                        K.TacitText {id:sortWords;text:workspace.controller.ui.filter+", "+workspace.controller.ui.sort.toLowerCase();size:"meta";weight:"medium";ink:"sec"}
                        K.Symbol {text:"expand_more";size:workspace.t.icon.rail-workspace.t.space.xs/2;color:workspace.t.inkMeta}
                    }
                K.Menu {
                    id:viewMenu
                    items:[{label:"All mail",checked:workspace.controller.ui.filter==="All mail"},{label:"Unread",checked:workspace.controller.ui.filter==="Unread"},{label:"With attachments",checked:workspace.controller.ui.filter==="With attachments"},{label:"Starred",checked:workspace.controller.ui.filter==="Starred"},{rule:true},{label:"Newest first",checked:workspace.controller.ui.sort==="Newest first"},{label:"Oldest first",checked:workspace.controller.ui.sort==="Oldest first"},{label:"Sender",checked:workspace.controller.ui.sort==="Sender"},{label:"Unread first",checked:workspace.controller.ui.sort==="Unread first"}]
                    onPicked:i=>i<4?workspace.controller.act("filter",{value:items[i].label}):workspace.controller.act("sort",{value:items[i].label})
                }
                }
            }
            Rule {Layout.fillWidth:true;Layout.leftMargin:workspace.t.space.xxl;Layout.rightMargin:workspace.t.space.xxl;color:Qt.alpha(workspace.t.inkMain,workspace.t.wash.currentHover+0.01)}
        K.RowList {
            id:mailList
            objectName:"messageList"
            Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumHeight:0
            Layout.leftMargin:workspace.t.space.m;Layout.rightMargin:workspace.t.space.m;Layout.bottomMargin:workspace.t.space.m
            label:"Messages in "+workspace.controller.ui.folder
            model:workspace.controller.rows
            onActivated:i=>workspace.openMessage(workspace.controller.rows[i].id)
            onCursorChanged: {if(cursor>=0&&cursor<workspace.controller.rows.length){const id=workspace.controller.rows[cursor].id;Qt.callLater(function(){workspace.openMessage(id);});}}
            section.property:"day";section.criteria:ViewSection.FullString
            section.delegate:K.TacitText {required property string section;leftPadding:K.Kit.tokens.space.l;topPadding:K.Kit.tokens.space.m;bottomPadding:K.Kit.tokens.space.xs;text:section;size:"meta";weight:"medium";ink:"meta"}
            delegate:K.ListRow {
                id:preview
                required property var modelData
                required property int index
                readonly property bool chosen:modelData.id===workspace.controller.ui.selected||modelData.id===workspace.controller.ui.draftId&&workspace.controller.ui.view!=="read"
                readonly property bool hasAgent:!!workspace.controller.agentDraft(modelData.id)
                readonly property bool showPreview:!hasAgent||workspace.controller.ui.searching
                width:mailList.rowWidth;implicitHeight:previewContent.implicitHeight+workspace.t.space.m*2;height:implicitHeight
                name:"";glyph:"";facts:[];focusable:false;selected:false
                ring:mailList.ringAt(index)
                Accessible.selected:chosen
                Accessible.name:modelData.from+", "+modelData.subject+", "+(modelData.unread?"unread":"read")
                onClicked:m=>{const id=modelData.id;const c=workspace.controller;mailList.clickAt(index,m);workspace.openMessage(id);}
                onActivated:workspace.openMessage(modelData.id)
                onContextRequested:p=>{workspace.controller.act("select",{id:modelData.id});messageMenu.openAt(preview,p.x,p.y);}
                Rectangle {visible:preview.chosen;x:workspace.t.space.xs/2;y:workspace.t.space.m+workspace.t.space.xs/2;width:workspace.t.state.focusRing;height:parent.height-2*y;color:workspace.t.inkMain}
                ColumnLayout {
                    id:previewContent
                    anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top
                    anchors.leftMargin:workspace.t.space.l+workspace.t.space.xs;anchors.rightMargin:workspace.t.space.l+workspace.t.space.xs;anchors.topMargin:workspace.t.space.m
                    spacing:workspace.t.space.xs
                    RowLayout {Layout.fillWidth:true;spacing:workspace.t.space.s
                        K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;text:preview.modelData.from;weight:preview.modelData.unread?"strong":"medium";ink:preview.modelData.unread?"main":"sec";elide:Text.ElideRight}
                        K.TacitText {text:(preview.modelData.starred?"Starred  ·  ":"")+preview.modelData.account+"  ·  "+preview.modelData.time;size:"meta";ink:"meta"}
                    }
                    RowLayout {Layout.fillWidth:true;spacing:workspace.t.space.s
                        K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;text:preview.modelData.subject;ink:preview.modelData.unread?"main":"meta";elide:Text.ElideRight}
                        K.TacitText {visible:(preview.modelData.history?.length ?? 0)+(preview.modelData.replies?.length ?? 0)>0;text:((preview.modelData.history?.length ?? 0)+(preview.modelData.replies?.length ?? 0)+1)+" messages";size:"meta";ink:"meta"}
                        K.TacitText {visible:preview.modelData.files.length>0;text:preview.modelData.files.length+" file"+(preview.modelData.files.length>1?"s":"");size:"meta";ink:"meta"}
                    }
                    K.TacitText {visible:preview.showPreview;Layout.fillWidth:true;text:workspace.controller.highlight(preview.modelData.body.replace(/\n/g," "));textFormat:Text.StyledText;size:"meta";ink:"meta";elide:Text.ElideRight}
                    RowLayout {visible:preview.hasAgent;Layout.fillWidth:true;spacing:workspace.t.space.s
                        Item {implicitWidth:workspace.t.space.s;implicitHeight:workspace.t.icon.rail
                            Rectangle {width:1;height:parent.height;color:workspace.controller.agentInk}
                            Rectangle {y:parent.height/2;width:parent.width;height:1;color:workspace.controller.agentInk}
                        }
                        K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;text:"Reply drafted: answers both of Mara's questions";size:"meta";color:workspace.controller.agentInk;elide:Text.ElideRight}
                    }
                }
            }
        }
        }
        K.PageState {visible:workspace.controller.rows.length===0&&workspace.controller.ui.searching;x:workspace.t.space.xxl;y:mailList.y+workspace.t.space.xl;maxWidth:inbox.width-workspace.t.space.page;text:"No messages match your search.";action:"Clear search";onActivated:workspace.controller.act("closeSearch")}
    }
    Item {
        id:reading
        objectName:"readerPane"
        visible:!workspace.compact||workspace.compactReading
        Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumWidth:workspace.compact?0:workspace.readerMinimum
        Layout.preferredWidth:workspace.t.width.list
        MailReader {
            id:reader
            visible:workspace.controller.ui.view!=="importing"&&(!!workspace.controller.selected||["draft","compose"].includes(workspace.controller.ui.view))
            anchors.fill:parent;controller:workspace.controller;compact:workspace.compact;onBackRequested:workspace.compactReading=false;onAttachRequested:files.open()
        }
        Column {
            visible:workspace.controller.ui.view==="importing"
            x:reader.textX;y:workspace.t.height.header+workspace.t.space.page+workspace.t.space.xs;width:reader.textWidth;spacing:workspace.t.space.xl
            K.TacitText {text:"Getting your mail";size:"headline";weight:"strong";cut:"display"}
            K.TacitText {text:workspace.controller.ui.imported.toLocaleString()+" of 8,600 from Personal. Read what has arrived while the rest comes in.";ink:"sec";width:parent.width;wrapMode:Text.Wrap}
            K.Progress {width:parent.width;value:workspace.controller.ui.imported/8600;label:"Importing mock mail"}
        }
        Column {
            visible:!reader.visible&&workspace.controller.ui.view!=="importing"
            anchors.centerIn:parent;anchors.verticalCenterOffset:-(workspace.t.space.xl+workspace.t.space.l);width:Math.min(parent.width-workspace.t.space.page*2,workspace.t.width.panel+workspace.t.space.page*4);spacing:workspace.t.space.xl
            K.TacitText {width:parent.width;horizontalAlignment:Text.AlignHCenter;text:workspace.controller.rows.length?"Choose a message":"Nothing in "+workspace.controller.ui.folder;size:"headline";weight:"strong";cut:"display";wrapMode:Text.Wrap}
            K.TacitText {width:parent.width;horizontalAlignment:Text.AlignHCenter;text:workspace.controller.ui.folder==="Later"?"Mail you set aside with Later comes back to your inbox at the time you chose. It waits here until then.":"Your messages will appear here.";ink:"sec";wrapMode:Text.Wrap}
            MailAction {anchors.horizontalCenter:parent.horizontalCenter;text:"Back to Inbox";onActivated:workspace.controller.act("folder",{folder:"Inbox"})}
        }
    }
    }
    MailSettings {visible:workspace.controller.ui.view==="settings";anchors.fill:parent;controller:workspace.controller}
    Flickable {
        visible:workspace.controller.ui.view==="setup";anchors.fill:parent;clip:true;boundsBehavior:Flickable.StopAtBounds
        contentWidth:width;contentHeight:setupContent.y+setupContent.implicitHeight+workspace.t.space.page
    ColumnLayout {
        id:setupContent
        x:(parent.width-width)/2;y:workspace.t.space.page;width:Math.min(parent.width-workspace.t.space.page*2,workspace.t.width.panel+workspace.t.space.page*4);spacing:workspace.t.space.l
        MailAction {text:"Back to Mail";onActivated:workspace.controller.act("back")}
        K.TacitText {text:"Add your mail";size:"headline";weight:"strong";cut:"display"}
        K.TacitText {Layout.fillWidth:true;wrapMode:Text.Wrap;ink:"sec";text:"Every account in one place. Choose your provider to continue in the system sign-in window."}
        Column {Layout.fillWidth:true
        Repeater {
            model:["Google","Microsoft","iCloud","Fastmail","Another provider"]
            delegate:K.ListRow {
                required property string modelData
                objectName:"provider-"+modelData
                width:parent.width;name:modelData;aside:modelData==="Another provider"?"IMAP and SMTP":"";facts:[]
                onClicked:workspace.controller.act("provider",{name:modelData});onActivated:workspace.controller.act("provider",{name:modelData})
                accessory:[K.Symbol {text:"chevron_right";size:K.Kit.tokens.icon.rail}]
            }
        }
    }
    }
    }
    K.TacitText {
        visible:workspace.controller.ui.view==="setup"&&workspace.controller.ui.provider!==""
        anchors.horizontalCenter:parent.horizontalCenter;anchors.bottom:parent.bottom;anchors.bottomMargin:workspace.t.space.xl
        text:"Waiting for "+workspace.controller.ui.provider+" sign-in in the system…";ink:"meta"
    }
    K.Menu {
        id:folderPicker
        items:["Inbox","Later","Starred","Drafts","Sent","Archive","Junk","Trash"].map(v=>({label:v,folder:v})).concat([{rule:true}],workspace.controller.accounts.map(a=>({label:a.name+" · "+a.email,folder:"Inbox",account:a.name})),[{rule:true},{label:"Add account",action:"setup"},{label:"Settings",action:"settings"}])
        onPicked:i=>{const entry=items[i];if(entry.action)workspace.controller.act(entry.action);else workspace.controller.act("folder",{folder:entry.folder,account:entry.account});workspace.compactReading=false;}
    }
    K.Menu {
        id:messageMenu
        items:[{label:"Reply"},{label:"Reply all"},{label:"Forward"},{label:"Mark unread"},{label:"Star"},{label:"Archive"},{label:"Move to Trash",risk:true}]
        onPicked:i=>{if(i<3)workspace.controller.reply(items[i].label,false);else if(i===3)workspace.controller.act("unread",{value:true});else if(i===4)workspace.controller.act("star");else workspace.controller.act("move",{folder:i===5?"Archive":"Trash"});}
    }
    K.Notice {
        id:notice
        objectName:"mailNotice"
        onActivated:workspace.controller.act("undo")
        onClosed:if(workspace.controller.ui.notice===text)workspace.controller.act("clearNotice")
    }
    Connections {
        target:workspace.controller
        function onDataChanged(){if(workspace.controller.ui.notice&&workspace.controller.ui.notice!==notice.text)notice.show(workspace.controller.ui.notice,workspace.controller.ui.undo?"Undo":"");}
    }
}
