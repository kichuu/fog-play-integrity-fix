# fog-play-integrity-fix

Getting GPay / PhonePe working again on a rooted Redmi 10C (`fog`) running an old (Jan 2023) Android 13 custom ROM.

## TL;DR — next time it breaks

Turn on Developer options + USB debugging, plug in the phone, then:

```bash
./fix.sh --status   # see what's wrong, change nothing
./fix.sh            # fix it (new keybox if revoked, fresh fingerprint if old, config drift, hook)
```

Then on the phone: **Play Integrity API Checker → CHECK**, turn **Developer options OFF**, open GPay.

Most of the time the cause is that the leaked keybox got revoked by Google — `fix.sh` detects that and pulls a new one through Integrity Box.

## What was wrong (Oct 2026)

Three separate problems, all needed fixing:

1. **Revoked keybox.** Tricky Store's `keybox.xml` (and the backup) were on Google's
   [revocation list](https://android.googleapis.com/attestation/status). Leaked keyboxes get revoked every few weeks.
2. **Module mess.** Magisk's built-in Zygisk was on alongside Zygisk Next (conflict), and Yurikey
   (keybox server now 404) was installed next to Integrity Box — both manage the keybox.
3. **The ROM itself blocks key attestation.** This was the real blocker. The ROM ships
   `com.android.internal.util.custom.PixelPropsUtils`, decompiled from `/system/framework/framework.jar`:

   ```java
   public static void onEngineGetCertificateChain() {
       if (sIsGms && isCallerSafetyNet()) throw new UnsupportedOperationException();
       if (sIsFinsky) throw new UnsupportedOperationException();   // Play Store: always
   }
   ```

   That was a common 2023 trick to force basic attestation. Since Google's 2025 Play Integrity changes,
   it makes the Play Store fail key attestation (`Finsky: integrity key attestation record generation failed`)
   and **every verdict comes back UNEVALUATED** — all three checks red. It is hardcoded: this ROM version reads
   none of the `persist.sys.pihooks.*` / `persist.sys.pixelprops.*` opt-out props that newer ROMs (and
   PlayIntegrityFork's workaround) use. `setProps()` also overrides the Play Services integrity process
   fingerprint with an old Nexus 6P one.

## The fix

| Piece | What | Where |
|---|---|---|
| Tricky Store | uses a non-revoked keybox | `/data/adb/tricky_store/keybox.xml` (fetched by Integrity Box) |
| Integrity Box v42 | Play Integrity Fix fork, Pixel Canary fingerprint | `/data/adb/modules/playintegrityfix` |
| Zygisk Next | Zygisk implementation (Magisk's built-in Zygisk **off**) | module `zygisksu` |
| [Vector v2.2](https://github.com/JingMatrix/Vector) (LSPosed) | in-memory hooking framework | module `zygisk_vector` |
| **PPU Hook** (this repo) | no-ops `PixelPropsUtils.onEngineGetCertificateChain()` and `setProps()` | app `local.ppuhook`, scope: Play Store + Play Services only |

The hook only runs inside `com.android.vending` and `com.google.android.gms`; nothing on `/system` is modified.
Logcat shows `PPUHook: PixelPropsUtils disabled in …` when it's active.

### Installing from scratch

1. Magisk + Zygisk Next + Tricky Store + Integrity Box (and turn Magisk's own Zygisk off).
2. Vector: download the Release zip from [Vector releases](https://github.com/JingMatrix/Vector/releases)
   (v2.2 = `Vector-v2.2-3080-Release.zip`, sha256 `9ee8323575d615f7b3f1076ff60b2a63a49390ef11881b52632311a37f6f79cc`),
   `adb push` it and `su -c magisk --install-module /data/local/tmp/<zip>`, reboot.
3. `./fix.sh` — builds/installs the hook, enables it in Vector with the right scope, checks keybox + fingerprint.

## Repo layout

```
fix.sh                 maintenance script (status / repair)
lib/keybox_check.py    checks a keybox.xml against Google's revocation list
hook/                  PPU Hook Xposed module (legacy Xposed API, built without Gradle)
  build.sh             javac + d8 + aapt2 + apksigner -> hook/out/ppuhook.apk
  src/                 the hook
  stubs/               compile-only Xposed API stubs (Vector provides the real ones)
  key.jks              signing key — gitignored, keep a backup (updates must use the same key)
archive/framework-patch/   first attempt (patched framework.jar) — DON'T USE, see its README
```

## Gotchas

- **GPay refuses to work with Developer options on.** Turn them off after using adb.
- **Integrity Box per-app spoofing** makes PhonePe/GPay see the phone as a "Pixel 7a"
  (`/data/adb/modules/playintegrityfix/apps.txt`). It works right now; if a payment app starts closing itself
  or failing device binding, try removing it from that list (may trigger re-verification in the app).
- **Updating/changing the ROM:** disable PPU Hook first. A newer ROM with a spoofing toggle won't need it.
- **Long-term:** the only fix that doesn't depend on leaked keyboxes is stock firmware + locked bootloader.

## Debugging commands

```bash
adb logcat -d | grep -E "PPUHook|PixelPropsUtils|IntegrityKeyAttestation"   # hook active? ROM still blocking?
adb logcat -d -b crash | grep -E "Fatal signal"                               # native crashes
adb shell su -c 'sh /data/adb/modules/zygisk_vector/cli modules ls'           # Vector modules
adb shell su -c 'sh /data/adb/modules/zygisk_vector/cli scope ls local.ppuhook'
```
