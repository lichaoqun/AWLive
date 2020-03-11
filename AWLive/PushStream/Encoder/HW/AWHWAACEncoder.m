/*
 copyright 2016 wanghongyu.
 The project page：https://github.com/hardman/AWLive
 My blog page: http://www.jianshu.com/u/1240d2400ca1
 */

#import "AWHWAACEncoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import "AWEncoderManager.h"

@interface AWHWAACEncoder()
//audio params
@property (nonatomic, strong) NSData *curFramePcmData;

@property (nonatomic, unsafe_unretained) AudioConverterRef aConverter;
@property (nonatomic, unsafe_unretained) uint32_t aMaxOutputFrameSize;

@property (nonatomic, unsafe_unretained) aw_faac_config faacConfig;
@end

@implementation AWHWAACEncoder

static OSStatus aacEncodeInputDataProc(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData){
    AWHWAACEncoder *hwAacEncoder = (__bridge AWHWAACEncoder *)inUserData;
    if (hwAacEncoder.curFramePcmData) {
        // - 填充需要编码的数据
        ioData->mBuffers[0].mData = (void *)hwAacEncoder.curFramePcmData.bytes;
        ioData->mBuffers[0].mDataByteSize = (uint32_t)hwAacEncoder.curFramePcmData.length;
        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mNumberChannels = (uint32_t)hwAacEncoder.audioConfig.channelCount;
        
        return noErr;
    }
    
    return -1;
}

-(aw_flv_audio_tag *)encodePCMDataToFlvTag:(NSData *)pcmData{
    /* 直接根据 sampleBuffer 的转换的另一种写法
     CFRetain(sampleBuffer);
     CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
     CFRetain(blockBuffer);
     size_t  pcmDataLen;
     uint8_t *pcmData;
     OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &pcmDataLen, &pcmData);
     self.curFramePcmData =  [NSData dataWithBytes:pcmData length:pcmDataLen];
     */
    self.curFramePcmData = pcmData;

    // - 赋值outAudioBufferList
    AudioBufferList outAudioBufferList = {0};
    outAudioBufferList.mNumberBuffers = 1;
    outAudioBufferList.mBuffers[0].mNumberChannels = (uint32_t)self.audioConfig.channelCount;
    outAudioBufferList.mBuffers[0].mDataByteSize = self.aMaxOutputFrameSize;
    outAudioBufferList.mBuffers[0].mData = malloc(self.aMaxOutputFrameSize);
    
    UInt32 outputDataPacketSize = 1;
    //配置填充函数，获取输出数据
    //转换由输入回调函数提供的数据
    /*
     参数1: inAudioConverter 音频转换器
     参数2: inInputDataProc 回调函数.提供要转换的音频数据的回调函数。当转换器准备好接受新的输入数据时，会重复调用此回调.
     参数3: inInputDataProcUserData
     参数4: inInputDataProcUserData,self
     参数5: ioOutputDataPacketSize,输出缓冲区的大小
     参数6: outOutputData,编码后输出的数据
     参数7: outPacketDescription,输出包信息
     */
    OSStatus status = AudioConverterFillComplexBuffer(_aConverter, aacEncodeInputDataProc, (__bridge void * _Nullable)(self), &outputDataPacketSize, &outAudioBufferList, NULL);
    if (status == noErr) {
        NSData *rawAAC = [NSData dataWithBytesNoCopy: outAudioBufferList.mBuffers[0].mData length:outAudioBufferList.mBuffers[0].mDataByteSize];
        self.manager.timestamp += 1024 * 1000 / self.audioConfig.sampleRate;
        return aw_encoder_create_audio_tag((int8_t *)rawAAC.bytes, rawAAC.length, (uint32_t)self.manager.timestamp, &_faacConfig);
    }else{
        [self onErrorWithCode:AWEncoderErrorCodeAudioEncoderFailed des:@"aac 编码错误"];
    }
    
    return NULL;
}

-(aw_flv_audio_tag *)createAudioSpecificConfigFlvTag{
    uint8_t profile = kMPEG4Object_AAC_LC;
    uint8_t sampleRate = 4;
    uint8_t chanCfg = 1;
    uint8_t config1 = (profile << 3) | ((sampleRate & 0xe) >> 1);
    uint8_t config2 = ((sampleRate & 0x1) << 7) | (chanCfg << 3);
    
    aw_data *config_data = NULL;
    data_writer.write_uint8(&config_data, config1);
    data_writer.write_uint8(&config_data, config2);
    
    aw_flv_audio_tag *audio_specific_config_tag = aw_encoder_create_audio_specific_config_tag(config_data, &_faacConfig);
    
    free_aw_data(&config_data);
    
    return audio_specific_config_tag;
}

-(void)open{
    //创建audio encode converter
    /* - 输入的音频参数, 可以通过 CMSampleBufferRef 直接取到;
         AudioStreamBasicDescription inputAduioDes = *CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sampleBuffer));
    */
    AudioStreamBasicDescription inputAudioDes = {
        .mFormatID = kAudioFormatLinearPCM,
        .mSampleRate = self.audioConfig.sampleRate,
        .mBitsPerChannel = (uint32_t)self.audioConfig.sampleSize,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2,
        .mBytesPerPacket = 2,
        .mChannelsPerFrame = (uint32_t)self.audioConfig.channelCount,
        .mFormatFlags = kLinearPCMFormatFlagIsPacked | kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsNonInterleaved,
        .mReserved = 0
    };
    
    // - 输出音频参数
    AudioStreamBasicDescription outputAudioDes = {
       .mSampleRate = (Float64)self.audioConfig.sampleRate,       //采样率
       .mFormatID = kAudioFormatMPEG4AAC,                //输出格式
       .mFormatFlags = kMPEG4Object_AAC_LC,              // 如果设为0 代表无损编码
       .mBytesPerPacket = 0,                             //自己确定每个packet 大小
       .mFramesPerPacket = 1024,                         //每一个packet帧数 AAC-1024；
       .mBytesPerFrame = 0,                              //每一帧大小
       .mChannelsPerFrame = (uint32_t)self.audioConfig.channelCount, //输出声道数
       .mBitsPerChannel = 0,                             //数据帧中每个通道的采样位数。
       .mReserved =  0                                  //对其方式 0(8字节对齐)
    };
    
    // - 填充输出的相关参数 测试 如果outputAudioDes 参数填充完全的话, 是不需要调用下边的函数的
//    UInt32 outDesSize = sizeof(outputAudioDes);
//    AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &outDesSize, &outputAudioDes);
    
    // - 创建编码器
    /* 此功能与AudioConverterNewSpecific功能相同，不同之处在于，AudioConverterNewSpecific可以显式选择要实例化的编解码器, 而 AudioConverterNew 不可以选择编码器
     // - 使用软编码
     AudioClassDescription *audioClassDesc = [self getAudioCalssDescriptionWithType:outputAudioDes.mFormatID fromManufacture:kAppleSoftwareAudioCodecManufacturer];
     OSStatus status = AudioConverterNewSpecific(&inputAduioDes, &outputAudioDes, 1, audioClassDesc, &_audioConverter);
     */
    OSStatus status = AudioConverterNew(&inputAudioDes, &outputAudioDes, &_aConverter);
    if (status != noErr) {
        [self onErrorWithCode:AWEncoderErrorCodeCreateAudioConverterFailed des:@"硬编码AAC创建失败"];
    }
    
    //设置码率
    uint32_t aBitrate = (uint32_t)self.audioConfig.bitrate;
    uint32_t aBitrateSize = sizeof(aBitrate);
    status = AudioConverterSetProperty(_aConverter, kAudioConverterEncodeBitRate, aBitrateSize, &aBitrate);
    
    //查询最大输出
    uint32_t aMaxOutput = 0;
    uint32_t aMaxOutputSize = sizeof(aMaxOutput);
    AudioConverterGetProperty(_aConverter, kAudioConverterPropertyMaximumOutputPacketSize, &aMaxOutputSize, &aMaxOutput);
    self.aMaxOutputFrameSize = aMaxOutput;
    if (aMaxOutput == 0) {
        [self onErrorWithCode:AWEncoderErrorCodeAudioConverterGetMaxFrameSizeFailed des:@"AAC 获取最大frame size失败"];
    }
}

// - 根据编码格式和一个编码方式(软/硬编码)返回一个编码器的描述 在使用 AudioConverterNewSpecific 生成编码器时候用到
- (AudioClassDescription *)getAudioCalssDescriptionWithType: (AudioFormatID)type fromManufacture: (uint32_t)manufacture {
    
    static AudioClassDescription desc;
    UInt32 encoderSpecific = type;
    
    //获取满足AAC编码器的总大小
    UInt32 size;
    
    /**
     参数1：编码器类型
     参数2：类型描述大小
     参数3：类型描述
     参数4：大小
     */
    OSStatus status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecific), &encoderSpecific, &size);
    if (status != noErr) {
        NSLog(@"Error！：硬编码AAC get info 失败, status= %d", (int)status);
        return nil;
    }
    //计算aac编码器的个数
    unsigned int count = size / sizeof(AudioClassDescription);
    //创建一个包含count个编码器的数组
    AudioClassDescription description[count];
    //将满足aac编码的编码器的信息写入数组
    status = AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecific), &encoderSpecific, &size, &description);
    if (status != noErr) {
        NSLog(@"Error！：硬编码AAC get propery 失败, status= %d", (int)status);
        return nil;
    }
    for (unsigned int i = 0; i < count; i++) {
        if (type == description[i].mSubType && manufacture == description[i].mManufacturer) {
            desc = description[i];
            return &desc;
        }
    }
    return nil;
}


-(void)close{
    AudioConverterDispose(_aConverter);
    _aConverter = nil;
    self.curFramePcmData = nil;
    self.aMaxOutputFrameSize = 0;
}

@end
