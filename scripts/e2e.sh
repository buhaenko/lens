#!/bin/zsh
# End-to-end + crash test of the real, built app.
# Runs a renamed copy (com.serhii.Lensy.e2e, its own settings and history) next to the real Lensy, in test mode:
# no global keys, no permission prompts, no windows, no update checks. Its menu bar icon shows up for a moment.
#
#   scripts/e2e.sh            (builds first if build/Lensy.app is missing)
set -u
cd "${0:A:h}/.."
[[ -d build/Lensy.app ]] || scripts/build.sh e2e >/dev/null

ID=com.serhii.Lensy.e2e; NAME=LensyE2E
T=$(mktemp -d); APP=$T/$NAME.app; LOG=$T/app.log
SUPPORT="$HOME/Library/Application Support/$NAME"
REPORTS=~/Library/Logs/DiagnosticReports
ok=0; bad=0; PID=""
check() { if eval "$2"; then echo "  ✓ $1"; ok=$((ok+1)); else echo "  ✗ $1"; bad=$((bad+1)); fi }
cleanup() {
  [[ -n "$PID" ]] && kill $PID 2>/dev/null
  pkill -f "$APP/Contents/MacOS/Lensy" 2>/dev/null
  defaults delete $ID >/dev/null 2>&1; rm -rf "$SUPPORT" $T
}
trap cleanup EXIT

cp -R build/Lensy.app $APP
plutil -replace CFBundleIdentifier -string $ID $APP/Contents/Info.plist
plutil -replace CFBundleName -string $NAME $APP/Contents/Info.plist
codesign --force -s - $APP 2>/dev/null
defaults write $ID onboarded -bool true
marker=$T/started; touch $marker; sleep 1

launch() { LENSY_E2E=1 $APP/Contents/MacOS/Lensy >>$LOG 2>&1 & PID=$!; }
alive() { kill -0 $PID 2>/dev/null; }
stop() { kill $PID 2>/dev/null; for _ in {1..50}; do alive || break; sleep 0.1; done; ! alive; }
crashes() { find $REPORTS -maxdepth 1 \( -name "Lensy*" -o -name "$NAME*" \) -newer $marker 2>/dev/null | wc -l | tr -d ' '; }

echo "▸ launch"
launch; sleep 4
check "starts and keeps running" 'alive'
check "says hello in the log" 'grep -q "Lensy: launched" $LOG'
rss=$(ps -o rss= -p $PID | tr -d ' '); mb=$((rss / 1024))
check "uses little memory at rest (${mb} MB < 150)" '[[ $mb -lt 150 ]]'
cpu=$(ps -o %cpu= -p $PID | tr -d ' '); sleep 3; cpu=$(ps -o %cpu= -p $PID | tr -d ' ')
check "idles at ~0% CPU (${cpu}%)" '(( ${cpu%.*} < 5 ))'

echo "▸ single instance"
LENSY_E2E=1 $APP/Contents/MacOS/Lensy >>$LOG 2>&1 & second=$!
for _ in {1..50}; do kill -0 $second 2>/dev/null || break; sleep 0.1; done
check "a second copy quits right away" '! kill -0 $second 2>/dev/null'
sleep 0.5
check "and asks the running one to open instead" 'grep -q "Lensy: asked to open" $LOG'
check "the first one is still running" 'alive'

echo "▸ quit"
check "quits cleanly on SIGTERM" 'stop'

echo "▸ broken data on disk"
mkdir -p "$SUPPORT"; head -c 50000 /dev/urandom > "$SUPPORT/history.json"
defaults write $ID languages -int 42
defaults write $ID hotKeyCode -string "not a number"
defaults write $ID menuBarIcon -string "no-such-icon"
defaults write $ID historyLimit -int -5
defaults write $ID tapKey -string "🙂"
defaults write $ID lastUpdateCheck -string "yesterday"
launch; sleep 4
check "starts with a corrupted history and nonsense settings" 'alive'
stop >/dev/null

echo "▸ hammering"
for i in {1..12}; do launch; sleep $((RANDOM % 8 / 10.0 + 0.2)); kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null; done
launch; sleep 3
check "12 hard kills mid-start, then starts fine" 'alive'
for i in {1..10}; do kill -STOP $PID; sleep 0.1; kill -CONT $PID; done
sleep 1
check "survives being frozen and resumed 10×" 'alive'
stop >/dev/null

echo "▸ crash reports"
check "macOS recorded no Lensy crash during the run" '[[ $(crashes) -eq 0 ]]'
if grep -qiE "fatal error|assertion|EXC_|Thread .* Crashed" $LOG; then echo "  ✗ the log mentions a crash:"; grep -iE "fatal error|assertion|EXC_" $LOG | head -3; bad=$((bad+1)); else echo "  ✓ no crash or assertion in the log"; ok=$((ok+1)); fi

echo "\ne2e: $ok passed, $bad failed"; [[ $bad -eq 0 ]]
