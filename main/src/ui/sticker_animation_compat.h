#pragma once

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>
#include <gdk/gdk.h>

GdkPixbufAnimation* dinox_pixbuf_animation_new_from_stream(GInputStream* stream, int max_width, int max_height,
    int* source_width, int* source_height, GCancellable* cancellable, GError** error);
GdkPixbuf* dinox_pixbuf_from_texture(GdkTexture* texture);
gboolean dinox_pixbuf_animation_is_static_image(GdkPixbufAnimation* animation);
GdkPixbuf* dinox_pixbuf_animation_get_static_image(GdkPixbufAnimation* animation);
GdkPixbufAnimationIter* dinox_pixbuf_animation_get_iter(GdkPixbufAnimation* animation);
int dinox_pixbuf_animation_iter_get_delay_time(GdkPixbufAnimationIter* iter);
gboolean dinox_pixbuf_animation_iter_advance(GdkPixbufAnimationIter* iter);
GdkPixbuf* dinox_pixbuf_animation_iter_get_pixbuf(GdkPixbufAnimationIter* iter);
