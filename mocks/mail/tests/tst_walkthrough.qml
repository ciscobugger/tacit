import QtQuick
import QtTest
import Tacit.Kit as K

Item {
    width:1720;height:972
    Loader {id:app;anchors.fill:parent;source:"../mail.qml"}
    SignalSpy {id:authorization;target:app.item?.controller ?? null;signalName:"authorizationRequested"}
    SignalSpy {id:notifications;target:app.item?.controller ?? null;signalName:"notificationRequested"}
    SignalSpy {id:sending;target:app.item?.controller ?? null;signalName:"sendStatusChanged"}
    TestCase {
        name:"MailWalkthrough"
        when:windowShown&&app.status===Loader.Ready
        function c(){return app.item.controller;}
        function init(){c().act("reset");authorization.clear();notifications.clear();sending.clear();wait(30);}
        function click(name){var b=findChild(app.item,name);verify(b!==null,"Missing "+name);mouseClick(b,b.width/2,b.height/2);wait(30);}
        function stableWindow(){var scene=findChild(app.item,"mailScene");compare(scene.width,app.width);compare(scene.height,app.height);verify(scene.visible);}
        function test_providerImport(){
            c().act("setup");click("provider-Google");stableWindow();compare(authorization.count,1);compare(authorization.signalArguments[0][0],"Google");
            compare(findChild(app.item,"providerNext"),null);compare(findChild(app.item,"providerEmail"),null);
            c().completeAuthorization("lorenz@example.com");compare(c().ui.view,"importing");tryVerify(function(){return c().ui.view==="read";},6000);verify(c().ui.imported===8600);
        }
        function test_reviewSendUndo(){
            click("reviewReply");compare(c().ui.view,"draft");verify(c().draft.agent,"Agent draft expected");wait(400);
            var body=findChild(app.item,"draftBody");body.input.forceActiveFocus();keyClick("x");wait(30);verify(c().draft.edited,"Body edit did not reach state");
            var scroll=findChild(app.item,"readingScroll");verify(scroll.contentY<=Math.max(0,scroll.contentHeight-scroll.height)+1,"Scroll must stay within the message");
            click("sendDraft");verify(c().undoAvailable,"Send did not start");stableWindow();compare(sending.count,1);compare(findChild(app.item,"undoSend"),null);
            c().act("undoSend");compare(c().ui.view,"draft");verify(c().draft.body.includes("x"),"Undo lost body edit");compare(c().data.jobs.length,0);compare(sending.count,2);
        }
        function test_systemNotificationReply(){
            c().act("notify");stableWindow();compare(notifications.count,1);compare(notifications.signalArguments[0][0].id,"anna-notification");
            compare(findChild(app.item,"notificationReply"),null);verify(findChild(app.item,"newMessage").visible);
            c().notificationAction("reply");compare(c().ui.selected,"anna-notification");compare(c().ui.view,"draft");
        }
        function test_reducedMotion(){c().act("settings");wait(30);click("reduceMotion");verify(c().settings.reducedMotion);verify(K.Kit.reducedMotion);}
    }
}
