package eu.siacs.conversations.entities;

public class BotCommand {
    private final String command;
    private final String description;

    public BotCommand(final String command, final String description) {
        this.command = command != null && command.startsWith("/") ? command.substring(1) : (command != null ? command : "");
        this.description = description != null ? description : "";
    }

    public String getCommand() {
        return command;
    }

    public String getDescription() {
        return description;
    }
}
