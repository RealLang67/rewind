#import "RewindObjCSupport.h"

@implementation RewindExceptionCatcher

+ (BOOL)catchException:(__attribute__((noescape)) void (^)(void))block
                 error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            userInfo[@"RewindExceptionName"] = exception.name;
            if (exception.userInfo != nil) {
                userInfo[@"RewindExceptionUserInfo"] = exception.userInfo;
            }
            *error = [NSError errorWithDomain:@"RewindObjCException" code:0 userInfo:userInfo];
        }
        return NO;
    }
}

@end
