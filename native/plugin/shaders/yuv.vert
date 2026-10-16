#version 440
// A Gliff picture's quad (plugin/yuvnode.cpp); the texture coordinates span the picture.

layout(location = 0) in vec4 qt_VertexPosition;
layout(location = 1) in vec2 qt_VertexTexCoord;
layout(location = 0) out vec2 tc;

layout(std140, binding = 0) uniform buf
{
	mat4 qt_Matrix;
	float qt_Opacity;
	float dual;
	float smoothing;
	vec2 size;
};

void main()
{
	tc = qt_VertexTexCoord;
	gl_Position = qt_Matrix * qt_VertexPosition;
}
