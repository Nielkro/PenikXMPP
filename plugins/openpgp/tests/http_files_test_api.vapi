namespace Dino {
    namespace Plugins {
        namespace HttpFiles {
            [CCode (cheader_filename = "http-files.h")]
            public class FileProvider : Dino.FileProvider, GLib.Object {
                public FileProvider(Dino.StreamInteractor stream_interactor, Dino.Database db);
                public void shutdown();
            }

            [CCode (cheader_filename = "http-files.h")]
            public class HttpFileSender : Dino.FileSender, GLib.Object {
                public HttpFileSender(Dino.StreamInteractor stream_interactor, Dino.Database db);
                public void shutdown();
            }
        }
    }
}
