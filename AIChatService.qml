import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "./AIApiAdapters.js" as Adapters

// Multi-provider chat backend.
//  - "pollinations": keyless GET {baseUrl}/{prompt}?model=...  (plain text reply)
//  - openai / anthropic / gemini / ollama / custom (OpenAI-compatible): streamed via curl
Item {
    id: root

    property string pluginId: "aiChat"

    readonly property var providerIds: ["pollinations", "openai", "anthropic", "gemini", "ollama", "custom"]

    readonly property string baseDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/DankMaterialShell/plugins/" + pluginId)
    readonly property string sessionPath: baseDir + "/session.json"
    property bool sessionLoaded: false
    property int maxStoredMessages: 50
    property int maxPromptChars: 6000   // Pollinations only: the prompt lives in the URL

    property ListModel messagesModel: ListModel {}
    property int messageCount: messagesModel.count
    property bool isStreaming: false    // a request is in flight
    property bool isOnline: false
    property string activeStreamId: ""
    property real streamStartedAtMs: 0
    property string lastUserText: ""
    property int lastHttpStatus: 0

    // Settings (active provider's profile is mirrored into these)
    property var providers: ({})
    property string provider: "pollinations"
    property string baseUrl: "https://text.pollinations.ai"
    property string model: "openai"
    property string apiKey: ""
    property string apiKeyEnvVar: ""
    property string sessionApiKey: ""
    property real temperature: 0.7
    property int maxTokens: 4096
    property string systemPrompt: "You are a helpful assistant inside a desktop shell. Be concise and use markdown when it helps."
    property bool includeHistory: true
    property bool privateMode: true
    property bool useMonospace: false

    readonly property bool needsKey: provider !== "pollinations" && provider !== "ollama" && provider !== "custom"
    readonly property bool hasCredentials: !needsKey || resolveApiKey().length > 0

    // Model discovery / connection test
    property var availableModels: []
    property bool modelsLoading: false
    property string modelsError: ""
    property string modelFetchOutput: ""
    property bool connectionTested: false
    readonly property var selectableModels: (availableModels || []).slice()
    readonly property bool currentModelDiscovered: !!model && (availableModels || []).indexOf(model) >= 0

    Component.onCompleted: {
        loadSettings();
        mkdirProcess.running = true;
    }

    // ---- provider profiles -------------------------------------------------

    function defaultsForProvider(id) {
        switch (id) {
        case "openai":
            return { baseUrl: "https://api.openai.com", model: "gpt-5.2" };
        case "anthropic":
            return { baseUrl: "https://api.anthropic.com", model: "claude-sonnet-4-5" };
        case "gemini":
            return { baseUrl: "https://generativelanguage.googleapis.com", model: "gemini-2.5-flash" };
        case "ollama":
            return { baseUrl: "http://localhost:11434", model: "" };
        case "custom":
            return { baseUrl: "https://openrouter.ai/api/v1", model: "" };
        default:
            return { baseUrl: "https://text.pollinations.ai", model: "openai" };
        }
    }

    function normalizedProfile(id, raw) {
        const d = defaultsForProvider(id);
        const p = raw || {};
        return {
            baseUrl: String(p.baseUrl || d.baseUrl).trim(),
            model: String(p.model !== undefined && p.model !== null ? p.model : d.model).trim(),
            apiKey: String(p.apiKey || "").trim(),
            apiKeyEnvVar: String(p.apiKeyEnvVar || "").trim()
        };
    }

    function loadSettings() {
        const load = (k, d) => PluginService.loadPluginData(pluginId, k, d);
        const sel = String(load("provider", "pollinations")).trim();
        const id = providerIds.indexOf(sel) >= 0 ? sel : "pollinations";
        const raw = load("providers", null);
        const next = {};
        for (let i = 0; i < providerIds.length; i++)
            next[providerIds[i]] = normalizedProfile(providerIds[i], raw && raw[providerIds[i]]);
        providers = next;

        const active = next[id];
        const changed = id !== provider || active.baseUrl !== baseUrl;
        provider = id;
        baseUrl = active.baseUrl.endsWith("/") ? active.baseUrl.slice(0, -1) : active.baseUrl;
        model = active.model;
        apiKey = active.apiKey;
        apiKeyEnvVar = active.apiKeyEnvVar;

        systemPrompt = String(load("systemPrompt", systemPrompt));
        includeHistory = load("includeHistory", true) !== false;
        privateMode = load("privateMode", true) !== false;
        temperature = Number(load("temperature", 0.7));
        maxTokens = Number(load("maxTokens", 4096));
        useMonospace = load("useMonospace", false) === true;

        if (changed) {
            availableModels = [];
            modelsError = "";
            connectionTested = false;
        }
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pId) {
            if (pId === root.pluginId)
                root.loadSettings();
        }
    }

    function resolveApiKey() {
        if (provider === "pollinations") {
            const envName = (apiKeyEnvVar || "").trim();
            return apiKey || (envName ? (Quickshell.env(envName) || "") : "") || Quickshell.env("POLLINATIONS_TOKEN") || "";
        }
        const customEnvName = (apiKeyEnvVar || "").trim();
        const customEnv = customEnvName ? (Quickshell.env(customEnvName) || "") : "";
        let common = "";
        switch (provider) {
        case "anthropic": common = Quickshell.env("ANTHROPIC_API_KEY") || ""; break;
        case "gemini": common = Quickshell.env("GEMINI_API_KEY") || ""; break;
        case "openai": common = Quickshell.env("OPENAI_API_KEY") || ""; break;
        default: break;
        }
        return sessionApiKey || apiKey || customEnv || common || "";
    }

    function setCurrentModel(nextModel) {
        const trimmed = String(nextModel || "").trim();
        if (!trimmed || trimmed === model)
            return;
        model = trimmed;
        const next = Object.assign({}, providers || {});
        const active = Object.assign({}, next[provider] || normalizedProfile(provider, null));
        active.model = trimmed;
        next[provider] = active;
        providers = next;
        PluginService.savePluginData(pluginId, "providers", next);
    }

    // ---- persistence -------------------------------------------------------

    Process {
        id: mkdirProcess
        command: ["mkdir", "-p", root.baseDir]
        running: false
        onExited: code => {
            if (code === 0)
                sessionFile.path = root.sessionPath;
        }
    }

    FileView {
        id: sessionFile
        path: ""
        blockWrites: true
        atomicWrites: true

        onLoaded: {
            try {
                const data = JSON.parse(text());
                root.loadMessages(Array.isArray(data.messages) ? data.messages : []);
            } catch (e) {
                root.loadMessages([]);
            }
            root.sessionLoaded = true;
        }
        onLoadFailed: root.sessionLoaded = true
    }

    function loadMessages(msgs) {
        messagesModel.clear();
        for (let i = 0; i < msgs.length; i++) {
            const m = msgs[i];
            if (!m || !m.role || !m.content)
                continue;
            messagesModel.append({
                role: m.role,
                content: m.content,
                timestamp: m.timestamp || Date.now(),
                id: m.id || (m.role + "-" + Date.now() + "-" + i),
                status: m.status || "ok"
            });
        }
        lastUserText = findLastUserText();
    }

    function saveSession() {
        if (!sessionLoaded || !sessionFile.path)
            return;
        const msgs = [];
        for (let i = 0; i < messagesModel.count; i++) {
            const m = messagesModel.get(i);
            if ((m.role === "user" || m.role === "assistant") && m.status === "ok")
                msgs.push({ role: m.role, content: m.content, timestamp: m.timestamp, id: m.id, status: m.status });
        }
        const capped = msgs.length > maxStoredMessages ? msgs.slice(msgs.length - maxStoredMessages) : msgs;
        sessionFile.setText(JSON.stringify({ version: 1, messages: capped }, null, 2));
    }

    function clearHistory(saveNow) {
        chatFetcher.running = false;
        messagesModel.clear();
        isStreaming = false;
        activeStreamId = "";
        streamStartedAtMs = 0;
        isOnline = false;
        lastUserText = "";
        if (saveNow)
            saveSession();
    }

    // ---- chatting ----------------------------------------------------------

    function findIndexById(msgId) {
        for (let i = 0; i < messagesModel.count; i++) {
            if (messagesModel.get(i).id === msgId)
                return i;
        }
        return -1;
    }

    function findLastUserText() {
        for (let i = messagesModel.count - 1; i >= 0; i--) {
            const m = messagesModel.get(i);
            if (m.role === "user" && m.status === "ok")
                return m.content;
        }
        return "";
    }

    function sendMessage(text) {
        if (!text || text.trim().length === 0)
            return;
        if (isStreaming && chatFetcher.running) {
            markError(activeStreamId, "Please wait until the current response finishes.");
            return;
        }
        startRequest(text.trim(), true);
    }

    function retryLast() {
        if (isStreaming && chatFetcher.running)
            return;
        const text = lastUserText || findLastUserText();
        if (text)
            startRequest(text, false);
    }

    function regenerateFromMessageId(messageId) {
        if (!messageId || (isStreaming && chatFetcher.running))
            return;
        const idx = findIndexById(messageId);
        if (idx < 0 || messagesModel.get(idx).role !== "assistant") {
            retryLast();
            return;
        }
        let userText = "";
        for (let i = idx - 1; i >= 0; i--) {
            const m = messagesModel.get(i);
            if (m.role === "user" && m.status === "ok" && (m.content || "").trim().length > 0) {
                userText = m.content;
                break;
            }
        }
        if (!userText) {
            retryLast();
            return;
        }
        for (let i = messagesModel.count - 1; i >= idx; i--)
            messagesModel.remove(i, 1);
        lastUserText = userText;
        startRequest(userText, false);
    }

    // Completed turns (oldest first); call before appending the new user message / placeholder.
    function priorTurns() {
        const turns = [];
        for (let i = 0; i < messagesModel.count; i++) {
            const m = messagesModel.get(i);
            if (m.status !== "ok" || (m.role !== "user" && m.role !== "assistant"))
                continue;
            if (!m.content || m.content.trim().length === 0)
                continue;
            turns.push({ role: m.role, content: m.content });
        }
        return turns;
    }

    function startRequest(text, addUser) {
        const now = Date.now();
        const streamId = "assistant-" + now;
        const history = priorTurns();

        if (addUser) {
            messagesModel.append({ role: "user", content: text, timestamp: now, id: "user-" + now, status: "ok" });
            lastUserText = text;
        }
        // On retry/regenerate the user message is already in history; drop it so it isn't duplicated.
        if (!addUser && history.length > 0 && history[history.length - 1].role === "user"
                && history[history.length - 1].content === text)
            history.pop();

        messagesModel.append({ role: "assistant", content: "", timestamp: now + 1, id: streamId, status: "streaming" });
        activeStreamId = streamId;
        isStreaming = true;
        streamStartedAtMs = now;
        lastHttpStatus = 0;
        streamBuffer = "";
        streamCollector.lastLen = 0;

        let cmd = null;
        if (provider === "pollinations") {
            cmd = pollinationsCommand(text, history);
        } else {
            if (needsKey && !resolveApiKey()) {
                markError(streamId, "No API key set for " + provider + ". Open settings to add one.");
                return;
            }
            cmd = Adapters.buildCurlCommand(provider, buildPayload(text, history), resolveApiKey());
        }
        if (!cmd) {
            markError(streamId, "Provider is not configured.");
            return;
        }
        chatFetcher.command = cmd;
        chatFetcher.running = true;
        saveSession();
    }

    function cancel() {
        if (!isStreaming)
            return;
        chatFetcher.running = false;
        markError(activeStreamId, "Cancelled");
    }

    function markError(streamId, message) {
        const idx = findIndexById(streamId);
        if (idx >= 0) {
            messagesModel.setProperty(idx, "content", message);
            messagesModel.setProperty(idx, "status", "error");
        }
        isStreaming = false;
        activeStreamId = "";
        streamStartedAtMs = 0;
        saveSession();
    }

    function updateStreamContent(streamId, delta) {
        if (!delta)
            return;
        const idx = findIndexById(streamId);
        if (idx >= 0) {
            messagesModel.setProperty(idx, "content", (messagesModel.get(idx).content || "") + delta);
            messagesModel.setProperty(idx, "status", "streaming");
        }
    }

    function getMessageContentById(msgId) {
        const idx = findIndexById(msgId);
        return idx >= 0 ? (messagesModel.get(idx).content || "") : "";
    }

    function finalizeStream(streamId) {
        const idx = findIndexById(streamId);
        if (idx >= 0)
            messagesModel.setProperty(idx, "status", "ok");
        isStreaming = false;
        activeStreamId = "";
        streamStartedAtMs = 0;
        isOnline = true;
        saveSession();
    }

    // ---- Pollinations (GET, plain text) -------------------------------------

    function pollinationsPrompt(latestText, history) {
        if (!includeHistory || history.length === 0)
            return latestText;
        const latest = "User: " + latestText;
        const kept = [];
        let used = latest.length;
        for (let i = history.length - 1; i >= 0; i--) {
            const line = (history[i].role === "user" ? "User: " : "Assistant: ") + history[i].content;
            if (used + line.length + 2 > maxPromptChars)
                break;
            kept.unshift(line);
            used += line.length + 2;
        }
        if (kept.length === 0)
            return latestText;
        return "Conversation so far:\n" + kept.join("\n\n") + "\n\n" + latest
            + "\n\nReply to the latest user message only, as the assistant, without a role prefix.";
    }

    function pollinationsCommand(text, history) {
        const params = [];
        if (model)
            params.push("model=" + encodeURIComponent(model));
        if (systemPrompt && systemPrompt.trim().length > 0)
            params.push("system=" + encodeURIComponent(systemPrompt.trim()));
        params.push("seed=" + Math.floor(Math.random() * 1000000));
        if (privateMode)
            params.push("private=true");
        const url = Adapters.normalizeBaseUrl(baseUrl || "https://text.pollinations.ai")
            + "/" + encodeURIComponent(pollinationsPrompt(text, history)) + "?" + params.join("&");
        const cmd = ["curl", "-sS", "-L", "--connect-timeout", "8", "--max-time", "90",
            "-w", "\nDMS_STATUS:%{http_code}\n"];
        const key = resolveApiKey();
        if (key)
            cmd.push("-H", "Authorization: Bearer " + key);
        cmd.push(url);
        return cmd;
    }

    function handlePlainTextResponse(fullText) {
        if (!isStreaming)
            return;
        const marker = "\nDMS_STATUS:";
        const cut = fullText.lastIndexOf(marker);
        const body = (cut >= 0 ? fullText.substring(0, cut) : fullText).trim();
        const m = fullText.match(/DMS_STATUS:(\d+)/);
        lastHttpStatus = m ? parseInt(m[1]) : 0;

        if (lastHttpStatus === 0 || lastHttpStatus >= 400) {
            isOnline = false;
            if (lastHttpStatus === 0)
                markError(activeStreamId, "No response from Pollinations. Check your connection.");
            else
                markError(activeStreamId, "Request failed (HTTP " + lastHttpStatus + ")" + (body ? ": " + body.slice(0, 400) : ""));
            return;
        }
        if (!body) {
            markError(activeStreamId, "Pollinations returned an empty reply.");
            return;
        }
        const idx = findIndexById(activeStreamId);
        if (idx >= 0)
            messagesModel.setProperty(idx, "content", body);
        finalizeStream(activeStreamId);
    }

    // ---- API providers (streamed) -------------------------------------------

    function buildPayload(latestText, history) {
        const msgs = [];
        if (includeHistory) {
            // Keep the last 20 turns, alternating strictly so every provider accepts it.
            const recent = history.slice(Math.max(0, history.length - 40));
            let expect = "user";
            let start = 0;
            while (start < recent.length && recent[start].role !== "user")
                start++;
            for (let i = start; i < recent.length; i++) {
                if (recent[i].role !== expect)
                    continue;
                msgs.push({ role: recent[i].role, content: recent[i].content });
                expect = expect === "user" ? "assistant" : "user";
            }
            if (msgs.length > 0 && msgs[msgs.length - 1].role === "user")
                msgs.pop();
        }
        msgs.push({ role: "user", content: latestText });
        const payload = {
            provider: provider,
            baseUrl: baseUrl,
            model: model,
            temperature: temperature,
            max_tokens: maxTokens,
            messages: msgs,
            stream: true,
            timeout: 60
        };
        if (systemPrompt && systemPrompt.trim().length > 0)
            payload.system = systemPrompt.trim();
        return payload;
    }

    property string streamBuffer: ""

    function handleStreamChunk(chunk) {
        const buffer = streamBuffer + chunk;
        const parts = buffer.split(/\r?\n/);
        if (buffer.length > 0 && !buffer.endsWith("\n") && !buffer.endsWith("\r"))
            streamBuffer = parts.pop();
        else
            streamBuffer = "";

        for (let i = 0; i < parts.length; i++) {
            const line = parts[i].trim();
            if (!line || line.startsWith("DMS_STATUS:"))
                continue;
            if (provider === "ollama") {
                parseProviderDelta(line);
                continue;
            }
            if (line === "data: [DONE]" || line === "data:[DONE]") {
                finalizeStream(activeStreamId);
                continue;
            }
            if (line.startsWith("data:"))
                parseProviderDelta(line.substring(5).trim());
        }
    }

    function parseProviderDelta(jsonText) {
        try {
            const data = JSON.parse(jsonText);
            if (provider === "anthropic") {
                const delta = data.delta?.text || "";
                if (delta)
                    updateStreamContent(activeStreamId, delta);
                if (data.type === "message_stop" || data.delta?.stop_reason)
                    finalizeStream(activeStreamId);
            } else if (provider === "ollama") {
                const delta = data.message?.content || "";
                if (delta)
                    updateStreamContent(activeStreamId, delta);
                if (data.done)
                    finalizeStream(activeStreamId);
            } else if (provider === "gemini") {
                const chunks = Array.isArray(data) ? data : [data];
                chunks.forEach(chunk => {
                    const cand = chunk.candidates?.[0];
                    (cand?.content?.parts || []).forEach(p => {
                        if (p.text)
                            updateStreamContent(activeStreamId, p.text);
                    });
                    const fr = cand?.finishReason;
                    if (fr && fr !== "FINISH_REASON_UNSPECIFIED")
                        finalizeStream(activeStreamId);
                });
            } else { // openai, custom
                const d = data.choices?.[0]?.delta?.content;
                if (Array.isArray(d)) {
                    d.forEach(x => {
                        if (x.text)
                            updateStreamContent(activeStreamId, x.text);
                    });
                } else if (typeof d === "string") {
                    updateStreamContent(activeStreamId, d);
                }
                if (data.choices?.[0]?.finish_reason)
                    finalizeStream(activeStreamId);
            }
        } catch (e) {
            // ignore malformed chunks
        }
    }

    function extractNonStreamingText(bodyText) {
        if (provider === "ollama") {
            let out = "";
            bodyText.split(/\r?\n/).forEach(line => {
                try {
                    const c = JSON.parse(line.trim());
                    if (c.message?.content)
                        out += c.message.content;
                } catch (e) {}
            });
            return out;
        }
        try {
            const data = JSON.parse(bodyText);
            if (provider === "anthropic") {
                return Array.isArray(data.content) ? data.content.map(c => c?.text || "").join("") : (data.text || "");
            }
            if (provider === "gemini") {
                const chunks = Array.isArray(data) ? data : [data];
                let out = "";
                chunks.forEach(c => (c.candidates?.[0]?.content?.parts || []).forEach(p => { if (p?.text) out += p.text; }));
                return out;
            }
            const msg = data.choices?.[0]?.message?.content;
            if (typeof msg === "string")
                return msg;
            if (typeof data.choices?.[0]?.text === "string")
                return data.choices[0].text;
        } catch (e) {}
        return "";
    }

    function errorFromBody(bodyText) {
        try {
            const d = JSON.parse(bodyText);
            const e = d.error || (Array.isArray(d) ? d[0]?.error : null);
            if (typeof e === "string")
                return e;
            if (e && e.message)
                return e.message;
            if (d.message)
                return d.message;
        } catch (err) {}
        return bodyText.slice(0, 400);
    }

    function handleApiFinished(text) {
        const m = text.match(/DMS_STATUS:(\d+)/);
        if (m)
            lastHttpStatus = parseInt(m[1]);
        const cut = text.lastIndexOf("\nDMS_STATUS:");
        const body = (cut >= 0 ? text.substring(0, cut) : text).trim();

        if (!isStreaming)
            return;

        if (lastHttpStatus >= 400) {
            isOnline = false;
            const detail = errorFromBody(body);
            markError(activeStreamId, "Request failed (HTTP " + lastHttpStatus + ")" + (detail ? ": " + detail : ""));
            return;
        }
        const existing = getMessageContentById(activeStreamId);
        if (!existing && body) {
            const parsed = extractNonStreamingText(body);
            if (parsed) {
                const idx = findIndexById(activeStreamId);
                if (idx >= 0)
                    messagesModel.setProperty(idx, "content", parsed);
            }
        }
        if (!getMessageContentById(activeStreamId)) {
            markError(activeStreamId, lastHttpStatus === 0 ? "No response from the server. Check the base URL and connection." : "The provider returned an empty reply.");
            return;
        }
        finalizeStream(activeStreamId);
    }

    Process {
        id: chatFetcher
        running: false

        stdout: StdioCollector {
            id: streamCollector
            property int lastLen: 0

            onTextChanged: {
                if (root.provider === "pollinations")
                    return;
                const fresh = text.substring(lastLen);
                lastLen = text.length;
                root.handleStreamChunk(fresh);
            }

            onStreamFinished: {
                if (root.provider === "pollinations")
                    root.handlePlainTextResponse(text);
                else
                    root.handleApiFinished(text);
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0 && root.isStreaming && root.activeStreamId !== "")
                root.markError(root.activeStreamId, "Request failed (curl exit " + exitCode + ")");
        }
    }

    // ---- model discovery & connection test ---------------------------------

    function refreshAvailableModels(force) {
        if (modelsLoading && !force)
            return;
        if (needsKey && !resolveApiKey()) {
            availableModels = [];
            modelsLoading = false;
            modelsError = "";
            connectionTested = false;
            return;
        }
        modelsLoading = true;
        modelsError = "";
        connectionTested = false;
        modelFetchOutput = "";
        modelFetcher.running = false;

        const base = Adapters.normalizeBaseUrl(baseUrl || defaultsForProvider(provider).baseUrl);
        if (provider === "pollinations") {
            modelFetcher.command = ["curl", "-sS", "-L", "--connect-timeout", "5", "--max-time", "15",
                "-w", "\nDMS_STATUS:%{http_code}\n", base + "/models"];
        } else {
            modelFetcher.command = Adapters.buildModelsCurlCommand(provider, base, resolveApiKey());
        }
        modelFetchProvider = provider;
        modelFetcher.running = true;
    }

    property string modelFetchProvider: "pollinations"

    function parsePollinationsModels(body) {
        const parsed = JSON.parse(body || "[]");
        const raw = Array.isArray(parsed) ? parsed : (Array.isArray(parsed.data) ? parsed.data : (Array.isArray(parsed.models) ? parsed.models : []));
        const ids = [];
        const seen = {};
        raw.forEach(item => {
            const id = typeof item === "string" ? item : String((item && (item.name || item.id)) || "");
            if (id && !seen[id]) {
                seen[id] = true;
                ids.push(id);
            }
        });
        ids.sort();
        return ids;
    }

    function modelDiscoveryStatusText() {
        if (modelsLoading)
            return "Testing connection…";
        if (modelsError)
            return modelsError;
        if (connectionTested)
            return "Connection OK. %1 model(s) available.".arg(availableModels.length);
        if (needsKey && !resolveApiKey())
            return "Enter an API key, then test the connection.";
        return "Not tested yet. You can still type a model name.";
    }

    Process {
        id: modelFetcher
        running: false

        stdout: StdioCollector {
            onStreamFinished: root.modelFetchOutput = text
        }

        onExited: exitCode => {
            root.modelsLoading = false;
            if (root.modelFetchProvider !== root.provider)
                return;   // provider changed while testing
            if (exitCode !== 0) {
                root.availableModels = [];
                root.modelsError = "Connection failed. Check the base URL and your network.";
                return;
            }
            const out = root.modelFetchOutput;
            const m = out.match(/\nDMS_STATUS:(\d{3})\s*$/);
            const status = m ? Number(m[1]) : 0;
            const body = m ? out.substring(0, m.index) : out;
            if (status < 200 || status >= 300) {
                root.availableModels = [];
                root.modelsError = (status === 401 || status === 403)
                    ? "Authentication failed: check the API key."
                    : "Connection test failed (HTTP %1).".arg(status || "unknown");
                return;
            }
            try {
                let ids;
                if (root.provider === "pollinations")
                    ids = root.parsePollinationsModels(body);
                else
                    ids = Adapters.parseModelsResponse(root.provider, body).map(x => x.id);
                root.availableModels = ids;
                root.connectionTested = true;
                root.modelsError = "";
            } catch (e) {
                root.availableModels = [];
                root.modelsError = "Connected, but the model list could not be parsed. You can still type a model name.";
            }
        }
    }
}
