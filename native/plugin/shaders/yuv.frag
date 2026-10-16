#version 440
// Gliff's decoded NV12 surfaces to RGB, per pixel: the recombination and colour of Gliff's own
// client (gliff-vk/shaders/recombine.comp, common.glsl), done where the picture is drawn. With
// dual, the auxiliary picture fills in the chroma Single420 leaves out (Dual420, see
// native/gliff/video.hpp for the layout).

layout(location = 0) in vec2 tc;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf
{
	mat4 qt_Matrix;
	float qt_Opacity;
	float dual;
	float smoothing; // the picture is scaled: blend the four nearest pixels
	vec2 size;       // the picture, in pixels
};

layout(binding = 1) uniform sampler2D mainY;
layout(binding = 2) uniform sampler2D mainUV;
layout(binding = 3) uniform sampler2D auxY;
layout(binding = 4) uniform sampler2D auxUV;

// BT.709, limited range.
vec3 to_rgb(float y8, float u8, float v8)
{
	float y = y8 * 255.0 - 16.0;
	float cb = u8 * 255.0 - 128.0;
	float cr = v8 * 255.0 - 128.0;
	return clamp(vec3(1.1644 * y + 1.7927 * cr, 1.1644 * y - 0.2132 * cb - 0.5329 * cr, 1.1644 * y + 2.1124 * cb) / 255.0,
	             0.0, 1.0);
}

vec3 pixel(ivec2 p)
{
	float y = texelFetch(mainY, p, 0).r;
	ivec2 b = p / 2;
	vec2 c = texelFetch(mainUV, b, 0).rg;
	if (dual > 0.5 && (p.x & 1) + (p.y & 1) > 0)
	{
		if ((p.y & 1) == 0)
			c = texelFetch(auxUV, b, 0).rg;
		else
		{
			int halfH = int(size.y) / 2;
			c = vec2(texelFetch(auxY, ivec2(p.x, b.y), 0).r, texelFetch(auxY, ivec2(p.x, halfH + b.y), 0).r);
		}
	}
	return to_rgb(y, c.r, c.g);
}

void main()
{
	vec2 at = tc * size;
	ivec2 last = ivec2(size) - 1;
	vec3 rgb;
	if (smoothing < 0.5)
		rgb = pixel(clamp(ivec2(at), ivec2(0), last));
	else
	{
		vec2 q = at - 0.5;
		ivec2 i = ivec2(floor(q));
		vec2 f = q - floor(q);
		vec3 a = pixel(clamp(i, ivec2(0), last));
		vec3 b = pixel(clamp(i + ivec2(1, 0), ivec2(0), last));
		vec3 c = pixel(clamp(i + ivec2(0, 1), ivec2(0), last));
		vec3 d = pixel(clamp(i + ivec2(1, 1), ivec2(0), last));
		rgb = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
	}
	fragColor = vec4(rgb, 1.0) * qt_Opacity;
}
