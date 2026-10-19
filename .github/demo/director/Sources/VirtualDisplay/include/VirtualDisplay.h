#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A display that exists only to WindowServer: no panel shows it, but windows, the menu bar and
/// screen recording treat it as attached. It goes away when released, or when the process exits.
@interface EMVirtualDisplay : NSObject

/// A 60 Hz display offering `width`×`height` pixels, and the same at half size in points (HiDPI).
/// Nil if WindowServer refuses it, which it does while another live one has the same `serial`.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned int)width
                               height:(unsigned int)height
                               serial:(unsigned int)serial;

@property(readonly) CGDirectDisplayID displayID;

@end

NS_ASSUME_NONNULL_END
