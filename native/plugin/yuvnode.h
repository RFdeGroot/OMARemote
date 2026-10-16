#pragma once

#include <QHash>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSize>

class QQuickWindow;
class QSGTexture;
class YuvMaterial;

// A decoded NV12 surface a Gliff session handed over as a dmabuf ("surface" line, see
// native/gliff/main.cpp). RdpView keeps the descriptors open, so a node made anew (the scene graph
// rebuilt) can import it again.
struct DmabufSurface
{
	quint32 id = 0;
	int width = 0, height = 0;
	int objects = 0;
	int fds[4] = { -1, -1, -1, -1 };
	quint64 modifiers[4] = {};
	struct Layer
	{
		quint32 fourcc = 0;
		int object = 0;
		quint32 offset = 0, pitch = 0;
	} layers[2]; // Y (R8), then UV (GR88)
};

// Draws Gliff pictures straight from the decoder's surfaces: each one imported once through EGL
// as two GL textures, converted to RGB by the shader (shaders/yuv.frag). OpenGL scene graph only;
// lives on the render thread.
class YuvNode : public QSGGeometryNode
{
  public:
	explicit YuvNode(QQuickWindow* window);
	~YuvNode() override;

	// Shows main (and aux for Dual420) at size; the surfaces' generation changes when the session
	// starts its list again. False when the GPU cannot import them: draw another way.
	bool setPicture(const DmabufSurface& main, const DmabufSurface* aux, QSize size, quint64 generation);
	bool hasPicture() const { return m_hasPicture; }
	void setRect(const QRectF& rect, bool smooth);

  private:
	struct Imported
	{
		unsigned int tex[2] = {};
		void* images[2] = {};
		QSGTexture* textures[2] = {};
	};
	bool import(const DmabufSurface& s, Imported& out);
	void forget(Imported& im);
	void forgetAll();

	QQuickWindow* m_window;
	QSGGeometry m_geometry;
	YuvMaterial* m_material;
	QHash<quint32, Imported> m_imported;
	quint64 m_generation = 0;
	bool m_hasPicture = false;
};
