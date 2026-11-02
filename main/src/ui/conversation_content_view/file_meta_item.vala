using Gee;
using Dino.Entities;

namespace Dino.Ui {

public class FileMetaItem : ConversationSummary.ContentMetaItem {

    private StreamInteractor stream_interactor;
    private FileItem file_item;
    protected FileTransfer file_transfer;

    public FileMetaItem(ContentItem content_item, StreamInteractor stream_interactor) {
        base(content_item);
        this.stream_interactor = stream_interactor;
        this.file_item = content_item as FileItem;
        this.file_transfer = file_item.file_transfer;
    }

    public override Object? get_widget(Plugins.ConversationItemWidgetInterface outer, Plugins.WidgetType type) {
        FileWidget widget = new FileWidget(file_transfer, stream_interactor);
        new FileWidgetController(widget, file_transfer, stream_interactor);
        return widget;
    }

    public override Gee.List<Plugins.MessageAction>? get_item_actions(Plugins.WidgetType type) {
        Gee.List<Plugins.MessageAction> actions = new ArrayList<Plugins.MessageAction>();

        actions.add(get_reply_action(content_item, file_item.conversation,
            stream_interactor));
        actions.add(get_reaction_action(content_item, file_item.conversation,
            stream_interactor));

        // var kick_action = get_kick_action(content_item, file_item.conversation, stream_interactor);
        // if (kick_action != null) actions.add(kick_action);

        // var ban_action = get_ban_action(content_item, file_item.conversation, stream_interactor);
        // if (ban_action != null) actions.add(ban_action);

        var delete_action = get_delete_action(content_item,
            file_item.conversation, stream_interactor);
        if (delete_action != null) actions.add(delete_action);

        return actions;
    }
}

}
