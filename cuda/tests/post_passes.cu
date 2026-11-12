// The post-processing kernels on the CPU target (#277), through the C API alone: each pass
// against what its arithmetic gives on a small image worked out by hand, the calls it refuses,
// and the 8-bit pack. The Swift tests draw whole frames with a PostPlan
// (Tests/SillageCUDATests/CUDAPostTests.swift); this one runs where there is no Swift, with g++
// and with clang++.
#include "cuda_cpu.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "sillage_cuda.h"
#include "Shaders.h"

#if defined(SILLAGE_CPU)

namespace metal {
namespace Shaders {

static int failures = 0;

static void expect(bool condition, const char *what) {
    if (condition) { return; }
    failures += 1;
    std::printf("cuda/tests/post_passes.cu: %s\n", what);
}

static bool ok(sc_status status, const char *what) {
    if (status == SC_OK) { return true; }
    failures += 1;
    std::printf("cuda/tests/post_passes.cu: %s: %s, %s\n", what, sc_status_name(status), sc_last_error());
    return false;
}

static bool near(float a, float b, float tolerance = 1e-5f) {
    return std::fabs(a - b) <= tolerance * (1.0f + std::fabs(b));
}

struct Image {
    sc_buffer *buffer = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;

    Image(sc_context *context, uint32_t w, uint32_t h) : width(w), height(h) {
        ok(sc_buffer_create(context, size_t(w) * h * 16u, &buffer), "an image");
    }
    ~Image() { sc_buffer_destroy(buffer); }
    Image(const Image &) = delete;
    Image &operator=(const Image &) = delete;

    sc_post_image handle() const { return sc_post_image{buffer, width, height}; }

    void fill(const std::vector<float> &texels) {
        ok(sc_buffer_upload(buffer, 0, texels.data(), texels.size() * 4u), "an upload");
    }
    // Every texel the same, alpha 1.
    void fill(float r, float g, float b) {
        std::vector<float> texels;
        for (uint32_t i = 0; i < width * height; ++i) {
            texels.insert(texels.end(), {r, g, b, 1.0f});
        }
        fill(texels);
    }
    std::vector<float> read() const {
        std::vector<float> texels(size_t(width) * height * 4u);
        ok(sc_buffer_download(buffer, 0, texels.data(), texels.size() * 4u), "a download");
        return texels;
    }
};

static int run() {
    sc_context *context = nullptr;
    if (!ok(sc_context_create(0, &context), "a context")) { return 1; }

    // resolve: the box average, alpha 1.
    {
        Image light(context, 4, 4), average(context, 2, 2);
        std::vector<float> texels;
        for (uint32_t y = 0; y < 4; ++y) {
            for (uint32_t x = 0; x < 4; ++x) { texels.insert(texels.end(), {float(x), float(y), float(x + y), 7.0f}); }
        }
        light.fill(texels);
        sc_post_image in = light.handle(), out = average.handle();
        ok(sc_post_resolve(&in, &out, 2), "resolve");
        std::vector<float> got = average.read();
        // The first block holds x in {0, 1}, y in {0, 1}: means 0.5, 0.5 and 1.
        expect(near(got[0], 0.5f) && near(got[1], 0.5f) && near(got[2], 1.0f) && got[3] == 1.0f,
               "resolve is not the box average");
        expect(near(got[12], 2.5f) && near(got[13], 2.5f) && near(got[14], 5.0f), "resolve of the last block");
        Image odd(context, 3, 2);
        sc_post_image wrong = odd.handle();
        expect(sc_post_resolve(&in, &wrong, 2) == SC_INVALID_ARGUMENT, "resolve into a size that is not a factor of the light");
    }

    // plainComposite: the exposure curve of the raw look, times the fade.
    {
        Image light(context, 2, 2), picture(context, 1, 1);
        light.fill(1.0f, 0.5f, 0.0f);
        sc_post_image in = light.handle(), out = picture.handle();
        ok(sc_post_plain_composite(&in, &out, 2, 0.5f), "plainComposite");
        std::vector<float> got = picture.read();
        float red = std::pow(1.0f - std::exp(-1.0f), 1.0f / 2.2f) * 0.5f;
        float green = std::pow(1.0f - std::exp(-0.5f), 1.0f / 2.2f) * 0.5f;
        expect(near(got[0], red, 1e-4f) && near(got[1], green, 1e-4f) && got[2] == 0.0f && got[3] == 1.0f,
               "plainComposite is not 1 - exp(-energy) to the power 1 / 2.2, faded");
    }

    // brightPass: what is under the threshold goes, what is over keeps its excess's share.
    {
        Image src(context, 2, 2), bright(context, 2, 2);
        src.fill({0.2f, 0.2f, 0.2f, 1.0f, 1.0f, 0.5f, 0.25f, 1.0f, 0.2f, 0.2f, 0.2f, 1.0f, 1.0f, 0.5f, 0.25f, 1.0f});
        BloomParams p = {0.5f, 0.0f, 0.0f, 0.0f};
        sc_post_image in = src.handle(), out = bright.handle();
        ok(sc_post_bright(&in, &out, &p, sizeof p), "brightPass");
        std::vector<float> got = bright.read();
        // The bilinear filter at a texel's own centre gives the texel; the grid is 2 by 2 and the
        // destination too, so every sample lands on a centre.
        expect(got[0] == 0.0f && got[1] == 0.0f && got[2] == 0.0f, "a texel under the threshold is not dark");
        expect(near(got[4], 0.5f, 1e-4f) && near(got[5], 0.25f, 1e-4f) && near(got[6], 0.125f, 1e-4f),
               "a texel over the threshold does not keep (brightness - threshold) / brightness of its colour");
        expect(sc_post_bright(&in, &out, &p, sizeof p - 4u) == SC_INVALID_ARGUMENT, "BloomParams of another size");
    }

    // downsample and upsampleAdd keep a flat image flat: the filters' weights add up to one.
    {
        Image big(context, 8, 8), small(context, 4, 4), up(context, 8, 8), base(context, 8, 8);
        big.fill(0.6f, 0.3f, 0.1f);
        sc_post_image in = big.handle(), half = small.handle();
        ok(sc_post_downsample(&in, &half), "downsample");
        std::vector<float> got = small.read();
        bool flat = true;
        for (size_t i = 0; i < got.size(); i += 4) {
            flat = flat && near(got[i], 0.6f, 1e-4f) && near(got[i + 1], 0.3f, 1e-4f) && near(got[i + 2], 0.1f, 1e-4f);
        }
        expect(flat, "downsample changes a flat image");
        base.fill(0.25f, 0.25f, 0.25f);
        sc_post_image under = base.handle(), out = up.handle();
        ok(sc_post_upsample(&half, &under, &out), "upsampleAdd");
        got = up.read();
        flat = true;
        for (size_t i = 0; i < got.size(); i += 4) {
            flat = flat && near(got[i], 0.85f, 1e-4f) && near(got[i + 1], 0.55f, 1e-4f) && near(got[i + 2], 0.35f, 1e-4f);
        }
        expect(flat, "upsampleAdd is not the flat image plus the base");
        Image wrong(context, 4, 4);
        sc_post_image other = wrong.handle();
        expect(sc_post_upsample(&half, &other, &out) == SC_INVALID_ARGUMENT, "a base that is not the destination's size");
    }

    // compactLight: the point source less a share of the broad one, never under zero.
    {
        Image point(context, 2, 2), broad(context, 2, 2), out(context, 2, 2);
        point.fill(0.5f, 0.2f, 1.0f);
        broad.fill(1.0f, 0.1f, 0.5f);
        sc_post_image a = point.handle(), b = broad.handle(), c = out.handle();
        ok(sc_post_compact(&a, &b, &c, 0.5f), "compactLight");
        std::vector<float> got = out.read();
        expect(near(got[0], 0.0f) && near(got[1], 0.15f, 1e-4f) && near(got[2], 0.75f, 1e-4f), "compactLight");
    }

    // diffractionSpikes: nothing with no arm; on a flat image the sum of the falloff.
    {
        Image src(context, 8, 8), out(context, 8, 8);
        src.fill(1.0f, 1.0f, 1.0f);
        sc_post_image in = src.handle(), result = out.handle();
        SpikeParams none = {0u, 0.0f, 3.0f, 1.0f, 4u, 0u, 0.0f, 0.0f};
        ok(sc_post_spikes(&in, &result, &none, sizeof none), "diffractionSpikes without arms");
        std::vector<float> got = out.read();
        expect(got[0] == 0.0f && got[1] == 0.0f && got[3] == 1.0f, "spikes with no arm are not dark");
        SpikeParams two = {2u, 0.3f, 0.5f, 2.0f, 4u, 0u, 0.0f, 0.0f};
        ok(sc_post_spikes(&in, &result, &two, sizeof two), "diffractionSpikes");
        got = out.read();
        float sum = 0.0f;
        for (int sample = 1; sample <= 4; ++sample) { sum += std::exp(-float(sample) / 4.0f * 2.0f); }
        // The taps sit inside the image, where the filter reads 1, so each arm adds the sum of
        // exp(-t falloff) over its samples, and the total is divided by the samples.
        expect(near(got[4 * 27], 2.0f * sum / 4.0f, 1e-4f), "spikes on a flat image are not the falloff's sum");
    }

    // composite: black stays dark, the fade scales the picture, the picture grows with its light.
    {
        Image hdr(context, 2, 2), glow(context, 2, 2), rays(context, 2, 2), out(context, 2, 2);
        glow.fill(0.0f, 0.0f, 0.0f);
        rays.fill(0.0f, 0.0f, 0.0f);
        CompositeParams p = {0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 3.0f, 4.0f, 1.0f, 0.36f, 0.42f, 0.60f};
        sc_post_image a = hdr.handle(), b = glow.handle(), c = rays.handle(), d = out.handle();
        hdr.fill(0.0f, 0.0f, 0.0f);
        ok(sc_post_composite(&a, &b, &c, &d, &p, sizeof p), "composite of black");
        std::vector<float> got = out.read();
        expect(got[0] == 0.0f && got[1] == 0.0f && got[2] == 0.0f && got[3] == 1.0f, "composite of black is not black");
        float last = -1.0f;
        bool grows = true;
        for (float level : {0.05f, 0.2f, 0.8f, 3.0f}) {
            hdr.fill(level, level, level);
            ok(sc_post_composite(&a, &b, &c, &d, &p, sizeof p), "composite");
            got = out.read();
            grows = grows && got[0] > last && got[0] <= 1.0f && near(got[0], got[1], 1e-5f) && near(got[1], got[2], 1e-5f);
            last = got[0];
        }
        expect(grows, "composite does not map more light to a brighter grey inside 0 and 1");
        float lit = last;
        p.fade = 0.5f;
        ok(sc_post_composite(&a, &b, &c, &d, &p, sizeof p), "composite faded");
        got = out.read();
        expect(near(got[0], lit * 0.5f, 1e-5f), "composite does not scale its picture by the fade");
        p.skyLevel = 0.1f;
        p.fade = 1.0f;
        hdr.fill(0.0f, 0.0f, 0.0f);
        ok(sc_post_composite(&a, &b, &c, &d, &p, sizeof p), "composite of the sky");
        got = out.read();
        expect(got[2] > got[1] && got[1] > got[0] && got[0] > 0.0f, "the sky is not bluer than red");
        // The grain depends on the pixel and the seed alone, so it repeats.
        p.noiseLevel = 0.01f;
        ok(sc_post_composite(&a, &b, &c, &d, &p, sizeof p), "composite with grain");
        std::vector<float> first = out.read();
        ok(sc_post_composite(&a, &b, &c, &d, &p, sizeof p), "composite with grain again");
        expect(first == out.read(), "the grain is not the same twice");
        expect(first[0] != first[4] || first[1] != first[5], "the grain is the same on two pixels");
        expect(sc_post_composite(&a, &b, &c, &d, &p, sizeof p - 4u) == SC_INVALID_ARGUMENT, "CompositeParams of another size");
    }

    // The grain's hash: the argument of its sine is of the order of 1e5, where the last bit of
    // its rounding sets the whole hash. Fused as Metal's compiler fuses it, the hash is Metal's;
    // multiplied and added apart it is another, on a third of the pixels.
    {
        int differing = 0;
        int pixels = 0;
        bool fused = true;
        for (int y = 0; y < 90; ++y) {
            for (int x = 0; x < 160; ++x) {
                float2 cell(float(x) + 15.26f, float(y) + 15.26f);
                float apart = metal::sin(cell.x * 127.1f + cell.y * 311.7f) * 43758.5453f;
                apart -= metal::floor(apart);
                float written = hash2(cell);
                float together = metal::sin(fmaf(cell.y, 311.7f, cell.x * 127.1f)) * 43758.5453f;
                together -= metal::floor(together);
                fused = fused && written == together;
                if (std::fabs(apart - written) > 0.02f) { differing += 1; }
                pixels += 1;
            }
        }
        std::printf("  the grain's hash: %d of %d pixels differ when its argument is not fused\n", differing, pixels);
        expect(fused, "hash2 is not the sine of the fused multiply-add");
        expect(differing * 10 > pixels, "the hash no longer depends on how its argument is rounded");
    }

    // The pack: Metal's rgba8Unorm write, rounding to nearest even.
    {
        Image image(context, 2, 1);
        image.fill({0.0f, 1.0f, 0.5f, 1.0f, -3.0f, 7.0f, 0.2f, 1.0f});
        sc_buffer *bytes = nullptr;
        ok(sc_buffer_create(context, 8, &bytes), "bytes");
        sc_post_image in = image.handle();
        ok(sc_post_pack(&in, bytes, SC_POST_RGB), "pack rgb");
        unsigned char rgb[6];
        ok(sc_buffer_download(bytes, 0, rgb, 6), "download");
        // 0.5 is 127.5 of 255: nearest even is 128. A negative reads 0, past one clamps, 0.2 is 51.
        expect(rgb[0] == 0 && rgb[1] == 255 && rgb[2] == 128 && rgb[3] == 0 && rgb[4] == 255 && rgb[5] == 51,
               "rgb bytes");
        ok(sc_post_pack(&in, bytes, SC_POST_BGRA), "pack bgra");
        unsigned char bgra[8];
        ok(sc_buffer_download(bytes, 0, bgra, 8), "download");
        expect(bgra[0] == 128 && bgra[1] == 255 && bgra[2] == 0 && bgra[3] == 255 && bgra[4] == 51 && bgra[5] == 255
                   && bgra[6] == 0 && bgra[7] == 255,
               "bgra bytes");
        ok(sc_post_pack(&in, bytes, SC_POST_RGBA), "pack rgba");
        unsigned char rgba[8];
        ok(sc_buffer_download(bytes, 0, rgba, 8), "download");
        expect(rgba[0] == 0 && rgba[2] == 128 && rgba[3] == 255 && rgba[4] == 0 && rgba[6] == 51 && rgba[7] == 255,
               "rgba bytes");
        sc_buffer *short_bytes = nullptr;
        ok(sc_buffer_create(context, 5, &short_bytes), "short bytes");
        expect(sc_post_pack(&in, short_bytes, SC_POST_RGB) == SC_INVALID_ARGUMENT, "a pack into too few bytes");
        expect(sc_post_pack(&in, bytes, sc_post_format(9)) == SC_INVALID_ARGUMENT, "a format that is not one");
        sc_buffer_destroy(short_bytes);
        sc_buffer_destroy(bytes);
        std::vector<float> nan = {std::nanf(""), 0.0f, 0.0f, 1.0f};
        Image one(context, 1, 1);
        one.fill(nan);
        sc_buffer *single = nullptr;
        ok(sc_buffer_create(context, 3, &single), "a pixel");
        sc_post_image lone = one.handle();
        ok(sc_post_pack(&lone, single, SC_POST_RGB), "pack a number that is not one");
        unsigned char zero[3];
        ok(sc_buffer_download(single, 0, zero, 3), "download");
        expect(zero[0] == 0, "a value that is not a number is not 0");
        sc_buffer_destroy(single);
    }

    // The images a pass is given are checked.
    {
        Image image(context, 2, 2), out(context, 2, 2);
        sc_post_image empty = {nullptr, 2, 2}, in = image.handle(), result = out.handle();
        expect(sc_post_downsample(&empty, &result) == SC_INVALID_ARGUMENT, "an image without a buffer");
        sc_post_image big = {image.buffer, 3, 3};
        expect(sc_post_downsample(&big, &result) == SC_INVALID_ARGUMENT, "an image bigger than its buffer");
        sc_post_image none = {image.buffer, 0, 2};
        expect(sc_post_downsample(&in, &none) == SC_INVALID_ARGUMENT, "an empty image");
    }

    sc_context_destroy(context);
    if (failures == 0) { std::printf("cuda/tests/post_passes.cu: the post-processing passes run on the CPU target\n"); }
    return failures == 0 ? 0 : 1;
}

}  // namespace Shaders
}  // namespace metal

int main() { return metal::Shaders::run(); }

#endif
