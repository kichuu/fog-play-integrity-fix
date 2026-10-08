# Framework patch (abandoned — don't use)

`patch_ppu.py` patches `framework.jar` in place: the first instruction of `PixelPropsUtils.setProps()` and
`onEngineGetCertificateChain()` becomes `return-void; nop`, then the dex checksum/SHA-1 and zip CRC are fixed.
It was loaded systemlessly via a Magisk module (`system/framework/framework.jar`, plus blanked
`boot-framework.{art,oat,vdex}`), the same mechanism as FrameworkPatcherGO.

It **did** get all three integrity verdicts green, but this ROM is odexed: system apps, `services.odex` and
shared libraries like `org.apache.http.legacy.odex` are precompiled against the original framework. With a
changed `framework.jar` those crashed with `SIGBUS ... fault addr 0x5` / `SIGSEGV` (Play Services' `gapps`,
Truecaller, Play Store). Recompiling user apps (`cmd package compile -a -f -m verify`) fixed most but not the
system-side code. Replaced by the in-memory Vector hook in `../../hook`.

If you ever remove a framework patch like this: run `cmd package compile -a -f -m verify` afterwards, because
apps compiled against the patched framework crash on the original one.

usage: `python3 patch_ppu.py framework.jar framework-patched.jar`
