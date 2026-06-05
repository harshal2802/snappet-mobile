#import "ObjCException.h"

@implementation ObjCException

+ (NSException *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

@end
