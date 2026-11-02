import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions

// Resolves an image source to a picture on this computer and measures it: an address is
// downloaded into `filePath`, a path (an absolute one, or a file:// one) is read where it is,
// which is what the Files picker and Settings' field hand over.
Process {
    id: root

    signal done(string path, int width, int height);
    property string filePath: ""
    property string sourceUrl: ""
    property string downloadUserAgent: Config.options?.networking.userAgent ?? ""

    readonly property string localPath: /^(?:file:\/\/)?\//.test(sourceUrl) ? FileUtils.trimFileProtocol(sourceUrl) : ""
    readonly property string cachePath: FileUtils.trimFileProtocol(filePath)
    // What the picture ends up as, and what `done` hands back.
    readonly property string picturePath: root.localPath.length > 0 ? root.localPath : root.cachePath

    function commandLine() {
        const picture = StringUtils.shellSingleQuoteEscape(root.picturePath);
        // `printf` names the picture, so the measurement below can be matched to the source that
        // asked for it; `[0]` is the first frame, because every frame of a GIF is one line.
        const measure = `printf '%s|' '${picture}'; magick identify -ping -format '%w %h' '${picture}[0]'`;
        if (root.localPath.length > 0)
            return measure;
        const cache = StringUtils.shellSingleQuoteEscape(root.cachePath);
        const userAgent = root.downloadUserAgent.length > 0
            ? ` -H 'User-Agent: ${StringUtils.shellSingleQuoteEscape(root.downloadUserAgent)}'` : "";
        // The measurement runs whether or not the download did: behind `||` and `&&` it was skipped
        // exactly when the cache was already there, so a picture measured once was never measured
        // again and the widget stayed empty from the second start on.
        return `mkdir -p $(dirname '${cache}'); [ -f '${cache}' ] || curl -sSL '${StringUtils.shellSingleQuoteEscape(root.sourceUrl)}'${userAgent} -o '${cache}'; ${measure}`;
    }

    // A run is set up here, not by a binding on `command`: a binding moves after the properties
    // that changed it, so a run started from a change handler measured the source it replaced.
    function start(url, cacheFilePath) {
        root.sourceUrl = url;
        root.filePath = cacheFilePath;
        root.command = ["bash", "-c", root.commandLine()];
        root.running = false;
        root.running = true;
    }

    function stop() {
        root.running = false;
    }

    running: false
    stdout: StdioCollector {
        id: imageSizeOutputCollector
        onStreamFinished: {
            // "<the picture>|<width> <height>": a run whose source has since been replaced is dropped
            const text = imageSizeOutputCollector.text.trim();
            const prefix = `${root.picturePath}|`;
            if (!text.startsWith(prefix))
                return;
            const [width, height] = text.slice(prefix.length).trim().split(/\s+/).map(Number);
            if (width > 0 && height > 0)
                root.done(root.picturePath, width, height);
        }
    }
}
