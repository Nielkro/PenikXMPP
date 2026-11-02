#include "sticker_animation_compat.h"

typedef struct {
    int max_width, max_height, width, height;
    gboolean oversized;
} PreviewSize;

static void preview_size_prepared(GdkPixbufLoader* loader, int width, int height, gpointer data) {
    PreviewSize* size = data;
    size->width = width;
    size->height = height;
    size->oversized = width <= 0 || height <= 0 || (gint64) width * height > 64000000;
    if (size->oversized) {
        gdk_pixbuf_loader_set_size(loader, 1, 1);
        return;
    }
    double scale = MIN(1.0, MIN((double) size->max_width / width, (double) size->max_height / height));
    gdk_pixbuf_loader_set_size(loader, MAX(1, (int) (width * scale)), MAX(1, (int) (height * scale)));
}

GdkPixbufAnimation* dinox_pixbuf_animation_new_from_stream(GInputStream* stream, int max_width, int max_height,
    int* source_width, int* source_height, GCancellable* cancellable, GError** error) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    if (g_cancellable_set_error_if_cancelled(cancellable, error)) return NULL;
    g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
    PreviewSize size = { max_width, max_height, -1, -1, FALSE };
    g_signal_connect(loader, "size-prepared", G_CALLBACK(preview_size_prepared), &size);
    guint8 buffer[4096];
    gssize count;
    while ((count = g_input_stream_read(stream, buffer, sizeof buffer, cancellable, error)) > 0) {
        if (g_cancellable_set_error_if_cancelled(cancellable, error)) {
            gdk_pixbuf_loader_close(loader, NULL);
            return NULL;
        }
        gboolean written = gdk_pixbuf_loader_write(loader, buffer, (gsize) count, error);
        if (size.oversized) {
            g_clear_error(error);
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NO_SPACE, "Image exceeds the inline preview pixel limit");
            gdk_pixbuf_loader_close(loader, NULL);
            return NULL;
        }
        if (!written) {
            gdk_pixbuf_loader_close(loader, NULL);
            return NULL;
        }
    }
    if (count < 0) {
        gdk_pixbuf_loader_close(loader, NULL);
        return NULL;
    }
    gboolean closed = gdk_pixbuf_loader_close(loader, error);
    // Small files can remain buffered until close(), which may emit the size
    // signal for the first time. Enforce the same limit for that path too.
    if (size.oversized) {
        // Keep the size rejection even if a malformed payload also fails to
        // decode. A generic decode error would enable the fallback decoder.
        g_clear_error(error);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NO_SPACE, "Image exceeds the inline preview pixel limit");
        return NULL;
    }
    if (!closed) return NULL;
    if (g_cancellable_set_error_if_cancelled(cancellable, error)) return NULL;
    *source_width = size.width;
    *source_height = size.height;
    GdkPixbufAnimation* animation = gdk_pixbuf_loader_get_animation(loader);
    if (animation == NULL) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "No preview image decoded");
        return NULL;
    }
    return g_object_ref(animation);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

GdkPixbuf* dinox_pixbuf_from_texture(GdkTexture* texture) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_get_from_texture(texture);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

gboolean dinox_pixbuf_animation_is_static_image(GdkPixbufAnimation* animation) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_animation_is_static_image(animation);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

GdkPixbuf* dinox_pixbuf_animation_get_static_image(GdkPixbufAnimation* animation) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_animation_get_static_image(animation);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

GdkPixbufAnimationIter* dinox_pixbuf_animation_get_iter(GdkPixbufAnimation* animation) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_animation_get_iter(animation, NULL);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

int dinox_pixbuf_animation_iter_get_delay_time(GdkPixbufAnimationIter* iter) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_animation_iter_get_delay_time(iter);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

gboolean dinox_pixbuf_animation_iter_advance(GdkPixbufAnimationIter* iter) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_animation_iter_advance(iter, NULL);
    G_GNUC_END_IGNORE_DEPRECATIONS
}

GdkPixbuf* dinox_pixbuf_animation_iter_get_pixbuf(GdkPixbufAnimationIter* iter) {
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    return gdk_pixbuf_animation_iter_get_pixbuf(iter);
    G_GNUC_END_IGNORE_DEPRECATIONS
}
