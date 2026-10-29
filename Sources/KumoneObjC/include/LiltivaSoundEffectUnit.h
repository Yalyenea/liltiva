#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The render block performs no allocation, locking, file I/O or Objective-C
/// messaging. Configuration builds a replacement kernel off the audio thread.
@interface LiltivaSoundEffectUnit : AUAudioUnit
- (void)configureParameters:(NSData *)json
                sampleRate:(double)sampleRate
                  strength:(double)strength
               impulseLeft:(nullable NSData *)left
              impulseRight:(nullable NSData *)right
         impulseSampleRate:(double)impulseSampleRate;
@end

NS_ASSUME_NONNULL_END
