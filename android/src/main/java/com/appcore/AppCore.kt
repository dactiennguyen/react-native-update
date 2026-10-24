package com.appcore

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.appcore.Common.CURRENT_VERSION_CODE
import com.appcore.Common.DEFAULT_BUNDLE
import com.appcore.Common.PATH
import com.appcore.Common.VERSION


class AppCore : BaseReactPackage() {
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
    return if (name == AppCoreModule.NAME) {
      AppCoreModule(reactContext)
    } else {
      null
    }
  }

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider {
    return ReactModuleInfoProvider {
      val moduleInfos: MutableMap<String, ReactModuleInfo> = HashMap()
      val isTurboModule: Boolean = BuildConfig.IS_NEW_ARCHITECTURE_ENABLED
      moduleInfos[AppCoreModule.NAME] = ReactModuleInfo(
        AppCoreModule.NAME,
        AppCoreModule.NAME,
        false,  // canOverrideExistingModule
        false,  // needsEagerInit
        false,  // isCxxModule
        isTurboModule // isTurboModule
      )
      moduleInfos
    }
  }
  companion object {
    fun Context.getVersionCode(): String {
      return when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
          packageManager.getPackageInfo(
            packageName,
            PackageManager.PackageInfoFlags.of(0)
          ).longVersionCode.toString()
        }
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> {
          @Suppress("DEPRECATION")
          packageManager.getPackageInfo(packageName, 0).longVersionCode.toString()
        }
        else -> {
          @Suppress("DEPRECATION")
          packageManager.getPackageInfo(packageName, 0).versionCode.toString()
        }
      }
    }
    fun bundleJS(context: Context, isHandleCrash: Boolean = true): String {
      if (isHandleCrash) {
        Thread.setDefaultUncaughtExceptionHandler(CrashHandler(context))
      }
      LegacyCleanup.start(context)
      val sharedPrefs = SharedPrefs(context)
      val pathBundle = sharedPrefs.getString(PATH)
      val version = sharedPrefs.getString(VERSION)
      val currentVersionName = sharedPrefs.getString(CURRENT_VERSION_CODE)
      val hasBundlePath = !pathBundle.isNullOrBlank()
      val isSameAppVersion = currentVersionName == context.getVersionCode()
      val bundleFileExists = hasBundlePath && File(pathBundle!!).isFile

      if (!hasBundlePath || !isSameAppVersion || !bundleFileExists) {
        if (pathBundle != "") {
          sharedPrefs.putString(PATH, "")
        }
        if (version != "") {
          // reset version number because bundle is wrong version, need download from new version
          sharedPrefs.putString(VERSION, "")
        }
        return DEFAULT_BUNDLE
      }
      return pathBundle!!
    }
  }
}
