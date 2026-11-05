import QtQuick
import QtQuick.Layouts
import Tacit.Kit as K

Item {
    id:settings
    required property var controller
    readonly property var t:K.Kit.tokens
    readonly property real pageInset:width<t.width.list?t.space.xl:t.space.page
    readonly property bool twoColumns:width-pageInset*2>=t.width.panel*2+t.space.page
    readonly property real columnWidth:Math.min(t.width.rail*2,(width-pageInset*2-(twoColumns?t.space.page:0))/(twoColumns?2:1))
    property string editingSignature:""
    property string removalEmail:""
    component Rule:Rectangle {height:1;color:Qt.alpha(settings.t.inkMain,settings.t.wash.hover+0.02)}
    component Heading:Item {
        property string text
        property bool agent:false
        width:settings.columnWidth;height:settings.t.height.row
        Rectangle {visible:parent.agent;x:0;y:parent.height/2;width:settings.t.space.s;height:1;color:settings.controller.agentInk}
        K.TacitText {x:parent.agent?settings.t.space.l:0;anchors.verticalCenter:parent.verticalCenter;text:parent.text;size:"body";weight:"strong";color:parent.agent?settings.controller.agentInk:settings.t.inkMain}
    }
    component Setting:K.WordAction {
        id:row
        property string label
        property string value
        property string note:""
        property bool quiet:false
        property var options:[]
        signal picked(int index)
        width:settings.columnWidth;height:rowContent.implicitHeight+settings.t.space.l*2
        text:"";Accessible.name:label+", "+value
        onActivated:if(options.length)menu.openAt(row,row.width-menu.implicitWidth,row.height)
        ColumnLayout {
            id:rowContent
            anchors.left:parent.left;anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter
            spacing:settings.t.space.s
            RowLayout {Layout.fillWidth:true;spacing:settings.t.space.l
                K.TacitText {Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;text:row.label;ink:"sec"}
                K.TacitText {Layout.maximumWidth:row.width*0.45;wrapMode:Text.Wrap;text:row.value;weight:"medium";ink:row.quiet?"meta":"main"}
                K.Symbol {visible:row.options.length>0;text:"expand_more";size:settings.t.icon.rail;color:settings.t.inkMeta}
            }
            K.TacitText {visible:row.note!=="";Layout.fillWidth:true;wrapMode:Text.Wrap;text:row.note;size:"meta";ink:"meta"}
        }
        Rule {anchors.bottom:parent.bottom;width:parent.width}
        K.Menu {id:menu;items:row.options.map(v=>({label:v,checked:v===row.value}));onPicked:i=>row.picked(i)}
    }
    Flickable {
        id:view;objectName:"settingsScroll"
        anchors.fill:parent;contentWidth:width;contentHeight:settingsContent.y+settingsContent.implicitHeight+settings.t.space.page;clip:true;boundsBehavior:Flickable.StopAtBounds
        ColumnLayout {
            id:settingsContent
            x:(parent.width-width)/2;y:settings.t.space.page
            width:Math.max(0,Math.min(parent.width-settings.pageInset*2,settings.twoColumns?settings.t.width.rail*4+settings.t.space.page:settings.t.width.rail*2));spacing:settings.t.space.l
            MailAction {text:"Back to Mail";onActivated:settings.controller.act("back")}
            Rule {Layout.fillWidth:true}
            K.TacitText {text:"Settings";size:"headline";cut:"display";weight:"strong"}
            GridLayout {
                id:columns;objectName:"settingsColumns"
                Layout.fillWidth:true;Layout.topMargin:settings.t.space.l
                columns:settings.twoColumns?2:1;columnSpacing:settings.t.space.page;rowSpacing:settings.t.space.page
            Column {
                Layout.fillWidth:true;Layout.alignment:Qt.AlignTop;Layout.preferredWidth:settings.columnWidth;spacing:0
                Heading {text:"Accounts"}
                Repeater {model:settings.controller.accounts;delegate:Setting {required property var modelData;label:modelData.name+", "+modelData.email;value:"Signed in";quiet:true}}
                Item {width:1;height:settings.t.space.m}
                Row {spacing:settings.t.space.xl+settings.t.space.xs/2
                    MailAction {text:"Add account";onActivated:settings.controller.act("setup")}
                    MailAction {text:"Remove an account";onActivated:removeMenu.openAt(this,0,height)}
                }
                MailAction {visible:settings.removalEmail!=="";text:"Remove "+settings.removalEmail;risk:true;confirm:"Remove "+settings.removalEmail+" from this preview";onActivated:{settings.controller.act("removeAccount",{email:settings.removalEmail});settings.removalEmail="";}}
                Item {width:1;height:settings.t.height.action}
                Heading {text:"Your agent";agent:true}
                Setting {label:"Draft replies for you to review";value:settings.controller.settings.agentDrafts?"On":"Off";options:["On","Off"];onPicked:i=>settings.controller.act("setting",{key:"agentDrafts",value:i===0})}
                Setting {label:"Sort new mail into mailboxes";value:settings.controller.settings.agentSort?"On":"Off";options:["On","Off"];onPicked:i=>settings.controller.act("setting",{key:"agentSort",value:i===0})}
                Setting {label:"Mail it may read";value:settings.controller.settings.agentScope;options:["Work only","Personal only","All accounts"];onPicked:i=>settings.controller.act("setting",{key:"agentScope",value:options[i]})}
                Setting {label:"Sending";value:"Never on its own";quiet:true;note:"Your agent can prepare mail. Only you send it."}
            }
            Column {
                Layout.fillWidth:true;Layout.alignment:Qt.AlignTop;Layout.preferredWidth:settings.columnWidth;spacing:0
                Heading {text:"Sending"}
                Setting {label:"Undo after sending";value:settings.controller.settings.undoSeconds+" seconds";options:["5 seconds","10 seconds","20 seconds","30 seconds"];onPicked:i=>settings.controller.act("setting",{key:"undoSeconds",value:[5,10,20,30][i]})}
                Setting {label:"Signature for Work";value:settings.controller.settings.workSignature.replace(/\n/g,", ");onActivated:settings.editingSignature=settings.editingSignature==="workSignature"?"":"workSignature"}
                K.TextArea {visible:settings.editingSignature==="workSignature";width:parent.width;label:"Signature for Work";text:settings.controller.settings.workSignature;onEdited:{const value=text;Qt.callLater(function(){settings.controller.act("setting",{key:"workSignature",value:value});});}onDismissed:settings.editingSignature=""}
                Setting {label:"Signature for Personal";value:settings.controller.settings.personalSignature.replace(/\n/g,", ");onActivated:settings.editingSignature=settings.editingSignature==="personalSignature"?"":"personalSignature"}
                K.TextArea {visible:settings.editingSignature==="personalSignature";width:parent.width;label:"Signature for Personal";text:settings.controller.settings.personalSignature;onEdited:{const value=text;Qt.callLater(function(){settings.controller.act("setting",{key:"personalSignature",value:value});});}onDismissed:settings.editingSignature=""}
                Item {width:1;height:settings.t.height.action}
                Heading {text:"Reading"}
                Setting {label:"Pictures from the web";value:settings.controller.settings.pictures;note:"Pictures in mail can tell the sender when you opened it.";options:["Ask first","Never","Always"];onPicked:i=>settings.controller.act("setting",{key:"pictures",value:options[i]})}
                Item {width:1;height:settings.t.height.action}
                Heading {text:"Notifications"}
                Setting {label:"New mail";value:settings.controller.settings.notifications;options:["From people only","All new mail","Off"];onPicked:i=>settings.controller.act("setting",{key:"notifications",value:options[i]})}
                Item {width:1;height:settings.t.height.action}
                Heading {text:"Accessibility"}
                Item {width:parent.width;height:settings.t.height.row
                    K.TacitText {anchors.verticalCenter:parent.verticalCenter;text:"Reduce motion";ink:"sec"}
                    K.Switch {objectName:"reduceMotion";anchors.right:parent.right;anchors.verticalCenter:parent.verticalCenter;label:"Reduce motion";checked:settings.controller.settings.reducedMotion;onToggled:v=>settings.controller.act("setting",{key:"reducedMotion",value:v})}
                }
            }
        }
    }
    }
    K.Menu {id:removeMenu;items:settings.controller.accounts.map(a=>({label:a.name+", "+a.email}));onPicked:i=>settings.removalEmail=settings.controller.accounts[i].email}
    K.Glide {view:view}
    K.ScrollBar {view:view;anchors.fill:view}
}
