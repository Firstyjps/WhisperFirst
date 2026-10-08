#import "ObjCTry.h"

BOOL WFObjCTry(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"WhisperFirstObjC" code:6
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]}];
        }
        return NO;
    }
}
