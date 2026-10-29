pragma Singleton

import Quickshell

Singleton {
    // Formats
    readonly property list<string> validImageTypes: ["jpeg", "png", "webp", "tiff", "svg"]
    // A superset of what services/Wallpapers.qml offers as a wallpaper, so nothing the picker
    // lists is left without a thumbnail. Matched case-insensitively: a camera writes IMG_0001.JPG.
    readonly property list<string> validImageExtensions: ["jpg", "jpeg", "png", "webp", "avif", "bmp", "tif", "tiff", "svg"]

    function isValidImageByName(name: string): bool {
        const lower = name.toLowerCase();
        return validImageExtensions.some(t => lower.endsWith(`.${t}`));
    }

    // Thumbnails
    // https://specifications.freedesktop.org/thumbnail-spec/latest/directory.html
    readonly property var thumbnailSizes: ({
        "normal": 128,
        "large": 256,
        "x-large": 512,
        "xx-large": 1024
    })
    // Thumbnail generation is one magick per visible tile, so a folder of photos would fan out
    // as many processes at once as the grid has cells - on this machine that is a hang, not a
    // slow scroll. A tile takes a slot before it spawns and releases it when magick exits.
    readonly property int maxConcurrentThumbnails: 4
    property int thumbnailsInFlight: 0
    property var thumbnailQueue: []

    // false means the tile is queued; it is called back through requestGeneration() when a slot
    // frees up. A tile destroyed while queued reads back as null here and is simply dropped.
    function requestThumbnailSlot(item): bool {
        if (thumbnailsInFlight < maxConcurrentThumbnails) {
            thumbnailsInFlight += 1;
            return true;
        }
        if (thumbnailQueue.indexOf(item) === -1)
            thumbnailQueue.push(item);
        return false;
    }
    function releaseThumbnailSlot() {
        thumbnailsInFlight = Math.max(0, thumbnailsInFlight - 1);
        while (thumbnailQueue.length > 0 && thumbnailsInFlight < maxConcurrentThumbnails) {
            const next = thumbnailQueue.shift();
            if (next) next.requestGeneration();
        }
    }

    function thumbnailSizeNameForDimensions(width: int, height: int): string {
        const sizeNames = Object.keys(thumbnailSizes);
        for(let i = 0; i < sizeNames.length; i++) {
            const sizeName = sizeNames[i];
            const maxSize = thumbnailSizes[sizeName];
            if (width <= maxSize && height <= maxSize) return sizeName;
        }
        return "xx-large";
    }
}
