#include "image.h"

#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>

#include <jpeglib.h>

namespace {
struct JErr {
    jpeg_error_mgr pub;
    jmp_buf jb;
};
void jerrExit(j_common_ptr c) { longjmp(reinterpret_cast<JErr*>(c->err)->jb, 1); }
void jerrSilent(j_common_ptr, int) {}
}  // namespace

bool decodeJpeg(const uint8_t* data, size_t len, Image& out, int minW, int minH) {
    jpeg_decompress_struct ci;
    JErr err;
    ci.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = jerrExit;
    err.pub.emit_message = jerrSilent;
    if (setjmp(err.jb)) {
        jpeg_destroy_decompress(&ci);
        return false;
    }
    jpeg_create_decompress(&ci);
    jpeg_mem_src(&ci, const_cast<unsigned char*>(data), (unsigned long)len);
    if (jpeg_read_header(&ci, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&ci);
        return false;
    }
    // Untrusted input (network camera): refuse absurd dimensions before allocating
    // w*h*3 bytes (a 16k x 16k header would ask for 768 MB and trip the cgroup OOM killer).
    if (ci.image_width == 0 || ci.image_height == 0 || ci.image_width > kMaxJpegDim ||
        ci.image_height > kMaxJpegDim || ci.num_components < 1 || ci.num_components > 4) {
        jpeg_destroy_decompress(&ci);
        return false;
    }
    ci.out_color_space = JCS_RGB;
    ci.dct_method = JDCT_ISLOW;
    int denom = 1;
    for (int d : {8, 4, 2}) {
        if ((int)ci.image_width / d >= minW && (int)ci.image_height / d >= minH && minW > 0) {
            denom = d;
            break;
        }
    }
    ci.scale_num = 1;
    ci.scale_denom = denom;
    jpeg_start_decompress(&ci);
    out.w = ci.output_width;
    out.h = ci.output_height;
    out.px.resize((size_t)out.w * out.h * 3);
    while (ci.output_scanline < ci.output_height) {
        JSAMPROW row = out.px.data() + (size_t)ci.output_scanline * out.w * 3;
        jpeg_read_scanlines(&ci, &row, 1);
    }
    jpeg_finish_decompress(&ci);
    jpeg_destroy_decompress(&ci);
    return true;
}

bool encodeJpeg(const Image& img, int quality, std::vector<uint8_t>& out) {
    jpeg_compress_struct ci;
    JErr err;
    ci.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = jerrExit;
    unsigned char* buf = nullptr;
    unsigned long size = 0;
    if (setjmp(err.jb)) {
        jpeg_destroy_compress(&ci);
        free(buf);
        return false;
    }
    jpeg_create_compress(&ci);
    jpeg_mem_dest(&ci, &buf, &size);
    ci.image_width = img.w;
    ci.image_height = img.h;
    ci.input_components = 3;
    ci.in_color_space = JCS_RGB;
    jpeg_set_defaults(&ci);
    jpeg_set_quality(&ci, quality, TRUE);
    jpeg_start_compress(&ci, TRUE);
    while (ci.next_scanline < ci.image_height) {
        JSAMPROW row = const_cast<uint8_t*>(img.px.data()) + (size_t)ci.next_scanline * img.w * 3;
        jpeg_write_scanlines(&ci, &row, 1);
    }
    jpeg_finish_compress(&ci);
    out.assign(buf, buf + size);
    jpeg_destroy_compress(&ci);
    free(buf);
    return true;
}

void resizeBilinear(const Image& src, int w, int h, std::vector<uint8_t>& dst) {
    dst.resize((size_t)w * h * 3);
    if (src.w == w && src.h == h) {
        std::memcpy(dst.data(), src.px.data(), dst.size());
        return;
    }
    const float sx = (float)src.w / w, sy = (float)src.h / h;
    // precompute horizontal taps once per call
    std::vector<int> x0s(w), x1s(w);
    std::vector<float> fxs(w);
    for (int x = 0; x < w; ++x) {
        float fx = (x + 0.5f) * sx - 0.5f;
        if (fx < 0) fx = 0;
        int x0 = (int)fx;
        x0s[x] = x0;
        x1s[x] = std::min(x0 + 1, src.w - 1);
        fxs[x] = fx - x0;
    }
    for (int y = 0; y < h; ++y) {
        float fy = (y + 0.5f) * sy - 0.5f;
        if (fy < 0) fy = 0;
        int y0 = (int)fy, y1 = std::min(y0 + 1, src.h - 1);
        float wy = fy - y0;
        const uint8_t* r0 = src.px.data() + (size_t)y0 * src.w * 3;
        const uint8_t* r1 = src.px.data() + (size_t)y1 * src.w * 3;
        uint8_t* d = dst.data() + (size_t)y * w * 3;
        for (int x = 0; x < w; ++x) {
            const uint8_t* a = r0 + x0s[x] * 3;
            const uint8_t* b = r0 + x1s[x] * 3;
            const uint8_t* c = r1 + x0s[x] * 3;
            const uint8_t* e = r1 + x1s[x] * 3;
            float wx = fxs[x];
            for (int k = 0; k < 3; ++k) {
                float top = a[k] + (b[k] - a[k]) * wx;
                float bot = c[k] + (e[k] - c[k]) * wx;
                d[x * 3 + k] = (uint8_t)(top + (bot - top) * wy + 0.5f);
            }
        }
    }
}

void fillRect(Image& img, int x0, int y0, int x1, int y1, const uint8_t rgb[3]) {
    x0 = std::max(0, x0); y0 = std::max(0, y0);
    x1 = std::min(img.w - 1, x1); y1 = std::min(img.h - 1, y1);
    for (int y = y0; y <= y1; ++y)
        for (int x = x0; x <= x1; ++x) std::memcpy(&img.px[((size_t)y * img.w + x) * 3], rgb, 3);
}

void drawBox(Image& img, int x0, int y0, int x1, int y1, const uint8_t rgb[3], int t) {
    fillRect(img, x0, y0, x1, y0 + t - 1, rgb);
    fillRect(img, x0, y1 - t + 1, x1, y1, rgb);
    fillRect(img, x0, y0, x0 + t - 1, y1, rgb);
    fillRect(img, x1 - t + 1, y0, x1, y1, rgb);
}

// 5x7 bitmap font: A-Z, 0-9, space, '%', '.', '-'
static const uint8_t* glyph(char c) {
    static const uint8_t L[26][7] = {
        {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},{0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E},
        {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},
        {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
        {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F},{0x11,0x11,0x11,0x1F,0x11,0x11,0x11},
        {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},{0x07,0x02,0x02,0x02,0x02,0x12,0x0C},
        {0x11,0x12,0x14,0x18,0x14,0x12,0x11},{0x10,0x10,0x10,0x10,0x10,0x10,0x1F},
        {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},{0x11,0x11,0x19,0x15,0x13,0x11,0x11},
        {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10},
        {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11},
        {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04,0x04,0x04},
        {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},{0x11,0x11,0x11,0x11,0x11,0x0A,0x04},
        {0x11,0x11,0x11,0x15,0x15,0x15,0x0A},{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11},
        {0x11,0x11,0x11,0x0A,0x04,0x04,0x04},{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F}};
    static const uint8_t D[10][7] = {
        {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
        {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
        {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
        {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
        {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}};
    static const uint8_t PCT[7] = {0x18,0x19,0x02,0x04,0x08,0x13,0x03};
    static const uint8_t DOT[7] = {0,0,0,0,0,0x0C,0x0C};
    static const uint8_t DASH[7] = {0,0,0,0x1F,0,0,0};
    static const uint8_t SP[7] = {0,0,0,0,0,0,0};
    if (c >= 'a' && c <= 'z') c -= 32;
    if (c >= 'A' && c <= 'Z') return L[c - 'A'];
    if (c >= '0' && c <= '9') return D[c - '0'];
    if (c == '%') return PCT;
    if (c == '.') return DOT;
    if (c == '-') return DASH;
    return SP;
}

void drawText(Image& img, int x, int y, const std::string& text, const uint8_t rgb[3], int s) {
    for (char ch : text) {
        const uint8_t* g = glyph(ch);
        for (int r = 0; r < 7; ++r)
            for (int c = 0; c < 5; ++c)
                if (g[r] & (0x10 >> c)) fillRect(img, x + c * s, y + r * s, x + c * s + s - 1, y + r * s + s - 1, rgb);
        x += 6 * s;
    }
}
