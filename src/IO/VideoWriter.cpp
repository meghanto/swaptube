#include "VideoWriter.h"
#include "../Core/State/GlobalState.h"
#include "../Core/Smoketest.h"

#include <iostream>
#include <string>
#include <sstream>
#include <cassert>
#include <chrono>
#include <vector>
#include "Writer.h"
#include <cstdlib>

#if defined(USE_NVIDIA)
    #define PIXEL_FORMAT AV_PIX_FMT_CUDA
    #define HWDEVICE_TYPE AV_HWDEVICE_TYPE_CUDA
    #define CODEC_NAME "hevc_nvenc"
#elif defined(USE_AMD)
    #define PIXEL_FORMAT AV_PIX_FMT_VAAPI
    #define HWDEVICE_TYPE AV_HWDEVICE_TYPE_VAAPI
    #define CODEC_NAME "av1_vaapi"
#else // Placeholders, shouldn't actually happen
    #define PIXEL_FORMAT AV_PIX_FMT_YUV420P
    #define HWDEVICE_TYPE AV_HWDEVICE_TYPE_NONE
    #define CODEC_NAME "libx265"
#endif

using namespace std;

const bool USE_LIVE = false;

static bool terminal_preview_enabled() {
    const char* quiet = std::getenv("SWAPTUBE_QUIET");
    return quiet == nullptr || quiet[0] == '\0' || string(quiet) == "0";
}

#if defined(USE_NVIDIA)
extern "C" int cuda_diagnostic_sync(char* error_message, size_t error_message_size);

static void check_cuda_boundary(const char* boundary) {
    const char* diagnostics = std::getenv("SWAPTUBE_CUDA_DIAGNOSTICS");
    if (diagnostics == nullptr || diagnostics[0] == '\0' || string(diagnostics) == "0") return;

    char error_message[256] = {};
    if (cuda_diagnostic_sync(error_message, sizeof(error_message)) != 0) {
        throw runtime_error(string("CUDA failure ") + boundary + ": " + error_message);
    }
}
#endif

extern "C" void preprocess_argb_to_p010(
    const uint32_t* d_argb,
    uint16_t* d_y_plane,
    uint16_t* d_uv_plane,
    int fd,
    size_t obj_size,
    int width,
    int height,
    int y_pitch_bytes,
    int uv_pitch_bytes,
    unsigned long long y_offset,
    unsigned long long uv_offset,
    uint32_t bg
);

extern "C" void preprocess_argb_to_nv12(
    const uint32_t* d_argb,
    uint8_t* d_y_plane,
    uint8_t* d_uv_plane,
    int width,
    int height,
    int y_pitch_bytes,
    int uv_pitch_bytes,
    uint32_t bg
);

extern "C" void cuda_copy_pixels_to_host(uint32_t* h_pixels, int size, uint32_t* d_pixels);

bool VideoWriter::encode_and_write_frame(AVFrame* frame){
    int ret = avcodec_send_frame(videoCodecContext, frame);
    //if (ret == AVERROR_EOF) return false;
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        throw runtime_error(string("avcodec_send_frame failed: ") + errbuf);
    }

    while (true) {
        int ret2 = avcodec_receive_packet(videoCodecContext, &pkt);
        if (ret2 == 0) {
            av_packet_rescale_ts(&pkt, videoCodecContext->time_base, videoStream->time_base);
            pkt.stream_index = videoStream->index;
            av_interleaved_write_frame(fc, &pkt);
            av_packet_unref(&pkt);
        } else if (ret2 == AVERROR(EAGAIN)) {
            return true;
        } else if (ret2 == AVERROR_EOF) {
            cout << "Encoder flushed, no more packets to receive." << endl;
            return false;
        } else
            throw runtime_error("Failed to receive video packet!");
    }

    return true;
}

static void cleanup_codec_context(AVCodecContext*& codec_ctx) {
    if (codec_ctx) {
        avcodec_free_context(&codec_ctx);
        codec_ctx = nullptr;
    }
}

static AVCodecContext* attempt_codec_init(
    const AVCodec* codec,
    AVBufferRef* hw_device_ctx,
    AVPixelFormat pix_fmt,
    AVPixelFormat sw_fmt,
    int video_width_pixels,
    int video_height_pixels,
    int video_framerate_fps)
{
    AVCodecContext* codec_ctx = avcodec_alloc_context3(codec);
    if (!codec_ctx) {
        return nullptr;
    }

    codec_ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
    if (!codec_ctx->hw_device_ctx) {
        avcodec_free_context(&codec_ctx);
        return nullptr;
    }

    codec_ctx->width = video_width_pixels;
    codec_ctx->height = video_height_pixels;
    codec_ctx->pix_fmt = pix_fmt;
    codec_ctx->colorspace = AVCOL_SPC_BT709;
    codec_ctx->color_primaries = AVCOL_PRI_BT709;
    codec_ctx->color_trc = AVCOL_TRC_BT709;
    codec_ctx->time_base = { 1, video_framerate_fps };
    codec_ctx->framerate = { video_framerate_fps, 1 };
    codec_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    AVBufferRef* hw_frames_ctx = av_hwframe_ctx_alloc(codec_ctx->hw_device_ctx);
    if (!hw_frames_ctx) {
        av_buffer_unref(&codec_ctx->hw_device_ctx);
        avcodec_free_context(&codec_ctx);
        return nullptr;
    }

    AVHWFramesContext* frames_ctx = reinterpret_cast<AVHWFramesContext*>(hw_frames_ctx->data);
    frames_ctx->format = pix_fmt;
    frames_ctx->sw_format = sw_fmt;
    frames_ctx->width = video_width_pixels;
    frames_ctx->height = video_height_pixels;
    frames_ctx->initial_pool_size = 4;

    int ret = av_hwframe_ctx_init(hw_frames_ctx);
    if (ret < 0) {
        av_buffer_unref(&hw_frames_ctx);
        av_buffer_unref(&codec_ctx->hw_device_ctx);
        avcodec_free_context(&codec_ctx);
        return nullptr;
    }

    codec_ctx->hw_frames_ctx = hw_frames_ctx;
    return codec_ctx;
}

VideoWriter::VideoWriter(AVFormatContext *fc_, const string& video_path, int video_width_pixels, int video_height_pixels, int video_framerate_fps) : fc(fc_) {
    if (USE_LIVE) {
        live_player = new LivePlayer(ivec2(video_width_pixels, video_height_pixels));
        return;
    }

    #ifdef USE_AMD
    #ifdef _WIN32
    _putenv_s("AMD_DEBUG", "notiling");
    #else
    setenv("AMD_DEBUG", "notiling", 1);
    #endif
    #endif
    av_log_set_level(AV_LOG_DEBUG);

    // Validate dimensions are even (required for 4:2:0 subsampling)
    if ((video_width_pixels & 1) || (video_height_pixels & 1)) {
        throw runtime_error("VideoWriter: width and height must be even for 4:2:0 encoding. Got " +
                          to_string(video_width_pixels) + "x" + to_string(video_height_pixels));
    }

    // Setting up the codec.
    const AVCodec* codec = avcodec_find_encoder_by_name(CODEC_NAME);
    if (!codec) {
        throw runtime_error("Failed to find video codec");
    }

    AVBufferRef* hw_device_ctx = nullptr;
    int ret = av_hwdevice_ctx_create(&hw_device_ctx, HWDEVICE_TYPE, nullptr, nullptr, 0);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        cout << "Failed to create CUDA device context: " << errbuf << endl;
        throw runtime_error("Failed to create CUDA device context!");
    }

    videoStream = avformat_new_stream(fc, codec);
    if (!videoStream) {
        av_buffer_unref(&hw_device_ctx);
        throw runtime_error("Failed to create new videostream!");
    }

    // Try P010LE first on NVIDIA, then fall back to NV12 if it fails
    #ifdef USE_NVIDIA
    vector<pair<AVPixelFormat, HWFrameFormat>> formats_to_try = {
        {AV_PIX_FMT_P010LE, HWFrameFormat::P010LE},
        {AV_PIX_FMT_NV12, HWFrameFormat::NV12}
    };
    #else
    // AMD always uses P010LE
    vector<pair<AVPixelFormat, HWFrameFormat>> formats_to_try = {
        {AV_PIX_FMT_P010LE, HWFrameFormat::P010LE}
    };
    #endif

    string p010_error_msg;
    bool codec_opened = false;

    for (size_t fmt_idx = 0; fmt_idx < formats_to_try.size(); ++fmt_idx) {
        AVPixelFormat sw_fmt = formats_to_try[fmt_idx].first;
        HWFrameFormat format_enum = formats_to_try[fmt_idx].second;

        // Attempt to initialize codec context with this format
        videoCodecContext = attempt_codec_init(
            codec,
            hw_device_ctx,
            PIXEL_FORMAT,
            sw_fmt,
            video_width_pixels,
            video_height_pixels,
            video_framerate_fps
        );

        if (!videoCodecContext) {
            char errbuf[256];
            av_strerror(ret, errbuf, sizeof(errbuf));
            string format_name = (sw_fmt == AV_PIX_FMT_P010LE) ? "P010LE" : "NV12";
            cerr << "Failed to allocate codec context for " << format_name << ": " << errbuf << endl;
            continue;
        }

        // Try to open the codec with this format
        AVDictionary* opt = NULL;
        av_dict_set(&opt, "qp", "20", 0);
        av_dict_set(&opt, "global_quality", "20", 0);

        int ret2 = avcodec_open2(videoCodecContext, codec, &opt);
        av_dict_free(&opt);

        if (ret2 < 0) {
            char errbuf[256];
            av_strerror(ret2, errbuf, sizeof(errbuf));
            string format_name = (sw_fmt == AV_PIX_FMT_P010LE) ? "P010LE" : "NV12";
            string msg = string("Failed to open hevc_nvenc with ") + format_name + ": " + errbuf;
            cerr << msg << endl;

            if (fmt_idx == 0 && sw_fmt == AV_PIX_FMT_P010LE) {
                p010_error_msg = msg;
            }

            // Clean up failed attempt
            cleanup_codec_context(videoCodecContext);
            continue;
        }

        // Successfully opened codec with this format
        negotiated_format = format_enum;
        codec_opened = true;

        if (sw_fmt == AV_PIX_FMT_NV12) {
            cout << "NVIDIA NVENC fallback: P010LE failed, using NV12 instead" << endl;
            if (!p010_error_msg.empty()) {
                cout << "  P010LE error: " << p010_error_msg << endl;
            }
        }
        break;
    }

    if (!codec_opened) {
        cleanup_codec_context(videoCodecContext);
        av_buffer_unref(&hw_device_ctx);
        throw runtime_error("Failed to open video codec with any supported format!");
    }

    ret = avcodec_parameters_from_context(videoStream->codecpar, videoCodecContext);
    if (ret < 0) {
        cleanup_codec_context(videoCodecContext);
        av_buffer_unref(&hw_device_ctx);
        throw runtime_error("Failed avcodec_parameters_from_context!");
    }

    ret = avio_open(&fc->pb, video_path.c_str(), AVIO_FLAG_WRITE);
    if (ret < 0) {
        cleanup_codec_context(videoCodecContext);
        av_buffer_unref(&hw_device_ctx);
        throw runtime_error("Failed avio_open!");
    }

    AVDictionary* opt = NULL;
    ret = avformat_write_header(fc, &opt);
    av_dict_free(&opt);
    if (ret < 0) {
        cout << "Failed to write header: " << ff_errstr(ret) << endl;
        cleanup_codec_context(videoCodecContext);
        av_buffer_unref(&hw_device_ctx);
        throw runtime_error("Failed to write header!");
    }

    av_buffer_unref(&hw_device_ctx);
}

void VideoWriter::add_frame(uint32_t* device_pixels) {
    bool live = rendering_on();

    #if defined(USE_NVIDIA)
    check_cuda_boundary("before encoder preprocessing");
    #endif

    static auto last_print_time = chrono::steady_clock::time_point::min();
    auto now = chrono::steady_clock::now();
    if(terminal_preview_enabled() &&
       (!live || last_print_time == chrono::steady_clock::time_point::min() || chrono::duration_cast<chrono::seconds>(now - last_print_time).count() >= 1)) {
        Pixels p(get_video_dimensions_pixels());
        cuda_copy_pixels_to_host(p.pixels.data(), get_video_width_pixels() * get_video_height_pixels(), device_pixels);
        p.print_to_terminal();
        last_print_time = now;
    }

    if (!live) return; // Don't encode video in smoketest

    if (USE_LIVE) {
        live_player->accept_frame(device_pixels, false);
        return;
    }

    AVFrame* gpu_frame = av_frame_alloc();
    if (!gpu_frame) {
        throw runtime_error("Failed to allocate frame!");
    }

    gpu_frame->format = PIXEL_FORMAT;
    gpu_frame->width  = get_video_width_pixels();
    gpu_frame->height = get_video_height_pixels();
    gpu_frame->hw_frames_ctx = av_buffer_ref(videoCodecContext->hw_frames_ctx);

    int ret = av_hwframe_get_buffer(videoCodecContext->hw_frames_ctx, gpu_frame, 0);
    if (ret < 0) {
        av_frame_free(&gpu_frame);
        throw runtime_error("Failed to allocate hardware frame buffer!");
    }
    
    // Initialize values only used on AMD
    int fd = 0;
    size_t obj_size = 0;
    unsigned long long y_offset = 0;
    unsigned long long uv_offset = 0;
    
    int y_pitch = gpu_frame->linesize[0];
    int uv_pitch = gpu_frame->linesize[1];

    #ifdef USE_AMD
    AVFrame* drm_frame = av_frame_alloc();
    if (!drm_frame) {
        av_frame_free(&gpu_frame);
        av_frame_free(&drm_frame);
        throw runtime_error("Failed to allocate DRM frame!");
    }
    drm_frame->format = AV_PIX_FMT_DRM_PRIME;

    int ret2 = av_hwframe_map(drm_frame, gpu_frame, AV_HWFRAME_MAP_READ | AV_HWFRAME_MAP_WRITE);
    if (ret2 < 0) {
        av_frame_free(&gpu_frame);
        av_frame_free(&drm_frame);
        throw runtime_error("Failed to map VAAPI surface to DRM PRIME!");
    };

    AVDRMFrameDescriptor* desc = (AVDRMFrameDescriptor*) drm_frame->data[0];
    
    int obj_idx = desc->layers[0].planes[0].object_index;

    fd      = desc->objects[obj_idx].fd;
    obj_size = desc->objects[obj_idx].size;
    y_pitch = desc->layers[0].planes[0].pitch;
    uv_pitch = desc->layers[1].planes[0].pitch;
    y_offset = desc->layers[0].planes[0].offset;
    uv_offset = desc->layers[1].planes[0].offset;
    #endif

    // Dispatch to appropriate preprocessing based on negotiated format
    if (negotiated_format == HWFrameFormat::NV12) {
        preprocess_argb_to_nv12(
                device_pixels,
                reinterpret_cast<uint8_t*>(gpu_frame->data[0]),
                reinterpret_cast<uint8_t*>(gpu_frame->data[1]),
                gpu_frame->width,
                gpu_frame->height,
                y_pitch,
                uv_pitch,
                get_video_background_color()
        );
    } else {
        // P010LE (default for AMD and newer NVIDIA GPUs)
        preprocess_argb_to_p010(
                device_pixels,
                reinterpret_cast<uint16_t*>(gpu_frame->data[0]),
                reinterpret_cast<uint16_t*>(gpu_frame->data[1]),
                fd,
                obj_size,
                gpu_frame->width,
                gpu_frame->height,
                y_pitch,
                uv_pitch,
                y_offset,
                uv_offset,
                get_video_background_color()
        );
    }

    #if defined(USE_NVIDIA)
    check_cuda_boundary("after encoder preprocessing");
    #endif

    gpu_frame->pts = outframe++;

    encode_and_write_frame(gpu_frame);

    #ifdef USE_AMD
    av_frame_free(&drm_frame);
    #endif
    av_frame_free(&gpu_frame);
}

VideoWriter::~VideoWriter() {
    if (USE_LIVE) {
        delete live_player;
        return;
    }

    cout << "Cleaning up VideoWriter..." << endl;

    while(encode_and_write_frame(NULL));

    avcodec_free_context(&videoCodecContext);

    av_packet_unref(&pkt);

    av_write_trailer(fc);
    avio_closep(&fc->pb);
    avformat_free_context(fc);
}
