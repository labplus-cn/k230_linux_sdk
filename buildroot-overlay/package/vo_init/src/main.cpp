#include "display.h"
#include <stdio.h>
#include <drm/drm_fourcc.h>
#include <unistd.h>
#include <cstring>
#include <vector>
#include <fstream>
#include <iostream>
#include <opencv4/opencv2/core.hpp>
#include <opencv4/opencv2/imgproc.hpp>    // 图像处理（cvtColor/颜色枚举）
#include <opencv4/opencv2/imgcodecs.hpp>  // 图像读写（imread/imwrite，若用到）

using namespace cv;
using namespace std;

#define RECT_X 0
#define RECT_Y 0

static int g_width = 480;
static int g_height = 800;

bool bgr_to_nv12(const Mat& bgr_img, vector<uchar>& nv12_buf) {
    // 1. 输入参数校验
    if (bgr_img.empty() || bgr_img.channels() != 3) {
        cerr << "输入图像为空或非3通道BGR格式！" << endl;
        return false;
    }

    const int width = bgr_img.cols;
    const int height = bgr_img.rows;
    const int y_size = width * height;
    const int uv_size = y_size / 2;
    const int nv12_total_size = y_size + uv_size; // 1.5 * 分辨率

    // 2. 初始化输出缓冲区
    nv12_buf.clear();
    nv12_buf.resize(nv12_total_size);

    // 3. BGR 转 YCrCb（等价于 YUV420P，OpenCV 4.x 标准转换）
    Mat yuv420p;
    cvtColor(bgr_img, yuv420p, COLOR_BGR2YCrCb); // 4.x 推荐的枚举写法
    // 确保内存连续（避免 OpenCV 4.x 自动对齐导致的内存间隙）
    if (!yuv420p.isContinuous()) {
        yuv420p = yuv420p.clone();
    }

    // 4. 提取 Y 分量（YUV420P 的 Y 平面占前 width*height 字节）
    uchar* y_plane = yuv420p.data;
    memcpy(nv12_buf.data(), y_plane, y_size);

    // 5. 提取 U/Cb、V/Cr 分量并交错合并（NV12 核心逻辑）
    uchar* uv_dst = nv12_buf.data() + y_size; // NV12 的 UV 起始位置
    uchar* u_plane = y_plane + y_size;       // YUV420P 的 U/Cb 起始
    uchar* v_plane = u_plane + (y_size / 4); // YUV420P 的 V/Cr 起始

    // 按 U0V0U1V1... 顺序合并（UV 各占 y_size/4 字节，合并后为 y_size/2）
    for (int i = 0; i < y_size / 4; ++i) {
        uv_dst[2 * i] = u_plane[i];    // U/Cb 分量
        uv_dst[2 * i + 1] = v_plane[i];// V/Cr 分量
    }

    return true;
}

// void yuvNV12ToNV21(const uint8_t *NV12,int w,int h,uint8_t *NV21)
// {
//     std::memcpy(NV21,NV12,w*h);//y分量
//     for(int i = 0;i<w*h/4;i++)
//     {
//         std::memcpy(NV21+w*h+i,NV12+w*h+i+1,1);//V分量
//         std::memcpy(NV21+w*h+i+1,NV12+w*h+i,1);//u分量
//     }
// }

// 在NV12格式的缓冲区中绘制黑色矩形
int draw_rectangle(struct display_buffer* buffer) {
    uint8_t* y_ptr = (uint8_t*)buffer->map;

    Mat bgr_img = imread("input.jpg", IMREAD_COLOR);
    if (bgr_img.empty()) {
        cerr << "读取图像失败！请检查文件路径或格式" << endl;
        return -1;
    }
    // 图片尺寸与屏幕分辨率不符时缩放，避免 memcpy 数据量与 buffer 尺寸不匹配
    if (bgr_img.cols != g_width || bgr_img.rows != g_height) {
        printf("resize image %dx%d -> %dx%d\n", bgr_img.cols, bgr_img.rows, g_width, g_height);
        cv::resize(bgr_img, bgr_img, cv::Size(g_width, g_height));
    }
    Mat rgb_img;
    cvtColor(bgr_img, rgb_img, COLOR_BGR2RGB);
    size_t copy_size = rgb_img.total() * rgb_img.elemSize();
    printf("buffer size: %zu\n", copy_size);
    memcpy(y_ptr, rgb_img.data, copy_size);
    return 0;
    // yuvNV12ToNV21(data, 800, 480, y_ptr);
    // // Y平面
    // uint8_t* y_ptr = (uint8_t*)buffer->map;
    // // UV平面
    // uint8_t* uv_ptr = y_ptr + buffer->stride * g_height;

    // // 更新Y平面
    // for (int y = RECT_Y; y < RECT_Y + g_height; y++) {
    //     for (int x = RECT_X; x < RECT_X + g_width; x++) {
    //         int y_index = y * buffer->stride + x;
    //         // 设置亮度值为0以表示黑色
    //         y_ptr[y_index] = 0xff;
    //     }
    // }

    // // 对于黑色矩形，UV平面不需要特别处理，因为黑色只与亮度有关
    // // 这里可以选择保持UV平面不变，或者简单地将其设置为默认值（通常是128）
    // // 以下是将UV平面设置为默认值的示例代码
    // int uv_width = g_width / 2;
    // int uv_height = g_height / 2;
    // int rect_uv_x = RECT_X / 2;
    // int rect_uv_y = RECT_Y / 2;
    // int rect_uv_width = g_width / 2;
    // int rect_uv_height = g_height / 2;

    // for (int y = rect_uv_y; y < rect_uv_y + rect_uv_height; y++) {
    //     for (int x = rect_uv_x; x < rect_uv_x + rect_uv_width; x++) {
    //         int uv_index = (y * uv_width + x) * 2;
    //         // 设置U分量为默认值
    //         uv_ptr[uv_index] = 0;
    //         // 设置V分量为默认值
    //         uv_ptr[uv_index + 1] = 128;
    //     }
    // }
}

int main(void) {
    // 初始化显示设备
    struct display* display = display_init(0);
    if (display == NULL) {
        fprintf(stderr, "Failed to initialize display\n");
        return -1;
    }

    if (display->conn->connector_type != DRM_MODE_CONNECTOR_DSI )
    {
        display_exit(display);
        return 0;
    }
    //printf("display connector type:%d\n",display->conn->connector_type);

    g_width = display->width;
    g_height = display->height;

    printf("Display width: %d, height: %d\n", g_width, g_height);

    display->drm_rotation = rotation_90;
    // 获取显示平面
    struct display_plane* plane = display_get_plane(display, DRM_FORMAT_BGR888);
    if (plane == NULL) {
        fprintf(stderr, "Failed to get display plane\n");
        display_exit(display);
        return -1;
    }

    plane->drm_rotation = rotation_90; // 设置平面旋转为90度
    // 分配缓冲区
    struct display_buffer* buffer = display_allocate_buffer(plane, g_width, g_height);
    if (buffer == NULL) {
        fprintf(stderr, "Failed to allocate display buffer\n");
        display_free_plane(plane);
        display_exit(display);
        return -1;
    }

    // 显示 input.jpg，加载失败则不提交脏 buffer，释放资源直接退出
    if (draw_rectangle(buffer) != 0) {
        fprintf(stderr, "Failed to load input.jpg\n");
        display_free_buffer(buffer);
        display_free_plane(plane);
        display_exit(display);
        return -1;
    }

    display_wait_vsync(display);

    // 更新缓冲区并提交显示
    if (display_update_buffer(buffer, 0, 0) != 0) {
        fprintf(stderr, "Failed to update display buffer\n");
    }
    if (display_commit(display) != 0) {
        fprintf(stderr, "Failed to commit display\n");
    }

    // 等待一段时间
    sleep(40);

    // 释放资源
    display_free_buffer(buffer);
    display_free_plane(plane);
    display_exit(display);

    return 0;
}