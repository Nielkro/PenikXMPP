namespace Dino.Ui.Test {
class BotProviderSelectionTest : Gee.TestCase {
    public BotProviderSelectionTest() {
        base("BotProviderSelection");
        add_test("LOCALE_api_keys_keep_the_selected_provider", () => {
            foreach (string key in Ui.BotProviderSelection.KEYS) {
                uint index = Ui.BotProviderSelection.index_of(" " + key.ascii_up() + " ");
                fail_if_not_eq_str(key, Ui.BotProviderSelection.key_at(index));
            }
            fail_if_not_eq_str("ollama", Ui.BotProviderSelection.key_at(999));
        });
    }
}
}
