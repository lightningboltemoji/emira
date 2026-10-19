#import "VirtualDisplay.h"

// CoreGraphics' own classes, as Chromium declares them (ui/display/mac/test/virtual_display_util_mac.mm).

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@property(strong, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(strong, nonatomic) id queue;
@property(copy, nonatomic) id terminationHandler;
@end

@interface CGVirtualDisplayMode : NSObject
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(strong, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
- (id)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

@implementation EMVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned int)width
                               height:(unsigned int)height
                               serial:(unsigned int)serial {
    if (!(self = [super init])) {
        return nil;
    }
    CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.name = name;
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    // A Retina density, so macOS offers the HiDPI mode.
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / 218, 25.4 * height / 218);
    descriptor.serialNum = serial;
    descriptor.serialNumber = serial;
    descriptor.productID = 0xE31A;
    // macOS 14 and later refuse a zero vendor.
    descriptor.vendorID = 505;
    _display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!_display) {
        return nil;
    }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = 1;
    settings.modes = @[
        [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:width / 2 height:height / 2 refreshRate:60],
    ];
    if (![_display applySettings:settings]) {
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
