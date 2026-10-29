pragma ComponentBehavior: Bound
pragma Singleton
import qs.modules.common
import qs.modules.common.utils
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import Qt.labs.synchronizer
import Quickshell

Singleton {
    id: root

    enum Action {
        Copy,
        Edit,
        Search,
        CharRecognition,
        Record,
        RecordWithSound,
        Claude
    }

    property string imageSearchEngineBaseUrl: Config.options.search.imageSearch.imageSearchEngineBaseUrl
    property string fileUploadApiEndpoint: "https://uguu.se/upload"

    function getCommand(x, y, width, height, screenshotPath, action, saveDir = "") {
        // Set command for action
        const rx = Math.round(x);
        const ry = Math.round(y);
        const rw = Math.round(width);
        const rh = Math.round(height);
        if (rw <= 0 || rh <= 0) {
            // ImageMagick reads a 0x0 crop geometry as "everything left", i.e. the whole screen
            console.warn("[Screenshot] Refusing a zero-size crop.");
            return null;
        }
        const cropBase = `magick '${StringUtils.shellSingleQuoteEscape(screenshotPath)}' `
            + `-crop ${rw}x${rh}+${rx}+${ry} +repage`
        const cropToStdout = `${cropBase} -`
        const cropInPlace = `${cropBase} '${StringUtils.shellSingleQuoteEscape(screenshotPath)}'`
        const cleanup = `rm '${StringUtils.shellSingleQuoteEscape(screenshotPath)}'`
        const slurpRegion = `${rx},${ry} ${rw}x${rh}`
        const uploadAndGetUrl = (filePath) => {
            return `curl -sF files[]=@'${StringUtils.shellSingleQuoteEscape(filePath)}' ${root.fileUploadApiEndpoint} | jq -r '.files[0].url'`
        }
        // A missing annotation tool would swallow the crop with only a stderr line nobody reads
        const annotationTool = Config.options.regionSelector.annotation.useSatty ? "satty" : "swappy";
        const annotationCommand = `if command -v ${annotationTool} > /dev/null; then ${annotationTool} -f -; `
            + `else cat > /dev/null; notify-send "Screenshot" "${annotationTool} is not installed" -a "Screen Snip" -i "image-x-generic"; fi`;
        switch (action) {
            case ScreenshotAction.Action.Copy:
                if (saveDir === "") {
                    // Nothing is saved, so the notch has no file to park and announce: say it here
                    return ["bash", "-c", `${cropToStdout} | wl-copy && ${cleanup}`
                        + ` && notify-send "Screenshot Copied" "Copied to clipboard" -a "Screen Snip" -i "image-x-generic"`]
                    break;
                }
                return [
                    "bash", "-c",
                    `mkdir -p '${StringUtils.shellSingleQuoteEscape(saveDir)}' && \
                    savePathBase='${StringUtils.shellSingleQuoteEscape(saveDir)}'"/screenshot-$(date '+%Y-%m-%d_%H.%M.%S')" && \
                    savePath="$savePathBase.png" && \
                    suffix=1 && while [ -e "$savePath" ]; do savePath="$savePathBase-$suffix.png"; suffix=$((suffix+1)); done && \
                    ${cropToStdout} | tee >(wl-copy) > "$savePath" && \
                    ${cleanup}`
                ]

                break;
            case ScreenshotAction.Action.Edit:
                return ["bash", "-c", `${cropToStdout} | ${annotationCommand} && ${cleanup}`]
                break;
            case ScreenshotAction.Action.Search:
                return ["bash", "-c", `${cropInPlace} && xdg-open "${root.imageSearchEngineBaseUrl}$(${uploadAndGetUrl(screenshotPath)})" && ${cleanup}`]
                break;
            case ScreenshotAction.Action.CharRecognition:
                return ["bash", "-c", `${cropInPlace} && tesseract '${StringUtils.shellSingleQuoteEscape(screenshotPath)}' stdout -l $(tesseract --list-langs | awk 'NR>1{print $1}' | tr '\\n' '+' | sed 's/\\+$/\\n/') | wl-copy && ${cleanup}`]
                break;
            case ScreenshotAction.Action.Record:
                return ["bash", "-c", `${Directories.recordScriptPath} --region '${slurpRegion}'`]
                break;
            case ScreenshotAction.Action.RecordWithSound:
                return ["bash", "-c", `${Directories.recordScriptPath} --region '${slurpRegion}' --sound`]
                break;
            case ScreenshotAction.Action.Claude:
                // the crop goes to the notch's Ask (IslandAsk), attached to the question you are writing
                // The crop stays on disk after the ask: ${cleanup} removes the full-screen source, not
                // this file, and nothing else prunes the directory - it grew for the life of the
                // install. A capture is handed over within seconds, so anything a day old is dead;
                // the sweep is by directory, so it bounds the window shots written beside it too.
                return ["bash", "-c", `d='${StringUtils.shellSingleQuoteEscape(Directories.agentHostRegion)}' && mkdir -p "$d" && find "$d" -maxdepth 1 -type f -mtime +1 -delete; f="$d/region-$(date '+%Y-%m-%d_%H.%M.%S')-$$.png" && ${cropToStdout} > "$f" && ${cleanup} && qs -p '${StringUtils.shellSingleQuoteEscape(Quickshell.shellPath(""))}' ipc call island askWith "$f"`]
                break;
            default:
                console.warn("[Region Selector] Unknown snip action, skipping snip.");
                return;
        }
    }
}
