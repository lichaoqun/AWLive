/*
 copyright 2016 wanghongyu.
 The project page：https://github.com/hardman/AWLive
 My blog page: http://www.jianshu.com/u/1240d2400ca1
 */

#import "AWHWH264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import "AWEncoderManager.h"

@interface AWHWH264Encoder()
@property (nonatomic, unsafe_unretained) VTCompressionSessionRef vEnSession;
@property (nonatomic, strong) dispatch_semaphore_t vSemaphore;
@property (nonatomic, copy) NSData *spsPpsData;
@property (nonatomic, copy) NSData *naluData;
@property (nonatomic, unsafe_unretained) BOOL isKeyFrame;

@end

@implementation AWHWH264Encoder

-(dispatch_semaphore_t)vSemaphore{
    if (!_vSemaphore) {
        _vSemaphore = dispatch_semaphore_create(0);
    }
    return _vSemaphore;
}

-(aw_flv_video_tag *)encodeYUVDataToFlvTag:(NSData *)yuvData{
    if (!_vEnSession) {
        return NULL;
    }
    //yuv 变成 转CVPixelBufferRef
    OSStatus status = noErr;
    
    //视频宽度
    size_t pixelWidth = self.videoConfig.pushStreamWidth;
    //视频高度
    size_t pixelHeight = self.videoConfig.pushStreamHeight;
    
    //现在要把NV12数据放入 CVPixelBufferRef中，因为 硬编码主要调用VTCompressionSessionEncodeFrame函数，此函数不接受yuv数据，但是接受CVPixelBufferRef类型。
    CVPixelBufferRef pixelBuf = NULL;
    //初始化pixelBuf，数据类型是kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange，此类型数据格式同NV12格式相同。
    CVPixelBufferCreate(NULL, pixelWidth, pixelHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pixelBuf);
    
    // Lock address，锁定数据，应该是多线程防止重入操作。
    if(CVPixelBufferLockBaseAddress(pixelBuf, 0) != kCVReturnSuccess){
        [self onErrorWithCode:AWEncoderErrorCodeLockSampleBaseAddressFailed des:@"encode video lock base address failed"];
        return NULL;
    }
    
    //将yuv数据填充到CVPixelBufferRef中
    size_t y_size = aw_stride(pixelWidth) * pixelHeight;
    size_t uv_size = y_size / 4;
    uint8_t *yuv_frame = (uint8_t *)yuvData.bytes;
    
    //处理y frame
    uint8_t *y_frame = CVPixelBufferGetBaseAddressOfPlane(pixelBuf, 0);
    memcpy(y_frame, yuv_frame, y_size);
    
    uint8_t *uv_frame = CVPixelBufferGetBaseAddressOfPlane(pixelBuf, 1);
    memcpy(uv_frame, yuv_frame + y_size, uv_size * 2);
    
    //硬编码 CmSampleBufRef
    
    //时间戳
    uint32_t ptsMs = self.manager.timestamp + 1; //self.vFrameCount++ * 1000.f / self.videoConfig.fps;
    
    CMTime pts = CMTimeMake(ptsMs, 1000);
    /*
     1. VTCompressionSessionRef
     2. 未编码的数据(可以直接使用摄像头才采集的数据, 不用上述的转换)     CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(videoSample);
     3. 时间戳
     4. 帧显示时间, 如果没有时间信息, KCMTimeInvalid
     5. 帧属性, NULL
     6. 编码过程的回调
     7. flags 同步/异步
     */
    //硬编码主要其实就这一句。将携带NV12数据的PixelBuf送到硬编码器中，进行编码。
    // - 注意 : typedef CVImageBufferRef CVPixelBufferRef; 两者是同一种数据类型
    status = VTCompressionSessionEncodeFrame(_vEnSession, pixelBuf, pts, kCMTimeInvalid, NULL, pixelBuf, NULL);
    
    //        1/3 判断 vtCompressionSessionCallback 和 VTCompressionSessionEncodeFrame 代码的先后顺序
//        NSLog(@"encoder VTCompressionSessionEncodeFrameStatsusChange ...");
    
    if (status == noErr) {
        // - 这里使用 信号量是因为上边要有返回值, 但是这里的编码操作是个异步操作, 为了给异步操作返回值, 这里就使用了信号量
        dispatch_semaphore_wait(self.vSemaphore, DISPATCH_TIME_FOREVER);
        
//        3/3 判断 vtCompressionSessionCallback 和 VTCompressionSessionEncodeFrame 代码的先后顺序(结论 先执行 VTCompressionSessionEncodeFrame的下一行代码 因为因为信号量的关系, 然后执行vtCompressionSessionCallback, 最后执行 dispatch_semaphore_wait 之后的代码)
//        NSLog(@"encoder statusChange ...");
        
        if (_naluData) {
            /* AVCC 格式*/
            //此处 硬编码成功，_naluData内的数据即为h264编码后的流数据.
            //我们是推流，所以获取帧长度，转成大端字节序，放到数据的最前面
            uint32_t naluLen = (uint32_t)_naluData.length;
            //小端转大端。计算机内一般都是小端，而网络和文件中一般都是大端。大端转小端和小端转大端算法一样，就是字节序反转就行了。
            uint8_t naluLenArr[4] = {naluLen >> 24 & 0xff, naluLen >> 16 & 0xff, naluLen >> 8 & 0xff, naluLen & 0xff};
            NSMutableData *mutableData = [NSMutableData dataWithBytes:naluLenArr length:4];
            [mutableData appendData:_naluData];
            
            /* ** ---- Annex B 格式 ---- **
             uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
             NSMutableData *mutableData = [NSMutableData dataWithBytes:startCode length:4];
             [mutableData appendData:_naluData];

             */

            //将h264数据合成flv tag，合成flvtag之后就可以直接发送到服务端了。后续会介绍
            aw_flv_video_tag *video_tag = aw_encoder_create_video_tag((int8_t *)mutableData.bytes, mutableData.length, ptsMs, 0, self.isKeyFrame);
            
            //到此，编码工作完成，清除状态。
            _naluData = nil;
            _isKeyFrame = NO;
            
            CVPixelBufferUnlockBaseAddress(pixelBuf, 0);
            
            CFRelease(pixelBuf);
            
            return video_tag;
        }
    }else{
        [self onErrorWithCode:AWEncoderErrorCodeEncodeVideoFrameFailed des:@"encode video frame error"];
    }
    CVPixelBufferUnlockBaseAddress(pixelBuf, 0);
    
    CFRelease(pixelBuf);
    
    return NULL;
}

-(aw_flv_video_tag *)createSpsPpsFlvTag{
    while(!self.spsPpsData) {
        dispatch_semaphore_wait(self.vSemaphore, DISPATCH_TIME_FOREVER);
    }
    aw_data *sps_pps_data = alloc_aw_data((uint32_t)self.spsPpsData.length);
    memcpy_aw_data(&sps_pps_data, (uint8_t *)self.spsPpsData.bytes, (uint32_t)self.spsPpsData.length);
    aw_flv_video_tag *sps_pps_tag = aw_encoder_create_sps_pps_tag(sps_pps_data);
    free_aw_data(&sps_pps_data);
    return sps_pps_tag;
}
/**
 赋值 encoder.spsPpsData   encoder.naluData  encoder.isKeyFrame
 */
static void vtCompressionSessionCallback (void * CM_NULLABLE outputCallbackRefCon,
                                          void * CM_NULLABLE sourceFrameRefCon,
                                          OSStatus status,
                                          VTEncodeInfoFlags infoFlags,
                                          CM_NULLABLE CMSampleBufferRef sampleBuffer ){
    //通过outputCallbackRefCon获取AWHWH264Encoder的对象指针，将编码好的h264数据传出去。
    
//    2/3 判断 vtCompressionSessionCallback 和 VTCompressionSessionEncodeFrame 代码的先后顺序
//    NSLog(@"encoder finish...");
    
    AWHWH264Encoder *encoder = (__bridge AWHWH264Encoder *)(outputCallbackRefCon);
    
//    1/1 这里验证每次进入到这个函数中的 encoder 都是同一个对象; (结论每次进入这个函数的都是同一个对象, 所以在上次一的encoder.nalu 没有处理完, 是不可以在此编码新的帧的)
//    NSLog(@"encoder ... %@", encoder);
    
    //判断是否编码成功
    if (status != noErr) {
        dispatch_semaphore_signal(encoder.vSemaphore);
        [encoder onErrorWithCode:AWEncoderErrorCodeEncodeVideoFrameFailed des:@"encode video frame error 1"];
        return;
    }
    
    //是否数据是完整的
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        dispatch_semaphore_signal(encoder.vSemaphore);
        [encoder onErrorWithCode:AWEncoderErrorCodeEncodeVideoFrameFailed des:@"encode video frame error 2"];
        return;
    }
    
    //是否是关键帧，关键帧和非关键帧要区分清楚只有关键帧有 sps 和 pps。推流时也要注明。
    BOOL isKeyFrame = !CFDictionaryContainsKey( (CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0)), kCMSampleAttachmentKey_NotSync);
    
    //首先获取sps 和pps
    //sps pss 也是h264的一部分，可以认为它们是特别的h264视频帧，保存了h264视频的一些必要信息。
    //没有这部分数据h264视频很难解析出来。
    //数据处理时，sps pps 数据可以作为一个普通h264帧，放在h264视频流的最前面。
    BOOL needSpsPps = NO;
    if (!encoder.spsPpsData) {
        if (isKeyFrame) {
            //获取avcC，这就是我们想要的sps和pps数据。
            //如果保存到文件中，需要将此数据前加上 [0 0 0 1] 4个字节，写入到h264文件的最前面。
            //如果推流，将此数据放入flv数据区即可。
            CMFormatDescriptionRef sampleBufFormat = CMSampleBufferGetFormatDescription(sampleBuffer);
            NSDictionary *dict = (__bridge NSDictionary *)CMFormatDescriptionGetExtensions(sampleBufFormat);
            
            // - 打印描述的字典
//            NSLog(@"sampleBufFormat description : %@", dict);

            // - spsPpsData : 01 4D 00 1F FF E1 00 0A 27 4D 00 1F AB 40 44 0F 3D E8 01 00 04 28 EE 3C 30
            
            /* 两种获取 sps pps的方式对应着两种不同的H.264流媒体协议格式中的Annex B格式和AVCC格式
             AVCC 格式: 代码中使用的格式
             dict[@"SampleDescriptionExtensionAtoms"][@"avcC"] + NALULen0(4字节) + NALU数据(NALULen0字节) + NALULen1(4字节) + NALU数据(NALULen1字节) + .... + NALULenx(4字节) + NALU数据(NALULenx字节)
             
             Annex B 格式 : 代码中注释的格式
                0x00000001(4字节) + sps + 0x00000001(4字节) + pps + 0x00000001(4字节) + NALU 数据 + 0x00000001(4字节) + NALU 数据 + ..... + 0x00000001(4字节) + NALU 数据
             */

            
            /* ** ---- AVCC ---- ** 格式 */
            encoder.spsPpsData = dict[@"SampleDescriptionExtensionAtoms"][@"avcC"];
            
            /* ** ---- Annex B ---- ** 格式
            size_t spsSize, spsCount;
            const uint8_t *spsContent;
            OSStatus spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sampleBufFormat, 0, &spsContent, &spsSize, &spsCount, 0);
            
            size_t ppsSize, ppsCount;
            const uint8_t *ppsContent;
            OSStatus ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sampleBufFormat, 1, &ppsContent, &ppsSize, &ppsCount, 0);
            
            NSMutableData *spsPpsData = [NSMutableData data];
            uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
            [spsPpsData appendBytes:startCode length:4];
            [spsPpsData appendBytes:spsContent length:spsSize];
            [spsPpsData appendBytes:startCode length:4];
            [spsPpsData appendBytes:ppsContent length:ppsSize];
            encoder.spsPpsData = spsPpsData;
             
            */
            
        }
        needSpsPps = YES;
    }
    
    //获取真正的视频帧数据 是很多 NALU 的合集
    // CMSampleBuffer在解码前存储的是 CVPixelBuffer, 解码后存储的是 CMBlockBuffer
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t blockDataLen;
    uint8_t *blockData;
    status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &blockDataLen, (char **)&blockData);
    // - vtCompressionSessionCallback 函数中
    // - blockData : 00 00 07 25 21 EB 2C 7F 7B DF...
    // - blockDataLen : 29 07 00 00
    // - NALULen : CFSwapInt32BigToHost 之前 : 00 00 07 25 CFSwapInt32BigToHost 之后 : 25 07 00 00
    // - encoder.naluData : 21 EB 2C 7F 7B DF...
    
    // - encodeYUVDataToFlvTag 函数中
    // - _naluData : 21 EB 2C 7F 7B DF...
    // - naluLen : 25 07 00 00
    // - mutableData 拼接之前 : 00 00 07 25  拼接之后 : 00 00 07 25 21 EB 2C 7F 7B DF...
    
    if (status == noErr) {
        
//        1/3 确定每次encoder 完成后产生多少 NALU
//        NSLog(@"NALU begin...==============");
        
        size_t currReadPos = 0;
        //一般情况下都是只有1个 nalu，在最开始编码的时候有2个，取最后1个
        // - 循环获取每个 nalu 每个 nalu 前边都有 4 字节的 nalu 流长度
        while (currReadPos < blockDataLen - 4) {
            uint32_t naluLen = 0;
            memcpy(&naluLen, blockData + currReadPos, 4);
            naluLen = CFSwapInt32BigToHost(naluLen);
            
            //naluData 即为一帧h264数据。
            //如果保存到文件中，需要将此数据前加上 [0 0 0 1] 4个字节，按顺序写入到h264文件中。
            //如果推流，需要将此数据前加上4个字节表示数据长度的数字，此数据需转为大端字节序.
            //关于大端和小端模式，请参考此网址：http://blog.csdn.net/hackbuteer1/article/details/7722667
            encoder.naluData = [NSData dataWithBytes:blockData + currReadPos + 4 length:naluLen];
            
            currReadPos += 4 + naluLen;
            
            encoder.isKeyFrame = isKeyFrame;
            
//            2/3 确定每次encoder 完成后产生多少 NALU
//            NSLog(@"NALU ing....****************");
            
        }
        
//        3/3 确定每次encoder 完成后产生多少 NALU(结论 除了第1 帧会产生两个 NALU外, 每次编码一个帧, 都只是产生一个 NALU)
//        NSLog(@"NALU end...================");
        
    }else{
        [encoder onErrorWithCode:AWEncoderErrorCodeEncodeGetH264DataFailed des:@"got h264 data failed"];
    }
    
    dispatch_semaphore_signal(encoder.vSemaphore);
    if (needSpsPps) {
        dispatch_semaphore_signal(encoder.vSemaphore);
    }
}

/** 创建并配置编码器 */
-(void)open{
    /* 配置编码器, 这里并不是立刻开始编码, 只是配置编码器
     1. 分配器  传 NULL
     2. 分辨率的 width
     3. 分辨率的 height
     4. 编码类型 kCMVideoCodecType_H264
     5. 编码规范 NULL
     6. 源像素缓冲区 NULL
     7. 压缩数据分配器 NULL
     8. 编码完成的回调
     9. self, 将 self 桥接过去
     10. VTCompressionSessionRef  &_vEnSession
     */
    OSStatus status = VTCompressionSessionCreate(NULL, (int32_t)(self.videoConfig.pushStreamWidth), (int32_t)self.videoConfig.pushStreamHeight, kCMVideoCodecType_H264, NULL, NULL, NULL, vtCompressionSessionCallback, (__bridge void * _Nullable)(self), &_vEnSession);
    
    /** 编码器创建成功 配置编码器的参数 */
    if (status == noErr) {
        // 设置参数
        // ProfileLevel，h264的协议等级，不同的清晰度使用不同的ProfileLevel。  kVTProfileLevel_H264_Baseline_AutoLevel 表示舍弃 B 帧
        VTSessionSetProperty(_vEnSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
        
        // 设置码率 通常设置为 宽 * 高 * 3 * 4 * 8;
//        int bitrate = width * height * 8 * 3 * 4;
//        CFNumberRef bitrateRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bitrateRef);
//        VTSessionSetProperty(_vEnSession, kVTCompressionPropertyKey_AverageBitRate, bitrate);
        VTSessionSetProperty(_vEnSession, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(self.videoConfig.bitrate));

        // 设置实时编码
        VTSessionSetProperty(_vEnSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        // 关闭重排Frame，因为有了B帧（双向预测帧，根据前后的图像计算出本帧）后，编码顺序可能跟显示顺序不同。此参数可以关闭B帧。
        VTSessionSetProperty(_vEnSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        
        // 关键帧最大间隔(GOP) 这里是 2s。
        VTSessionSetProperty(_vEnSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(self.videoConfig.fps * 2));
        
        // 关于B帧 P帧 和I帧，请参考：http://blog.csdn.net/abcjennifer/article/details/6577934
        //编码器参数设置完毕，准备开始，随时来数据，随时编码
        status = VTCompressionSessionPrepareToEncodeFrames(_vEnSession);
        if (status != noErr) {
            [self onErrorWithCode:AWEncoderErrorCodeVTSessionPrepareFailed des:@"硬编码vtsession prepare失败"];
        }
    }else{
        [self onErrorWithCode:AWEncoderErrorCodeVTSessionCreateFailed des:@"硬编码vtsession创建失败"];
    }
}

-(void)close{
    dispatch_semaphore_signal(self.vSemaphore);
    
    VTCompressionSessionInvalidate(_vEnSession);
    CFRelease(_vEnSession);
    _vEnSession = nil;
    
    self.naluData = nil;
    self.isKeyFrame = NO;
    self.spsPpsData = nil;
}

@end
