#!/bin/bash
# End-to-end check of browser automation (WP-B4, BROWSER-AGENTS-EXPERIMENT A.3/A.4):
# private smthzd + a copied app bundle + a local HTTP server on 127.0.0.1 (no external network),
# driven only through `smthz browser ...`. Needs an unlocked desktop (the app must run).
#   scripts/browser-e2e.sh            build, package, copy, run
#   scripts/browser-e2e.sh --app P    use an existing smthz.app at P (copied first)
# Env: SMTHZ_SCRATCH_PATH (default /tmp/smthz-b4), KEEP=1 keeps the work dir.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${SMTHZ_SCRATCH_PATH:-/tmp/smthz-b4}"
WORK=/tmp/smthz-b4e2e
APP_SOURCE=""
[[ "${1:-}" == "--app" ]] && APP_SOURCE="$2"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
if [[ "$front" == "loginwindow" || -z "$front" ]]; then
  echo "SKIP: desktop is locked (frontmost: ${front:-unknown}); browser e2e not run" >&2
  exit 3
fi

rm -rf "$WORK"; mkdir -p "$WORK/state" "$WORK/site"
APP="$WORK/smthz.app"; SOCK="$WORK/s.sock"; PORT=18765; BASE="http://127.0.0.1:$PORT"
HOSTPID=""; SERVERPID=""
cleanup() {
  pkill -f "$APP/Contents/MacOS/smthz" 2>/dev/null
  [[ -n "$HOSTPID" ]] && kill "$HOSTPID" 2>/dev/null
  [[ -n "$SERVERPID" ]] && kill "$SERVERPID" 2>/dev/null
  sleep 1
  [[ "${KEEP:-0}" == 1 ]] || rm -rf "$WORK"
}
trap cleanup EXIT

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product smthz >/dev/null || { echo "build smthz failed" >&2; exit 2; }
swift build --scratch-path "$SCRATCH" --product smthzd >/dev/null || { echo "build smthzd failed" >&2; exit 2; }
if [[ -z "$APP_SOURCE" ]]; then
  SMTHZ_SCRATCH_PATH="$SCRATCH" scripts/package-app.sh debug >/dev/null || { echo "package failed" >&2; exit 2; }
  APP_SOURCE="$ROOT/build/smthz.app"
fi
cp -R "$APP_SOURCE" "$APP"
CLI="$SCRATCH/debug/smthz"

# --- local site --------------------------------------------------------------------------------
cat > "$WORK/site/index.html" <<'HTML'
<!doctype html><html><head><title>E2E Page</title></head><body>
<h1>Hello smthz</h1>
<button id="btn" onclick="document.getElementById('out').textContent='clicked:'+event.isTrusted" ondblclick="document.getElementById('out2').textContent='dbl'">Press</button>
<div id="out"></div><div id="out2"></div>
<input id="name" placeholder="Your name">
<input id="cb" type="checkbox" aria-label="Agree">
<select id="sel" aria-label="Color"><option value="r">Red</option><option value="g">Green</option></select>
<input id="file" type="file" aria-label="Upload" onchange="document.getElementById('fileout').textContent=this.files[0].name+':'+this.files[0].size">
<div id="fileout"></div>
<div id="hov" onmouseover="this.textContent='hovered'">hover me</div>
<div id="src" draggable="true" ondragstart="event.dataTransfer.setData('text','x')">drag me</div>
<div id="dst" ondragover="event.preventDefault()" ondrop="this.textContent='dropped'">drop here</div>
<a id="dl" href="/download">Download</a>
<div style="height:4000px">tall</div><div id="bottom">bottom</div>
<script>
console.log('page-loaded 42'); console.warn('a warning');
setTimeout(() => { throw new Error('boom-uncaught'); }, 0);
fetch('/api').then((r) => r.json());
document.cookie = 'sc=visible';
document.getElementById('name').addEventListener('keydown', (e) => { window.lastKey = e.key + ':' + e.isTrusted; });
document.addEventListener('mousedown', (e) => { window.lastDown = e.clientX + ',' + e.clientY; });
</script></body></html>
HTML
echo '<!doctype html><title>Page Two</title><p>second</p>' > "$WORK/site/page2.html"
printf 'hello' > "$WORK/up.txt"
cat > "$WORK/server.py" <<'PY'
import base64, http.server, json, sys
root = sys.argv[2]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(self, *a): pass
    def send_body(self, body, ctype='text/html', extra=()):
        data = body.encode(); self.send_response(200); self.send_header('Content-Type', ctype)
        for k, v in extra: self.send_header(k, v)
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path == '/api': return self.send_body(json.dumps({'ok': True}), 'application/json')
        if self.path == '/echo-headers':
            return self.send_body(json.dumps({k.lower(): v for k, v in self.headers.items()}), 'application/json')
        if self.path == '/download':
            return self.send_body('downloaded-content', 'application/octet-stream', [('Content-Disposition', 'attachment; filename="file.txt"')])
        if self.path == '/auth':
            if self.headers.get('Authorization') == 'Basic ' + base64.b64encode(b'user:pass').decode():
                return self.send_body('<title>Authed</title>Authed')
            self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="e2e"'); self.end_headers(); return
        return super().do_GET()
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 -I "$WORK/server.py" "$PORT" "$WORK/site" & SERVERPID=$!

"$SCRATCH/debug/smthzd" --state-dir "$WORK/state" --socket "$SOCK" >"$WORK/host.log" 2>&1 & HOSTPID=$!
for _ in $(seq 50); do [[ -S "$SOCK" ]] && break; sleep 0.2; done
open -n --env SMTHZ_SOCKET="$SOCK" "$APP" --args -SmthzStateDirectory "$WORK/state"

# --- helpers -----------------------------------------------------------------------------------
PASS=0; FAIL=0; OUT=""
B() { OUT=$("$CLI" browser "$@" --socket "$SOCK" --json 2>&1); }
ok() { # ok <label> <jq filter that must yield true on $OUT>
  if [[ "$(jq -r "$2" <<<"$OUT" 2>/dev/null)" == "true" ]]; then PASS=$((PASS+1)); echo "PASS $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1: $(head -c 400 <<<"$OUT")"; fi
}
D='.result.data'
EVAL() { B eval --expression "$1"; }

for _ in $(seq 60); do B tab list; [[ "$OUT" == *'"ok":true'* || "$OUT" == *'"ok" : true'* ]] && break; sleep 0.5; done
ok "provider registered (tab list)" '.ok'

# --- A.3 rows ----------------------------------------------------------------------------------
B tab create --url "$BASE/index.html";       ok "load/goto (tab create)" "$D.title == \"E2E Page\""
PAGE=$(jq -r "$D.pageId" <<<"$OUT")
B goto --url "$BASE/index.html";             ok "goto" "$D.url == \"$BASE/index.html\""
sleep 0.5
B console;                                   ok "console capture" "[$D.entries[].text] | (any(test(\"page-loaded 42\")) and any(test(\"a warning\")) and any(test(\"boom-uncaught\")))"
B snapshot;                                  ok "snapshot refs" "$D.snapshot | test(\"button \\\"Press\\\" \\\\[ref=e\")"
REF=$(jq -r "$D.refs[] | select(.role==\"button\") | .ref" <<<"$OUT" | head -1)
B click --element "@$REF";                   ok "click by ref" "$D.command == \"click\""
TRUSTED=$(jq -r "$D.trusted" <<<"$OUT")
B get --what text --element '#out';          ok "click landed (trusted=$TRUSTED)" "$D.value | startswith(\"clicked:\")"
B dblclick --element '#btn';                 B get --what text --element '#out2'; ok "dblclick" "$D.value == \"dbl\""
B hover --element '#hov';                    B get --what text --element '#hov';  ok "hover" "$D.value == \"hovered\""
B focus --element '#name';                   B type --input hi; ok "type" "$D.trusted == true"
B get --what value --element '#name';        ok "type value" "$D.value == \"hi\""
EVAL 'window.lastKey';                       ok "type is trusted keydown" "$D.value == \"i:true\""
B inserttext --text " there";                B get --what value --element '#name'; ok "inserttext" "$D.value == \"hi there\""
B keypress --key Backspace;                  B get --what value --element '#name'; ok "keypress Backspace" "$D.value == \"hi ther\""
B fill --element '#name' --value filled;     B get --what value --element '#name'; ok "fill" "$D.value == \"filled\""
B select-all --element '#name';              EVAL 'document.activeElement.selectionEnd - document.activeElement.selectionStart'; ok "select-all" "$D.value == 6"
B clear --element '#name';                   B get --what value --element '#name'; ok "clear" "$D.value == \"\""
B select --element '#sel' --value g;         B get --what value --element '#sel'; ok "select" "$D.value == \"g\""
B check --element '#cb';                     B is --what checked --element '#cb'; ok "check" "$D.value == true"
B uncheck --element '#cb';                   B is --what checked --element '#cb'; ok "uncheck" "$D.value == false"
B is --what visible --element '#btn';        ok "is visible" "$D.value == true"
B drag --from '#src' --to '#dst';            B get --what text --element '#dst'; ok "drag" "$D.value == \"dropped\""
B mouse move --x 5 --y 5;                    B mouse down; B mouse up; EVAL 'window.lastDown'; ok "mouse move/down/up" "$D.value == \"5,5\""
B scroll --direction down --amount 300;      ok "scroll" "$D.command == \"scroll\""
EVAL 'scrollY';                              ok "scroll moved" "$D.value > 0"
B mouse wheel --dy 200;                      EVAL 'scrollY'; ok "mouse wheel" "$D.value > 0"
B scrollintoview --element '#bottom';        EVAL 'scrollY > 3000'; ok "scrollintoview" "$D.value == true"
B screenshot;                                ok "screenshot" "$D.width > 0 and $D.format == \"png\" and ($D.dataBase64 | startswith(\"iVBOR\"))"
VIEWH=$(jq -r "$D.height" <<<"$OUT")
B full-screenshot;                           ok "full-screenshot taller than viewport ($VIEWH)" "$D.height > $VIEWH * 2"
B pdf;                                       ok "pdf" "$D.byteCount > 0 and ($D.dataBase64 | startswith(\"JVBER\"))"
B eval --expression '(async () => ({ a: 40 + 2, t: document.title, f: (await (await fetch("/api")).json()).ok }))()'
ok "eval (async, page world)" "$D.value.a == 42 and $D.value.t == \"E2E Page\" and $D.value.f == true"
B network;                                   ok "network (document + fetch status)" "([$D.entries[] | select(.source==\"document\" and .status==200)] | length > 0) and ([$D.entries[] | select(.source==\"script\" and (.url|test(\"/api\")) and .status==200)] | length > 0)"
B capture start;                             ok "capture start" "$D.capturing == true"
B capture stop;                              ok "capture stop" "$D.capturing == false"
B cookie get;                                ok "cookie get (page cookie)" "[$D.cookies[].name] | index(\"sc\") != null"
B cookie set --name hc --value secret --httpOnly; B cookie get; ok "cookie set httpOnly" "[$D.cookies[] | select(.name==\"hc\" and .httpOnly)] | length == 1"
EVAL 'document.cookie';                      ok "httpOnly hidden from page" "($D.value | test(\"hc=\")) == false"
B cookie delete --name hc;                   B cookie get; ok "cookie delete" "[$D.cookies[].name] | index(\"hc\") == null"
B storage local set --key k --value v;       B storage local get --key k; ok "localStorage set/get" "$D.value == \"v\""
B storage local clear;                       B storage local get --key k; ok "localStorage clear" "$D.value == null"
B storage session set --key s --value 1;     B storage session get --key s; ok "sessionStorage" "$D.value == \"1\""
EVAL 'setTimeout(() => { window.c = confirm("ok?"); window.p = prompt("name?", "d"); }, 0); 1'
sleep 0.5; B dialog accept;                  ok "dialog accept (confirm)" '.ok'
sleep 0.5; B dialog accept --text typed-answer; ok "dialog accept (prompt)" '.ok'
EVAL '[window.c, window.p]';                 ok "dialog values" "$D.value == [true, \"typed-answer\"]"
EVAL 'setTimeout(() => { window.c2 = confirm("no?"); }, 0); 1'
sleep 0.5; B dialog dismiss;                 EVAL 'window.c2'; ok "dialog dismiss" "$D.value == false"
B download --selector '#dl' --path "$WORK/dl.txt"; ok "download" '.ok'
[[ "$(cat "$WORK/dl.txt" 2>/dev/null)" == "downloaded-content" ]] && { PASS=$((PASS+1)); echo "PASS download content"; } || { FAIL=$((FAIL+1)); echo "FAIL download content"; }
B upload --element '#file' --files "$WORK/up.txt"; B get --what text --element '#fileout'; ok "upload" "$D.value == \"up.txt:5\""
B find --locator text --value 'Hello smthz' --action text; ok "find (semantic locator)" "$D.value == \"Hello smthz\""
B find --locator placeholder --value 'Your name' --action fill --text viaFind; B get --what value --element '#name'; ok "find fill" "$D.value == \"viaFind\""
B highlight --selector '#btn';               ok "highlight" '.ok'
B viewport --width 400 --height 700;         EVAL 'innerWidth'; ok "viewport width" "$D.value == 400"
B set device --name 'iPhone 14';             ok "set device (partial)" "$D.width == 390 and ($D.ignored | index(\"touch\") != null)"
EVAL 'navigator.userAgent';                  ok "device user agent" "$D.value | test(\"iPhone\")"
B set device --name Desktop
B set media --color-scheme dark;             EVAL 'matchMedia("(prefers-color-scheme: dark)").matches'; ok "set media color scheme" "$D.value == true"
B set media --reduced-motion reduce;         EVAL 'matchMedia("(prefers-reduced-motion: reduce)").matches'; ok "set media reduced motion (shim)" "$D.value == true"
B geolocation --latitude 40.4 --longitude -3.7
EVAL 'new Promise((r) => navigator.geolocation.getCurrentPosition((p) => r(p.coords.latitude + "," + p.coords.longitude)))'; ok "geolocation (shim)" "$D.value == \"40.4,-3.7\""
B set offline --state on;                    EVAL 'fetch("/api").then(() => "online", () => "failed").then((s) => s + ":" + navigator.onLine)'; ok "set offline" "$D.value == \"failed:false\""
B set offline --state off;                   EVAL 'fetch("/api").then(() => "online", () => "failed")'; ok "set offline off" "$D.value == \"online\""
B intercept enable --patterns '*/api*';      ok "intercept enable" "$D.enabled == true"
EVAL 'fetch("/api").then(() => { window.released = true; }); 1'; sleep 0.3
B intercept list;                            ok "intercept list (paused fetch)" "[$D.requests[] | select(.url|test(\"/api\"))] | length == 1"
B intercept disable;                         sleep 0.3; EVAL 'window.released === true'; ok "intercept disable releases" "$D.value == true"
B set headers --headers '{"X-E2E":"yes"}';   EVAL 'fetch("/echo-headers").then((r) => r.json()).then((h) => h["x-e2e"])'; ok "set headers (fetch)" "$D.value == \"yes\""
B goto --url "$BASE/echo-headers";           EVAL 'document.body.innerText'; ok "set headers (top-level)" "$D.value | test(\"x-e2e\")"
B set headers --headers '{"X-E2E":""}'
B set credentials --user user --pass pass;  B goto --url "$BASE/auth"; ok "set credentials (HTTP auth)" "$D.title == \"Authed\""
B goto --url "$BASE/index.html"
B goto --url "$BASE/page2.html";             B back; ok "back" "$D.url == \"$BASE/index.html\""
B forward;                                   ok "forward" "$D.url == \"$BASE/page2.html\""
B reload;                                    ok "reload" "$D.title == \"Page Two\""
EVAL 'setTimeout(() => { const d = document.createElement("div"); d.id = "late"; d.textContent = "late"; document.body.append(d); }, 300); 1'
B wait --selector '#late' --timeout 3000;    ok "wait selector" "$D.value == true"
B wait --text late --timeout 3000;           ok "wait text" "$D.value == true"
B get --what title;                          ok "get title" "$D.value == \"Page Two\""
B identity set --mode clean;                 ok "identity set" "$D.appliedMode == \"clean\""
EVAL 'navigator.userAgent';                  ok "identity clean UA" "$D.value | test(\"Safari/\")"
B identity set --mode native --reset;        B identity get; ok "identity get/reset" "$D.configuredMode == null"
ORIG_CLIP=$(pbpaste 2>/dev/null)
B clipboard write --text e2e-clip;           B clipboard read; ok "clipboard" "$D.value == \"e2e-clip\""
printf '%s' "$ORIG_CLIP" | pbcopy
EVAL 'window.open("/page2.html"); 1';        sleep 1; B tab list; ok "popup opens tab" "$D.tabs | length >= 2"
B tab switch --index 0;                      ok "tab switch" "$D.index == 0"
# Native pointer path (R-B1): only when smthz is active and the tab is shown in the key window.
open "$APP"; sleep 1; B tab switch --page "$PAGE" --focus; sleep 1
B goto --url "$BASE/index.html"; B click --element '#btn'; NATIVE=$(jq -r "$D.trusted" <<<"$OUT")
B get --what text --element '#out'; ok "click with app active (trusted=$NATIVE)" "$D.value == \"clicked:$NATIVE\""
B tab current;                               ok "tab current" "$D.pageId == \"$PAGE\""
B tab show --page "$PAGE";                   ok "tab show" "$D.pageId == \"$PAGE\""
B tab profile list; ok "profile list" "[$D.profiles[].id] | index(\"default\") != null"
B tab profile create --label e2e;            ok "profile create" "$D.profile.label == \"e2e\""
PROFILE=$(jq -r "$D.profile.id" <<<"$OUT")
B tab create --url "$BASE/page2.html" --profile "$PROFILE"; PAGE2=$(jq -r "$D.pageId" <<<"$OUT")
B cookie get --page "$PAGE2";                ok "profile isolation (no sc cookie)" "[$D.cookies[].name] | index(\"sc\") == null"
B tab profile show --page "$PAGE2";          ok "profile show" "$D.profile.id == \"$PROFILE\""
B tab profile clone --page "$PAGE" --profile "$PROFILE"; ok "profile clone copies cookies" "$D.cookiesCopied >= 1"
CLONE=$(jq -r "$D.pageId" <<<"$OUT")
B tab close --page "$CLONE"
B tab profile delete --profile "$PROFILE";   ok "profile delete deferred while in use" "$D.deleted == true and $D.deferred == true"
B tab close --page "$PAGE2";                 ok "tab close" '.ok'
B exec --command 'snapshot';                 ok "exec unsupported (R-B9)" '(.ok | not) and (tostring | test("unsupported"))'

echo "browser-e2e: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
