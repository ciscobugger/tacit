// Interactive local mail prototype. All mail/provider/agent operations are in-memory simulations.
import QtQuick
import QtQuick.Effects
import Quickshell
import qs.services
import Tacit.Kit as K

ShellRoot {
    id:shell
    readonly property int sw:parseInt(Quickshell.env("DUNE_W") ?? "1720")
    readonly property int sh:parseInt(Quickshell.env("DUNE_H") ?? "972")
    property alias controller:model
    MailState {
        id:model
        initialScreen:Quickshell.env("DUNE_SURFACE") ?? "read"
        agentInk:Qt.hsla(Math.abs(K.Kit.tokens.accent.hslHue-0.70)<0.10?0.48:0.70,0.42,0.76,1)
        onSettingsChanged:K.Kit.reducedMotion=settings.reducedMotion
    }
    Component.onCompleted:MaterialThemeLoader.reapplyTheme()
    FloatingWindow {
        objectName:"mailWindow"
        implicitWidth:shell.sw;implicitHeight:shell.sh
        visible:true;color:"transparent"
        Item {
            id:scene
            objectName:"mailScene"
            anchors.fill:parent
            Item {
                id:win
                anchors.fill:parent
                Item {id:mask;anchors.fill:parent;visible:false;layer.enabled:true
                    Rectangle {anchors.fill:parent;radius:K.Kit.tokens.radius.window;color:K.Kit.tokens.inkMain}
                }
                Item {
                    anchors.fill:parent;layer.enabled:true
                    layer.effect:MultiEffect {maskEnabled:true;maskSource:mask}
                    K.WindowGround {}
                }
                MailWorkspace {id:workspace;anchors.fill:parent;controller:model}
                Item {
                    anchors.horizontalCenter:parent.horizontalCenter;y:K.Kit.tokens.space.xs;width:K.Kit.tokens.height.header*2;height:K.Kit.tokens.height.field
                    Rectangle {anchors.centerIn:parent;width:K.Kit.tokens.height.row;height:K.Kit.tokens.space.xs;radius:height/2;color:K.Kit.tokens.inkFaint}
                }
            }

        }
        Timer {
            interval:parseInt(Quickshell.env("DUNE_SHOT_DELAY") ?? "4500");running:!!Quickshell.env("DUNE_SHOT")
            onTriggered:scene.grabToImage(r=>{r.saveToFile(Quickshell.env("DUNE_SHOT"));Qt.quit();})
        }
    }
}
