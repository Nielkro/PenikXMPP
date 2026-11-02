namespace Dino.Ui {

// Provider identifiers are API/storage keys, never translated display labels.
internal class BotProviderSelection : Object {
    internal const string[] KEYS = {
        "ollama", "openai", "claude", "gemini", "groq", "mistral",
        "deepseek", "perplexity", "xai", "openclaw"
    };

    internal static uint index_of(string provider) {
        string normalized = provider.strip().ascii_down();
        for (int i = 0; i < KEYS.length; i++) {
            if (KEYS[i] == normalized) return (uint) i;
        }
        return 0;
    }

    internal static string key_at(uint index) {
        return index < KEYS.length ? KEYS[index] : "ollama";
    }
}
}
