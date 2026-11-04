#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL OBMenuBarVisibilityAvailable(void);
void OBMenuBarActivate(NSArray<NSString *> *bundles,
                      void (^completion)(id _Nullable assertion, NSString * _Nullable error));
void OBMenuBarInvalidate(id _Nullable assertion);
NS_ASSUME_NONNULL_END
