#import <React/RCTReloadCommand.h>

#if defined(RCT_NEW_ARCH_ENABLED) && __has_include("RNAppCoreSpec.h")
#import "RNAppCoreSpec.h"
@interface AppCore : NSObject <NativeAppCoreSpec>
#else
#import <React/RCTBridgeModule.h>
@interface AppCore : NSObject <RCTBridgeModule>
#endif

+ (NSURL *)getBundle;

@end
