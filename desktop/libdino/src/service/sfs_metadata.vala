using Gdk;
using GLib;
using Gee;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;


namespace Dino {
    public static string? mime_type_from_filename(string? filename) {
        if (filename == null || filename == "") return null;

        // Extensions and MIME tokens use ASCII case rules, even with a
        // Turkish system locale. Never apply language rules to protocol IDs.
        string lower = filename.ascii_down();
        if (lower.has_suffix(".png") || lower.has_suffix(".apng")) return "image/png";
        if (lower.has_suffix(".jpg") || lower.has_suffix(".jpeg")) return "image/jpeg";
        if (lower.has_suffix(".gif")) return "image/gif";
        if (lower.has_suffix(".webp")) return "image/webp";
        if (lower.has_suffix(".heic")) return "image/heic";
        if (lower.has_suffix(".heif")) return "image/heif";
        if (lower.has_suffix(".avif")) return "image/avif";
        if (lower.has_suffix(".jxl")) return "image/jxl";
        if (lower.has_suffix(".svg") || lower.has_suffix(".svgz")) return "image/svg+xml";
        if (lower.has_suffix(".bmp")) return "image/bmp";
        if (lower.has_suffix(".tif") || lower.has_suffix(".tiff")) return "image/tiff";

        if (lower.has_suffix(".txt") || lower.has_suffix(".text")) return "text/plain";

        if (lower.has_suffix(".mp3")) return "audio/mpeg";
        if (lower.has_suffix(".ogg") || lower.has_suffix(".oga")) return "audio/ogg";
        if (lower.has_suffix(".wav")) return "audio/wav";
        if (lower.has_suffix(".m4a")) return "audio/mp4";
        if (lower.has_suffix(".flac")) return "audio/flac";

        if (lower.has_suffix(".mp4") || lower.has_suffix(".m4v")) return "video/mp4";
        if (lower.has_suffix(".mov")) return "video/quicktime";
        if (lower.has_suffix(".webm")) return "video/webm";
        if (lower.has_suffix(".ogv")) return "video/ogg";
        if (lower.has_suffix(".avi")) return "video/x-msvideo";
        if (lower.has_suffix(".mkv")) return "video/x-matroska";

        return null;
    }

    /** Normalize platform content types and incomplete MIME types. */
    public static string normalize_mime_type(string? content_type, string? filename = null) {
        if (content_type == null || content_type == "") {
            return mime_type_from_filename(filename) ?? "application/octet-stream";
        }

        // GIO reports extensions such as ".bmp" on Windows, not MIME types.
        // Convert registered types; unknown extensions still use our filename
        // fallback, including when only the extension itself is available.
        if (content_type.has_prefix(".")) {
            string? mime_type = ContentType.get_mime_type(content_type);
            string fallback_filename = filename != null && filename != ""
                ? filename : "file" + content_type;
            // Only pass a MIME type onward, so this conversion runs once.
            return normalize_mime_type(mime_type != null && mime_type.contains("/") && !mime_type.has_prefix(".")
                ? mime_type : "application/octet-stream", fallback_filename);
        }
        
        // If the platform only reports a generic type, prefer the filename.
        string lower_content_type = content_type.ascii_down();
        if (lower_content_type == "application/octet-stream" ||
            lower_content_type == "binary/octet-stream" ||
            lower_content_type.has_prefix("application/x-ext-")) {
            return mime_type_from_filename(filename) ?? "application/octet-stream";
        }

        // If already contains "/", it's valid.
        if (content_type.contains("/")) {
            return content_type;
        }
        
        // Windows sometimes returns just the type without subtype
        // Try to guess based on content and filename
        switch (content_type.ascii_down()) {
            case "text":
                if (filename != null) {
                    string lower = filename.ascii_down();
                    if (lower.has_suffix(".html") || lower.has_suffix(".htm")) return "text/html";
                    if (lower.has_suffix(".css")) return "text/css";
                    if (lower.has_suffix(".js")) return "text/javascript";
                    if (lower.has_suffix(".xml")) return "text/xml";
                    if (lower.has_suffix(".csv")) return "text/csv";
                    if (lower.has_suffix(".md")) return "text/markdown";
                }
                return "text/plain";
            case "image":
                if (filename != null) {
                    string? guessed = mime_type_from_filename(filename);
                    if (guessed != null && guessed.has_prefix("image/")) return guessed;
                }
                return "image/png";
            case "audio":
                if (filename != null) {
                    string? guessed = mime_type_from_filename(filename);
                    if (guessed != null && guessed.has_prefix("audio/")) return guessed;
                }
                return "audio/mpeg";
            case "video":
                if (filename != null) {
                    string? guessed = mime_type_from_filename(filename);
                    if (guessed != null && guessed.has_prefix("video/")) return guessed;
                }
                return "video/mp4";
            case "application":
                return "application/octet-stream";
            default:
                return "application/octet-stream";
        }
    }

    public static string normalize_display_mime_type(string? content_type, string? filename = null) {
        string normalized = normalize_mime_type(content_type, filename);
        string? by_name = mime_type_from_filename(filename);
        if (by_name == null) return normalized;

        if (by_name.has_prefix("video/") || by_name.has_prefix("audio/")) {
            return by_name;
        }

        if (by_name.has_prefix("image/") &&
            (normalized == "application/octet-stream" || normalized.has_prefix("application/x-ext-"))) {
            return by_name;
        }

        if (normalized == "application/octet-stream" || normalized.has_prefix("application/x-ext-")) {
            return by_name;
        }

        return normalized;
    }

    public interface FileMetadataProvider : Object {
        public abstract bool supports_file(File file);
        public abstract async void fill_metadata(File file, Xep.FileMetadataElement.FileMetadata metadata);
    }

    class GenericFileMetadataProvider: Dino.FileMetadataProvider, Object {
        public bool supports_file(File file) {
            return true;
        }

        public async void fill_metadata(File file, Xep.FileMetadataElement.FileMetadata metadata) {
            debug("GenericFileMetadataProvider: Processing %s", file.get_path());
            FileInfo info;
            try {
                info = file.query_info("*", FileQueryInfoFlags.NONE);
            } catch (GLib.Error e) {
                warning("Failed to query file info: %s", e.message);
                return;
            }

            metadata.name = info.get_display_name().make_valid();
            metadata.mime_type = normalize_mime_type(info.get_content_type(), metadata.name);
            if (metadata.name.has_suffix(".m4a")) {
                metadata.mime_type = "audio/mp4";
            }
            metadata.size = info.get_size();
            metadata.date = info.get_modification_date_time();

            // Skip hashing for files larger than 50MB to avoid stability issues and long delays
            if (metadata.size < 50 * 1024 * 1024) {
                var checksum_types = new ArrayList<ChecksumType>();
                checksum_types.add(ChecksumType.SHA256);
                checksum_types.add(ChecksumType.SHA512);
                var file_hashes = yield compute_file_hashes(file, checksum_types);

                if (file_hashes.has_key(ChecksumType.SHA256) && file_hashes.has_key(ChecksumType.SHA512)) {
                    metadata.hashes.add(new CryptographicHashes.Hash.with_checksum(ChecksumType.SHA256, file_hashes[ChecksumType.SHA256]));
                    metadata.hashes.add(new CryptographicHashes.Hash.with_checksum(ChecksumType.SHA512, file_hashes[ChecksumType.SHA512]));
                }
            }
        }
    }

    public class ImageFileMetadataProvider: Dino.FileMetadataProvider, Object {
        public bool supports_file(File file) {
            string mime_type;
            try {
                var info = file.query_info("*", FileQueryInfoFlags.NONE);
                mime_type = normalize_mime_type(info.get_content_type(), file.get_basename());
            } catch (GLib.Error e) {
                return false;
            }
            return Dino.Util.can_preview_image(mime_type, file.get_basename());
        }

        // Delegate to shared FileUtils (clone removal)
        private static bool looks_like_svg_file(File file) {
            return Dino.FileDetectionUtils.looks_like_svg_file(file);
        }

        private const int[] THUMBNAIL_DIMS = { 1, 2, 3, 4, 8 };
        private const string IMAGE_TYPE = "png";
        private const string MIME_TYPE = "image/png";
        private const int64 MAX_METADATA_IMAGE_BYTES = 25 * 1024 * 1024;
        private const int64 MAX_METADATA_IMAGE_PIXELS = 64000000;
        private static ThreadPool<ImageMetadataJob>? metadata_pool;

        private class ImageMetadataJob : Object {
            public File file;
            public Xep.FileMetadataElement.FileMetadata? result;
            public MainContext context;
            public SourceFunc? completed;

            public void run() {
                try {
                    result = read_image_metadata(file);
                } catch (Error e) {
                    // Optional metadata must not prevent sending the original
                    // file when a decoder rejects it or a preview exceeds limits.
                    debug("Image metadata unavailable: %s", e.message);
                }
                var idle = new IdleSource();
                idle.set_callback(() => {
                    SourceFunc? callback = (owned) completed;
                    if (callback != null) callback();
                    return Source.REMOVE;
                });
                idle.attach(context);
            }
        }

        public async void fill_metadata(File file, Xep.FileMetadataElement.FileMetadata metadata) {
            debug("ImageFileMetadataProvider: Processing %s", file.get_path());
            var job = new ImageMetadataJob() {
                file = file,
                context = MainContext.ref_thread_default(),
                completed = fill_metadata.callback
            };
            try {
                if (metadata_pool == null) {
                    metadata_pool = new ThreadPool<ImageMetadataJob>.with_owned_data((item) => item.run(), 2, false);
                }
                metadata_pool.add(job);
            } catch (ThreadError e) {
                // A failed worker creation can leave a queued job behind.
                // Do not let a later worker resume this caller a second time.
                job.completed = null;
                debug("Image metadata worker unavailable: %s", e.message);
                return;
            }
            yield;

            if (job.result == null) return;
            metadata.width = job.result.width;
            metadata.height = job.result.height;
            metadata.thumbnails.add_all(job.result.thumbnails);
        }

        private static Xep.FileMetadataElement.FileMetadata? read_image_metadata(File file) throws Error {
            // Do not invoke the SVG loader (librsvg/gdk-pixbuf) in Flatpak runtimes due to crashes.
            // Some files may be mislabeled (e.g. SVGZ content with image/png mime type).
            if (looks_like_svg_file(file)) {
                return null;
            }
            if (file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size() > MAX_METADATA_IMAGE_BYTES) {
                throw new IOError.NO_SPACE("Image exceeds the metadata preview byte limit");
            }
            var metadata = new Xep.FileMetadataElement.FileMetadata();
            var loader = new PixbufLoader();
            bool oversized = false;
            bool closed = false;
            ulong size_handler = loader.size_prepared.connect((width, height) => {
                metadata.width = width;
                metadata.height = height;
                oversized = width <= 0 || height <= 0 || (int64) width * height > MAX_METADATA_IMAGE_PIXELS;
                if (oversized) {
                    loader.set_size(1, 1);
                    return;
                }
                double scale = double.min(1.0, double.min(8.0 / width, 8.0 / height));
                loader.set_size(int.max(1, (int) (width * scale)), int.max(1, (int) (height * scale)));
            });
            FileInputStream? stream = null;
            Pixbuf? pixbuf = null;
            try {
                stream = file.read();
                uint8[] chunk = new uint8[4096];
                int64 bytes_read = 0;
                ssize_t count;
                while ((count = stream.read(chunk)) > 0) {
                    bytes_read += count;
                    if (bytes_read > MAX_METADATA_IMAGE_BYTES) {
                        throw new IOError.NO_SPACE("Image exceeds the metadata preview byte limit");
                    }
                    loader.write(chunk[0:count]);
                    if (oversized) throw new IOError.NO_SPACE("Image exceeds the metadata preview pixel limit");
                }
                closed = true;
                loader.close();
                if (oversized) throw new IOError.NO_SPACE("Image exceeds the metadata preview pixel limit");
                pixbuf = loader.get_pixbuf();
            } finally {
                if (!closed) { try { loader.close(); } catch (Error ignored) { } }
                loader.disconnect(size_handler);
                if (stream != null) { try { stream.close(); } catch (Error ignored) { } }
            }
            if (pixbuf == null || metadata.width <= 0 || metadata.height <= 0) {
                throw new IOError.INVALID_DATA("No image metadata decoded");
            }
            float ratio = (float)metadata.width / (float) metadata.height;

            int thumbnail_width = -1;
            int thumbnail_height = -1;
            float diff = float.INFINITY;
            for (int i = 0; i < THUMBNAIL_DIMS.length; i++) {
                int test_width = THUMBNAIL_DIMS[i];
                int test_height = THUMBNAIL_DIMS[THUMBNAIL_DIMS.length - 1 - i];
                float test_ratio = (float)test_width / (float)test_height;
                float test_diff = (test_ratio - ratio).abs();
                if (test_diff < diff) {
                    thumbnail_width = test_width;
                    thumbnail_height = test_height;
                    diff = test_diff;
                }
            }

            Pixbuf? thumbnail_pixbuf = pixbuf.scale_simple(thumbnail_width, thumbnail_height, InterpType.BILINEAR);
            if (thumbnail_pixbuf == null) throw new IOError.FAILED("Could not create image metadata thumbnail");
            uint8[] buffer = pixbuf_to_png_bytes(thumbnail_pixbuf);
            var thumbnail = new Xep.JingleContentThumbnails.Thumbnail();
            thumbnail.data = new Bytes.take(buffer);
            thumbnail.media_type = MIME_TYPE;
            thumbnail.width = thumbnail_width;
            thumbnail.height = thumbnail_height;
            metadata.thumbnails.add(thumbnail);
            return metadata;
        }
    }
}
