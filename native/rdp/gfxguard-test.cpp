// The graphics-pipeline guard (gfxguard.hpp) against a stand-in for FreeRDP's gdi handlers: what
// a server's CreateSurface and SurfaceToCache may allocate. Run by tests/test_memory.py; prints
// FAIL lines, exit 1.

#include "gfxguard.hpp"

#include "../common/link.hpp"

#include <freerdp/gdi/gfx.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

static int failures = 0;

static void expect(bool ok, const char* what)
{
	if (!ok)
	{
		printf("FAIL %s\n", what);
		failures++;
	}
}

// gdi's side: the surfaces it holds, by id, sized as gdi_CreateSurface sizes them.
static std::map<UINT16, gdiGfxSurface> surfaces;
static int created = 0;

static UINT gdi_create(RdpgfxClientContext*, const RDPGFX_CREATE_SURFACE_PDU* pdu)
{
	created++;
	gdiGfxSurface s = {};
	s.width = (pdu->width + 15u) & ~15u;
	s.height = (pdu->height + 15u) & ~15u;
	s.scanline = ((s.width * 4 + 15u) & ~15u) + 16;
	s.mappedWidth = pdu->width;
	s.mappedHeight = pdu->height;
	surfaces[pdu->surfaceId] = s;
	return CHANNEL_RC_OK;
}

static UINT gdi_ids(RdpgfxClientContext*, UINT16** ids, UINT16* count)
{
	*count = UINT16(surfaces.size());
	*ids = static_cast<UINT16*>(calloc(surfaces.size() + 1, sizeof(UINT16)));
	UINT16 i = 0;
	for (const auto& [id, s] : surfaces)
		(*ids)[i++] = id;
	return CHANNEL_RC_OK;
}

static void* gdi_data(RdpgfxClientContext*, UINT16 id)
{
	auto it = surfaces.find(id);
	return it == surfaces.end() ? nullptr : &it->second;
}

// gdi's cache: slot to entry, sized as gdi_GfxCacheEntryNew sizes it; a slot written again is replaced.
static std::map<UINT16, gdiGfxCacheEntry> cache;
static int cached = 0;

static UINT gdi_to_cache(RdpgfxClientContext*, const RDPGFX_SURFACE_TO_CACHE_PDU* pdu)
{
	cached++;
	gdiGfxCacheEntry e = {};
	e.width = UINT32(pdu->rectSrc.right - pdu->rectSrc.left);
	e.height = UINT32(pdu->rectSrc.bottom - pdu->rectSrc.top);
	e.scanline = (e.width * 4 + 15u) & ~15u;
	cache[pdu->cacheSlot] = e;
	return CHANNEL_RC_OK;
}

static void* gdi_slot(RdpgfxClientContext*, UINT16 slot)
{
	auto it = cache.find(slot);
	return it == cache.end() ? nullptr : &it->second;
}

static UINT to_cache(RdpgfxClientContext* gfx, UINT16 slot, UINT16 w, UINT16 h)
{
	RDPGFX_SURFACE_TO_CACHE_PDU pdu = {};
	pdu.cacheSlot = slot;
	pdu.rectSrc = { 0, 0, w, h };
	return gfx->SurfaceToCache(gfx, &pdu);
}

static UINT create(RdpgfxClientContext* gfx, UINT16 id, UINT16 w, UINT16 h)
{
	RDPGFX_CREATE_SURFACE_PDU pdu = {};
	pdu.surfaceId = id;
	pdu.width = w;
	pdu.height = h;
	return gfx->CreateSurface(gfx, &pdu);
}

int main(int argc, char** argv)
{
	// "ceiling": C++ code past kMaxSessionData ends the process with 147 (oma::limit_memory).
	if (argc > 1 && strcmp(argv[1], "ceiling") == 0)
	{
		oma::limit_memory();
		volatile char* p = new char[oma::kMaxSessionData + (1ull << 20)];
		p[0] = 1;
		return 0;
	}
	RdpgfxClientContext gfx;
	memset(&gfx, 0, sizeof(gfx));
	gfx.CreateSurface = gdi_create;
	gfx.GetSurfaceIds = gdi_ids;
	gfx.GetSurfaceData = gdi_data;
	gfx.SurfaceToCache = gdi_to_cache;
	gfx.GetCacheSlotData = gdi_slot;
	int ended = 0;
	oma::guard_gfx(&gfx, [&](const std::string&) { ended++; });
	oma::guard_gfx(&gfx, [&](const std::string&) { ended += 100; }); // a second call wraps nothing

	expect(create(&gfx, 1, 3840, 2160) == CHANNEL_RC_OK && created == 1, "a 4K surface is created");
	expect(create(&gfx, 2, 8192, 8192) == CHANNEL_RC_OK && created == 2, "8192 a side is created");
	expect(create(&gfx, 3, 8193, 16) != CHANNEL_RC_OK && created == 2, "8193 wide is refused before gdi");
	expect(create(&gfx, 3, 16, 65535) != CHANNEL_RC_OK && created == 2, "65535 tall is refused before gdi");
	expect(create(&gfx, 3, 0, 16) != CHANNEL_RC_OK && created == 2, "an empty surface is refused");
	expect(ended == 1, "the session is ended once, by the first guard");

	// Room is what the surfaces gdi still holds take, tiles counted: with the 4K one and one of
	// 8192x8192 (1.35 GB) there is no room for a second 8192x8192, but there is once it is deleted.
	expect(create(&gfx, 10, 8192, 8192) != CHANNEL_RC_OK, "a second 8192x8192 surface is refused");
	surfaces.erase(2);
	expect(create(&gfx, 10, 8192, 8192) == CHANNEL_RC_OK, "a deleted surface makes room");
	int fit = 0;
	for (UINT16 id = 20; id < 40; id++)
		if (create(&gfx, id, 3840, 2160) == CHANNEL_RC_OK)
			fit++;
	expect(fit == 3, "4K surfaces fill the rest: three beside the 8192x8192 and the first 4K one");
	uint64_t total = 0, tiles = 0;
	for (const auto& [id, s] : surfaces)
	{
		total += uint64_t(s.scanline) * s.height;
		tiles += ((s.mappedWidth + 63) / 64) * ((s.mappedHeight + 63) / 64) * oma::kGfxTileBytes;
	}
	expect(total + tiles <= oma::kMaxGfxSurfaceBytes, "gdi never holds more than kMaxGfxSurfaceBytes, tiles counted");


	// The cache: 4K entries (31.6 MiB) fit four times in 128 MiB, the fifth is refused before gdi.
	ended = 0;
	expect(to_cache(&gfx, 1, 3840, 2160) == CHANNEL_RC_OK, "a 4K cache entry");
	for (UINT16 slot = 1; slot <= 10; slot++) // the same slot again replaces it: no growth
		expect(to_cache(&gfx, 1, 3840, 2160) == CHANNEL_RC_OK, "a slot written again replaces its entry");
	expect(to_cache(&gfx, 2, 3840, 2160) == CHANNEL_RC_OK && to_cache(&gfx, 3, 3840, 2160) == CHANNEL_RC_OK &&
	           to_cache(&gfx, 4, 3840, 2160) == CHANNEL_RC_OK,
	       "four 4K entries fit");
	const int before = cached;
	expect(to_cache(&gfx, 5, 3840, 2160) != CHANNEL_RC_OK && cached == before, "the fifth is refused before gdi");
	cache.erase(2); // the server evicted one: room again
	expect(to_cache(&gfx, 5, 3840, 2160) == CHANNEL_RC_OK, "an evicted entry makes room");
	expect(to_cache(&gfx, 6, 8192, 8192) != CHANNEL_RC_OK, "an 8192x8192 entry does not fit beside them");
	uint64_t held = 0;
	for (const auto& [slot, e] : cache)
		held += uint64_t(e.scanline) * e.height;
	expect(held <= oma::kMaxGfxCacheBytes, "gdi never holds more than kMaxGfxCacheBytes of cache");

	if (failures == 0)
		printf("ok\n");
	return failures ? 1 : 0;
}
