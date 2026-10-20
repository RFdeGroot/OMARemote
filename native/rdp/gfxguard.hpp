#pragma once

// RDP's graphics pipeline (/gfx) is FreeRDP's own gdi code: a server's CreateSurface has it
// allocate that surface's pixels, up to 65535x65535 (17 GB) each and as many as the server likes,
// before anything is shown; SurfaceToCache copies any part of a surface into one of 25600 cache
// slots, with no total. guard_gfx wraps both once gdi has installed them: a surface over
// kMaxFrameSide a side, or one that takes all surfaces together past kMaxGfxSurfaceBytes, and a
// cache entry that takes the cache past kMaxGfxCacheBytes, are refused before they are allocated,
// and onRefuse (once) ends the session.

#include <freerdp/client/rdpgfx.h>

#include <cstdint>
#include <functional>
#include <string>

namespace oma
{

// All surfaces together, each counted with the RemoteFX progressive tiles FreeRDP allocates for it
// (about 66 KB per 64x64 tile, four times the pixels): a 4K monitor is about 170 MB, one surface of
// the largest desktop (8192x8192) 1.35 GB.
constexpr uint64_t kMaxGfxSurfaceBytes = 2ull << 30;
constexpr uint64_t kGfxTileBytes = 66 * 1024;
// MS-RDPEGFX holds a server to 100 MB of cache (16 MB with the small cache).
constexpr uint64_t kMaxGfxCacheBytes = 128ull << 20;

void guard_gfx(RdpgfxClientContext* gfx, std::function<void(const std::string&)> onRefuse);

} // namespace oma
