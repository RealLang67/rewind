#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// bridges obj-c exceptions into swift error handling
///
/// avfoundation config apis raise an `NSException` when the
/// hardware encoder rejects the requested settings. swift's `do/catch` cannot
/// intercept an `NSException`; it unwinds straight through the swift frames and
/// crashes the process. route the risky call through this "trampoline" so the
/// exception surfaces as a recoverable `NSError` instead
@interface RewindExceptionCatcher : NSObject

/// runs `block`, returning `YES` on success. if `block` raises an `NSException`,
/// returns `NO` and populates `error` with the exception's name and reason
+ (BOOL)catchException:(__attribute__((noescape)) void (^)(void))block
                 error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
