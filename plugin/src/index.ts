import {
  withMainApplication,
  withAppDelegate,
  IOSConfig,
} from '@expo/config-plugins';

// Rest of an import line: optional `;`, then an optional trailing comment.
const END_OF_IMPORT = String.raw`(?=[ \t]*;?[ \t]*(?:\/\/.*|\/\*.*)?\r?$)`;
const importLine = (prefix: string, name: string) =>
  new RegExp(String.raw`^([ \t]*${prefix})${name}${END_OF_IMPORT}`, 'gm');

/**
 * Projects prebuilt with the previous package name (react-native-ota-hot-update) already contain
 * its import and bundle call. Rename them first so the checks below see them as already applied
 * instead of injecting a second copy next to the old one. Only imports of the old module and
 * calls on it are touched, so an app or package that happens to use the old name keeps it.
 */
const migrateLegacyNames = (contents: string): string =>
  contents
    // Kotlin
    .replace(importLine(String.raw`import[ \t]+`, String.raw`com\.otahotupdate\.OtaHotUpdate`), '$1com.appcore.AppCore')
    .replace(/\b(?:com\.otahotupdate\.)?OtaHotUpdate\s*\.\s*bundleJS\s*\(/g, 'AppCore.bundleJS(')
    // Swift (attributes such as @preconcurrency may precede the import)
    .replace(importLine(String.raw`(?:@\w+[ \t]+)*import[ \t]+`, 'react_native_ota_hot_update'), '$1react_native_app_core')
    .replace(/\b(?:react_native_ota_hot_update\s*\.\s*)?OtaHotUpdate\s*\.\s*getBundle\s*\(\s*\)/g, 'AppCore.getBundle()')
    // Objective-C
    .replace(importLine(String.raw`#[ \t]*(?:import|include)[ \t]*`, '"OtaHotUpdate\\.h"'), '$1"AppCore.h"')
    .replace(importLine(String.raw`#[ \t]*(?:import|include)[ \t]*`, '<OtaHotUpdate\\.h>'), '$1<AppCore.h>')
    .replace(
      importLine(String.raw`#[ \t]*(?:import|include)[ \t]*`, '<react_native_ota_hot_update\\/OtaHotUpdate\\.h>'),
      '$1<react_native_app_core/AppCore.h>'
    )
    .replace(importLine(String.raw`@import[ \t]+`, 'react_native_ota_hot_update'), '$1react_native_app_core')
    .replace(/\[\s*OtaHotUpdate\s+getBundle\s*\]/g, '[AppCore getBundle]');

const OBJC_IMPORT = /^[ \t]*(?:#[ \t]*(?:import|include)[ \t]*["<](?:react_native_app_core\/)?AppCore\.h[">]|@import[ \t]+react_native_app_core\b)/m;
const SWIFT_IMPORT = /^[ \t]*(?:@\w+[ \t]+)*import[ \t]+react_native_app_core\b/m;
const KOTLIN_IMPORT = /^[ \t]*import[ \t]+com\.appcore\.AppCore\b/m;

const withAndroidAction: any = (config: any) => {
  return withMainApplication(config, (config) => {
    let content = migrateLegacyNames(config.modResults.contents);

    const isNewReactHost = content.includes('context = applicationContext');

    if (!KOTLIN_IMPORT.test(content)) {
      content = content.replace(
        /import android.app.Application/g,
        `
import android.app.Application
import com.appcore.AppCore`
      );
    }
    if (isNewReactHost) {
      if (!content.includes('AppCore.bundleJS')) {
        content = content.replace(
          /context = applicationContext,/,
          `context = applicationContext,
      jsBundleFilePath = AppCore.bundleJS(applicationContext),`
        );
      }

      config.modResults.contents = content;
      return config;
    }

    if (!content.includes('AppCore.bundleJS(this@MainApplication)')) {
      content = content.replace(
        /DefaultReactNativeHost\s*\(this\)\s*\{/,
        `
          DefaultReactNativeHost(this) {

          override fun getJSBundleFile(): String = AppCore.bundleJS(this@MainApplication)`
      );
    }

    config.modResults.contents = content;
    return config;
  });
};

const withIosAction: any = (config: any) => {
  return withAppDelegate(config, (config) => {
    const appDelegatePath = config.modRequest.projectRoot + '/ios/' + IOSConfig.Paths.getAppDelegateFilePath(config.modRequest.projectRoot);
    const isSwift = appDelegatePath.endsWith('.swift');
    config.modResults.contents = migrateLegacyNames(config.modResults.contents);

    if (isSwift) {
      // Swift: AppDelegate.swift
      if (!SWIFT_IMPORT.test(config.modResults.contents)) {
        config.modResults.contents = `import react_native_app_core\n${config.modResults.contents}`;
      }

      if (!config.modResults.contents.includes('AppCore.getBundle()')) {
        config.modResults.contents = config.modResults.contents.replace(
          /return Bundle.main.url\(forResource: "main", withExtension: "jsbundle"\)/,
          `return AppCore.getBundle()`
        );
      }
    } else {
      // Objective-C: AppDelegate.mm
      if (!OBJC_IMPORT.test(config.modResults.contents)) {
        config.modResults.contents = config.modResults.contents.replace(
          /#import "AppDelegate.h"/g,
          `#import "AppDelegate.h"
#import "AppCore.h"`
        );
      }

      config.modResults.contents = config.modResults.contents.replace(
        /\[\[NSBundle mainBundle\] URLForResource:@\"main\" withExtension:@\"jsbundle\"\]/,
        `[AppCore getBundle]`
      );
    }

    return config;
  });
};

const withAction: any = (config: any) => {
  config = withAndroidAction(config);
  config = withIosAction(config);
  return config;
};

module.exports = withAction;
