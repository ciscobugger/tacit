#!/usr/bin/env bash
geom=$(slurp) || exit 0
f=$(mktemp --suffix=.png) || exit 1
trap 'rm -f "$f"' EXIT
grim -g "$geom" "$f" || exit 1
imageLink=$(curl -sF files[]=@"$f" 'https://uguu.se/upload' | jq -r '.files[0].url')
[[ -n $imageLink && $imageLink != null ]] || exit 1
xdg-open "https://lens.google.com/uploadbyurl?url=${imageLink}"
