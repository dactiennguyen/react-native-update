#import "AppCore.h"
#import <SSZipArchive/SSZipArchive.h>
#include <signal.h>

@interface AppCore ()
- (NSArray *)loadBundleHistory;
- (void)saveBundleHistory:(NSArray *)history;
- (void)saveBundleVersion:(NSString *)path version:(NSInteger)version maxVersions:(NSInteger)maxVersions metadata:(NSString *)metadata;
- (NSString *)extractFolderName:(NSString *)path;
@end

static NSUncaughtExceptionHandler *previousHandler = NULL;
static BOOL isBeginning = YES;
// An uncaught NSException is followed by abort() -> SIGABRT, so both handlers can run for one
// crash. Only the first may roll back; the second would find PREVIOUS_BUNDLE_PATH already
// consumed and clear the rolled-back PATH, dropping the app to the built-in bundle.
static BOOL didHandleCrash = NO;

// Dedicated suite instead of standardUserDefaults, so keys like PATH/VERSION never
// mix with the host app's defaults (same role as the SharedPreferences file on Android).
static NSUserDefaults *AppCoreDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.appcore.storage"];
    });
    return defaults;
}

static NSArray<NSString *> *AppCoreHistoryPaths(NSString *historyJson) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (historyJson.length == 0) {
        return paths;
    }
    id history = [NSJSONSerialization JSONObjectWithData:[historyJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([history isKindOfClass:[NSArray class]]) {
        for (id bundle in history) {
            if ([bundle isKindOfClass:[NSDictionary class]] && [bundle[@"path"] isKindOfClass:[NSString class]]) {
                [paths addObject:bundle[@"path"]];
            }
        }
    }
    return paths;
}

static BOOL AppCoreIsInside(NSString *path, NSString *folder) {
    NSString *child = path.stringByStandardizingPath;
    NSString *parent = folder.stringByStandardizingPath;
    return [child isEqualToString:parent] || [child hasPrefix:[parent stringByAppendingString:@"/"]];
}

static BOOL AppCoreHoldsAny(NSString *folder, NSArray<NSString *> *paths) {
    for (NSString *path in paths) {
        if (AppCoreIsInside(path, folder)) {
            return YES;
        }
    }
    return NO;
}

// Recorded paths are absolute, but the app's data container can move between app versions.
static NSString *AppCoreRebaseIntoContainer(NSString *path) {
    NSRange range = [path rangeOfString:@"/Containers/Data/Application/[^/]+/" options:NSRegularExpressionSearch];
    if (range.location == NSNotFound) {
        return path;
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:[path substringFromIndex:NSMaxRange(range)]];
}

// The old package unzipped every download into "<zip name>.unzip": the folder a bundle was
// extracted into, or nil.
static NSString *AppCoreLegacyUnzipFolder(NSString *bundlePath) {
    NSString *home = NSHomeDirectory();
    NSString *current = bundlePath.stringByDeletingLastPathComponent;
    while (AppCoreIsInside(current, home) && !AppCoreIsInside(home, current)) {
        if ([current.pathExtension isEqualToString:@"unzip"]) {
            return current;
        }
        current = current.stringByDeletingLastPathComponent;
    }
    return nil;
}

// Its git mode cloned into Documents + folderName ("/git_hot_update" unless configured): the
// folder above a recorded bundle that holds the .git directory, strictly inside Documents, or nil.
static NSString *AppCoreLegacyGitCheckout(NSString *bundlePath, NSString *documentsDir) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *current = bundlePath.stringByDeletingLastPathComponent;
    while (AppCoreIsInside(current, documentsDir) && !AppCoreIsInside(documentsDir, current)) {
        if ([fileManager fileExistsAtPath:[current stringByAppendingPathComponent:@".git"]]) {
            return current;
        }
        current = current.stringByDeletingLastPathComponent;
    }
    return nil;
}

// One-time removal of what the previous package (react-native-ota-hot-update) left behind.
// Those bundles call the old native module name and cannot run on this binary, so nothing is
// migrated, only deleted.
// - Runs only while traces of the old package exist, and records completion in our own storage,
//   so it never touches anything again afterwards (e.g. a new git checkout in the same folder).
// - Only deletes what the old package created: its zips, its unzip folders and its git
//   checkouts. A recorded bundle anywhere else is left alone.
// - Never deletes a folder holding a bundle this package currently uses.
// - The old keys live in standardUserDefaults under generic names (PATH, VERSION...): they are
//   only removed when they point at the old package's bundles, and only after those files are
//   gone, so a failed run is retried on the next start instead of losing track of the files.
static void AppCoreLegacyCleanup(void) {
    NSUserDefaults *store = AppCoreDefaults();
    if ([store boolForKey:@"LEGACY_CLEANUP_DONE"]) {
        return;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSUserDefaults *legacyDefaults = [NSUserDefaults standardUserDefaults];
    NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *libraryDir = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSString *cachesDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *defaultGitFolder = [documentsDir stringByAppendingPathComponent:@"git_hot_update"];
    NSString *trash = [cachesDir stringByAppendingPathComponent:@"appcore-trash"];

    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in @[@"PATH", @"PREVIOUS_BUNDLE_PATH", @"OLD_PATH"]) {
        id value = [legacyDefaults objectForKey:key];
        if (value) {
            [values addObject:value];
        }
    }
    [values addObjectsFromArray:AppCoreHistoryPaths([legacyDefaults stringForKey:@"BUNDLE_HISTORY"])];
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    NSMutableArray<NSString *> *checkouts = [NSMutableArray array];
    // Remembered across retries: once a checkout is moved aside, its paths no longer resolve.
    BOOL ownsKeys = [store boolForKey:@"LEGACY_KEYS_FOUND"];
    for (id value in values) {
        if (![value isKindOfClass:[NSString class]] || [value length] == 0) {
            continue;
        }
        NSString *bundle = AppCoreRebaseIntoContainer(value);
        NSString *unzipFolder = AppCoreLegacyUnzipFolder(bundle);
        NSString *checkout = unzipFolder ? nil : AppCoreLegacyGitCheckout(bundle, documentsDir);
        if (unzipFolder) {
            [targets addObject:unzipFolder];
        } else if (checkout) {
            [checkouts addObject:checkout];
        } else if (!AppCoreIsInside(bundle, defaultGitFolder)) {
            continue; // not created by the old package
        }
        ownsKeys = YES;
    }

    // Downloads were saved as <timestamp>_hotupdate.zip and unzipped next to it.
    for (NSString *dir in @[libraryDir, cachesDir]) {
        for (NSString *name in [fileManager contentsOfDirectoryAtPath:dir error:nil]) {
            if ([name hasSuffix:@"_hotupdate.unzip"] || [name hasSuffix:@"_hotupdate.zip"]) {
                [targets addObject:[dir stringByAppendingPathComponent:name]];
            }
        }
    }
    BOOL hasTrash = [fileManager fileExistsAtPath:trash];
    if (!ownsKeys && targets.count == 0 && !hasTrash) {
        [store setBool:YES forKey:@"LEGACY_CLEANUP_DONE"];
        [store synchronize];
        return;
    }
    if (ownsKeys) {
        [store setBool:YES forKey:@"LEGACY_KEYS_FOUND"];
        [checkouts addObject:defaultGitFolder];
    }

    NSMutableArray<NSString *> *inUse = [NSMutableArray array];
    NSString *currentPath = [store stringForKey:@"PATH"];
    if (currentPath.length > 0) {
        [inUse addObject:currentPath];
    }
    [inUse addObjectsFromArray:AppCoreHistoryPaths([store stringForKey:@"BUNDLE_HISTORY"])];

    // Move the old checkouts aside before JS starts, so a new clone into the same folder can
    // never race with the delete below.
    BOOL movedAll = YES;
    for (NSString *checkout in [NSOrderedSet orderedSetWithArray:checkouts]) {
        if (AppCoreHoldsAny(checkout, inUse) || ![fileManager fileExistsAtPath:checkout]) {
            continue;
        }
        [fileManager createDirectoryAtPath:trash withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *destination = [trash stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        if (![fileManager moveItemAtPath:checkout toPath:destination error:nil]) {
            movedAll = NO; // retried on the next start
        }
    }
    [targets addObject:trash];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            BOOL removedAll = movedAll;
            for (NSString *target in targets) {
                if (AppCoreHoldsAny(target, inUse) || ![fileManager fileExistsAtPath:target]) {
                    continue;
                }
                if (![fileManager removeItemAtPath:target error:nil]) {
                    removedAll = NO;
                }
            }
            if (!removedAll) {
                return;
            }
            if (ownsKeys) {
                for (NSString *key in @[@"PATH", @"VERSION", @"VERSION_NAME", @"METADATA", @"BUNDLE_HISTORY",
                                        @"PREVIOUS_BUNDLE_PATH", @"PREVIOUS_BUNDLE_VERSION", @"OLD_PATH", @"PREVIOUS_VERSION"]) {
                    [legacyDefaults removeObjectForKey:key];
                }
                [legacyDefaults synchronize];
            }
            [store removeObjectForKey:@"LEGACY_KEYS_FOUND"];
            [store setBool:YES forKey:@"LEGACY_CLEANUP_DONE"];
            [store synchronize];
        } @catch (NSException *exception) {
            // best effort, retried on the next start
        }
    });
}

// Called on app start (before JS runs) and on module init; does its work once per process.
static void AppCoreStartLegacyCleanup(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            AppCoreLegacyCleanup();
        } @catch (NSException *exception) {
            // best effort, must never affect app start
        }
    });
}

@implementation AppCore
RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        previousHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&AppCoreExceptionHandler);
        signal(SIGABRT, AppCoreSignalHandler);
        signal(SIGILL, AppCoreSignalHandler);
        signal(SIGSEGV, AppCoreSignalHandler);
        signal(SIGFPE, AppCoreSignalHandler);
        signal(SIGBUS, AppCoreSignalHandler);
        signal(SIGPIPE, AppCoreSignalHandler);
        AppCoreStartLegacyCleanup();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            isBeginning = NO;
        });
    }
    return self;
}

void AppCoreSignalHandler(int sig) {
    if (isBeginning && !didHandleCrash) {
        didHandleCrash = YES;
        NSUserDefaults *defaults = AppCoreDefaults();
        // Use PREVIOUS_BUNDLE_PATH (simple key, written by saveBundleVersion before each update)
        NSString *previousPath = [defaults stringForKey:@"PREVIOUS_BUNDLE_PATH"];
        if (previousPath && previousPath.length > 0) {
            BOOL isDeleted = [AppCore removeBundleIfNeeded:@"PATH"];
            if (isDeleted) {
                [defaults setObject:previousPath forKey:@"PATH"];
                NSString *previousVersion = [defaults stringForKey:@"PREVIOUS_BUNDLE_VERSION"];
                if (previousVersion) {
                    [defaults setObject:previousVersion forKey:@"VERSION"];
                }
            } else {
                [defaults removeObjectForKey:@"PATH"];
            }
        } else {
            [defaults removeObjectForKey:@"PATH"];
        }
        [defaults removeObjectForKey:@"PREVIOUS_BUNDLE_PATH"];
        [defaults removeObjectForKey:@"PREVIOUS_BUNDLE_VERSION"];
        [defaults synchronize];
    }

    signal(sig, SIG_DFL);
    raise(sig);
}
void AppCoreExceptionHandler(NSException *exception) {
    NSUserDefaults *defaults = AppCoreDefaults();
    if (isBeginning && !didHandleCrash) {
        didHandleCrash = YES;
        NSString *previousPath = [defaults stringForKey:@"PREVIOUS_BUNDLE_PATH"];
        if (previousPath && previousPath.length > 0) {
            BOOL isDeleted = [AppCore removeBundleIfNeeded:@"PATH"];
            if (isDeleted) {
                [defaults setObject:previousPath forKey:@"PATH"];
                NSString *previousVersion = [defaults stringForKey:@"PREVIOUS_BUNDLE_VERSION"];
                if (previousVersion) {
                    [defaults setObject:previousVersion forKey:@"VERSION"];
                }
            } else {
                [defaults removeObjectForKey:@"PATH"];
            }
        } else {
            [defaults removeObjectForKey:@"PATH"];
        }
        [defaults removeObjectForKey:@"PREVIOUS_BUNDLE_PATH"];
        [defaults removeObjectForKey:@"PREVIOUS_BUNDLE_VERSION"];
        [defaults synchronize];
    } else if (!isBeginning && previousHandler) {
        previousHandler(exception);
    }
}

// Check if a file path is valid
+ (BOOL)isFilePathValid:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    return [fileManager fileExistsAtPath:path];
}

// Delete a file at the specified path
- (BOOL)deleteFileAtPath:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL success = [fileManager removeItemAtPath:path error:&error];
    if (!success) {
      NSLog(@"Error deleting file: %@", [error localizedDescription]);
    }
    return success;
}
+ (BOOL)deleteAllContentsOfParentDirectoryOfFile:(NSString *)filePath error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Get the parent directory of the file
    NSString *parentDirectory = [filePath stringByDeletingLastPathComponent];

    // Ensure the parent directory exists
    BOOL isDirectory;
    if (![fileManager fileExistsAtPath:parentDirectory isDirectory:&isDirectory] || !isDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:@{NSLocalizedDescriptionKey: @"Parent directory does not exist or is not a directory."}];
        }
        return NO;
    }

    // Get the contents of the parent directory
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:parentDirectory error:error];
    if (error && *error) {
        return NO;
    }

    BOOL success = YES;
    for (NSString *fileName in contents) {
        NSString *filePathInDirectory = [parentDirectory stringByAppendingPathComponent:fileName];

        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:filePathInDirectory isDirectory:&isDirectory]) {
            NSError *removeError = nil;
            if (isDirectory) {
                // Recursively delete directory contents
                if (![fileManager removeItemAtPath:filePathInDirectory error:&removeError]) {
                    NSLog(@"Failed to delete directory at path: %@", filePathInDirectory);
                    success = NO;
                }
            } else {
                // Delete file
                if (![fileManager removeItemAtPath:filePathInDirectory error:&removeError]) {
                    NSLog(@"Failed to delete file at path: %@", filePathInDirectory);
                    success = NO;
                }
            }
        }
    }

    return success;
}

+ (BOOL)deleteBundleAtPath:(NSString *)path {
    if (!path || path.length == 0) {
        return NO;
    }
    NSError *error = nil;
    if ([self isFilePathValid:path]) {
        BOOL isDeleted = [self deleteAllContentsOfParentDirectoryOfFile:path error:&error];
        return isDeleted;
    }
    return NO;
}

+ (BOOL)removeBundleIfNeeded:(NSString *)pathKey {
    NSString *keyToUse = pathKey ? pathKey : @"OLD_PATH";
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *retrievedString = [defaults stringForKey:keyToUse];
    NSError *error = nil;
  if (retrievedString && [self isFilePathValid:retrievedString]) {
        BOOL isDeleted = [self deleteAllContentsOfParentDirectoryOfFile:retrievedString error:&error];
        [defaults removeObjectForKey:keyToUse];
        [defaults synchronize];
        return isDeleted;
    } else {
        return NO;
    }
}

+ (BOOL)isFilePathExist:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    return [fileManager fileExistsAtPath:path];
}

+ (NSURL *)getBundle {
    AppCoreStartLegacyCleanup();
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *retrievedString = [defaults stringForKey:@"PATH"];
    NSString *currentVersionName = [defaults stringForKey:@"VERSION_NAME"];
    NSString *versionName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];

  if (retrievedString && [self isFilePathExist:retrievedString] && [currentVersionName isEqualToString:versionName]) {
       NSURL *fileURL = [NSURL fileURLWithPath:retrievedString];
       return fileURL;
    } else {
         // reset version number because bundle is wrong version, need download from new version
        [defaults removeObjectForKey:@"VERSION"];
        [defaults removeObjectForKey:@"PATH"];
        [defaults synchronize];
        return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
    }
}

- (NSString *)searchForJsBundleInDirectory:(NSString *)directoryPath extension:(NSString *)extension {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;

    // Get contents of the directory
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:directoryPath error:&error];
    if (error) {
        NSLog(@"Error reading directory contents: %@", error.localizedDescription);
        return nil;
    }

    for (NSString *file in contents) {
        NSString *filePath = [directoryPath stringByAppendingPathComponent:file];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:filePath isDirectory:&isDirectory]) {
            if (isDirectory) {
                // Recursively search in subdirectories
                NSString *foundPath = [self searchForJsBundleInDirectory:filePath extension:extension];
                if (foundPath) {
                    return foundPath;
                }
            } else if ([filePath hasSuffix:extension]) {
                // Return the path if it's a .jsbundle file
                return filePath;
            }
        }
    }

    return nil;
}
- (NSString *)renameExtractedFolderInDirectory:(NSString *)directoryPath version:(NSNumber *)version {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;

    // Get the contents of the extracted directory
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:directoryPath error:&error];
    if (error || contents.count != 1) {
        NSLog(@"Error retrieving extracted folder or unexpected structure: %@", error.localizedDescription);
        return nil;
    }

    // Get the original extracted folder name (assuming only one folder exists)
    NSString *originalFolderName = contents.firstObject;
    NSString *originalFolderPath = [directoryPath stringByAppendingPathComponent:originalFolderName];

    // Generate new folder name with version and timestamp
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy_MM_dd_HH_mm"];
    [dateFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    NSString *folderName = version != nil
        ? [NSString stringWithFormat:@"output_v%@_%@", version, timestamp]
        : [NSString stringWithFormat:@"output_%@", timestamp];
    NSString *newFolderPath = [directoryPath stringByAppendingPathComponent:folderName];

    // Rename the extracted folder
    if (![fileManager moveItemAtPath:originalFolderPath toPath:newFolderPath error:&error]) {
        NSLog(@"Failed to rename folder: %@", error.localizedDescription);
        return nil;
    }

    NSLog(@"Renamed extracted folder to: %@", newFolderPath);
    return newFolderPath;
}
- (NSString *)unzipFileAtPath:(NSString *)zipFilePath extension:(NSString *)extension version:(NSNumber *)version  {
    // Define the directory where the files will be extracted
    NSString *extractedFolderPath = [[zipFilePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"unzip"];

    // Create the directory if it does not exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:extractedFolderPath]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:extractedFolderPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            [self deleteFileAtPath:zipFilePath];
            NSLog(@"Failed to create directory: %@", error.localizedDescription);
            return nil;
        }
    }

    // Unzip the file
    BOOL success = [SSZipArchive unzipFileAtPath:zipFilePath toDestination:extractedFolderPath];
    if (!success) {
        [self deleteFileAtPath:zipFilePath];
        NSLog(@"Failed to unzip file");
        return nil;
    }
  // Try renaming the extracted folder
      NSString *renamedFolderPath = [self renameExtractedFolderInDirectory:extractedFolderPath version:version];

      // If renaming fails, use the original extracted folder path
      NSString *finalFolderPath = renamedFolderPath ? renamedFolderPath : extractedFolderPath;

    // Find .jsbundle files in the extracted directory
    NSString *jsbundleFilePath = [self searchForJsBundleInDirectory:finalFolderPath extension:extension];

        // Delete the zip file after extraction
        NSError *removeError = nil;
        [fileManager removeItemAtPath:zipFilePath error:&removeError];
        if (removeError) {
            NSLog(@"Failed to delete zip file: %@", removeError.localizedDescription);
        }
        return jsbundleFilePath;
}

// Expose setupBundlePath method to JavaScript
RCT_EXPORT_METHOD(setupBundlePath:(NSString *)path extension:(NSString *)extension version:(nonnull NSNumber *)version maxVersions:(nonnull NSNumber *)maxVersions metadata:(NSString *)metadata
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if ([AppCore isFilePathValid:path]) {
        //Unzip file
        NSString *extractedFilePath = [self unzipFileAtPath:path extension:(extension != nil) ? extension : @".jsbundle" version:version];
        if (extractedFilePath) {
            NSUserDefaults *defaults = AppCoreDefaults();

            // If version is provided, save to history system
            if (version != nil) {
                // Default maxVersions to 2 if not provided (backward compatible)
                NSInteger defaultMaxVersions = 2;
                NSInteger maxVersionsToKeep = maxVersions != nil ? [maxVersions integerValue] : defaultMaxVersions;
                [self saveBundleVersion:extractedFilePath version:[version integerValue] maxVersions:maxVersionsToKeep metadata:metadata];
            } else {
                // No version (e.g., Git update) - just set path, no history
                [defaults setObject:extractedFilePath forKey:@"PATH"];
            }

            [defaults setObject:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] forKey:@"VERSION_NAME"];
            [defaults synchronize];
            isBeginning = YES;
            resolve(@(YES));
        } else {
            reject(@"E_UNZIP_FAIL", @"Unzipping failed, zip file invalid", nil);
        }
    } else {
        reject(@"E_INVALID_PATH", @"Invalid or missing file path", nil);
    }
}
RCT_EXPORT_METHOD(deleteBundle:(double)i
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *currentPath = [defaults stringForKey:@"PATH"];

    // Delete current bundle from file system
    BOOL isDeleted = [AppCore removeBundleIfNeeded:@"PATH"];

    // Remove current bundle from history if exists
    if (currentPath && currentPath.length > 0) {
        NSArray *history = [self loadBundleHistory];
        NSMutableArray *updatedHistory = [NSMutableArray array];
        for (NSDictionary *bundle in history) {
            if (![bundle[@"path"] isEqualToString:currentPath]) {
                [updatedHistory addObject:bundle];
            }
        }
        [self saveBundleHistory:updatedHistory];
    }

    // Clear paths and version
    [defaults removeObjectForKey:@"PATH"];
    [defaults setObject:@"0" forKey:@"VERSION"];
    [defaults synchronize];

    resolve(@(isDeleted));
}
// Expose deleteBundle method to JavaScript
RCT_EXPORT_METHOD(rollbackToPreviousBundle:(double)i
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  NSUserDefaults *defaults = AppCoreDefaults();
  NSString *currentPath = [defaults stringForKey:@"PATH"];

  // Use history to find previous version
  NSArray *history = [self loadBundleHistory];
  if (history.count > 0 && currentPath && currentPath.length > 0) {
    // Find current bundle in history
    NSDictionary *currentBundle = nil;
    for (NSDictionary *bundle in history) {
      if ([bundle[@"path"] isEqualToString:currentPath]) {
        currentBundle = bundle;
        break;
      }
    }

    if (currentBundle) {
      // Find previous version (older than current, max version)
      NSDictionary *previousBundle = nil;
      NSInteger currentVersion = [currentBundle[@"version"] integerValue];
      for (NSDictionary *bundle in history) {
        NSInteger bundleVersion = [bundle[@"version"] integerValue];
        if (bundleVersion < currentVersion) {
          if (!previousBundle || [bundle[@"version"] integerValue] > [previousBundle[@"version"] integerValue]) {
            previousBundle = bundle;
          }
        }
      }

      if (previousBundle && [AppCore isFilePathValid:previousBundle[@"path"]]) {
        // Rollback to previous bundle from history
        BOOL isDeleted = [AppCore removeBundleIfNeeded:@"PATH"];
        if (isDeleted) {
          [defaults setObject:previousBundle[@"path"] forKey:@"PATH"];
          [defaults setObject:[NSString stringWithFormat:@"%@", previousBundle[@"version"]] forKey:@"VERSION"];
          [defaults synchronize];
          resolve(@(YES));
          return;
        }
      }
    }
  }

  resolve(@(NO));
}

RCT_EXPORT_METHOD(getCurrentVersion:(double)a
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSUserDefaults *defaults = AppCoreDefaults();
  NSString *version = [defaults stringForKey:@"VERSION"];
     if (version) {
         resolve(version);
     } else {
         resolve(@"0");
     }
}

RCT_EXPORT_METHOD(setCurrentVersion:(NSString *)version
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    NSUserDefaults *defaults = AppCoreDefaults();
    // No longer save PREVIOUS_VERSION, use history instead
    if (version) {
        [defaults setObject:version forKey:@"VERSION"];
        [defaults synchronize];
        resolve(@(YES));
    } else {
        resolve(@(NO));
    }
}

RCT_EXPORT_METHOD(setUpdateMetadata:(NSString *)metadataString
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (metadataString) {
        NSUserDefaults *defaults = AppCoreDefaults();
        [defaults setObject:metadataString forKey:@"METADATA"];
        [defaults synchronize];
        resolve(@(YES));
    } else {
        resolve(@(NO));
    }
}

RCT_EXPORT_METHOD(getUpdateMetadata:(double)a
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *metadata = [defaults stringForKey:@"METADATA"];

    if (metadata) {
        resolve(metadata);
    } else {
        resolve(nil);
    }
}

RCT_EXPORT_METHOD(setExactBundlePath:(NSString *)path
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  if ([AppCore isFilePathValid:path]) {
        NSUserDefaults *defaults = AppCoreDefaults();
        [defaults setObject:path forKey:@"PATH"];
        [defaults setObject:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] forKey:@"VERSION_NAME"];
        [defaults synchronize];
        resolve(@(YES));
    } else {
        resolve(@(NO));
    }
}

- (void)loadBundle
{
    RCTTriggerReloadCommandListeners(@"react-native-app-core: Restart");
}
- (NSArray *)loadBundleHistory {
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *historyJson = [defaults stringForKey:@"BUNDLE_HISTORY"];

    // If history exists, load it
    if (historyJson && historyJson.length > 0) {
        NSData *data = [historyJson dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        NSArray *history = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [history isKindOfClass:[NSArray class]]) {
            return history;
        }
    }

    // Migration: If history is empty but PATH exists, migrate from old system
    NSString *currentPath = [defaults stringForKey:@"PATH"];
    NSString *currentVersion = [defaults stringForKey:@"VERSION"];
    NSString *previousPath = [defaults stringForKey:@"OLD_PATH"];
    NSString *previousVersion = [defaults stringForKey:@"PREVIOUS_VERSION"];

    if (!currentPath || currentPath.length == 0) {
        return @[];
    }

    // Migrate current bundle
    NSMutableArray *migratedHistory = [NSMutableArray array];

    // Add current bundle if has version
    if (currentVersion && currentVersion.length > 0) {
        NSInteger version = [currentVersion integerValue];
        if (version > 0 && [AppCore isFilePathValid:currentPath]) {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:currentPath error:nil];
            NSDate *modificationDate = attributes[NSFileModificationDate];
            long long timestamp = modificationDate ? (long long)([modificationDate timeIntervalSince1970] * 1000) : (long long)([[NSDate date] timeIntervalSince1970] * 1000);

            NSMutableDictionary *bundle = [NSMutableDictionary dictionary];
            bundle[@"version"] = @(version);
            bundle[@"path"] = currentPath;
            bundle[@"timestamp"] = @(timestamp);
            bundle[@"metadata"] = [NSNull null];
            [migratedHistory addObject:bundle];
        }
    }

    // Add previous bundle if exists
    if (previousPath && previousPath.length > 0 && previousVersion && previousVersion.length > 0) {
        NSInteger version = [previousVersion integerValue];
        if (version > 0 && [AppCore isFilePathValid:previousPath]) {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:previousPath error:nil];
            NSDate *modificationDate = attributes[NSFileModificationDate];
            long long timestamp = modificationDate ? (long long)([modificationDate timeIntervalSince1970] * 1000) : (long long)([[NSDate date] timeIntervalSince1970] * 1000);

            NSMutableDictionary *bundle = [NSMutableDictionary dictionary];
            bundle[@"version"] = @(version);
            bundle[@"path"] = previousPath;
            bundle[@"timestamp"] = @(timestamp);
            bundle[@"metadata"] = [NSNull null];
            [migratedHistory addObject:bundle];
        }
    }

    // Save migrated history if any
    if (migratedHistory.count > 0) {
        // Sort by version descending
        NSArray *sortedHistory = [migratedHistory sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
            NSInteger v1 = [obj1[@"version"] integerValue];
            NSInteger v2 = [obj2[@"version"] integerValue];
            if (v1 > v2) return NSOrderedAscending;
            if (v1 < v2) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        [self saveBundleHistory:sortedHistory];
        return sortedHistory;
    }

    return @[];
}

- (void)saveBundleHistory:(NSArray *)history {
    NSUserDefaults *defaults = AppCoreDefaults();
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:history options:0 error:&error];
    if (!error && data) {
        NSString *historyJson = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [defaults setObject:historyJson forKey:@"BUNDLE_HISTORY"];
        [defaults synchronize];
    }
}

- (NSString *)extractFolderName:(NSString *)path {
    return [[path stringByDeletingLastPathComponent] lastPathComponent];
}

- (void)saveBundleVersion:(NSString *)path version:(NSInteger)version maxVersions:(NSInteger)maxVersions metadata:(NSString *)metadata {
    NSUserDefaults *defaults = AppCoreDefaults();
    NSArray *history = [self loadBundleHistory];

    // Create new bundle entry
    NSMutableDictionary *newBundle = [NSMutableDictionary dictionary];
    newBundle[@"version"] = @(version);
    newBundle[@"path"] = path;
    newBundle[@"timestamp"] = @((long long)([[NSDate date] timeIntervalSince1970] * 1000));
    if (metadata) {
        newBundle[@"metadata"] = metadata;
    }

    // Combine with existing history
    NSMutableArray *updatedHistory = [NSMutableArray arrayWithObject:newBundle];
    [updatedHistory addObjectsFromArray:history];

    // Sort by version descending and remove duplicates
    [updatedHistory sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        NSInteger v1 = [obj1[@"version"] integerValue];
        NSInteger v2 = [obj2[@"version"] integerValue];
        if (v1 > v2) return NSOrderedAscending;
        if (v1 < v2) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // Remove duplicates by version
    NSMutableArray *uniqueHistory = [NSMutableArray array];
    NSMutableSet *seenVersions = [NSMutableSet set];
    for (NSDictionary *bundle in updatedHistory) {
        NSInteger v = [bundle[@"version"] integerValue];
        if (![seenVersions containsObject:@(v)]) {
            [seenVersions addObject:@(v)];
            [uniqueHistory addObject:bundle];
        }
    }

    // Keep only maxVersions most recent
    NSArray *finalHistory = [uniqueHistory subarrayWithRange:NSMakeRange(0, MIN(maxVersions, uniqueHistory.count))];

    // Delete old versions beyond limit
    NSMutableSet *versionsToKeep = [NSMutableSet set];
    for (NSDictionary *bundle in finalHistory) {
        [versionsToKeep addObject:bundle[@"version"]];
    }

    for (NSDictionary *bundle in uniqueHistory) {
        if (![versionsToKeep containsObject:bundle[@"version"]]) {
            [AppCore deleteBundleAtPath:bundle[@"path"]];
        }
    }

    // Save updated history
    [self saveBundleHistory:finalHistory];

    // Before updating current path, save it as fallback for crash handler
    NSString *currentPath = [defaults stringForKey:@"PATH"];
    NSString *currentVersion = [defaults stringForKey:@"VERSION"];
    if (currentPath && currentPath.length > 0) {
        [defaults setObject:currentPath forKey:@"PREVIOUS_BUNDLE_PATH"];
        if (currentVersion) {
            [defaults setObject:currentVersion forKey:@"PREVIOUS_BUNDLE_VERSION"];
        }
    }

    // Set current path and version
    [defaults setObject:path forKey:@"PATH"];
    [defaults setObject:[NSString stringWithFormat:@"%ld", (long)version] forKey:@"VERSION"];
    [defaults synchronize];
}

RCT_EXPORT_METHOD(restart) {
    if ([NSThread isMainThread]) {
        [self loadBundle];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self loadBundle];
        });
    }
    return;
}


RCT_EXPORT_METHOD(getBundleList:(double)a
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    NSArray *history = [self loadBundleHistory];
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *activePath = [defaults stringForKey:@"PATH"];

    NSMutableArray *bundleList = [NSMutableArray array];
    for (NSDictionary *bundle in history) {
        NSString *path = bundle[@"path"];
        NSString *folderName = [self extractFolderName:path];
        NSMutableDictionary *bundleInfo = [NSMutableDictionary dictionary];
        bundleInfo[@"id"] = folderName;
        bundleInfo[@"version"] = bundle[@"version"];
        bundleInfo[@"date"] = bundle[@"timestamp"];
        bundleInfo[@"path"] = path;
        bundleInfo[@"isActive"] = @([path isEqualToString:activePath]);
        // Entries migrated from PATH/VERSION carry NSNull here, which has no dataUsingEncoding:
        if ([bundle[@"metadata"] isKindOfClass:[NSString class]]) {
            NSError *error = nil;
            id metadata = [NSJSONSerialization JSONObjectWithData:[bundle[@"metadata"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
            bundleInfo[@"metadata"] = error ? bundle[@"metadata"] : metadata;
        } else {
            bundleInfo[@"metadata"] = [NSNull null];
        }
        [bundleList addObject:bundleInfo];
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:bundleList options:0 error:&error];
    if (!error && data) {
        NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        resolve(jsonString);
    } else {
        reject(@"GET_BUNDLE_LIST_ERROR", @"Failed to serialize bundle list", error);
    }
}

RCT_EXPORT_METHOD(deleteBundleById:(NSString *)id
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    NSArray *history = [self loadBundleHistory];
    NSUserDefaults *defaults = AppCoreDefaults();
    NSString *activePath = [defaults stringForKey:@"PATH"];

    NSDictionary *bundleToDelete = nil;
    for (NSDictionary *bundle in history) {
        NSString *folderName = [self extractFolderName:bundle[@"path"]];
        if ([folderName isEqualToString:id]) {
            bundleToDelete = bundle;
            break;
        }
    }

    if (!bundleToDelete) {
        resolve(@(NO));
        return;
    }

    // If deleting active bundle, rollback to oldest remaining bundle or clear
    if ([bundleToDelete[@"path"] isEqualToString:activePath]) {
        NSMutableArray *remainingBundles = [NSMutableArray array];
        for (NSDictionary *bundle in history) {
            if (![bundle[@"path"] isEqualToString:bundleToDelete[@"path"]]) {
                [remainingBundles addObject:bundle];
            }
        }
        if (remainingBundles.count > 0) {
            NSDictionary *oldestBundle = [remainingBundles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
                NSInteger v1 = [obj1[@"version"] integerValue];
                NSInteger v2 = [obj2[@"version"] integerValue];
                if (v1 < v2) return NSOrderedAscending;
                if (v1 > v2) return NSOrderedDescending;
                return NSOrderedSame;
            }].firstObject;
            [defaults setObject:oldestBundle[@"path"] forKey:@"PATH"];
            [defaults setObject:[NSString stringWithFormat:@"%@", oldestBundle[@"version"]] forKey:@"VERSION"];
        } else {
            [defaults removeObjectForKey:@"PATH"];
            [defaults removeObjectForKey:@"VERSION"];
        }
        [defaults synchronize];
    }

    // Delete bundle folder
    BOOL isDeleted = [AppCore deleteBundleAtPath:bundleToDelete[@"path"]];

    // Remove from history
    NSMutableArray *updatedHistory = [NSMutableArray array];
    for (NSDictionary *bundle in history) {
        if (![bundle[@"path"] isEqualToString:bundleToDelete[@"path"]]) {
            [updatedHistory addObject:bundle];
        }
    }
    [self saveBundleHistory:updatedHistory];

    resolve(@(isDeleted));
}

RCT_EXPORT_METHOD(clearAllBundles:(double)a
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    NSArray *history = [self loadBundleHistory];
    NSUserDefaults *defaults = AppCoreDefaults();

    // Delete all bundle folders
    for (NSDictionary *bundle in history) {
        [AppCore deleteBundleAtPath:bundle[@"path"]];
    }

    // Clear history
    [self saveBundleHistory:@[]];

    // Clear current path and version
    [defaults removeObjectForKey:@"PATH"];
    [defaults removeObjectForKey:@"VERSION"];
    [defaults synchronize];

    resolve(@(YES));
}

RCT_EXPORT_METHOD(writeFile:(NSString *)path
                  base64Content:(NSString *)base64Content
                  encoding:(NSString *)encoding
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  // Run on background queue to avoid blocking JS thread
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @try {
      // Decode base64 to NSData
      NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Content options:0];
      if (!data) {
        reject(@"DECODE_ERROR", @"Failed to decode base64 content", nil);
        return;
      }

      // Ensure parent directory exists
      NSString *parentDir = [path stringByDeletingLastPathComponent];
      NSFileManager *fileManager = [NSFileManager defaultManager];
      if (![fileManager fileExistsAtPath:parentDir]) {
        NSError *error;
        if (![fileManager createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:&error]) {
          reject(@"CREATE_DIR_ERROR", [NSString stringWithFormat:@"Failed to create directory: %@", error.localizedDescription], error);
          return;
        }
      }

      // Write file on background thread
      NSError *error;
      if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        reject(@"WRITE_ERROR", [NSString stringWithFormat:@"Failed to write file: %@", error.localizedDescription], error);
        return;
      }

      resolve(@(YES));
    } @catch (NSException *exception) {
      reject(@"WRITE_ERROR", [NSString stringWithFormat:@"Unexpected error: %@", exception.reason], nil);
    }
  });
}

// Don't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeAppCoreSpecJSI>(params);
}
#endif

@end
