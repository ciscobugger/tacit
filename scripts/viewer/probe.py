#!/usr/bin/env python3
"""Viewer helper: facts a Qt item cannot read, as one JSON line.

  probe.py facts <path>        image: EXIF; video/audio: ffprobe tags + a poster or cover jpg
  probe.py peaks <path> [n]    n loudness peaks (0..1) for the audio waveform ticks
  probe.py pages <path> [max]  pdftoppm pages as png, for files PDFium refuses

Results are cached under ~/.cache/tacit-viewer, keyed by path + mtime + size.
"""
import array, glob, hashlib, json, os, re, shutil, subprocess, sys

CACHE = os.path.expanduser("~/.cache/tacit-viewer")


def key(path):
    st = os.stat(path)
    return hashlib.sha1(f"{path}\0{st.st_mtime_ns}\0{st.st_size}".encode()).hexdigest()[:20]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=kw.pop("text", True), timeout=kw.pop("timeout", 60), **kw)


def facts(path):
    out = {}
    ext = path.rsplit(".", 1)[-1].lower()
    if ext in ("jpg", "jpeg", "tif", "tiff", "webp", "png"):
        r = run(["exiv2", "-q", "-Pkt", path])
        ex = {}
        # the summary line has the pixel size even where there is no EXIF block
        summ = run(["exiv2", "-q", path]).stdout
        for line in summ.splitlines():
            if line.startswith("Image size"):
                nums = [int(n) for n in re.findall(r"\d+", line)]
                if len(nums) >= 2:
                    out["w"], out["h"] = nums[0], nums[1]
        for line in r.stdout.splitlines():
            k, _, v = line.partition(" ")
            ex[k] = v.strip()
        out["exif"] = {
            "taken": ex.get("Exif.Photo.DateTimeOriginal", ""),
            "make": ex.get("Exif.Image.Make", ""),
            "model": ex.get("Exif.Image.Model", ""),
            "lens": ex.get("Exif.Photo.LensModel", ""),
            "focal": ex.get("Exif.Photo.FocalLength", ""),
            "fnumber": ex.get("Exif.Photo.FNumber", ""),
            "exposure": ex.get("Exif.Photo.ExposureTime", ""),
            "iso": ex.get("Exif.Photo.ISOSpeedRatings", ""),
        }
        # orientation 5-8 is a quarter turn: the picture is shown with width and height swapped
        # -Pkt prints it as words ("right, top"); the first word is left or right for 5-8
        if ex.get("Exif.Image.Orientation", "").startswith(("left", "right")) and "w" in out:
            out["w"], out["h"] = out["h"], out["w"]
        return out
    r = run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path])
    try:
        j = json.loads(r.stdout)
    except ValueError:
        return out
    fmt = j.get("format", {})
    tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
    streams = j.get("streams", [])
    vs = next((s for s in streams if s.get("codec_type") == "video" and s.get("disposition", {}).get("attached_pic") != 1), None)
    cover = next((s for s in streams if s.get("disposition", {}).get("attached_pic") == 1), None)
    au = next((s for s in streams if s.get("codec_type") == "audio"), None)
    dur = float(fmt.get("duration") or 0)
    out.update(duration=dur, bitrate=int(fmt.get("bit_rate") or 0), tags=tags,
               codec=(vs or au or {}).get("codec_name", ""),
               acodec=(au or {}).get("codec_name", ""),
               rate=int((au or {}).get("sample_rate") or 0),
               channels=int((au or {}).get("channels") or 0))
    if vs:
        num, _, den = vs.get("avg_frame_rate", "0/1").partition("/")
        out.update(w=vs.get("width", 0), h=vs.get("height", 0), fps=round(float(num) / float(den or 1), 2) if float(den or 1) else 0)
        rot = 0
        for sd in vs.get("side_data_list", []) or []:
            rot = abs(int(sd.get("rotation", 0)))
        if rot in (90, 270):
            out["w"], out["h"] = out["h"], out["w"]
    os.makedirs(f"{CACHE}/thumbs", exist_ok=True)
    jpg = f"{CACHE}/thumbs/{key(path)}.jpg"
    if not os.path.exists(jpg):
        # rendered beside the final name and renamed on success, so a cut-off ffmpeg never leaves a truncated jpg
        tmp = f"{jpg}.{os.getpid()}.part.jpg"
        try:
            r = None
            if vs:
                r = run(["ffmpeg", "-v", "error", "-y", "-ss", f"{min(1.0, dur / 10):.2f}", "-i", path,
                         "-frames:v", "1", "-vf", "scale=720:-2", "-q:v", "4", tmp])
            elif cover:
                r = run(["ffmpeg", "-v", "error", "-y", "-i", path, "-map", f"0:{cover['index']}", "-frames:v", "1",
                         "-vf", "scale=720:720:force_original_aspect_ratio=decrease", "-q:v", "3", tmp])
            if r and r.returncode == 0 and os.path.exists(tmp):
                os.replace(tmp, jpg)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    if os.path.exists(jpg):
        out["thumb"] = jpg
    return out


def peaks(path, n):
    os.makedirs(f"{CACHE}/peaks", exist_ok=True)
    cache = f"{CACHE}/peaks/{key(path)}-{n}.json"
    if os.path.exists(cache):
        return json.load(open(cache))
    r = run(["ffmpeg", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", "4000", "-f", "s16le", "-"], text=False, timeout=300)
    a = array.array("h")
    a.frombytes(r.stdout[: len(r.stdout) // 2 * 2])
    if not len(a):
        return {"peaks": []}
    step = max(1, len(a) // n)
    pk = [max(map(abs, a[i * step:(i + 1) * step] or [0])) / 32768 for i in range(n)]
    top = max(pk) or 1
    res = {"peaks": [round(p / top, 3) for p in pk]}
    json.dump(res, open(cache, "w"))
    return res


def pages(path, limit):
    d = f"{CACHE}/pages/{key(path)}"
    if not os.path.isdir(d):
        # rendered into a temp folder and renamed on success, so a timeout or a closed viewer never leaves a partial set
        tmp = f"{d}.{os.getpid()}.part"
        # a killed probe leaves its folder behind; remove those whose process is gone
        for f in glob.glob(f"{d}.*.part"):
            pid = f.rsplit(".", 2)[-2]
            if pid.isdigit() and not os.path.exists(f"/proc/{pid}"):
                shutil.rmtree(f, ignore_errors=True)
        os.makedirs(tmp, exist_ok=True)
        try:
            r = run(["pdftoppm", "-r", "110", "-png", "-l", str(limit), path, f"{tmp}/p"], timeout=240)
            if r.returncode == 0 and any(f.endswith(".png") for f in os.listdir(tmp)):
                try:
                    os.rename(tmp, d)
                except OSError:
                    pass  # another probe finished the same folder first; use that one
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    if not os.path.isdir(d):
        return {"pages": []}
    return {"pages": sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".png"))}


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    try:
        if mode == "facts":
            res = facts(path)
        elif mode == "peaks":
            res = peaks(path, int(sys.argv[3]) if len(sys.argv) > 3 else 120)
        else:
            res = pages(path, int(sys.argv[3]) if len(sys.argv) > 3 else 60)
    except Exception as e:  # a probe failing leaves the viewer with what Qt knows
        res = {"error": str(e)}
    res["path"] = path
    print(json.dumps(res))
