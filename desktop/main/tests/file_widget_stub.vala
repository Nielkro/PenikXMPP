using Gtk;

namespace Dino.Ui {

// AudioPlayerWidget shares a source file with the conversation meta adapter.
// Widget tests do not load the full timeline; retain only its required type.
public class FileMetaItem : Object {
    protected Dino.Entities.FileTransfer file_transfer;

    public FileMetaItem(Dino.ContentItem content_item, Dino.StreamInteractor stream_interactor) {
        file_transfer = ((Dino.FileItem) content_item).file_transfer;
    }

    public virtual Object? get_widget(Dino.Plugins.ConversationItemWidgetInterface outer, Dino.Plugins.WidgetType type) {
        return null;
    }
}

}
