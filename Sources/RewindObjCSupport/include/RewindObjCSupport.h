#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

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

/// receives `SCStreamDelegate` stop callbacks in obj-c, where the error can be
/// nil-checked before anything tries to read it
///
/// on macos 14.7.2 through 15.3 the framework sometimes stops a stream by itself
/// and passes a null pointer where an `NSError` should be. swift declares that
/// parameter non-optional, so merely bridging it crashes the process inside
/// `swift_getErrorValue` — there is no swift-side guard that can prevent it. a
/// plain `if (error != nil)` here is safe, and the reason is copied into a fresh
/// string so nothing owned by the framework outlives the callback
///
/// note this cannot defend against a non-null pointer to an already-freed error,
/// which is a separate reported failure. reading it synchronously (as here,
/// rather than after an `await`) is the mitigation apple suggests for that one
API_AVAILABLE(macos(12.3))
@interface RewindStreamStopObserver : NSObject <SCStreamDelegate>

/// invoked when the stream stops. `reason` is nil when the framework supplied no
/// usable error, which is itself the symptom of the bug above
@property(nonatomic, copy, nullable) void (^onStop)(NSString *_Nullable reason);

@end

NS_ASSUME_NONNULL_END
