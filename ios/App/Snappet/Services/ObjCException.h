#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C `@try/@catch` to Swift. AVFoundation raises `NSException` (not a Swift
/// `Error`) for some invalid inputs — e.g. `-[AVPlayerItem setVideoComposition:]` on a composition
/// the player rejects — and a Swift `do/catch` CANNOT catch those, so they abort the process.
/// Run the throwing call inside `block`; returns `nil` on success, or the caught `NSException`.
@interface ObjCException : NSObject
+ (nullable NSException *)catching:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
