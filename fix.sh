#!/usr/bin/env bash
# Play Integrity maintenance for the Redmi 10C (fog) custom-ROM phone.
#
# Run from the PC with the phone plugged in, USB debugging on and Magisk root granted to shell.
#
#   ./fix.sh                    check everything, repair what's broken, restart Play Store/Services
#   ./fix.sh --status           only report, change nothing
#   ./fix.sh --force-keybox     fetch a fresh keybox even if the current one isn't revoked
#   ./fix.sh --force-fingerprint  refresh the Pixel Canary fingerprint even if it's recent
#   ./fix.sh --reboot           reboot at the end instead of just restarting Play Store/Services
#
# Afterwards: run "Play Integrity API Checker" on the phone, then turn Developer options OFF (GPay needs that).
set -uo pipefail
cd "$(dirname "$0")"

STATUS_ONLY=0 FORCE_KB=0 FORCE_FP=0 REBOOT=0
for a in "$@"; do
  case "$a" in
    --status) STATUS_ONLY=1 ;;
    --force-keybox) FORCE_KB=1 ;;
    --force-fingerprint) FORCE_FP=1 ;;
    --reboot) REBOOT=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

FP_MAX_AGE_DAYS=30
PIF=/data/adb/modules/playintegrityfix          # Integrity Box (Play Integrity Fix fork)
TS=/data/adb/tricky_store
VECTOR_CLI=/data/adb/modules/zygisk_vector/cli  # Vector (LSPosed)
HOOK_PKG=local.ppuhook

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
# run a root shell script on the phone (script on stdin)
rsh()  { adb shell 'su -c sh'; }
CHANGED=0

hdr "Device"
state=$(adb get-state 2>/dev/null) || { bad "no device - plug in the phone and turn on USB debugging"; exit 1; }
[ "$state" = device ] || { bad "adb state: $state (accept the USB debugging prompt on the phone)"; exit 1; }
[ "$(echo 'id -u' | rsh | tr -d '\r')" = 0 ] || { bad "no root - grant Shell superuser access in Magisk"; exit 1; }
ok "$(adb shell getprop ro.product.model | tr -d '\r') ($(adb shell getprop ro.product.device | tr -d '\r')), Android $(adb shell getprop ro.build.version.release | tr -d '\r'), root ok"

hdr "Modules"
rsh <<EOF
for m in zygisksu playintegrityfix tricky_store zygisk_vector Yurikey pixelprops_off; do
  d=/data/adb/modules/\$m
  if [ ! -d \$d ]; then s="not installed"
  elif [ -f \$d/remove ]; then s="pending removal"
  elif [ -f \$d/disable ]; then s="disabled"
  else s="enabled \$(grep '^version=' \$d/module.prop | cut -d= -f2)"; fi
  echo "    \$m: \$s"
done
echo "    magisk built-in zygisk: \$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" | cut -d= -f2)"
EOF

hdr "Config drift"
drift=$(rsh <<'EOF'
[ "$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" | cut -d= -f2)" = 0 ] || echo zygisk
[ -d /data/adb/modules/Yurikey ] && [ ! -f /data/adb/modules/Yurikey/disable ] && echo yurikey
true
EOF
)
if [ -z "$drift" ]; then ok "Magisk built-in Zygisk off, Yurikey disabled"
else
  for d in $drift; do
    case $d in
      zygisk)  bad "Magisk built-in Zygisk is ON (conflicts with Zygisk Next)" ;;
      yurikey) bad "Yurikey is enabled (its keybox server is dead; it can overwrite the keybox)" ;;
    esac
  done
  if [ $STATUS_ONLY = 0 ]; then
    rsh <<'EOF'
magisk --sqlite "UPDATE settings SET value=0 WHERE key='zygisk'"
[ -d /data/adb/modules/Yurikey ] && touch /data/adb/modules/Yurikey/disable
true
EOF
    ok "fixed (takes effect after reboot)"; REBOOT=1; CHANGED=1
  fi
fi

hdr "Keybox"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
adb exec-out su -c "cat $TS/keybox.xml" > "$tmp/keybox.xml" 2>/dev/null
python3 -I lib/keybox_check.py "$tmp/keybox.xml"; kb=$?
if [ $kb = 0 ] && [ $FORCE_KB = 0 ]; then ok "keybox is not revoked"
else
  [ $kb = 0 ] || bad "keybox is revoked or unreadable"
  if [ $STATUS_ONLY = 0 ]; then
    echo "  fetching a new keybox via Integrity Box..."
    echo "sh $PIF/webroot/common_scripts/key.sh" | rsh | sed 's/^/    /'
    adb exec-out su -c "cat $TS/keybox.xml" > "$tmp/keybox.xml"
    if python3 -I lib/keybox_check.py "$tmp/keybox.xml"; then ok "new keybox installed and not revoked"; CHANGED=1
    else bad "Integrity Box's current keybox is revoked too - wait for them to publish a new one, or find another source"; fi
  fi
fi
rm -f "$tmp/keybox.xml"

hdr "Fingerprint"
read -r fp_age fp_print <<<"$(rsh <<EOF
echo \$(( (\$(date +%s) - \$(stat -c %Y $PIF/custom.pif.prop)) / 86400 )) \$(grep '^FINGERPRINT=' $PIF/custom.pif.prop | cut -d= -f2)
EOF
)"
echo "    $fp_print (set $fp_age days ago)"
if [ "$fp_age" -le $FP_MAX_AGE_DAYS ] && [ $FORCE_FP = 0 ]; then ok "fingerprint is recent"
else
  [ "$fp_age" -le $FP_MAX_AGE_DAYS ] || warn "fingerprint older than $FP_MAX_AGE_DAYS days (Canary prints expire ~monthly)"
  if [ $STATUS_ONLY = 0 ]; then
    echo "cd $PIF && sh osm0sis.sh" | rsh | grep -E 'Using|Found|Released|Expiry|rror|ailed' | sed 's/^/    /'
    ok "fingerprint refreshed: $(echo "grep '^FINGERPRINT=' $PIF/custom.pif.prop | cut -d= -f2" | rsh)"; CHANGED=1
  fi
fi

hdr "PPU Hook (disables the ROM's PixelPropsUtils in Play Store + Play Services)"
if ! adb shell pm path $HOOK_PKG >/dev/null 2>&1; then
  bad "$HOOK_PKG is not installed"
  if [ $STATUS_ONLY = 0 ]; then
    [ -f hook/out/ppuhook.apk ] || ./hook/build.sh
    adb install -r hook/out/ppuhook.apk && CHANGED=1
  fi
else ok "$HOOK_PKG installed"; fi
if echo "[ -f $VECTOR_CLI ]" | rsh; then
  hook_state=$(echo "sh $VECTOR_CLI modules ls" | rsh | awk -v p=$HOOK_PKG '$1==p{print $3}')
  scope=$(echo "sh $VECTOR_CLI scope ls $HOOK_PKG" | rsh | awk 'NR>2{print $1}' | sort | tr '\n' ' ')
  if [ "$hook_state" = enabled ] && [ "$scope" = "com.android.vending com.google.android.gms " ]; then
    ok "enabled in Vector, scope: $scope"
  else
    bad "Vector: state=${hook_state:-missing}, scope='${scope}'"
    if [ $STATUS_ONLY = 0 ]; then
      rsh <<EOF | sed 's/^/    /'
sh $VECTOR_CLI scope set $HOOK_PKG com.android.vending/0 com.google.android.gms/0
sh $VECTOR_CLI modules enable $HOOK_PKG
EOF
      CHANGED=1
    fi
  fi
else bad "Vector (LSPosed) is not installed - see README"; fi

[ $STATUS_ONLY = 1 ] && { echo; echo "Status only - nothing changed."; exit 0; }

hdr "Apply"
if [ $REBOOT = 1 ]; then
  echo "  rebooting..."; adb reboot; adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
  ok "rebooted"
elif [ $CHANGED = 1 ]; then
  echo "am force-stop com.android.vending; killall com.google.android.gms.unstable 2>/dev/null; true" | rsh
  ok "restarted Play Store and Play Integrity service"
else ok "nothing needed fixing"; fi

cat <<'EOF'

Next on the phone:
  1. Open "Play Integrity API Checker" -> CHECK (want Basic + Device, Strong is a bonus)
  2. Turn Developer options OFF, then open GPay / PhonePe
EOF
