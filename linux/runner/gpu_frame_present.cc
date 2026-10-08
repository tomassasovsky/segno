// Keeps the hand-off of each Flutter frame to GTK on the GPU (#1302).
//
// The Flutter GTK embedder (fl_compositor_opengl.cc, Flutter 3.44.4) hands
// GTK every frame as an RGBA GL texture through gdk_cairo_draw_from_gl. For a
// texture with alpha, GDK 3 (gdk/gdkgl.c) uploads its window-sized CPU paint
// surface to the GPU and blends the frame over it, on the main thread, every
// frame. On the appliance that upload was ~15% of the main thread's samples
// at idle, and it scales with the frame rate, so animating track meters paid
// it on every frame.
//
// GDK has a GPU-only path for an opaque renderbuffer: it blits it straight to
// the window's back buffer and marks the region as drawn, so nothing is
// uploaded. This file interposes gdk_cairo_draw_from_gl (the executable's
// definition wins symbol lookup, so libflutter_linux_gtk.so's call lands here),
// copies the embedder's texture into an opaque GL_RGB8 renderbuffer with
// glBlitFramebuffer, and hands GDK that renderbuffer. Flutter paints every
// pixel opaque, so dropping the alpha channel loses nothing.
//
// GDK shares GL objects per window, not across windows, so the renderbuffer
// and framebuffers live per GL context: the waveform window's context cannot
// use the main window's renderbuffer (it rendered nothing when it tried).
// Calls from anything but the embedder, and non-texture sources, go straight
// to GDK.

#include <dlfcn.h>
#include <epoxy/gl.h>
#include <gdk/gdk.h>

#include <unordered_map>

namespace {

constexpr char kEmbedderLibrary[] = "/libflutter_linux_gtk.so";

using DrawFromGl = void (*)(cairo_t*, GdkWindow*, int, int, int, int, int, int,
                            int);

// GL objects for one context. Framebuffer objects are never shared between
// contexts and the renderbuffer is only shared within this context's window.
struct PresentTarget {
  GLuint read_framebuffer = 0;
  GLuint draw_framebuffer = 0;
  GLuint renderbuffer = 0;
  int width = 0;
  int height = 0;
};

// Only touched on the GTK main thread, which is where GTK draws.
std::unordered_map<GdkGLContext*, PresentTarget> targets;

void forget_context(gpointer, GObject* context) {
  // The context is gone, and its GL objects with it.
  targets.erase(reinterpret_cast<GdkGLContext*>(context));
}

PresentTarget& target_for(GdkGLContext* context) {
  auto found = targets.find(context);
  if (found != targets.end()) {
    return found->second;
  }
  PresentTarget& target = targets[context];
  glGenFramebuffers(1, &target.read_framebuffer);
  glGenFramebuffers(1, &target.draw_framebuffer);
  glGenRenderbuffers(1, &target.renderbuffer);
  // A later context at the same address must not inherit these names.
  g_object_weak_ref(G_OBJECT(context), forget_context, nullptr);
  return target;
}

bool called_from_embedder(void* return_address) {
  Dl_info info;
  return dladdr(return_address, &info) != 0 && info.dli_fname != nullptr &&
         g_str_has_suffix(info.dli_fname, kEmbedderLibrary);
}

// Copies [x, y, width, height] of texture into target's renderbuffer.
void copy_to_renderbuffer(PresentTarget& target,
                          int texture,
                          int x,
                          int y,
                          int width,
                          int height) {
  if (target.width != width || target.height != height) {
    glBindRenderbuffer(GL_RENDERBUFFER, target.renderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGB8, width, height);
    target.width = width;
    target.height = height;
  }

  GLint saved_read_framebuffer;
  GLint saved_draw_framebuffer;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &saved_read_framebuffer);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &saved_draw_framebuffer);
  const GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);

  glBindFramebuffer(GL_READ_FRAMEBUFFER, target.read_framebuffer);
  glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, texture, 0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.draw_framebuffer);
  glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_RENDERBUFFER, target.renderbuffer);
  glDisable(GL_SCISSOR_TEST);
  glBlitFramebuffer(x, y, x + width, y + height, 0, 0, width, height,
                    GL_COLOR_BUFFER_BIT, GL_NEAREST);

  if (scissor) {
    glEnable(GL_SCISSOR_TEST);
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, saved_read_framebuffer);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, saved_draw_framebuffer);
  // GDK reads the renderbuffer from the window's paint context next.
  glFlush();
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void gdk_cairo_draw_from_gl(
    cairo_t* cr,
    GdkWindow* window,
    int source,
    int source_type,
    int buffer_scale,
    int x,
    int y,
    int width,
    int height) {
  static const auto gdk_draw_from_gl = reinterpret_cast<DrawFromGl>(
      dlsym(RTLD_NEXT, "gdk_cairo_draw_from_gl"));

  GdkGLContext* context = gdk_gl_context_get_current();
  if (source_type != GL_TEXTURE || context == nullptr || width <= 0 ||
      height <= 0 || !called_from_embedder(__builtin_return_address(0))) {
    gdk_draw_from_gl(cr, window, source, source_type, buffer_scale, x, y,
                     width, height);
    return;
  }

  PresentTarget& target = target_for(context);
  copy_to_renderbuffer(target, source, x, y, width, height);
  gdk_draw_from_gl(cr, window, static_cast<int>(target.renderbuffer),
                   GL_RENDERBUFFER, buffer_scale, 0, 0, width, height);
}
