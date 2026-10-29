#!/bin/bash
# Files' job runner: one operation, detached from the shell, reporting to a JSON file that the
# window and the notch read. Outlives the window, a shell reload and a crash.
#
#   job.sh <id> copy    <policy> <dest-dir> <src>...     policy: replace | keep | skip
#   job.sh <id> move    <policy> <dest-dir> <src>...
#   job.sh <id> trash   <src>...
#   job.sh <id> restore <trash-item>...                 (names under trash:///)
#   job.sh <id> rename  <src> <new-name>
#   job.sh <id> mkdir   <dir> <name>
#   job.sh <id> delete  <src>...                        (permanent; the UI has asked)
#   job.sh <id> moveback <from> <to> ...                (undo of a move or rename)
#   job.sh <id> restore-paths <orig-path>...            (undo of a trash)
#   job.sh <id> touch   <dir> <name>                    (a new, empty file)
#   job.sh <id> compress <dir> <zip-name> <src>...      (one .zip of them, in <dir>)
#   job.sh <id> renames <src> <new-name> ...            (many at once; every name checked before any moves)
#
# Report: $XDG_STATE_HOME/quickshell/user/files/jobs/<id>.json
#   { id, op, dest, state: running|done|failed|cancelled, total, done, bytes, bytesDone,
#     current, error, started, ended, results: [...], undo: {...} }
# Cancel: touch <id>.cancel next to the report.
set -u
id=$1; op=$2; shift 2
dir="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/files/jobs"
mkdir -p "$dir"
report="$dir/$id.json"; cancel="$dir/$id.cancel"
state=running; total=0; done_=0; bytes=0; bytesDone=0; current=""; error=""; dest=""
started=$(date +%s%3N); ended=null
results=(); undo='null'

# The freedesktop trash spec, by hand: find the record whose Path is $1 (URL-encoded), move the
# file back, drop the record. Home trash only; other disks go through gio above.
restore_from_home_trash() {
    local want=$1 info name path
    local tdir="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
    for info in "$tdir"/info/*.trashinfo; do
        [ -e "$info" ] || continue
        path=$(sed -n 's/^Path=//p' "$info" | head -1 | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().rstrip("\n")))')
        [ "$path" = "$want" ] || continue
        name=$(basename -- "$info" .trashinfo)
        [ -e "$tdir/files/$name" ] || continue   # an orphan record must not fail a valid restore
        [ -e "$want" ] && return 1
        mkdir -p "$(dirname -- "$want")" && mv -- "$tdir/files/$name" "$want" && rm -f -- "$info" && return 0
        return 1
    done
    return 1
}

write() {
    local ended_json=$ended
    jq -nc --arg id "$id" --arg op "$op" --arg dest "$dest" --arg state "$state" \
        --argjson total "$total" --argjson done "$done_" --argjson bytes "$bytes" --argjson bytesDone "$bytesDone" \
        --arg current "$current" --arg error "$error" --argjson started "$started" --argjson ended "$ended_json" \
        --argjson results "$(printf '%s\n' "${results[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')" --argjson undo "$undo" \
        '{id:$id, op:$op, dest:$dest, state:$state, total:$total, done:$done, bytes:$bytes, bytesDone:$bytesDone, current:$current, error:$error, started:$started, ended:$ended, results:$results, undo:$undo}' \
        > "$report.tmp" && mv -f "$report.tmp" "$report"
}
finish() { state=$1; ended=$(date +%s%3N); current=""; write; rm -f "$cancel"; exit 0; }
cancelled() { [ -e "$cancel" ]; }

# "name", "name 2", "name 3" ... beside a file that is already there
keep_name() {   # dir base -> free path
    local d=$1 b=$2 stem ext n=2
    [ ! -e "$d/$b" ] && { printf '%s' "$d/$b"; return; }
    # only a short, letters-and-digits tail counts as an extension ("tar.gz" keeps ".gz";
    # a folder "Hyprland-0.56.2" is not a file called Hyprland-0.56 with a ".2")
    if [ ! -d "$d/$b" ] && [[ "$b" =~ ^(.+)\.([A-Za-z0-9]{1,5})$ ]]; then stem=${BASH_REMATCH[1]}; ext=.${BASH_REMATCH[2]}; else stem=$b; ext=""; fi
    while [ -e "$d/$stem $n$ext" ]; do n=$((n+1)); done
    printf '%s' "$d/$stem $n$ext"
}

case "$op" in
copy|move)
    policy=$1; dest=$2; shift 2
    srcs=("$@"); total=${#srcs[@]}
    for s in "${srcs[@]}"; do b=$(du -sb -- "$s" 2>/dev/null | cut -f1); bytes=$((bytes + ${b:-0})); done
    write
    moved_from=(); made=()
    for s in "${srcs[@]}"; do
        cancelled && finish cancelled
        name=$(basename -- "$s"); target="$dest/$name"; current=$name; write
        if [ -e "$target" ]; then
            case "$policy" in
            skip)    done_=$((done_+1)); continue ;;
            keep)    target=$(keep_name "$dest" "$name") ;;
            replace) [ "$op" = move ] && [ -d "$target" ] && [ ! -d "$s" ] && rm -rf -- "$target" ;;
            esac
        fi
        # progress: the target growing, sampled while the copy runs
        if [ "$op" = copy ]; then cp -a -- "$s" "$target" & else mv -f -- "$s" "$target" & fi
        pid=$!; before=$bytesDone
        while kill -0 "$pid" 2>/dev/null; do
            if cancelled; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; [ "$op" = copy ] && rm -rf -- "$target"; finish cancelled; fi
            cur=$(du -sb -- "$target" 2>/dev/null | cut -f1); bytesDone=$((before + ${cur:-0})); write; sleep 0.3
        done
        if ! wait "$pid"; then error="Could not ${op} $name"; finish failed; fi
        cur=$(du -sb -- "$target" 2>/dev/null | cut -f1); bytesDone=$((before + ${cur:-0}))
        results+=("$target"); made+=("$target"); [ "$op" = move ] && moved_from+=("$s")
        done_=$((done_+1)); write
    done
    if [ "$op" = move ]; then
        undo=$(jq -nc --argjson to "$(printf '%s\n' "${made[@]}" | jq -R . | jq -sc .)" --argjson from "$(printf '%s\n' "${moved_from[@]}" | jq -R . | jq -sc .)" '{op:"move-back", from:$to, to:$from}')
    else
        undo=$(jq -nc --argjson paths "$(printf '%s\n' "${made[@]}" | jq -R . | jq -sc .)" '{op:"delete", paths:$paths}')
    fi
    finish done ;;
trash)
    total=$#; write
    for s in "$@"; do
        current=$(basename -- "$s"); write
        if ! out=$(gio trash -- "$s" 2>&1); then
            # no trash on this filesystem (a stick, /tmp): the UI asks about deleting for good
            case "$out" in *"not supported"*|*"trash"*"directory"*|*"Unable to find or create"*) error="no trash on this disk" ;; *) error="Could not move $(basename -- "$s") to the trash" ;; esac
            finish failed
        fi
        results+=("$s"); done_=$((done_+1)); write
    done
    undo=$(jq -nc --argjson paths "$(printf '%s\n' "${results[@]}" | jq -R . | jq -sc .)" '{op:"restore-paths", paths:$paths}')
    finish done ;;
restore-paths)
    total=$#; write
    for p in "$@"; do
        current=$(basename -- "$p"); write
        item=$(gio list -a trash::orig-path trash:/// 2>/dev/null | awk -F'\t' -v want="$p" '{ n=$1; for (i=2;i<=NF;i++) if (index($i, "trash::orig-path=")==1 && substr($i, 18)==want) print n }' | head -1)
        if [ -z "$item" ] || ! gio trash --restore "trash:///$item" 2>/dev/null; then
            # gio's listing lags a fresh trash by seconds (its monitor has not caught up), and
            # an undo comes right after the trash: read the home trash's own records instead.
            if ! restore_from_home_trash "$p"; then error="Could not put $(basename -- "$p") back"; finish failed; fi
        fi
        done_=$((done_+1)); write
    done
    finish done ;;
restore)
    total=$#; write
    for item in "$@"; do
        current=$item; write
        if ! gio trash --restore "trash:///$item" 2>/dev/null; then error="Could not put $item back"; finish failed; fi
        done_=$((done_+1)); write
    done
    finish done ;;
rename)
    src=$1; new=$2; total=1; dir_=$(dirname -- "$src"); target="$dir_/$new"; current=$new; write
    if [ -e "$target" ]; then error="$new is already here"; finish failed; fi
    if ! mv -- "$src" "$target"; then error="Could not rename"; finish failed; fi
    results+=("$target"); done_=1
    undo=$(jq -nc --arg from "$target" --arg to "$src" '{op:"move-back", from:[$from], to:[$to]}')
    finish done ;;
mkdir)
    parent=$1; name=$2; total=1; target="$parent/$name"; current=$name; write
    if [ -e "$target" ]; then error="$name is already here"; finish failed; fi
    if ! mkdir -- "$target"; then error="Could not make $name here"; finish failed; fi
    results+=("$target"); done_=1
    undo=$(jq -nc --arg p "$target" '{op:"delete", paths:[$p]}')
    finish done ;;
moveback)   # pairs: from to from to ... (the undo of a move or a rename)
    total=$(( $# / 2 )); write
    while [ $# -ge 2 ]; do
        from=$1; to=$2; shift 2; current=$(basename -- "$to"); write
        if [ -e "$to" ]; then error="$(basename -- "$to") is there again"; finish failed; fi
        mkdir -p -- "$(dirname -- "$to")"
        if ! mv -f -- "$from" "$to"; then error="Could not put $(basename -- "$to") back"; finish failed; fi
        results+=("$to"); done_=$((done_+1)); write
    done
    finish done ;;
extract)   # <archive> -> a folder beside it named after it (bsdtar reads every common format)
    src=$1; total=1; d=$(dirname -- "$src"); b=$(basename -- "$src"); stem=${b%.*}; case "$stem" in *.tar) stem=${stem%.tar} ;; esac
    target=$(keep_name "$d" "$stem"); current=$(basename -- "$target"); write
    mkdir -p -- "$target" || { error="Could not make a folder for it"; finish failed; }
    bsdtar -xf "$src" -C "$target" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if cancelled; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf -- "$target"; finish cancelled; fi
        cur=$(du -sb -- "$target" 2>/dev/null | cut -f1); bytesDone=${cur:-0}; write; sleep 0.3
    done
    if ! wait "$pid"; then rm -rf -- "$target"; error="Could not unpack $b"; finish failed; fi
    results+=("$target"); done_=1
    undo=$(jq -nc --arg p "$target" '{op:"delete", paths:[$p]}')
    finish done ;;
touch)
    parent=$1; name=$2; total=1; target="$parent/$name"; current=$name; write
    if [ -e "$target" ]; then error="$name is already here"; finish failed; fi
    if ! ( set -o noclobber; : > "$target" ) 2>/dev/null; then error="Could not make $name here"; finish failed; fi
    results+=("$target"); done_=1
    undo=$(jq -nc --arg p "$target" '{op:"delete", paths:[$p]}')
    finish done ;;
compress)   # names go in relative to their folder, so the archive holds them, not the path to them
    dest=$1; name=$2; shift 2; srcs=("$@"); total=${#srcs[@]}
    target=$(keep_name "$dest" "$name"); current=$(basename -- "$target"); write
    names=(); for s in "${srcs[@]}"; do names+=("./$(basename -- "$s")"); done
    bsdtar -a -cf "$target" -C "$(dirname -- "${srcs[0]}")" -- "${names[@]}" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if cancelled; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f -- "$target"; finish cancelled; fi
        sleep 0.3
    done
    if ! wait "$pid"; then rm -f -- "$target"; error="Could not compress $(basename -- "${srcs[0]}")"; finish failed; fi
    results+=("$target"); done_=$total
    undo=$(jq -nc --arg p "$target" '{op:"delete", paths:[$p]}')
    finish done ;;
renames)   # pairs: <src> <new-name>; nothing moves unless every new name is free and no two are alike
    total=$(( $# / 2 )); args=("$@"); write
    declare -A taken=()
    for ((i = 0; i < ${#args[@]}; i += 2)); do
        from=${args[i]}; to="$(dirname -- "$from")/${args[i+1]}"
        [ "$to" = "$from" ] && continue
        if [ -e "$to" ]; then error="${args[i+1]} is already here"; finish failed; fi
        if [ -n "${taken[$to]:-}" ]; then error="Two would be called ${args[i+1]}"; finish failed; fi
        taken[$to]=1
    done
    froms=(); tos=()
    for ((i = 0; i < ${#args[@]}; i += 2)); do
        from=${args[i]}; to="$(dirname -- "$from")/${args[i+1]}"; current=${args[i+1]}
        if [ "$to" != "$from" ]; then
            if ! mv -n -- "$from" "$to"; then error="Could not rename $(basename -- "$from")"; finish failed; fi
            froms+=("$from"); tos+=("$to")
        fi
        results+=("$to"); done_=$((done_ + 1)); write
    done
    undo=$(jq -nc --argjson from "$(printf '%s\n' "${tos[@]}" | jq -R . | jq -sc 'map(select(length > 0))')" --argjson to "$(printf '%s\n' "${froms[@]}" | jq -R . | jq -sc 'map(select(length > 0))')" '{op:"move-back", from:$from, to:$to}')
    finish done ;;
delete)
    total=$#; write
    tdir="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
    for s in "$@"; do
        current=$(basename -- "$s"); write
        if ! rm -rf -- "$s"; then error="Could not delete $(basename -- "$s")"; finish failed; fi
        # "Delete for good" inside the trash: the record goes with the file, or a later "put back"
        # of a same-named file matches a record whose file is gone. Only the trash's own top level
        # has records; a file inside a trashed folder is covered by that folder's one.
        case "$s" in
            "$tdir/files/"*/*) : ;;
            "$tdir/files/"*) rm -f -- "$tdir/info/$(basename -- "$s").trashinfo" ;;
        esac
        results+=("$s"); done_=$((done_+1)); write
    done
    finish done ;;
*)  error="unknown op $op"; finish failed ;;
esac
