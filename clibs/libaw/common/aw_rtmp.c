/*
 copyright 2016 wanghongyu.
 The project page：https://github.com/hardman/AWLive
 My blog page: http://www.jianshu.com/u/1240d2400ca1
 */

#include "aw_rtmp.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "aw_utils.h"

// - RTMP_Write 的开源实现
int RTMP_Write1(RTMP *r, const char *buf, int size);

extern const char *aw_rtmp_state_description(aw_rtmp_state rtmp_state){
    switch (rtmp_state) {
        case aw_rtmp_state_idle: {
            return "aw_rtmp_state_idle";
        }
        case aw_rtmp_state_connecting: {
            return "aw_rtmp_state_connecting";
        }
        case aw_rtmp_state_connected: {
            return "aw_rtmp_state_connected";
        }
        case aw_rtmp_state_opened: {
            return "aw_rtmp_state_opened";
        }
        case aw_rtmp_state_closed: {
            return "aw_rtmp_state_closed";
        }
        case aw_rtmp_state_error_write: {
            return "aw_rtmp_state_error_write";
        }
        case aw_rtmp_state_error_open: {
            return "aw_rtmp_state_error_open";
        }
        case aw_rtmp_state_error_net: {
            return "aw_rtmp_state_error_net";
        }
    }
}

extern void aw_init_rtmp_context(aw_rtmp_context *ctx, const char *rtmp_url, aw_rtmp_state_changed_cb state_changed_cb){
    ctx->rtmp = NULL;
    ctx->rtmp_state = aw_rtmp_state_idle;
    
    memset(ctx->rtmp_url, 0, 256);
    size_t url_size = strlen(rtmp_url);
    if (url_size <= 0 || url_size >= 256) {
        AWLog("[error] when init rtmp_context rtmp_url is error");
    }else{
        memcpy(ctx->rtmp_url, rtmp_url, url_size);
    }
    
    ctx->write_error_retry_curr_time = 0;
    ctx->write_error_retry_time_limit = 5;
    ctx->open_error_retry_curr_time = 0;
    ctx->open_error_retry_time_limit = 3;
    ctx->state_changed_cb = state_changed_cb;
}

extern aw_rtmp_context *alloc_aw_rtmp_context(const char *rtmp_url, aw_rtmp_state_changed_cb state_changed_cb){
    aw_rtmp_context *ctx = aw_alloc(sizeof(aw_rtmp_context));
    memset(ctx, 0, sizeof(aw_rtmp_context));
    aw_init_rtmp_context(ctx, rtmp_url, state_changed_cb);
    return ctx;
}

extern void free_aw_rtmp_context(aw_rtmp_context **ctx){
    aw_rtmp_context *inner_ctx = *ctx;
    
    if (inner_ctx) {
        if (inner_ctx->rtmp) {
            aw_rtmp_close(inner_ctx);
        }
        aw_free(inner_ctx);
    }
    *ctx = NULL;
}

static void aw_set_rtmp_state(aw_rtmp_context *ctx, aw_rtmp_state new_state);

static void aw_rtmp_state_changed_inner(aw_rtmp_context *ctx, aw_rtmp_state old_state, aw_rtmp_state new_state){
    switch (new_state) {
        case aw_rtmp_state_idle: {
            ctx->write_error_retry_curr_time = 0;
            ctx->is_header_sent = 0;
            
            //总时间
            ctx->total_duration += ctx->current_time_stamp;
            
            //当前流时间戳
            ctx->current_time_stamp = 0;
            break;
        }
        case aw_rtmp_state_opened: {
            ctx->open_error_retry_curr_time = 0;
            break;
        }
        case aw_rtmp_state_connected:{
            aw_set_rtmp_state(ctx, aw_rtmp_state_opened);
            break;
        }
        case aw_rtmp_state_closed: {
            aw_set_rtmp_state(ctx, aw_rtmp_state_idle);
            break;
        }
        case aw_rtmp_state_error_write: {
            aw_set_rtmp_state(ctx, old_state);
            //写入错误次数过多 重连
            if (ctx->write_error_retry_curr_time >= ctx->write_error_retry_time_limit) {
                aw_rtmp_close(ctx);
                aw_rtmp_open(ctx);
            }else{
                ctx->write_error_retry_curr_time++;
            }
            break;
        }
        case aw_rtmp_state_error_open: {
            aw_set_rtmp_state(ctx, aw_rtmp_state_idle);
            //open错误次数过多，认为网络错误
            if (ctx->open_error_retry_curr_time >= ctx->open_error_retry_curr_time) {
                aw_set_rtmp_state(ctx, aw_rtmp_state_error_net);
            }else{
                ctx->open_error_retry_curr_time++;
            }
            break;
        }
        case aw_rtmp_state_error_net:{
            ctx->open_error_retry_curr_time = 0;
            aw_set_rtmp_state(ctx, aw_rtmp_state_idle);
            break;
        }
        case aw_rtmp_state_connecting:
            break;
    }
}

static void aw_set_rtmp_state(aw_rtmp_context *ctx, aw_rtmp_state new_state){
    if (ctx->rtmp_state == new_state) {
        return;
    }
    aw_rtmp_state old_state = ctx->rtmp_state;
    ctx->rtmp_state = new_state;
    
    //回调用户接口
    if (ctx->state_changed_cb) {
        ctx->state_changed_cb(old_state, new_state);
    }
    
    //内部处理
    aw_rtmp_state_changed_inner(ctx, old_state, new_state);
}

int8_t aw_is_rtmp_opened(aw_rtmp_context *ctx){
    return ctx && ctx->rtmp != NULL;
}

int aw_rtmp_open(aw_rtmp_context *ctx){
    if (aw_is_rtmp_opened(ctx) || ctx->rtmp_state != aw_rtmp_state_idle) {
        AWLog("[error] static_aw_rtmp is in use");
        return 0;
    }
    if (strlen(ctx->rtmp_url) <= 0 || strlen(ctx->rtmp_url) > 255) {
        AWLog("[error ] aw rtmp setup url = %s\n", ctx->rtmp_url);
        return 0;
    }
    aw_set_rtmp_state(ctx, aw_rtmp_state_connecting);
    int recode = 0;
    ctx->rtmp = RTMP_Alloc();
    RTMP_Init(ctx->rtmp);
    ctx->rtmp->Link.timeout = 1;
    if (!RTMP_SetupURL(ctx->rtmp, ctx->rtmp_url)) {
        AWLog("[error ] aw rtmp setup url = %s\n", ctx->rtmp_url);
        recode = -2;
        goto FAILED;
    }
    
    RTMP_EnableWrite(ctx->rtmp);
    
    RTMP_SetBufferMS(ctx->rtmp, 3 * 1000);
    
    if (!RTMP_Connect(ctx->rtmp, NULL)) {
        recode = -3;
        goto FAILED;
    }
    
    if (!RTMP_ConnectStream(ctx->rtmp, 0)) {
        recode = -4;
        goto FAILED;
    }
    aw_set_rtmp_state(ctx, aw_rtmp_state_connected);
    return 1;
FAILED:
    aw_rtmp_close(ctx);
    aw_set_rtmp_state(ctx, aw_rtmp_state_error_open);
    return !recode;
}

int aw_rtmp_close(aw_rtmp_context *ctx){
    AWLog("aw rtmp closing.......\n");
    if (aw_is_rtmp_opened(ctx)) {
        signal(SIGPIPE, SIG_IGN);
        RTMP_Close(ctx->rtmp);
        RTMP_Free(ctx->rtmp);
        ctx->rtmp = NULL;
        AWLog("aw rtmp closed.......\n");
        aw_set_rtmp_state(ctx, aw_rtmp_state_closed);
    }
    return 1;
}

int aw_rtmp_write(aw_rtmp_context *ctx, const char *buf, int size){
    if (!aw_is_rtmp_opened(ctx)) {
        AWLog("[error] aw rtmp writing but rtmp is not open");
        return 0;
    }
    signal(SIGPIPE, SIG_IGN);
    
    /* 测试代码 测试发送自定义的数据 RTMP_Write1 为 RTMP_Write 的函数实现, 写在这里是为了看下实现源码
     char bytes[] = {0x09, 0x00, 0x00, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                       0x00, 0x17, 0x00, 0x00, 0x00, 0x00, 0x01, 0x4D, 0x00, 0x1F,
                       0xFF, 0xE1, 0x00, 0x0A, 0x27, 0x4D, 0x00, 0x1F, 0xAB, 0x40,
                       0x44, 0x0F, 0x3D, 0xE8, 0x01, 0x00, 0x04, 0x28, 0xEE, 0x3C,
                       0x30, 0x00, 0x00, 0x00, 0x29};
     int write_ret = RTMP_Write1(ctx->rtmp, bytes, sizeof(bytes) / sizeof(char));
     
     */
    
    int write_ret = RTMP_Write(ctx->rtmp, buf, size);
    if (write_ret <= 0) {
        aw_set_rtmp_state(ctx, aw_rtmp_state_error_write);
    }
    return write_ret;
}

uint32_t aw_rtmp_time(){
    return RTMP_GetTime();
}

// - RTMP_Write的实现
static const AVal av_setDataFrame = AVC("@setDataFrame");
int RTMP_Write1(RTMP *r, const char *buf, int size)
{
  RTMPPacket *pkt = &r->m_write;
  char *pend, *enc;
  int s2 = size, ret, num;

  pkt->m_nChannel = 0x04;    /* source channel */
  pkt->m_nInfoField2 = r->m_stream_id;

  while (s2)
    {
      if (!pkt->m_nBytesRead)
    {
      if (size < 11) {
        /* FLV pkt too small */
        return 0;
      }

      if (buf[0] == 'F' && buf[1] == 'L' && buf[2] == 'V')
        {
          buf += 13;
          s2 -= 13;
        }

      pkt->m_packetType = *buf++;
      pkt->m_nBodySize = AMF_DecodeInt24(buf);
      buf += 3;
      pkt->m_nTimeStamp = AMF_DecodeInt24(buf);
      buf += 3;
      pkt->m_nTimeStamp |= *buf++ << 24;
      buf += 3;
      s2 -= 11;

      if (((pkt->m_packetType == RTMP_PACKET_TYPE_AUDIO
                || pkt->m_packetType == RTMP_PACKET_TYPE_VIDEO) &&
            !pkt->m_nTimeStamp) || pkt->m_packetType == RTMP_PACKET_TYPE_INFO)
        {
          pkt->m_headerType = RTMP_PACKET_SIZE_LARGE;
          if (pkt->m_packetType == RTMP_PACKET_TYPE_INFO)
        pkt->m_nBodySize += 16;
        }
      else
        {
          pkt->m_headerType = RTMP_PACKET_SIZE_MEDIUM;
        }

      if (!RTMPPacket_Alloc(pkt, pkt->m_nBodySize))
        {
          return FALSE;
        }
      enc = pkt->m_body;
      pend = enc + pkt->m_nBodySize;
      if (pkt->m_packetType == RTMP_PACKET_TYPE_INFO)
        {
          enc = AMF_EncodeString(enc, pend, &av_setDataFrame);
          pkt->m_nBytesRead = enc - pkt->m_body;
        }
    }
      else
    {
      enc = pkt->m_body + pkt->m_nBytesRead;
    }
      num = pkt->m_nBodySize - pkt->m_nBytesRead;
      if (num > s2)
    num = s2;
      memcpy(enc, buf, num);
      pkt->m_nBytesRead += num;
      s2 -= num;
      buf += num;
      if (pkt->m_nBytesRead == pkt->m_nBodySize)
    {
      ret = RTMP_SendPacket(r, pkt, FALSE);
      RTMPPacket_Free(pkt);
      pkt->m_nBytesRead = 0;
      if (!ret)
        return -1;
      buf += 4;
      s2 -= 4;
      if (s2 < 0)
        break;
    }
    }
  return size+s2;
}
