#include "gfxguard.hpp"

#include "../common/link.hpp"

#include <freerdp/gdi/gfx.h>

#include <cstdlib>
#include <set>

namespace oma
{

namespace
{

// One session per process, one graphics channel per session.
pcRdpgfxCreateSurface createSurface = nullptr;
pcRdpgfxSurfaceToCache surfaceToCache = nullptr;
std::set<UINT16> cacheSlots; // slots this session filled; what they hold is read back from gdi
std::function<void(const std::string&)> refuse;
bool refused = false;

// What gdi allocates for a surface: rows of 16-pixel-aligned width plus 16 bytes, 16-aligned height;
// and progressive_surface_context_new's 64x64 tiles, once the server sends RemoteFX progressive.
uint64_t surface_bytes(uint32_t width, uint32_t height)
{
	const uint64_t w = (uint64_t(width) + 15) & ~15ull, h = (uint64_t(height) + 15) & ~15ull;
	const uint64_t tiles = ((uint64_t(width) + 63) / 64) * ((uint64_t(height) + 63) / 64);
	return (((w * 4 + 15) & ~15ull) + 16) * h + tiles * kGfxTileBytes;
}

uint64_t surfaces_bytes(RdpgfxClientContext* gfx)
{
	UINT16* ids = nullptr;
	UINT16 count = 0;
	uint64_t total = 0;
	if (gfx->GetSurfaceIds(gfx, &ids, &count) != CHANNEL_RC_OK)
		return UINT64_MAX; // not known: nothing more fits
	for (UINT16 i = 0; i < count; i++)
		if (const auto* s = static_cast<const gdiGfxSurface*>(gfx->GetSurfaceData(gfx, ids[i])))
			total += surface_bytes(s->mappedWidth, s->mappedHeight);
	free(ids);
	return total;
}

void refuse_once(const std::string& why)
{
	if (refused)
		return;
	refused = true;
	log("graphics pipeline: %s; ending the session", why.c_str());
	if (refuse)
		refuse(why);
}

uint64_t entry_bytes(const gdiGfxCacheEntry* e) { return e ? uint64_t(e->scanline) * e->height : 0; }

// What the cache holds now, from gdi's own entries: a slot evicted since is dropped from the list.
uint64_t cache_bytes(RdpgfxClientContext* gfx)
{
	uint64_t total = 0;
	for (auto it = cacheSlots.begin(); it != cacheSlots.end();)
	{
		const auto* e = static_cast<const gdiGfxCacheEntry*>(gfx->GetCacheSlotData(gfx, *it));
		if (!e)
		{
			it = cacheSlots.erase(it);
			continue;
		}
		total += entry_bytes(e);
		++it;
	}
	return total;
}

UINT surface_to_cache(RdpgfxClientContext* gfx, const RDPGFX_SURFACE_TO_CACHE_PDU* pdu)
{
	const RECTANGLE_16& r = pdu->rectSrc;
	if (r.right <= r.left || r.bottom <= r.top)
		return surfaceToCache(gfx, pdu); // gdi refuses it without allocating
	// As gdi_GfxCacheEntryNew sizes it: 4 bytes a pixel, rows 16-aligned. The slot's old entry goes.
	const uint64_t bytes = ((uint64_t(r.right - r.left) * 4 + 15) & ~15ull) * uint64_t(r.bottom - r.top);
	const uint64_t replaced = entry_bytes(static_cast<const gdiGfxCacheEntry*>(gfx->GetCacheSlotData(gfx, pdu->cacheSlot)));
	const uint64_t held = cache_bytes(gfx);
	if ((held > replaced ? held - replaced : 0) + bytes > kMaxGfxCacheBytes)
	{
		refuse_once("the server's cache takes more than " + std::to_string(kMaxGfxCacheBytes >> 20) + " MiB");
		return ERROR_INVALID_DATA;
	}
	const UINT rc = surfaceToCache(gfx, pdu);
	if (rc == CHANNEL_RC_OK)
		cacheSlots.insert(pdu->cacheSlot);
	return rc;
}

UINT create_surface(RdpgfxClientContext* gfx, const RDPGFX_CREATE_SURFACE_PDU* pdu)
{
	std::string why;
	if (pdu->width == 0 || pdu->height == 0 || pdu->width > kMaxFrameSide || pdu->height > kMaxFrameSide)
		why = "a " + std::to_string(pdu->width) + "x" + std::to_string(pdu->height) +
		      " surface is larger than OMARemote shows (" + std::to_string(kMaxFrameSide) + " a side at most)";
	else if (surfaces_bytes(gfx) + surface_bytes(pdu->width, pdu->height) > kMaxGfxSurfaceBytes)
		why = "the server's surfaces take more than " + std::to_string(kMaxGfxSurfaceBytes >> 20) + " MiB";
	if (why.empty())
		return createSurface(gfx, pdu);
	refuse_once(why);
	return ERROR_INVALID_DATA;
}

} // namespace

void guard_gfx(RdpgfxClientContext* gfx, std::function<void(const std::string&)> onRefuse)
{
	if (!gfx || !gfx->CreateSurface || gfx->CreateSurface == create_surface)
		return;
	createSurface = gfx->CreateSurface;
	gfx->CreateSurface = create_surface;
	surfaceToCache = gfx->SurfaceToCache;
	if (surfaceToCache)
		gfx->SurfaceToCache = surface_to_cache;
	cacheSlots.clear(); // a new channel starts with an empty cache
	refuse = std::move(onRefuse);
}

} // namespace oma
