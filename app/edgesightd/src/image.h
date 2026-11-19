#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

constexpr unsigned kMaxJpegDim = 4096;  // 4K: largest frame the service accepts

struct Image {
    int w = 0, h = 0;
    std::vector<uint8_t> px;  // interleaved RGB
};

// Decodes a JPEG. Uses libjpeg-turbo's DCT-domain scaling to produce the smallest
// image that is still >= (minW x minH) - decoding a 1080p frame at 1/4 scale is
// ~6x cheaper than full decode + resize.
bool decodeJpeg(const uint8_t* data, size_t len, Image& out, int minW = 0, int minH = 0);
bool encodeJpeg(const Image& img, int quality, std::vector<uint8_t>& out);
void resizeBilinear(const Image& src, int w, int h, std::vector<uint8_t>& dst);
void drawBox(Image& img, int x0, int y0, int x1, int y1, const uint8_t rgb[3], int thick);
void drawText(Image& img, int x, int y, const std::string& text, const uint8_t rgb[3], int scale);
void fillRect(Image& img, int x0, int y0, int x1, int y1, const uint8_t rgb[3]);
