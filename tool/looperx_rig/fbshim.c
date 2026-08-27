/* fbshim -- captures what the Looper X UI actually renders.
 *
 * Qt draws through EGL/GLES, so nothing is ever written to the framebuffer file
 * and there is no scanout to read. Intercept eglSwapBuffers instead: just
 * before each swap the back buffer holds the finished frame, so glReadPixels
 * there yields exactly what the panel would show.
 *
 * Frames land in $LOOPERX_FRAMEDIR as raw RGBA, bottom-row-first (GL's origin
 * is bottom-left). LOOPERX_FRAME_EVERY thins the stream -- software rendering
 * under emulation is slow and every frame is rarely wanted.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401

static int env_int(const char *k, int dflt) {
  const char *v = getenv(k);
  return (v && *v) ? atoi(v) : dflt;
}

unsigned int eglSwapBuffers(void *dpy, void *surface) {
  static unsigned int (*real)(void *, void *);
  static void (*readpixels)(int, int, int, int, unsigned, unsigned, void *);
  static unsigned char *buf;
  static long n;
  static int w, h, every;
  static const char *dir;

  if (!real) {
    real = dlsym(RTLD_NEXT, "eglSwapBuffers");
    readpixels = dlsym(RTLD_DEFAULT, "glReadPixels");
    w = env_int("QT_QPA_EGLFS_WIDTH", 800);
    h = env_int("QT_QPA_EGLFS_HEIGHT", 1280);
    every = env_int("LOOPERX_FRAME_EVERY", 30);
    dir = getenv("LOOPERX_FRAMEDIR");
    if (dir && readpixels) buf = malloc((size_t)w * h * 4);
    fprintf(stderr, "[fbshim] %dx%d every=%d dir=%s\n", w, h, every,
            dir ? dir : "(off)");
  }

  if (buf && (n % every) == 0) {
    readpixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf);
    char path[512];
    snprintf(path, sizeof path, "%s/frame_%06ld.rgba", dir, n / every);
    FILE *f = fopen(path, "wb");
    if (f) {
      fwrite(buf, 1, (size_t)w * h * 4, f);
      fclose(f);
    }
  }
  n++;
  return real(dpy, surface);
}
