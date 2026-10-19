#!/bin/bash
# Reads how the Cotypist app on this Mac is put together, so Nook's autocompletion can match it: which runtime and model
# files it uses, its settings keys, its prompt and sampling strings, and which macOS APIs it relies on.
#
#   scripts/inspect-cotypist.sh            writes ~/Desktop/cotypist-report.txt
#
# Read-only. It never opens your writing history, never prints what you typed, and changes nothing. Setting values longer
# than 60 characters are cut off (your own instructions could be in there); look the report over before you share it.
set -uo pipefail

OUT="${1:-$HOME/Desktop/cotypist-report.txt}"
exec > >(tee "$OUT") 2>&1

section() { printf '\n===== %s =====\n' "$1"; }

APP="$(mdfind "kMDItemCFBundleIdentifier == 'app.cotypist.Cotypist'" 2>/dev/null | head -1)"
[ -z "$APP" ] && [ -d /Applications/Cotypist.app ] && APP=/Applications/Cotypist.app
if [ -z "$APP" ]; then echo "Cotypist.app not found"; exit 1; fi
BUNDLE="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || echo app.cotypist.Cotypist)"
BIN="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"

section "app"
echo "path: $APP"
plutil -p "$APP/Contents/Info.plist" | grep -vE 'CFBundleIcon|NSHumanReadableCopyright' | head -80

section "binary"
file "$BIN"
du -sh "$APP" "$BIN"
otool -L "$BIN" | sed 1d

section "entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || codesign -d --entitlements - "$APP" 2>&1 | head -40

section "frameworks and resources (largest first)"
find "$APP/Contents/Frameworks" -maxdepth 2 2>/dev/null | sed "s|$APP/||" | head -60
find "$APP/Contents" -type f -size +1M -exec du -h {} + 2>/dev/null | sort -rh | sed "s|$APP/||" | head -40
find "$APP/Contents/Resources" -maxdepth 2 \( -name '*.json' -o -name '*.plist' -o -name '*.txt' -o -name '*.gbnf' -o -name '*.jinja' \) 2>/dev/null | sed "s|$APP/||" | head -60

section "settings keys (values cut at 60 chars)"
defaults read "$BUNDLE" 2>/dev/null | /usr/bin/awk '{ if (length($0) > 90) print substr($0, 1, 90) " …"; else print }' | head -250

section "data folders (names and sizes only)"
for dir in "$HOME/Library/Application Support/$BUNDLE" "$HOME/Library/Application Support/Cotypist" \
           "$HOME/Library/Containers/$BUNDLE" "$HOME/Library/Group Containers/"*cotypist* \
           "$HOME/Library/Caches/$BUNDLE" "$HOME/Library/Application Support/"*[Cc]otypist*; do
  [ -e "$dir" ] || continue
  echo "-- $dir"
  find "$dir" -maxdepth 6 -not -name '.*' 2>/dev/null | while read -r f; do
    if [ -f "$f" ]; then printf '%8s  %s\n' "$(du -h "$f" | cut -f1)" "${f#$dir/}"; else printf '%8s  %s/\n' "" "${f#$dir/}"; fi
  done | head -200
done

section "model files"
MODELS=$(find "$HOME/Library" "$APP" -maxdepth 9 -ipath '*cotypist*' -type f \( -iname '*.gguf' -o -iname '*.bin' -o -iname '*.safetensors' -o -iname '*.mlmodelc' -o -size +100M \) 2>/dev/null)
echo "$MODELS"
PY="$(command -v python3)"
for m in $MODELS; do
  echo "-- $m"
  printf 'magic: '; head -c 8 "$m" | xxd -p
  [ -n "$PY" ] || continue
  "$PY" -I - "$m" <<'PYEOF'
import struct, sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read(16 * 1024 * 1024)
if data[:4] != b"GGUF":
    print("not GGUF"); sys.exit()
pos = 4
def take(n):
    global pos
    if pos + n > len(data): raise EOFError
    b = data[pos:pos+n]; pos += n; return b
def u32(): return struct.unpack("<I", take(4))[0]
def u64(): return struct.unpack("<Q", take(8))[0]
def s(): return take(u64()).decode("utf-8", "replace")
fmt = {0:"<B",1:"<b",2:"<H",3:"<h",4:"<I",5:"<i",6:"<f",7:"<?",10:"<Q",11:"<q",12:"<d"}
def value(t):
    if t == 8: return s()
    if t == 9:
        et, n = u32(), u64()
        if et in fmt:
            size = struct.calcsize(fmt[et]); take(size * n); return f"[{n} x type {et}]"
        for _ in range(n): value(et)
        return f"[{n} x type {et}]"
    return struct.unpack(fmt[t], take(struct.calcsize(fmt[t])))[0]
version = u32(); tensors = u64(); count = u64()
print(f"gguf v{version}, {tensors} tensors, {count} keys")
try:
    for _ in range(count):
        k = s(); t = u32(); v = value(t)
        if k == "tokenizer.chat_template":
            print(f"{k} = {str(v)[:400]!r} …")
        elif not k.startswith("tokenizer.ggml.") or k in ("tokenizer.ggml.model", "tokenizer.ggml.pre", "tokenizer.ggml.add_bos_token", "tokenizer.ggml.bos_token_id", "tokenizer.ggml.eos_token_id"):
            print(f"{k} = {str(v)[:200]}")
except EOFError:
    print("(rest of the header is past the first 16 MB)")
PYEOF
done

section "runtime and model strings in the binary"
strings -n 5 "$BIN" | grep -iE 'llama|ggml|gguf|gemma|qwen|phi-?[0-9]|smollm|mlx|coreml|huggingface|\.gguf|n_ctx|n_batch|top_k|top_p|min_p|temperature|repeat_penalty|logit|grammar|sampler|kv.?cache|speculative|draft' | sort -u | head -250

section "prompt-like strings"
strings -n 12 "$BIN" | grep -iE 'you are|continue the|complete the|the user|instruction|<start_of_turn>|<end_of_turn>|<\|im_start\|>|<\|im_end\|>|<\|fim|fim_|prefix>|suffix>|middle>|\{\{|\}\}|system prompt|writing style|tone' | sort -u | head -200

section "macOS APIs and behaviour"
strings -n 6 "$BIN" | grep -E 'AX[A-Z][A-Za-z]+|kAX|TextMarker|SecureEventInput|CGEventTap|ScreenCaptureKit|SCScreenshot|VNRecognize|NSSpellChecker|ConcealedType|TransientType|IOPSCopy|SMAppService|NSPasteboard|caret|ghost|midline|mid-line|autocorrect|emoji|per.?app|blocklist|allowlist|bundle' | sort -u | head -300

section "network hosts"
strings -n 8 "$BIN" | grep -oE 'https?://[A-Za-z0-9./_%?=&-]+' | sort -u | head -80

echo
echo "Report written to $OUT"
