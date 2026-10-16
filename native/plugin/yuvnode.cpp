#include "yuvnode.h"

#include <QByteArray>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QQuickWindow>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGTexture>
#include <QtGui/qopenglcontext_platform.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <drm_fourcc.h>

#include <cstring>

// ---------------------------------------------------------------- material

class YuvMaterial : public QSGMaterial
{
  public:
	QSGTexture* textures[4] = {}; // main Y, main UV, aux Y, aux UV
	QSize size;
	bool dual = false;
	bool smooth = false;

	QSGMaterialType* type() const override
	{
		static QSGMaterialType kind;
		return &kind;
	}
	QSGMaterialShader* createShader(QSGRendererInterface::RenderMode) const override;
	int compare(const QSGMaterial* other) const override { return this == other ? 0 : (this < other ? -1 : 1); }
};

class YuvShader : public QSGMaterialShader
{
  public:
	YuvShader()
	{
		setShaderFileName(VertexStage, QStringLiteral(":/omaremote/shaders/yuv.vert.qsb"));
		setShaderFileName(FragmentStage, QStringLiteral(":/omaremote/shaders/yuv.frag.qsb"));
	}

	// The uniform block of shaders/yuv.vert and yuv.frag (std140): the matrix at 0, opacity at 64,
	// dual at 68, smoothing at 72, the size at 80.
	bool updateUniformData(RenderState& state, QSGMaterial* material, QSGMaterial*) override
	{
		auto* m = static_cast<YuvMaterial*>(material);
		char* buf = state.uniformData()->data();
		if (state.isMatrixDirty())
			memcpy(buf, state.combinedMatrix().constData(), 64);
		if (state.isOpacityDirty())
		{
			const float opacity = state.opacity();
			memcpy(buf + 64, &opacity, 4);
		}
		const float flags[2] = { m->dual ? 1.0f : 0.0f, m->smooth ? 1.0f : 0.0f };
		memcpy(buf + 68, flags, 8);
		const float size[2] = { float(m->size.width()), float(m->size.height()) };
		memcpy(buf + 80, size, 8);
		return true;
	}

	void updateSampledImage(RenderState&, int binding, QSGTexture** texture, QSGMaterial* material,
	                        QSGMaterial*) override
	{
		if (binding >= 1 && binding <= 4)
			*texture = static_cast<YuvMaterial*>(material)->textures[binding - 1];
	}
};

QSGMaterialShader* YuvMaterial::createShader(QSGRendererInterface::RenderMode) const
{
	return new YuvShader;
}

// ---------------------------------------------------------------- node

YuvNode::YuvNode(QQuickWindow* window)
    : m_window(window), m_geometry(QSGGeometry::defaultAttributes_TexturedPoint2D(), 4), m_material(new YuvMaterial)
{
	setGeometry(&m_geometry);
	setMaterial(m_material);
	setFlag(OwnsMaterial, true);
}

YuvNode::~YuvNode()
{
	forgetAll();
}

void YuvNode::setRect(const QRectF& rect, bool smooth)
{
	QSGGeometry::updateTexturedRectGeometry(&m_geometry, rect, QRectF(0, 0, 1, 1));
	markDirty(DirtyGeometry);
	if (m_material->smooth != smooth)
	{
		m_material->smooth = smooth;
		markDirty(DirtyMaterial);
	}
}

bool YuvNode::setPicture(const DmabufSurface& main, const DmabufSurface* aux, QSize size, quint64 generation)
{
	if (generation != m_generation)
	{
		forgetAll();
		m_generation = generation;
	}
	for (const DmabufSurface* s : { &main, aux })
	{
		if (!s || m_imported.contains(s->id))
			continue;
		Imported im;
		if (!import(*s, im))
			return false;
		m_imported.insert(s->id, im);
	}
	const Imported& m = m_imported[main.id];
	const Imported& a = aux ? m_imported[aux->id] : m;
	m_material->textures[0] = m.textures[0];
	m_material->textures[1] = m.textures[1];
	m_material->textures[2] = a.textures[0];
	m_material->textures[3] = a.textures[1];
	m_material->dual = aux != nullptr;
	m_material->size = size;
	m_hasPicture = true;
	markDirty(DirtyMaterial);
	return true;
}

namespace {
using CreateImage = EGLImageKHR (*)(EGLDisplay, EGLContext, EGLenum, EGLClientBuffer, const EGLint*);
using DestroyImage = EGLBoolean (*)(EGLDisplay, EGLImageKHR);
using TargetTexture = void (*)(GLenum, void*);

struct Egl
{
	EGLDisplay display = EGL_NO_DISPLAY;
	CreateImage create = nullptr;
	DestroyImage destroy = nullptr;
	TargetTexture target = nullptr;
	bool modifiers = false;
};

// The render thread's EGL, when the scene graph draws with it and can take dmabufs.
bool egl(Egl& e)
{
	QOpenGLContext* ctx = QOpenGLContext::currentContext();
	auto* native = ctx ? ctx->nativeInterface<QNativeInterface::QEGLContext>() : nullptr;
	if (!native)
		return false;
	e.display = native->display();
	const char* ext = eglQueryString(e.display, EGL_EXTENSIONS);
	if (!ext || !strstr(ext, "EGL_EXT_image_dma_buf_import"))
		return false;
	e.modifiers = strstr(ext, "EGL_EXT_image_dma_buf_import_modifiers") != nullptr;
	e.create = reinterpret_cast<CreateImage>(eglGetProcAddress("eglCreateImageKHR"));
	e.destroy = reinterpret_cast<DestroyImage>(eglGetProcAddress("eglDestroyImageKHR"));
	e.target = reinterpret_cast<TargetTexture>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
	return e.create && e.destroy && e.target;
}
}

bool YuvNode::import(const DmabufSurface& s, Imported& out)
{
	Egl e;
	if (!egl(e))
		return false;
	QOpenGLFunctions* gl = QOpenGLContext::currentContext()->functions();
	// The scene graph keeps its own idea of what is bound: leave it as it was.
	GLint boundTexture = 0;
	gl->glGetIntegerv(GL_TEXTURE_BINDING_2D, &boundTexture);
	bool ok = true;
	for (int i = 0; i < 2 && ok; i++)
	{
		const DmabufSurface::Layer& l = s.layers[i];
		const int w = i ? (s.width + 1) / 2 : s.width, h = i ? (s.height + 1) / 2 : s.height;
		if (l.object < 0 || l.object >= s.objects || s.fds[l.object] < 0)
		{
			ok = false;
			break;
		}
		const quint64 mod = s.modifiers[l.object];
		EGLint attrs[] = { EGL_WIDTH, w, EGL_HEIGHT, h, EGL_LINUX_DRM_FOURCC_EXT, EGLint(l.fourcc),
			               EGL_DMA_BUF_PLANE0_FD_EXT, s.fds[l.object], EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGLint(l.offset),
			               EGL_DMA_BUF_PLANE0_PITCH_EXT, EGLint(l.pitch), EGL_NONE, EGL_NONE, EGL_NONE, EGL_NONE,
			               EGL_NONE };
		if (mod != DRM_FORMAT_MOD_INVALID)
		{
			if (!e.modifiers && mod != DRM_FORMAT_MOD_LINEAR)
			{
				ok = false;
				break;
			}
			if (e.modifiers)
			{
				attrs[12] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
				attrs[13] = EGLint(mod & 0xffffffff);
				attrs[14] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
				attrs[15] = EGLint(mod >> 32);
			}
		}
		EGLImageKHR image = e.create(e.display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, attrs);
		if (image == EGL_NO_IMAGE_KHR)
		{
			qWarning("omaremote: could not import a Gliff surface (EGL error 0x%x)", eglGetError());
			ok = false;
			break;
		}
		out.images[i] = image;
		gl->glGenTextures(1, &out.tex[i]);
		gl->glBindTexture(GL_TEXTURE_2D, out.tex[i]);
		gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		while (gl->glGetError() != GL_NO_ERROR)
		{
		}
		e.target(GL_TEXTURE_2D, image);
		if (gl->glGetError() != GL_NO_ERROR)
		{
			qWarning("omaremote: the GPU cannot sample a Gliff surface");
			ok = false;
			break;
		}
		out.textures[i] = QNativeInterface::QSGOpenGLTexture::fromNative(out.tex[i], m_window, QSize(w, h));
		out.textures[i]->setFiltering(QSGTexture::Nearest);
	}
	gl->glBindTexture(GL_TEXTURE_2D, GLuint(boundTexture));
	if (!ok)
		forget(out);
	return ok;
}

void YuvNode::forget(Imported& im)
{
	for (int i = 0; i < 2; i++)
	{
		delete im.textures[i];
		im.textures[i] = nullptr;
	}
	QOpenGLContext* ctx = QOpenGLContext::currentContext();
	if (!ctx)
		return; // the context went first, and took the textures with it
	ctx->functions()->glDeleteTextures(2, im.tex);
	Egl e;
	if (egl(e))
		for (void*& image : im.images)
			if (image)
				e.destroy(e.display, image);
	im = {};
}

void YuvNode::forgetAll()
{
	for (Imported& im : m_imported)
		forget(im);
	m_imported.clear();
	for (QSGTexture*& t : m_material->textures)
		t = nullptr;
	m_hasPicture = false;
}
