using Gee;

namespace Dino.Plugins.BotFeatures {

/**
 * AI Integration for dedicated bots.
 * Supports:
 *   - OpenAI (GPT-4, GPT-4o, o1, ...)
 *   - Claude / Anthropic (claude-sonnet-4-20250514, Haiku, Opus)
 *   - Google Gemini (gemini-2.5-flash-lite, gemini-2.5-flash, gemini-2.5-pro)
 *   - Groq (llama-3.3-70b, mixtral, gemma2)
 *   - Mistral (mistral-large, mistral-medium)
 *   - Ollama (lokal: llama3, phi3, gemma, ...)
 *   - OpenClaw (autonomer AI-Agent / Orchestrator)
 *   - xAI / Grok (Responses API)
 *   - Jede OpenAI-kompatible API (vLLM, LM Studio, text-generation-webui, ...)
 *
 * Settings per bot (in bot_registry):
 *   bot_{id}_ai_enabled      = "true" / "false"
 *   bot_{id}_ai_endpoint     = API URL
 *   bot_{id}_ai_key          = API key (empty for Ollama)
 *   bot_{id}_ai_model        = model name
 *   bot_{id}_ai_system       = system prompt
 *   bot_{id}_ai_type         = "openai" / "claude" / "gemini" / "ollama"
 */
public class AiIntegration : Object {

    private BotRegistry registry;
    private Soup.Session http;

    // Per-bot conversation history (last N messages for context)
    private HashMap<string, ArrayList<ChatMessage>> histories;
    private const int MAX_HISTORY = 20;
    private const int MAX_HISTORY_KEYS = 100;  // BUG-13 fix: max unique bot+JID combos

    // Provider preset info
    public class ProviderPreset {
        public string ai_type;
        public string endpoint;
        public ProviderPreset(string ai_type, string endpoint) {
            this.ai_type = ai_type;
            this.endpoint = endpoint;
        }
    }

    // Provider presets: name -> ProviderPreset
    private HashMap<string, ProviderPreset> presets;

    public AiIntegration(BotRegistry registry) {
        this.registry = registry;
        this.http = new Soup.Session();
        this.http.timeout = 60;
        this.histories = new HashMap<string, ArrayList<ChatMessage>>();

        // Initialize provider presets
        presets = new HashMap<string, ProviderPreset>();
        presets["openai"]  = new ProviderPreset("openai", "https://api.openai.com/v1/chat/completions");
        presets["claude"]  = new ProviderPreset("claude", "https://api.anthropic.com/v1/messages");
        presets["gemini"]  = new ProviderPreset("gemini", "https://generativelanguage.googleapis.com/v1beta");
        presets["groq"]    = new ProviderPreset("openai", "https://api.groq.com/openai/v1/chat/completions");
        presets["mistral"] = new ProviderPreset("openai", "https://api.mistral.ai/v1/chat/completions");
        presets["ollama"]  = new ProviderPreset("ollama", "http://localhost:11434");
        presets["deepseek"]= new ProviderPreset("openai", "https://api.deepseek.com/v1/chat/completions");
        presets["perplexity"] = new ProviderPreset("openai", "https://api.perplexity.ai/chat/completions");
        presets["openclaw"]  = new ProviderPreset("openclaw", "http://localhost:18789/hooks/agent");
        presets["xai"] = new ProviderPreset("xai", "https://api.x.ai/v1/responses");
    }

    public class ChatMessage {
        public string role;
        public string content;
        public ChatMessage(string role, string content) {
            this.role = role;
            this.content = content;
        }
    }

    // Check if AI is enabled for a bot
    public bool is_enabled(int bot_id) {
        string? val = registry.get_setting("bot_%d_ai_enabled".printf(bot_id));
        return val == "true";
    }

    // Configure AI for a bot
    public void configure(int bot_id, string ai_type, string endpoint, string api_key,
                          string model, string? system_prompt, bool enable_ai) {
        string prefix = "bot_%d_ai".printf(bot_id);
        if (enable_ai) {
            registry.set_setting(prefix + "_enabled", "true");
        }
        registry.set_setting(prefix + "_type", ai_type);
        registry.set_setting(prefix + "_endpoint", endpoint);
        registry.set_secret_setting(prefix + "_key", api_key);
        registry.set_setting(prefix + "_model", model);
        if (system_prompt != null) {
            registry.set_setting(prefix + "_system", system_prompt);
        }
        message("AI: Configured for bot %d: type=%s model=%s endpoint=%s", bot_id, ai_type, model, endpoint);
    }

    // Configure using a preset provider name
    public bool has_provider_preset(string provider) {
        return presets.has_key(provider.ascii_down());
    }

    public bool provider_requires_api_key(string provider) {
        string normalized = provider.strip().ascii_down();
        return normalized != "ollama";
    }

    public string? provider_ai_type(string provider) {
        string normalized = provider.strip().ascii_down();
        if (!presets.has_key(normalized)) return null;
        return presets[normalized].ai_type;
    }

    public string? provider_endpoint(string provider) {
        string normalized = provider.strip().ascii_down();
        if (!presets.has_key(normalized)) return null;
        return presets[normalized].endpoint;
    }

    public string configure_preset(int bot_id, string provider, string api_key, string model, bool enable_ai) {
        string provider_lower = provider.ascii_down();
        if (!presets.has_key(provider_lower)) {
            var sb = new StringBuilder();
            sb.append("Unbekannter Anbieter: %s\n\nVerfuegbare Anbieter:\n".printf(provider));
            foreach (var key in presets.keys) {
                sb.append("  %s\n".printf(key));
            }
            return sb.str;
        }

        if (provider_requires_api_key(provider_lower) && (api_key.strip() == "" || api_key.strip() == "-")) {
            return "API key required for provider: %s".printf(provider_lower);
        }

        ProviderPreset preset = presets[provider_lower];
        string ai_type = preset.ai_type;
        string endpoint = preset.endpoint;

        string prefix = "bot_%d_ai".printf(bot_id);
        string? default_prompt = enable_ai && registry.get_setting(prefix + "_system") == null
            ? "Du bist ein hilfreicher Assistent."
            : null;

        configure(bot_id, ai_type, endpoint,
                  api_key == "-" ? "" : api_key, model,
                  default_prompt,
                  enable_ai);

        string state = enable_ai ? "KI konfiguriert und aktiviert!" : "KI konfiguriert.";
        return "%s\nAnbieter: %s\nTyp: %s\nModell: %s".printf(
            state,
            provider_lower, ai_type, model);
    }

    // Disable AI for a bot
    public void disable(int bot_id) {
        registry.set_setting("bot_%d_ai_enabled".printf(bot_id), "false");
        // Clear history
        clear_history(bot_id, "all");
        message("AI: Disabled for bot %d", bot_id);
    }

    // Clear conversation history
    public void clear_history(int bot_id, string from_jid) {
        if (from_jid == "all") {
            var to_remove = new ArrayList<string>();
            foreach (var key in histories.keys) {
                if (key.has_prefix("%d:".printf(bot_id))) {
                    to_remove.add(key);
                }
            }
            foreach (var key in to_remove) {
                histories.unset(key);
            }
        } else {
            string hkey = "%d:%s".printf(bot_id, from_jid);
            histories.unset(hkey);
        }
    }

    // Get current AI config as status string
    public string get_status(int bot_id) {
        string prefix = "bot_%d_ai".printf(bot_id);
        bool enabled = is_enabled(bot_id);
        if (!enabled) {
            return "KI: deaktiviert";
        }
        string ai_type = registry.get_setting(prefix + "_type") ?? "openai";
        string model = registry.get_setting(prefix + "_model") ?? "?";
        string endpoint = registry.get_setting(prefix + "_endpoint") ?? "?";
        string system = registry.get_setting(prefix + "_system") ?? "(Standard)";
        return "KI: aktiv\nTyp: %s\nModell: %s\nEndpunkt: %s\nSystem-Prompt: %s".printf(
            ai_type, model, endpoint, system);
    }

    // Get help text for available providers
    public string get_providers_help() {
        return "Verfuegbare KI-Anbieter:\n\n" +
            "openai    - OpenAI (gpt-4, gpt-4o, gpt-4o-mini, o1)\n" +
            "claude    - Anthropic (claude-sonnet-4-20250514, claude-3-haiku, claude-3-opus)\n" +
            "gemini    - Google (gemini-2.5-flash-lite, gemini-2.5-flash, gemini-2.5-pro)\n" +
            "groq      - Groq (llama-3.3-70b-versatile, mixtral-8x7b)\n" +
            "mistral   - Mistral (mistral-large-latest, mistral-medium)\n" +
            "deepseek  - DeepSeek (deepseek-chat, deepseek-coder)\n" +
            "perplexity- Perplexity (sonar-medium, sonar-small)\n" +
            "ollama    - Lokal (llama3, phi3, gemma, mistral, ...)\n" +
            "openclaw  - OpenClaw Agent (autonomous AI orchestrator)\n\n" +
            "Einrichten:\n" +
            "/ki setup <anbieter> <api_key> <model>\n\n" +
            "Beispiele:\n" +
            "/ki setup openai sk-abc123 gpt-4o\n" +
            "/ki setup claude sk-ant-abc123 claude-sonnet-4-20250514\n" +
            "/ki setup gemini AIza-abc123 gemini-2.5-flash-lite\n" +
            "/ki setup groq gsk_abc123 llama-3.3-70b-versatile\n" +
            "/ki setup ollama - llama3\n" +
            "/ki setup openclaw <token> agent";
    }

    // Send a message to the AI and get a response asynchronously
    public async string? ask(int bot_id, string from_jid, string question) {
        return yield ask_internal(bot_id, from_jid, question, null);
    }

    public async string? ask_with_context(int bot_id, string from_jid, string question, string? runtime_context) {
        return yield ask_internal(bot_id, from_jid, question, runtime_context);
    }

    private async string? ask_internal(int bot_id, string from_jid, string question, string? runtime_context) {
        string prefix = "bot_%d_ai".printf(bot_id);
        string? ai_type = registry.get_setting(prefix + "_type") ?? "openai";
        string? endpoint = registry.get_setting(prefix + "_endpoint");
        string? api_key = normalize_api_key(registry.get_secret_setting(prefix + "_key") ?? "");
        string? model = registry.get_setting(prefix + "_model");
        string? stored_system_prompt = registry.get_setting(prefix + "_system");
        string system_prompt = build_effective_system_prompt(stored_system_prompt, runtime_context);

        if (endpoint == null || model == null) {
            return "KI nicht konfiguriert.\n\n" + get_providers_help();
        }

        // Build conversation history
        string hkey = "%d:%s".printf(bot_id, from_jid);
        if (!histories.has_key(hkey)) {
            // BUG-13 fix: Evict oldest entries if we have too many unique conversations
            if (histories.size >= MAX_HISTORY_KEYS) {
                // Remove first key (oldest insertion)
                string? oldest_key = null;
                foreach (var key in histories.keys) {
                    oldest_key = key;
                    break;
                }
                if (oldest_key != null) histories.unset(oldest_key);
            }
            histories[hkey] = new ArrayList<ChatMessage>();
        }
        var history = histories[hkey];
        history.add(new ChatMessage("user", question));

        // Trim history
        while (history.size > MAX_HISTORY) {
            history.remove_at(0);
        }

        string? response = null;
        try {
            switch (ai_type) {
                case "ollama":
                    response = yield ask_ollama(endpoint, model, system_prompt, history);
                    break;
                case "claude":
                    response = yield ask_claude(endpoint, api_key, model, system_prompt, history);
                    break;
                case "gemini":
                    response = yield ask_gemini(endpoint, api_key, model, system_prompt, history);
                    break;
                case "openclaw":
                    response = yield ask_openclaw(endpoint, api_key, history);
                    break;
                case "xai":
                    response = yield ask_xai_responses(endpoint, api_key, model, system_prompt, history);
                    break;
                default: // openai and all compatible APIs
                    response = yield ask_openai(endpoint, api_key, model, system_prompt, history);
                    break;
            }
        } catch (Error e) {
            warning("AI: Request failed: %s", e.message);
            return "KI-Fehler: %s".printf(e.message);
        }

        if (response != null) {
            history.add(new ChatMessage("assistant", response));
            while (history.size > MAX_HISTORY) {
                history.remove_at(0);
            }
        }

        return response;
    }

    private string build_effective_system_prompt(string? stored_system_prompt, string? runtime_context) {
        string base_prompt = stored_system_prompt != null && stored_system_prompt.strip() != "" ?
            stored_system_prompt.strip() : default_system_prompt();
        if (runtime_context == null || runtime_context.strip() == "") return base_prompt;
        return base_prompt + "\n\nRuntime context:\n" + runtime_context.strip();
    }

    private string default_system_prompt() {
        return "You are a DinoX bot in an XMPP client. " +
            "Answer in the same language as the person who wrote to you. " +
            "Be concise, practical and friendly. " +
            "Do not introduce yourself as an AI unless someone asks directly. " +
            "Do not pretend to be human, a room admin or the bot owner. " +
            "If you are unsure, say so briefly and ask a useful follow-up question.";
    }

    // ──────────────────────────────────────────
    // Shared HTTP + JSON helpers (clone removal)
    // ──────────────────────────────────────────
    private async string? send_ai_http(Soup.Message request, string provider_name, out string? error_result) throws Error {
        error_result = null;
        var response = yield http.send_and_read_async(request, GLib.Priority.DEFAULT, null);
        uint status = request.get_status();
        string body_text = (string) response.get_data();

        if (status < 200 || status >= 300) {
            string detail = summarize_provider_error(body_text);
            if (detail != "") {
                warning("AI %s: HTTP %u: %s", provider_name, status, detail);
                error_result = "KI HTTP-Fehler %u: %s".printf(status, detail);
            } else {
                warning("AI %s: HTTP %u", provider_name, status);
                error_result = "KI HTTP-Fehler %u".printf(status);
            }
            return null;
        }

        return body_text;
    }

    private Json.Object parse_json_body(string body_text) throws Error {
        var parser = new Json.Parser();
        parser.load_from_data(body_text, -1);
        return parser.get_root().get_object();
    }

    private string summarize_provider_error(string body_text) {
        string text = body_text.strip();
        if (text == "") return "";

        try {
            var root = parse_json_body(text);
            if (root.has_member("error")) {
                var error_node = root.get_member("error");
                if (error_node.get_node_type() == Json.NodeType.OBJECT) {
                    var error_obj = root.get_object_member("error");
                    string message = "";
                    string code = "";
                    if (error_obj.has_member("message")) message = error_obj.get_string_member("message");
                    if (error_obj.has_member("code")) code = error_obj.get_member("code").get_string();
                    if (message != "" && code != "") return limit_error_text("%s (%s)".printf(message, code));
                    if (message != "") return limit_error_text(message);
                    if (code != "") return limit_error_text(code);
                } else if (error_node.get_node_type() == Json.NodeType.VALUE) {
                    string value = error_node.get_string();
                    if (value != "") return limit_error_text(value);
                }
            }

            foreach (string key in new string[] { "message", "detail", "description" }) {
                if (root.has_member(key) && root.get_member(key).get_node_type() == Json.NodeType.VALUE) {
                    string value = root.get_member(key).get_string();
                    if (value != "") return limit_error_text(value);
                }
            }
        } catch (Error e) {
            // Fall through to sanitized plain-text body.
        }

        return limit_error_text(text);
    }

    private string limit_error_text(string text) {
        string cleaned = text.replace("\r", " ").replace("\n", " ").strip();
        while (cleaned.contains("  ")) {
            cleaned = cleaned.replace("  ", " ");
        }
        cleaned = redact_error_identifiers(cleaned);
        return BotUtils.truncate_utf8(cleaned, 500);
    }

    private string redact_error_identifiers(string text) {
        string cleaned = text;
        try {
            var uuid_regex = new Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
            cleaned = uuid_regex.replace(cleaned, cleaned.length, 0, "[id]");
        } catch (Error e) {
            // Keep the provider message if the redaction regex is unavailable.
        }
        try {
            var key_regex = new Regex("(xai|sk|gsk|AIza)[A-Za-z0-9_\\-]{12,}");
            cleaned = key_regex.replace(cleaned, cleaned.length, 0, "[key]");
        } catch (Error e) {
            // Keep the provider message if the redaction regex is unavailable.
        }
        return cleaned;
    }

    private string normalize_api_key(string? api_key) {
        string key = (api_key ?? "").strip();
        if (key.ascii_down().has_prefix("bearer ")) {
            key = key.substring(7).strip();
        }
        while ((key.has_prefix("\"") && key.length > 1) || (key.has_prefix("'") && key.length > 1)) {
            key = key.substring(1).strip();
        }
        while ((key.has_suffix("\"") && key.length > 1) || (key.has_suffix("'") && key.length > 1)) {
            key = key.substring(0, key.length - 1).strip();
        }
        return key;
    }

    // ──────────────────────────────────────────
    // OpenAI-compatible API (OpenAI, Groq, Mistral, DeepSeek, Perplexity, vLLM, LM Studio)
    // ──────────────────────────────────────────
    private async string? ask_openai(string endpoint, string api_key, string model,
                                      string system_prompt, ArrayList<ChatMessage> history) throws Error {
        var sb = new StringBuilder();
        sb.append("{\"model\":\"%s\",\"messages\":[".printf(escape_json(model)));
        sb.append("{\"role\":\"system\",\"content\":\"%s\"}".printf(escape_json(system_prompt)));
        foreach (var msg in history) {
            sb.append(",{\"role\":\"%s\",\"content\":\"%s\"}".printf(
                escape_json(msg.role), escape_json(msg.content)));
        }
        sb.append("],\"max_tokens\":2048,\"temperature\":0.7}");

        var request = new Soup.Message("POST", endpoint);
        request.set_request_body_from_bytes("application/json", new Bytes(sb.str.data));
        if (api_key != null && api_key != "") {
            request.get_request_headers().append("Authorization", "Bearer " + api_key);
        }

        string? err;
        string? body_text = yield send_ai_http(request, "OpenAI", out err);
        if (body_text == null) return err;

        var root = parse_json_body(body_text);

        if (root.has_member("choices")) {
            var choices = root.get_array_member("choices");
            if (choices.get_length() > 0) {
                var choice = choices.get_object_element(0);
                var message_obj = choice.get_object_member("message");
                return message_obj.get_string_member("content");
            }
        }

        if (root.has_member("error")) {
            var err_obj = root.get_object_member("error");
            return "KI-Fehler: %s".printf(err_obj.get_string_member("message"));
        }

        return "KI: Unerwartete Antwort";
    }

    // ──────────────────────────────────────────
    // xAI Responses API (Grok)
    // ──────────────────────────────────────────
    private async string? ask_xai_responses(string endpoint, string api_key, string model,
                                            string system_prompt, ArrayList<ChatMessage> history) throws Error {
        var sb = new StringBuilder();
        sb.append("{\"model\":\"%s\",\"store\":false,\"input\":[".printf(escape_json(model)));
        sb.append("{\"role\":\"system\",\"content\":\"%s\"}".printf(escape_json(system_prompt)));
        foreach (var msg in history) {
            sb.append(",{\"role\":\"%s\",\"content\":\"%s\"}".printf(
                escape_json(msg.role), escape_json(msg.content)));
        }
        sb.append("]}");

        var request = new Soup.Message("POST", endpoint);
        request.set_request_body_from_bytes("application/json", new Bytes(sb.str.data));
        if (api_key != null && api_key != "") {
            request.get_request_headers().append("Authorization", "Bearer " + api_key);
        }

        string? err;
        string? body_text = yield send_ai_http(request, "xAI", out err);
        if (body_text == null) return err;

        var root = parse_json_body(body_text);

        if (root.has_member("output_text")) {
            return root.get_string_member("output_text");
        }

        if (root.has_member("output")) {
            var output = root.get_array_member("output");
            var text = new StringBuilder();
            for (uint i = 0; i < output.get_length(); i++) {
                var item = output.get_object_element(i);
                if (!item.has_member("content")) continue;
                var content = item.get_array_member("content");
                for (uint j = 0; j < content.get_length(); j++) {
                    var part = content.get_object_element(j);
                    if (part.has_member("type") &&
                            part.get_string_member("type") == "output_text" &&
                            part.has_member("text")) {
                        if (text.len > 0) text.append("\n");
                        text.append(part.get_string_member("text"));
                    }
                }
            }
            if (text.len > 0) return text.str;
        }

        if (root.has_member("error")) {
            var err_obj = root.get_object_member("error");
            if (err_obj.has_member("message")) {
                return "KI-Fehler: %s".printf(err_obj.get_string_member("message"));
            }
        }

        return "KI: Unerwartete xAI-Antwort";
    }

    // ──────────────────────────────────────────
    // Anthropic Claude API
    // ──────────────────────────────────────────
    private async string? ask_claude(string endpoint, string api_key, string model,
                                      string system_prompt, ArrayList<ChatMessage> history) throws Error {
        var sb = new StringBuilder();
        sb.append("{\"model\":\"%s\",\"max_tokens\":2048,\"system\":\"%s\",\"messages\":[".printf(
            escape_json(model), escape_json(system_prompt)));

        bool first = true;
        foreach (var msg in history) {
            if (!first) sb.append(",");
            sb.append("{\"role\":\"%s\",\"content\":\"%s\"}".printf(
                escape_json(msg.role), escape_json(msg.content)));
            first = false;
        }
        sb.append("]}");

        var request = new Soup.Message("POST", endpoint);
        request.set_request_body_from_bytes("application/json", new Bytes(sb.str.data));
        request.get_request_headers().append("x-api-key", api_key);
        request.get_request_headers().append("anthropic-version", "2023-06-01");
        request.get_request_headers().append("Content-Type", "application/json");

        string? err;
        string? body_text = yield send_ai_http(request, "Claude", out err);
        if (body_text == null) return err;

        var root = parse_json_body(body_text);

        // Claude response: { "content": [{"type": "text", "text": "..."}] }
        if (root.has_member("content")) {
            var content = root.get_array_member("content");
            if (content.get_length() > 0) {
                var block = content.get_object_element(0);
                if (block.has_member("text")) {
                    return block.get_string_member("text");
                }
            }
        }

        if (root.has_member("error")) {
            var err_obj = root.get_object_member("error");
            return "Claude-Fehler: %s".printf(err_obj.get_string_member("message"));
        }

        return "KI: Unerwartete Claude-Antwort";
    }

    // ──────────────────────────────────────────
    // Google Gemini API
    // ──────────────────────────────────────────
    private async string? ask_gemini(string endpoint, string api_key, string model,
                                      string system_prompt, ArrayList<ChatMessage> history) throws Error {
        // Gemini URL: {endpoint}/models/{model}:generateContent
        string base_url = endpoint;
        if (base_url.has_suffix("/")) base_url = base_url.substring(0, base_url.length - 1);
        string url = "%s/models/%s:generateContent".printf(base_url, model);

        var sb = new StringBuilder();
        sb.append("{");

        // System instruction
        sb.append("\"systemInstruction\":{\"parts\":[{\"text\":\"%s\"}]},".printf(escape_json(system_prompt)));

        // Contents (conversation history)
        sb.append("\"contents\":[");
        bool first = true;
        foreach (var msg in history) {
            if (!first) sb.append(",");
            // Gemini uses "user" and "model" (not "assistant")
            string role = msg.role == "assistant" ? "model" : "user";
            sb.append("{\"role\":\"%s\",\"parts\":[{\"text\":\"%s\"}]}".printf(
                role, escape_json(msg.content)));
            first = false;
        }
        sb.append("],");

        // Generation config
        sb.append("\"generationConfig\":{\"temperature\":0.7,\"maxOutputTokens\":2048}");
        sb.append("}");

        var request = new Soup.Message("POST", url);
        request.set_request_body_from_bytes("application/json", new Bytes(sb.str.data));
        if (api_key != null && api_key != "") {
            request.get_request_headers().append("x-goog-api-key", api_key);
        }

        string? err;
        string? body_text = yield send_ai_http(request, "Gemini", out err);
        if (body_text == null) return err;

        var root = parse_json_body(body_text);

        // Gemini response: { "candidates": [{"content": {"parts": [{"text": "..."}]}}] }
        if (root.has_member("candidates")) {
            var candidates = root.get_array_member("candidates");
            if (candidates.get_length() > 0) {
                var candidate = candidates.get_object_element(0);
                if (candidate.has_member("content")) {
                    var content = candidate.get_object_member("content");
                    if (content.has_member("parts")) {
                        var parts = content.get_array_member("parts");
                        if (parts.get_length() > 0) {
                            var part = parts.get_object_element(0);
                            if (part.has_member("text")) {
                                return part.get_string_member("text");
                            }
                        }
                    }
                }
            }
        }

        if (root.has_member("error")) {
            var err_obj = root.get_object_member("error");
            return "Gemini-Fehler: %s".printf(err_obj.get_string_member("message"));
        }

        return "KI: Unerwartete Gemini-Antwort";
    }

    // ──────────────────────────────────────────
    // Ollama native API (lokal)
    // ──────────────────────────────────────────
    private async string? ask_ollama(string endpoint, string model,
                                      string system_prompt, ArrayList<ChatMessage> history) throws Error {
        string url = endpoint;
        if (!url.has_suffix("/api/chat")) {
            if (url.has_suffix("/")) url = url.substring(0, url.length - 1);
            url = url + "/api/chat";
        }

        var sb = new StringBuilder();
        sb.append("{\"model\":\"%s\",\"stream\":false,\"messages\":[".printf(escape_json(model)));
        sb.append("{\"role\":\"system\",\"content\":\"%s\"}".printf(escape_json(system_prompt)));
        foreach (var msg in history) {
            sb.append(",{\"role\":\"%s\",\"content\":\"%s\"}".printf(
                escape_json(msg.role), escape_json(msg.content)));
        }
        sb.append("]}");

        var request = new Soup.Message("POST", url);
        request.set_request_body_from_bytes("application/json", new Bytes(sb.str.data));

        string? err;
        string? body_text = yield send_ai_http(request, "Ollama", out err);
        if (body_text == null) return err;

        var root = parse_json_body(body_text);

        if (root.has_member("message")) {
            var msg_obj = root.get_object_member("message");
            return msg_obj.get_string_member("content");
        }

        return "KI: Unerwartete Ollama-Antwort";
    }

    // ──────────────────────────────────────────
    // OpenClaw Agent API (autonomous orchestrator)
    // ──────────────────────────────────────────
    private async string? ask_openclaw(string endpoint, string api_key,
                                       ArrayList<ChatMessage> history) throws Error {
        // OpenClaw uses a simple {"message": "..."} format
        // Only send the last user message (agent manages its own context)
        string last_msg = "";
        for (int i = history.size - 1; i >= 0; i--) {
            if (history[i].role == "user") {
                last_msg = history[i].content;
                break;
            }
        }

        var sb = new StringBuilder();
        sb.append("{\"message\":\"%s\"}".printf(escape_json(last_msg)));

        var request = new Soup.Message("POST", endpoint);
        request.set_request_body_from_bytes("application/json", new Bytes(sb.str.data));
        if (api_key != null && api_key != "") {
            request.get_request_headers().append("Authorization", "Bearer " + api_key);
        }

        string? err;
        string? body_text = yield send_ai_http(request, "OpenClaw", out err);
        if (body_text == null) return err;

        if (body_text.strip() == "") {
            return "OpenClaw: Empty response";
        }

        // Try JSON response first
        try {
            var parser = new Json.Parser();
            parser.load_from_data(body_text, -1);
            var root = parser.get_root();
            if (root != null && root.get_node_type() == Json.NodeType.OBJECT) {
                var obj = root.get_object();
                // Try common response fields
                foreach (string field in new string[]{"response", "text", "message", "content", "reply", "result"}) {
                    if (obj.has_member(field)) {
                        var node = obj.get_member(field);
                        if (node.get_node_type() == Json.NodeType.VALUE) {
                            return node.get_string();
                        }
                    }
                }
                // If JSON but no known field, return the whole body
                return body_text.strip();
            }
        } catch (Error e) {
            // Not JSON - treat as plain text
        }

        return body_text.strip();
    }

    public void shutdown() {
        http.abort();
    }

    // Cleanup all settings for a bot
    public void cleanup(int bot_id) {
        string prefix = "bot_%d_ai".printf(bot_id);
        registry.delete_setting(prefix + "_enabled");
        registry.delete_setting(prefix + "_type");
        registry.delete_setting(prefix + "_endpoint");
        registry.delete_setting(prefix + "_key");
        registry.delete_setting(prefix + "_model");
        registry.delete_setting(prefix + "_system");
        clear_history(bot_id, "all");
    }

    // Delegate to shared BotUtils (clone removal)
    private static string escape_json(string s) {
        return BotUtils.escape_json(s);
    }
}

} // namespace
