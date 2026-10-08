package local.ppuhook;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Neutralises the ROM's built-in PixelPropsUtils inside Play Store and Play Services only.
 * The ROM throws from onEngineGetCertificateChain() for Finsky (always) and for DroidGuard,
 * which breaks Play Integrity key attestation, and setProps() overrides PIF's spoofed props.
 */
public class Hook implements IXposedHookLoadPackage {
    private static final String PPU = "com.android.internal.util.custom.PixelPropsUtils";
    private static boolean hooked;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (hooked) return;
        if (!"com.android.vending".equals(lpparam.packageName)
                && !"com.google.android.gms".equals(lpparam.packageName)) return;
        Class<?> ppu = XposedHelpers.findClassIfExists(PPU, null);
        if (ppu == null) {
            XposedBridge.log("PPUHook: " + PPU + " not found in " + lpparam.processName);
            return;
        }
        XposedHelpers.findAndHookMethod(ppu, "onEngineGetCertificateChain", XC_MethodReplacement.DO_NOTHING);
        XposedHelpers.findAndHookMethod(ppu, "setProps", String.class, XC_MethodReplacement.DO_NOTHING);
        hooked = true;
        XposedBridge.log("PPUHook: PixelPropsUtils disabled in " + lpparam.processName);
    }
}
