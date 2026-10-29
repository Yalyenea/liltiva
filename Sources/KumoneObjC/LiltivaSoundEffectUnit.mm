#import "include/LiltivaSoundEffectUnit.h"
#import <Accelerate/Accelerate.h>
#include <atomic>
#include <array>
#include <cmath>
#include <memory>
#include <vector>
#include <algorithm>

namespace {
constexpr double pi = 3.14159265358979323846;
double number(NSDictionary *d, NSString *key, double fallback = 0) {
    id v = d[key]; return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback;
}
bool enabled(NSDictionary *d) { return [d isKindOfClass:NSDictionary.class] && [d[@"on"] boolValue]; }
NSDictionary *group(NSDictionary *d, NSString *key) {
    id v = d[key]; return [v isKindOfClass:NSDictionary.class] ? v : @{};
}
double clamp(double n, double low, double high) { return std::max(low, std::min(high, n)); }
double db(double n) { return pow(10, n / 20); }

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1[2] = {}, z2[2] = {};
    Biquad(int type, double freq, double q, double gain, double rate) {
        double w = 2 * pi * clamp(freq, 10, rate * .45) / rate;
        double c = cos(w), s = sin(w), a = pow(10, gain / 40), alpha = s / (2 * clamp(q, .1, 20));
        double a0 = 1;
        if (type == 0 || type == 1) {
            // Legacy pass filters use q=0 for Butterworth response.
            alpha = s / (2 * (q > 0 ? clamp(q, .1, 20) : sqrt(.5)));
            b0 = type == 0 ? (1-c)/2 : (1+c)/2;
            b1 = type == 0 ? 1-c : -(1+c); b2=b0;
            a0=1+alpha; a1=-2*c; a2=1-alpha;
        } else if (type == 4 || type == 7 || type == 5 || type == 8) {
            // RBJ low/high shelves. Types 7/8 retain their resonant Q.
            double beta = 2 * sqrt(a) * alpha;
            if (type == 4 || type == 7) {
                b0=a*((a+1)-(a-1)*c+beta); b1=2*a*((a-1)-(a+1)*c); b2=a*((a+1)-(a-1)*c-beta);
                a0=(a+1)+(a-1)*c+beta; a1=-2*((a-1)+(a+1)*c); a2=(a+1)+(a-1)*c-beta;
            } else {
                b0=a*((a+1)+(a-1)*c+beta); b1=-2*a*((a-1)+(a+1)*c); b2=a*((a+1)+(a-1)*c-beta);
                a0=(a+1)-(a-1)*c+beta; a1=2*((a-1)-(a+1)*c); a2=(a+1)-(a-1)*c-beta;
            }
        } else if (type == 9) {
            b0=1; b1=-2*c; b2=1; a0=1+alpha; a1=-2*c; a2=1-alpha;
        } else {
            b0=1+alpha*a; b1=-2*c; b2=1-alpha*a; a0=1+alpha/a; a1=-2*c; a2=1-alpha/a;
        }
        b0/=a0; b1/=a0; b2/=a0; a1/=a0; a2/=a0;
    }
    double process(double x, int ch) {
        double y=b0*x+z1[ch]; z1[ch]=b1*x-a1*y+z2[ch]; z2[ch]=b2*x-a2*y;
        return y;
    }
    double response(double w) const {
        auto power = [w](double x, double y, double z) {
            double r=x+y*cos(w)+z*cos(2*w), i=-y*sin(w)-z*sin(2*w); return r*r+i*i;
        };
        return 10*log10(std::max(1e-20,power(b0,b1,b2))/std::max(1e-20,power(1,a1,a2)));
    }
};

struct Delay {
    std::vector<double> samples;
    size_t position = 0;
    explicit Delay(size_t count = 1) : samples(std::max(size_t(1),count),0) {}
    double read(size_t back) const { return samples[(position+samples.size()-std::min(back,samples.size()))%samples.size()]; }
    double tick(double input) { double out=samples[position]; samples[position]=input; position=(position+1)%samples.size(); return out; }
};

// Uniform partitioned overlap-save convolution: 256-frame latency independent
// of IR length. All FFT plans and spectra are prepared before publication.
struct Convolver {
    static constexpr size_t block=256, fft=512;
    FFTSetup setup = nullptr;
    size_t partitions, cursor=0, sample=0;
    std::vector<float> hr,hi,xr,xi;
    std::array<float,fft> real{},imag{},yr{},yi{};
    std::array<float,block> previous{},input{},output{};
    explicit Convolver(const std::vector<float>& ir) : partitions((ir.size()+block-1)/block),
        hr(partitions*fft),hi(partitions*fft),xr(partitions*fft),xi(partitions*fft) {
        setup=vDSP_create_fftsetup(9,kFFTRadix2);
        for(size_t p=0;p<partitions;++p) {
            real.fill(0); imag.fill(0);
            for(size_t i=0;i<block && p*block+i<ir.size();++i) real[i]=ir[p*block+i];
            DSPSplitComplex z{real.data(),imag.data()}; vDSP_fft_zip(setup,&z,1,9,FFT_FORWARD);
            std::copy(real.begin(),real.end(),hr.begin()+p*fft); std::copy(imag.begin(),imag.end(),hi.begin()+p*fft);
        }
    }
    ~Convolver() { if(setup) vDSP_destroy_fftsetup(setup); }
    void reset() {
        cursor=sample=0;
        std::fill(xr.begin(),xr.end(),0); std::fill(xi.begin(),xi.end(),0);
        previous.fill(0); input.fill(0); output.fill(0);
    }
    float process(float value) {
        float result=output[sample]; input[sample]=value;
        if(++sample==block) {
            sample=0; imag.fill(0); yr.fill(0); yi.fill(0);
            std::copy(previous.begin(),previous.end(),real.begin()); std::copy(input.begin(),input.end(),real.begin()+block);
            previous=input;
            DSPSplitComplex z{real.data(),imag.data()}; vDSP_fft_zip(setup,&z,1,9,FFT_FORWARD);
            std::copy(real.begin(),real.end(),xr.begin()+cursor*fft); std::copy(imag.begin(),imag.end(),xi.begin()+cursor*fft);
            for(size_t p=0;p<partitions;++p) {
                size_t x=((cursor+partitions-p)%partitions)*fft, h=p*fft;
                for(size_t k=0;k<fft;++k) {
                    yr[k]+=xr[x+k]*hr[h+k]-xi[x+k]*hi[h+k];
                    yi[k]+=xr[x+k]*hi[h+k]+xi[x+k]*hr[h+k];
                }
            }
            DSPSplitComplex y{yr.data(),yi.data()}; vDSP_fft_zip(setup,&y,1,9,FFT_INVERSE);
            for(size_t i=0;i<block;++i) output[i]=yr[block+i]/fft;
            cursor=(cursor+1)%partitions;
        }
        return result;
    }
};

std::vector<float> resample(NSData *bytes, double from, double to) {
    const float *source=(const float *)bytes.bytes; size_t count=bytes.length/sizeof(float);
    if (from==to) return std::vector<float>(source,source+count);
    size_t length=std::min(size_t(131072),size_t(ceil(count*to/from)));
    std::vector<float> result(length);
    // Windowed sinc resampling preserves the response when the source/output
    // rates differ, including the anti-alias cutoff when downsampling.
    double cutoff=std::min(1.0,to/from);
    for(size_t i=0;i<length;++i) {
        double position=i*from/to, sum=0; long center=long(floor(position));
        for(long j=center-24;j<=center+24;++j) {
            if(j<0 || j>=long(count)) continue;
            double distance=position-j, t=distance*cutoff;
            double sinc=abs(t)<1e-9 ? 1 : sin(pi*t)/(pi*t);
            double window=.5+.5*cos(pi*distance/25);
            sum+=source[j]*sinc*window*cutoff;
        }
        result[i]=float(sum);
    }
    return result;
}

struct Kernel {
    Kernel *nextRetired=nullptr;
    double rate, strength, gain=1, width=1, stereo=0, phase=0, phaseStep=0;
    double dry=1, late=0, early=0, damp=0, damping[8]={}, feedback[8]={};
    double reverbWidth=1, diffusion=.6, compressorThreshold=0, compressorRatio=1, attack=0, release=0, envelope=0;
    double limiterThreshold=1, limiterGain=1, limiterRelease=.999, limiterOutput=1;
    bool useReverb=false, useDynamics=false, active=false;
    std::vector<Biquad> filters, wetFilters;
    std::vector<Delay> delays;
    Delay preDelay, earlyDelay, stereoDelay;
    std::unique_ptr<Convolver> ir[2];
    std::array<Delay,2> dryIR{Delay(256),Delay(256)};
    size_t earlyTaps[6]={};

    Kernel(NSDictionary *parameters, double sampleRate, double amount, NSData *left, NSData *right, double irRate)
        : rate(sampleRate), strength(clamp(amount,0,1)), preDelay(1),earlyDelay(1),stereoDelay(size_t(sampleRate*.025)) {
        active=parameters.count>0 || left.length>0;
        if(!active || strength==0) { active=false; return; }
        NSDictionary *bt=group(parameters,@"bt"), *peq=group(parameters,@"peq"), *se=group(parameters,@"se");
        double pre=0;
        if(enabled(bt)) {
            double low=number(bt,@"bassFreq",120), high=number(bt,@"trebleFreq",6000);
            filters.emplace_back(4,low>0?low:120,number(bt,@"bassQ",.5)>0?number(bt,@"bassQ",.5):.5,number(bt,@"bass")*strength,rate);
            filters.emplace_back(5,high>0?high:6000,number(bt,@"trebleQ",.5)>0?number(bt,@"trebleQ",.5):.5,number(bt,@"treble")*strength,rate);
        }
        if(enabled(peq)) {
            pre+=number(peq,@"gain")*strength;
            for(NSDictionary *b in peq[@"f"]) if(enabled(b))
                filters.emplace_back(int(number(b,@"type",6)),number(b,@"freq",1000),number(b,@"q",1),number(b,@"gain")*strength,rate);
        }
        if(enabled(se)) {
            double presence=clamp(number(se,@"presence"),0,10)*strength;
            filters.emplace_back(5,3000,.7,presence*.5,rate);
            stereo=clamp(number(se,@"stereoizer"),0,10)*strength;
            bool shaper=[se[@"sshaper"] boolValue];
            width+=stereo*.1+(shaper?.2*strength:0);
            if(shaper) stereo+=1.2*strength;
        }
        NSDictionary *rotation=group(parameters,@"rotate");
        if(enabled(rotation)) phaseStep=2*pi*clamp(number(rotation,@"velocity",20),.1,180)/360/rate;
        NSDictionary *rvb=group(parameters,@"rvb"), *room=group(rvb,@"rvb"), *er=group(rvb,@"er"), *out=group(rvb,@"ol");
        double ambience=enabled(se)?clamp(number(se,@"ambience"),0,10):0;
        useReverb=enabled(rvb) || ambience>0;
        if(useReverb) {
            bool official=enabled(rvb), lateOn=![room[@"on"] isEqual:@NO];
            double decay=official?clamp(number(room,@"dtime",1.5),.1,12):.4+ambience*.12;
            double density=official?clamp(number(room,@"density",60),0,100):60;
            double shape=official?clamp(number(room,@"rshape",40),0,100):40;
            diffusion=official?clamp(number(room,@"diffusion",80)/100,0,1):.7;
            reverbWidth=official?clamp(number(room,@"swidth",100)/100,0,2):1.4;
            double cutoff=official?clamp(number(room,@"hfdamping",5)*1000,200,rate*.45):5000;
            damp=exp(-2*pi*cutoff/rate);
            dry=official?db(clamp(number(out,@"dry"),-80,12)*strength):1;
            late=official?(lateOn?db(clamp(number(out,@"rvb",-20),-80,0))*strength:0):ambience*.015*strength;
            early=official && enabled(er)?db(clamp(number(out,@"er",-23),-80,0))*strength:0;
            preDelay=Delay(size_t(clamp(number(room,@"pdelay"),0,500)*rate/1000)+1);
            earlyDelay=Delay(size_t(rate*.5));
            double size=clamp(number(er,@"rsize",50),0,100), start=clamp(number(er,@"sdelay"),0,300);
            int pattern=int(number(er,@"pattern"));
            for(int i=0;i<6;++i) earlyTaps[i]=size_t(rate*(start+3+(i+1)*(4+size*.18)+(pattern%5)*i*.7)/1000);
            const double lengths[]={.0297,.0371,.0411,.0437,.0531,.0617,.0673,.0797};
            for(int i=0;i<8;++i) {
                size_t length=size_t(rate*lengths[i]*(.6+shape*.012)*( .8+density*.004));
                delays.emplace_back(length);
                feedback[i]=pow(.001,double(length)/rate/decay);
            }
            NSDictionary *tc=group(rvb,@"tc");
            if(enabled(tc)) for(NSDictionary *b in tc[@"f"]) {
                int curve=int(number(b,@"curve",1));
                wetFilters.emplace_back(curve==0?4:(curve==2?5:6),number(b,@"freq",1000),number(b,@"q",1),number(b,@"gain"),rate);
            }
        }
        NSDictionary *cmp=group(parameters,@"cmp"), *limiter=group(parameters,@"limiter");
        if(enabled(cmp)) {
            pre+=(number(cmp,@"pregain")+number(cmp,@"postgain"))*strength;
            compressorRatio=clamp(number(cmp,@"ratio",1),1,40);
            useDynamics=compressorRatio>1;
            compressorThreshold=clamp(number(cmp,@"threshold"),-80,0);
            attack=exp(-1/(std::max(.001,number(cmp,@"attack",.01))*rate));
            release=exp(-1/(std::max(.01,number(cmp,@"release",.12))*rate));
        }
        if(enabled(limiter)) {
            limiterThreshold=db(clamp(number(limiter,@"threshold",-.8),-24,0));
            limiterOutput=db(clamp(number(limiter,@"outputgain"),-24,12)*strength);
            limiterRelease=exp(-1/(clamp(number(limiter,@"release",.12),.01,2)*rate));
        }
        double maxResponse=0;
        for(int i=0;i<512;++i) {
            double frequency=20*pow(std::min(24000.,rate*.49)/20.,double(i)/511), sum=0;
            for(const auto& b:filters) sum+=b.response(2*pi*frequency/rate);
            maxResponse=std::max(maxResponse,sum);
        }
        // Reserve headroom for EQ shelves and widened side energy. The final
        // linked peak limiter also catches reverb/IR transients without clipping.
        gain=db(pre-maxResponse-20*log10(std::max(1.,width)));
        if(left.length && irRate>0) {
            auto l=resample(left,irRate,rate), r=resample(right?:left,irRate,rate);
            ir[0]=std::make_unique<Convolver>(l); ir[1]=std::make_unique<Convolver>(r);
        }
    }
    void reset() {
        phase=envelope=0; limiterGain=1;
        for(auto& b:filters) { std::fill(std::begin(b.z1),std::end(b.z1),0); std::fill(std::begin(b.z2),std::end(b.z2),0); }
        for(auto& b:wetFilters) { std::fill(std::begin(b.z1),std::end(b.z1),0); std::fill(std::begin(b.z2),std::end(b.z2),0); }
        auto clear=[](Delay& d) { std::fill(d.samples.begin(),d.samples.end(),0); d.position=0; };
        clear(preDelay); clear(earlyDelay); clear(stereoDelay);
        for(auto& d:delays) clear(d);
        for(auto& d:dryIR) clear(d);
        std::fill(std::begin(damping),std::end(damping),0);
        for(auto& c:ir) if(c) c->reset();
    }
    void process(float *left, float *right, uint32_t count) {
        if(!active) return;
        for(uint32_t n=0;n<count;++n) {
            double l=left[n], r=right[n];
            for(auto& b:filters) { l=b.process(l,0); r=b.process(r,1); }
            if(ir[0]) {
                double wetL=ir[0]->process(float(l)),wetR=ir[1]->process(float(r));
                l=dryIR[0].tick(l)*(1-strength)+wetL*strength;
                r=dryIR[1].tick(r)*(1-strength)+wetR*strength;
            }
            double mid=(l+r)*.5, side=(l-r)*.5*width;
            side+=stereo*.035*(stereoDelay.read(size_t(rate*.006))-stereoDelay.read(size_t(rate*.011)));
            stereoDelay.tick(mid); l=mid+side; r=mid-side;
            if(phaseStep>0) {
                double pan=sin(phase)*strength*.85;
                l*=sqrt(1-pan); r*=sqrt(1+pan); phase+=phaseStep; if(phase>2*pi) phase-=2*pi;
            }
            if(useReverb) {
                double input=preDelay.tick((l+r)*.5), values[8],sum=0,wetL=0,wetR=0;
                for(int i=0;i<8;++i) { values[i]=delays[i].read(delays[i].samples.size()); sum+=values[i]; }
                for(int i=0;i<8;++i) {
                    // An orthogonal Householder feedback matrix remains stable
                    // at long decay times; diffusion interpolates its coupling.
                    double mixed=values[i]*(1-diffusion)+(sum*.25-values[i])*diffusion;
                    damping[i]=mixed*(1-damp)+damping[i]*damp;
                    delays[i].tick(input*.22+damping[i]*feedback[i]);
                    (i%2?wetR:wetL)+=values[i]*.5;
                }
                double erL=0,erR=0;
                for(int i=0;i<6;++i) (i%2?erR:erL)+=earlyDelay.read(earlyTaps[i])/(i+2);
                earlyDelay.tick((l+r)*.5);
                double wm=(wetL+wetR)*.5, ws=(wetL-wetR)*.5*reverbWidth;
                wetL=wm+ws; wetR=wm-ws;
                for(auto& b:wetFilters) { wetL=b.process(wetL,0); wetR=b.process(wetR,1); }
                l=l*dry+wetL*late+erL*early; r=r*dry+wetR*late+erR*early;
            }
            l*=gain; r*=gain;
            double peak=std::max(abs(l),abs(r));
            if(useDynamics) {
                double coefficient=peak>envelope?attack:release;
                envelope=coefficient*envelope+(1-coefficient)*peak;
                double over=20*log10(std::max(1e-12,envelope))-compressorThreshold;
                double reduction=over>0?db(-over*(1-1/compressorRatio)*strength):1;
                l*=reduction; r*=reduction; peak*=reduction;
            }
            double target=peak>limiterThreshold ? limiterThreshold/peak : 1;
            limiterGain=target<limiterGain?target:limiterRelease*limiterGain+(1-limiterRelease)*target;
            left[n]=float(clamp(l*limiterGain*limiterOutput,-1,1));
            right[n]=float(clamp(r*limiterGain*limiterOutput,-1,1));
        }
    }
};

struct Exchange {
    std::atomic<Kernel *> pending{nullptr}, retired{nullptr};
    std::atomic<bool> resetRequested{false};
    Kernel *active=nullptr;
    void reclaim() {
        Kernel *p=retired.exchange(nullptr);
        while(p) { Kernel *next=p->nextRetired; delete p; p=next; }
    }
    void publish(Kernel *kernel) { reclaim(); delete pending.exchange(kernel); }
    void render(float *left,float *right,uint32_t count) {
        if(Kernel *next=pending.exchange(nullptr)) {
            if(active) {
                Kernel *head=retired.load();
                do { active->nextRetired=head; } while(!retired.compare_exchange_weak(head,active));
            }
            active=next;
        }
        if(resetRequested.exchange(false) && active) active->reset();
        if(active) active->process(left,right,count);
    }
    ~Exchange() { delete pending.load(); delete active; reclaim(); }
};
}

@implementation LiltivaSoundEffectUnit {
    AUAudioUnitBusArray *_inputs, *_outputs;
    AVAudioPCMBuffer *_scratch;
    std::unique_ptr<Exchange> _exchange;
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    self=[super initWithComponentDescription:description options:options error:error];
    if(self) {
        AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        AUAudioUnitBus *input=[[AUAudioUnitBus alloc] initWithFormat:format error:error];
        AUAudioUnitBus *output=[[AUAudioUnitBus alloc] initWithFormat:format error:error];
        _inputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[input]];
        _outputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[output]];
        _exchange=std::make_unique<Exchange>();
        self.maximumFramesToRender=4096;
    }
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (void)reset {
    [super reset];
    if(_exchange) _exchange->resetRequested.store(true);
}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *format=_outputs[0].format;
    if(format.channelCount!=2 || format.commonFormat!=AVAudioPCMFormatFloat32 || format.interleaved) {
        if(error) *error=[NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    _scratch=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:self.maximumFramesToRender];
    return [super allocateRenderResourcesAndReturnError:error];
}
- (AUInternalRenderBlock)internalRenderBlock {
    Exchange *exchange=_exchange.get();
    // Capture only stable C pointers. The AU owns their lifetime and stops
    // rendering before deallocation/configuration of its bus buffers.
    AudioBufferList *scratch=_scratch.mutableAudioBufferList;
    AUAudioFrameCount maximum=self.maximumFramesToRender;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AUAudioFrameCount frames,
                            NSInteger bus,AudioBufferList *data,const AURenderEvent *events,AURenderPullInputBlock pull) {
        if(!pull) return kAudioUnitErr_NoConnection;
        if(frames>maximum) return kAudioUnitErr_TooManyFramesToProcess;
        for(UInt32 ch=0;ch<data->mNumberBuffers;++ch) {
            if(!data->mBuffers[ch].mData) data->mBuffers[ch].mData=scratch->mBuffers[ch].mData;
            data->mBuffers[ch].mDataByteSize=frames*sizeof(float);
        }
        AUAudioUnitStatus status=pull(flags,time,frames,0,data);
        if(status!=noErr) return status;
        if(data->mNumberBuffers!=2) return kAudioUnitErr_FormatNotSupported;
        exchange->render((float *)data->mBuffers[0].mData,(float *)data->mBuffers[1].mData,frames);
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    };
}
- (void)configureParameters:(NSData *)json sampleRate:(double)sampleRate strength:(double)strength
               impulseLeft:(NSData *)left impulseRight:(NSData *)right impulseSampleRate:(double)impulseSampleRate {
    NSDictionary *parameters=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    _exchange->publish(new Kernel(parameters?:@{},sampleRate,strength,left,right,impulseSampleRate));
}
@end
