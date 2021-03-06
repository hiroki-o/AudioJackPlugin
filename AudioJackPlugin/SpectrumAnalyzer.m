// Realtime FFT spectrum and octave-band analysis.
// by Keijiro Takahashi, 2013
// https://github.com/keijiro/AudioSpectrum

#import "SpectrumAnalyzer.h"
#import "AudioInputHandler.h"
#import "AudioRingBuffer.h"

// Octave band type definition

static Float32 middleFrequenciesForBands[][32] = {
    { 125.0f, 500, 1000, 2000 },
    { 250.0f, 400, 600, 800 },
    { 63.0f, 125, 500, 1000, 2000, 4000, 6000, 8000 },
    { 31.5f, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 },
    { 25.0f, 31.5f, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000 },
    { 20.0f, 25, 31.5f, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000 }
};

static Float32 bandwidthForBands[] = {
    1.41421356237f, // 2^(1/2)
    1.25992104989f, // 2^(1/3)
    1.41421356237f, // 2^(1/2)
    1.41421356237f, // 2^(1/2)
    1.12246204831f, // 2^(1/6)
    1.12246204831f  // 2^(1/6)
};

@implementation SpectrumAnalyzer

#if ! __has_feature(objc_arc)
@synthesize pointNumber = _pointNumber;
@synthesize bandType = _bandType;
@synthesize spectrum = _spectrum;
@synthesize bandLevels = _bandLevels;
#endif

#pragma mark Constructor / Destructor

- (id)init
{
    self = [super init];
    if (self) {
        _bandLevels = calloc(32, sizeof(Float32));
        self.pointNumber = 1024;
        self.bandType = 3;
    }
    return self;
}

- (void)dealloc
{
    self.pointNumber = 0;
    free(_bandLevels);
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}

#pragma mark Custom accessors

- (void)setPointNumber:(NSUInteger)number
{
    // No need to update.
    if (_pointNumber == number) return;
    
    // Free the objects if already initialized.
    if (_pointNumber != 0) {
        vDSP_destroy_fftsetup(_fftSetup);
        free(_fftBuffer.realp);
        free(_fftBuffer.imagp);
        free(_inputBuffer);
        free(_window);
        free(_spectrum);
    }
    
    // Update the number.
    _pointNumber = number;
    _logPointNumber = log2(number);
    
    if (number > 0) {
        // Allocate the objects and the arrays.
        _fftSetup = vDSP_create_fftsetup(_logPointNumber, FFT_RADIX2);
        
        _fftBuffer.realp = calloc(_pointNumber / 2, sizeof(Float32));
        _fftBuffer.imagp = calloc(_pointNumber / 2, sizeof(Float32));
        
        _inputBuffer = calloc(_pointNumber, sizeof(Float32));
        
        _window = calloc(_pointNumber, sizeof(Float32));
        vDSP_blkman_window(_window, number, 0);
        
        Float32 normFactor = 2.0f / number;
        vDSP_vsmul(_window, 1, &normFactor, _window, 1, number);
        
        _spectrum = calloc(_pointNumber / 2, sizeof(Float32));
    }
}

- (NSUInteger)countBands
{
    for (NSUInteger i = 0;; i++) {
        if (middleFrequenciesForBands[_bandType][i] == 0) return i;
    }
}

#pragma mark Instance method

- (void)processAudioInput:(AudioInputHandler *)input channel:(NSUInteger)channel
{
    // Retrieve a waveform from the specified channel.
    [[input.ringBuffers objectAtIndex:channel] copyTo:_inputBuffer length:_pointNumber];
    
    // Do FFT.
    [self calculateWithInputBuffer:input.sampleRate];
}

- (void)processAudioInput:(AudioInputHandler *)input channel1:(NSUInteger)channel1 channel2:(NSUInteger)channel2
{
    // Retrieve waveforms from the specified channel.
    [[input.ringBuffers objectAtIndex:channel1] copyTo:_inputBuffer length:_pointNumber];
    [[input.ringBuffers objectAtIndex:channel2] vectorAverageWith:_inputBuffer index:1 length:_pointNumber];
    
    // Do FFT.
    [self calculateWithInputBuffer:input.sampleRate];
}

- (void)processAudioInput:(AudioInputHandler *)input
{
    // Retrieve waveforms from channels and average these.
    [input.ringBuffers.firstObject copyTo:_inputBuffer length:_pointNumber];
    for (NSUInteger i = 1; i < input.ringBuffers.count; i++) {
        [[input.ringBuffers objectAtIndex:i] vectorAverageWith:_inputBuffer index:i length:_pointNumber];
    }
    
    // Do FFT.
    [self calculateWithInputBuffer:input.sampleRate];
}

- (void)calculateWithInputBuffer:(float)sampleRate
{
    NSUInteger length = _pointNumber / 2;
    
    // Split the waveform.
    DSPSplitComplex dest = { _fftBuffer.realp, _fftBuffer.imagp };
    vDSP_ctoz((const DSPComplex*)_inputBuffer, 2, &dest, 1, length);
    
    // Apply the window function.
    vDSP_vmul(_fftBuffer.realp, 1, _window, 2, _fftBuffer.realp, 1, length);
    vDSP_vmul(_fftBuffer.imagp, 1, _window + 1, 2, _fftBuffer.imagp, 1, length);
    
    // FFT.
    vDSP_fft_zrip(_fftSetup, &_fftBuffer, 1, _logPointNumber, FFT_FORWARD);
    
    // Zero out the nyquist value.
    _fftBuffer.imagp[0] = 0;
    
    // Calculate power spectrum.
    vDSP_zvmags(&_fftBuffer, 1, _spectrum, 1, length);
    
    // Add -128db offset to avoid log(0).
    float kZeroOffset = 1.5849e-13;
    vDSP_vsadd(_spectrum, 1, &kZeroOffset, _spectrum, 1, length);
    
    // Convert power to decibel.
    float kZeroDB = 0.70710678118f; // 1/sqrt(2)
    vDSP_vdbcon(_spectrum, 1, &kZeroDB, _spectrum, 1, length, 0);
    
    // Calculate the band levels.
    NSUInteger bandCount = [self countBands];
    
    const Float32 *middleFreqs = middleFrequenciesForBands[_bandType];
    Float32 bandWidth = bandwidthForBands[_bandType];
    
    Float32 freqToIndexCoeff = _pointNumber / sampleRate;
    int maxIndex = (int)_pointNumber / 2 - 1;
    
    for (NSUInteger band = 0; band < bandCount; band++) {
        int idxlo = MIN((int)floorf(middleFreqs[band] / bandWidth * freqToIndexCoeff), maxIndex);
        int idxhi = MIN((int)floorf(middleFreqs[band] * bandWidth * freqToIndexCoeff), maxIndex);
        
        Float32 maxLevel = _spectrum[idxlo];
        for (int i = idxlo + 1; i <= idxhi; i++) {
            maxLevel = MAX(maxLevel, _spectrum[i]);
        }
        
        _bandLevels[band] = maxLevel;
    }
}

#pragma mark Class method

+ (SpectrumAnalyzer *)sharedInstance
{
    static SpectrumAnalyzer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpectrumAnalyzer alloc] init];
    });
    return instance;
}

@end
