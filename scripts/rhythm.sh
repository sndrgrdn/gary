#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: scripts/rhythm.sh [options] <image.png | --rect x,y,w,h | --window id | --windows>

Measure the alignment and spacing rhythm of a screenshot, in points, and write
an annotated copy with a grid every --step points, frame edges (magenta), the
left and right edge of every row (yellow), and column edges that two or more
rows share (green for left edges, red for right edges).

  --windows        list Gary's on-screen windows: id, layer, x,y,w,h
  --window id      capture that window (screencapture -l)
  --rect x,y,w,h   capture that screen area (screencapture -R), such as the
                   frame `gary action` prints
  --step n         grid step in points (default 4)
  --bar            for a one-row strip such as the bar: draw the grid's columns
                   too, and list every ink box's left, right and centre with
                   each modulo the step
  --join n         merge ink less than n points apart vertically into one row (default 8)
  --tall n         a box taller than n points that holds other boxes is a frame (default 48)
  --scale n        pixels per point (default: from the image's resolution)
  -o file          annotated output (default: <input>.rhythm.png)
EOF
    exit 2
}

windows() {
    osascript -l JavaScript -e '
ObjC.import("CoreGraphics");
const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
const rows = [];
for (let i = 0; i < list.count; i++) {
  const w = list.objectAtIndex(i);
  if (!/^gary$/i.test(ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")))) continue;
  const b = w.objectForKey("kCGWindowBounds");
  rows.push([ObjC.unwrap(w.objectForKey("kCGWindowNumber")), ObjC.unwrap(w.objectForKey("kCGWindowLayer")),
    ["X", "Y", "Width", "Height"].map((k) => ObjC.unwrap(b.objectForKey(k))).join(",")].join(" "));
}
rows.join("\n");'
}

step=4 join=8 tall=48 bar=0 scale="" out="" image=""
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

while (($#)); do
    case "$1" in
        --windows) windows; exit ;;
        --window) image="$work/capture.png"; screencapture -x -o -l"$2" "$image"; shift ;;
        --rect) image="$work/capture.png"; screencapture -x -R"$2" "$image"; shift ;;
        --step) step="$2"; shift ;;
        --bar) bar=1 ;;
        --join) join="$2"; shift ;;
        --tall) tall="$2"; shift ;;
        --scale) scale="$2"; shift ;;
        -o) out="$2"; shift ;;
        -h | --help) usage ;;
        -*) usage ;;
        *) image="$1" ;;
    esac
    shift
done
[[ -n "$image" ]] || usage
[[ -n "$out" ]] || out="$( [[ "$image" == "$work"/* ]] && echo "${TMPDIR:-/tmp}/rhythm-$(date +%s)" || echo "${image%.*}").rhythm.png"
[[ -n "$scale" ]] || scale="$(magick identify -quiet -units PixelsPerInch -format '%[fx:max(1,round(resolution.x/72))]' "$image")"

reach=$((3 * scale)) lift=$((1 * scale))
magick -quiet "$image" -background black -alpha remove -alpha off -colorspace gray \
    -morphology Edge Square:1 -threshold 4% \
    -morphology Dilate "Rectangle:$((2 * reach + 1))x$((2 * lift + 1))" \
    -define connected-components:verbose=true -define connected-components:area-threshold=$((4 * scale * scale)) \
    -connected-components 8 null: | awk '/gray\(255\)|srgb\(255,255,255\)|100%/ { print $2 }' >"$work/boxes"

read -r width height < <(magick identify -quiet -format '%w %h\n' "$image")

awk -v s="$scale" -v reach="$reach" -v lift="$lift" -v step="$step" -v join="$join" -v tall="$tall" -v bar="$bar" \
    -v W="$width" -v H="$height" -v draw="$work/draw" '
function pt(v) { return sprintf("%.1f", v) }
function line(x1, y1, x2, y2, color) { printf "stroke %s line %d,%d %d,%d\n", color, x1 * s, y1 * s, x2 * s, y2 * s > draw }
function box(l, t, r, b, color) { printf "fill none stroke %s rectangle %d,%d %d,%d\n", color, l * s, t * s, r * s, b * s > draw }
function inside(j, i) { return i != j && L[j] >= L[i] && R[j] <= R[i] && T[j] >= T[i] && B[j] <= B[i] }
function shared(name, value, row, n, color,    i, j, t, count, first, seen, out) {
    for (i = 2; i <= n; i++) for (j = i; j > 1 && value[j] < value[j - 1]; j--) {
        t = value[j]; value[j] = value[j - 1]; value[j - 1] = t; t = row[j]; row[j] = row[j - 1]; row[j - 1] = t
    }
    out = ""
    for (i = 1; i <= n + 1; i++) {
        if (i <= n && i > 1 && value[i] - value[first] <= 1) { if (!(row[i] in seen)) { seen[row[i]] = 1; count++ }; continue }
        if (i > 1 && count > 1) { out = out sprintf(" %s..%s(%d)", pt(value[first]), pt(value[i - 1]), count); line(value[first], 0, value[first], H / s, color) }
        if (i <= n) { first = i; count = 1; split("", seen); seen[row[i]] = 1 }
    }
    print "shared " name " edges, pt (rows):" out
}
{
    split($1, g, /[x+]/)
    n++
    L[n] = (g[3] ? g[3] + reach : 0) / s; R[n] = (g[3] + g[1] < W ? g[3] + g[1] - reach : W) / s
    T[n] = (g[4] ? g[4] + lift : 0) / s; B[n] = (g[4] + g[2] < H ? g[4] + g[2] - lift : H) / s
}
END {
    for (y = 0; y < H / s; y += step) line(0, y, W / s, y, y % (4 * step) ? "\"rgba(0,255,255,0.12)\"" : "\"rgba(0,255,255,0.35)\"")
    for (i = 1; i <= n; i++) for (j = 1; j <= n; j++) if (B[i] - T[i] > tall && inside(j, i)) frame[i] = 1
    print "frames, pt: left right top bottom"
    for (i = 1; i <= n; i++) if (i in frame) { printf "  %7s %7s %7s %7s\n", pt(L[i]), pt(R[i]), pt(T[i]), pt(B[i]); box(L[i], T[i], R[i], B[i], "magenta") }
    m = 0
    for (i = 1; i <= n; i++) if (!(i in frame)) order[++m] = i
    for (i = 2; i <= m; i++) for (j = i; j > 1 && T[order[j]] < T[order[j - 1]]; j--) { t = order[j]; order[j] = order[j - 1]; order[j - 1] = t }
    rows = 0
    for (k = 1; k <= m; k++) {
        i = order[k]
        if (rows == 0 || T[i] > bottom[rows] + join) { rows++; top[rows] = T[i]; bottom[rows] = B[i]; left[rows] = L[i]; right[rows] = R[i]; lefts[rows] = "" }
        if (B[i] > bottom[rows]) bottom[rows] = B[i]
        if (L[i] < left[rows]) left[rows] = L[i]
        if (R[i] > right[rows]) right[rows] = R[i]
        nested = 0
        for (j = 1; j <= n; j++) if (!(j in frame) && inside(i, j)) nested = 1
        if (!nested) { lefts[rows] = lefts[rows] " " pt(L[i]); nl++; lx[nl] = L[i]; lr[nl] = rows }
    }
    widest = 0
    for (r = 1; r <= rows; r++) if (right[r] > widest) widest = right[r]
    print "rows, pt: top bottom height gap-above right right-minus-widest | left edges"
    for (r = 1; r <= rows; r++) {
        printf "  %2d %7s %7s %6s %6s %7s %6s |%s\n", r, pt(top[r]), pt(bottom[r]), pt(bottom[r] - top[r]), (r > 1 ? pt(top[r] - bottom[r - 1]) : "-"), pt(right[r]), pt(right[r] - widest), lefts[r]
        box(left[r], top[r], right[r], bottom[r], "yellow")
        printf "stroke none fill yellow text %d,%d \"%d\"\n", (left[r] < 14 ? right[r] + 3 : left[r] - 12) * s, (top[r] + 10) * s, r > draw
        rx[r] = right[r]; rr[r] = r
    }
    shared("left", lx, lr, nl, "lime")
    shared("right", rx, rr, rows, "red")
    if (!bar) exit
    for (x = 0; x < W / s; x += step) line(x, 0, x, H / s, x % (4 * step) ? "\"rgba(0,255,255,0.12)\"" : "\"rgba(0,255,255,0.35)\"")
    for (k = 1; k <= m; k++) by[k] = order[k]
    for (i = 2; i <= m; i++) for (j = i; j > 1 && L[by[j]] < L[by[j - 1]]; j--) { t = by[j]; by[j] = by[j - 1]; by[j - 1] = t }
    print "boxes, pt: left right centre | left%step right%step centre%step"
    for (k = 1; k <= m; k++) {
        i = by[k]; c = (L[i] + R[i]) / 2
        printf "  %7s %7s %7s | %5s %5s %5s\n", pt(L[i]), pt(R[i]), pt(c), pt(L[i] - step * int(L[i] / step)), pt(R[i] - step * int(R[i] / step)), pt(c - step * int(c / step))
    }
}' "$work/boxes"

magick -quiet "$image" -fill none -strokewidth 1 -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize $((10 * scale)) -draw "@$work/draw" "$out"
echo "annotated: $out"
