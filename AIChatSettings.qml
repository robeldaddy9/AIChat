import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import qs.Services

Item {
    id: root

    implicitWidth: 480
    implicitHeight: 600

    property bool isVisible: false
    signal closeRequested

    required property var aiService
    property string pluginId: "aiChat"

    readonly property var providerIds: ["pollinations", "openai", "anthropic", "gemini", "ollama", "custom"]
    property var providers: ({})
    property string provider: "pollinations"
    property string baseUrl: ""
    property string model: ""
    property string apiKey: ""
    property string apiKeyEnvVar: ""
    property string systemPrompt: ""
    property real temperature: 0.7
    property int maxTokens: 4096
    property bool includeHistory: true
    property bool privateMode: true
    property bool useMonospace: false
    property real panelWidth: 480

    readonly property bool keyRequired: provider !== "pollinations" && provider !== "ollama" && provider !== "custom"

    function save(key, value) {
        PluginService.savePluginData(pluginId, key, value)
        root[key] = value
    }

    function saveProviders(next) {
        providers = next
        PluginService.savePluginData(pluginId, "providers", next)
    }

    function saveActiveField(key, value) {
        root[key] = value
        const next = Object.assign({}, providers)
        const cur = Object.assign({}, next[provider] || aiService.normalizedProfile(provider, null))
        cur[key] = value
        next[provider] = cur
        saveProviders(next)
    }

    function setProvider(id) {
        if (id === provider)
            return
        save("provider", id)
        load()
        Qt.callLater(() => aiService.refreshAvailableModels(true))
    }

    function load() {
        const get = (k, d) => PluginService.loadPluginData(pluginId, k, d)
        const sel = String(get("provider", "pollinations"))
        provider = providerIds.indexOf(sel) >= 0 ? sel : "pollinations"
        const raw = get("providers", null)
        const next = {}
        for (let i = 0; i < providerIds.length; i++)
            next[providerIds[i]] = aiService.normalizedProfile(providerIds[i], raw && raw[providerIds[i]])
        providers = next
        const a = next[provider]
        baseUrl = a.baseUrl
        model = a.model
        apiKey = a.apiKey
        apiKeyEnvVar = a.apiKeyEnvVar
        systemPrompt = String(get("systemPrompt", aiService.systemPrompt))
        temperature = Number(get("temperature", 0.7))
        maxTokens = Number(get("maxTokens", 4096))
        includeHistory = get("includeHistory", true) !== false
        privateMode = get("privateMode", true) !== false
        useMonospace = get("useMonospace", false) === true
        panelWidth = Number(get("panelWidth", 480))
    }

    function focusApiKeyField() {
        if (apiKeyField)
            apiKeyField.forceActiveFocus()
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pId) {
            if (pId === pluginId)
                load()
        }
    }

    Component.onCompleted: load()
    onIsVisibleChanged: if (isVisible) load()

    visible: isVisible

    component Card: Rectangle {
        default property alias content: inner.data
        width: parent.width
        height: inner.height + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
        border.color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.08)
        border.width: 1

        Column {
            id: inner
            width: parent.width - Theme.spacingL * 2
            anchors.centerIn: parent
            spacing: Theme.spacingS
        }
    }

    component Hint: StyledText {
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        width: parent.width
    }

    component ToggleRow: Item {
        id: tr
        property string title: ""
        property string description: ""
        property alias checked: tg.checked
        signal toggled(bool value)
        width: parent.width
        height: Math.max(tg.height, txt.height)

        Column {
            id: txt
            anchors.left: parent.left
            anchors.right: tg.left
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            StyledText {
                text: tr.title
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
            }
            StyledText {
                text: tr.description
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
            }
        }

        DankToggle {
            id: tg
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: c => tr.toggled(c)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.98)
        radius: Theme.cornerRadius
        border.color: Theme.surfaceVariantAlpha
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingL

                StyledText {
                    text: I18n.tr("AI Chat Settings")
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceText
                    font.weight: Font.Medium
                    Layout.alignment: Qt.AlignVCenter
                }

                Item { Layout.fillWidth: true }

                DankButton {
                    text: I18n.tr("Close")
                    iconName: "close"
                    onClicked: closeRequested()
                }
            }

            DankFlickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: settingsColumn.implicitHeight + Theme.spacingXL
                contentWidth: width

                Column {
                    id: settingsColumn
                    width: Math.min(550, parent.width - Theme.spacingL * 2)
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingL

                    // Provider & connection
                    Card {
                        StyledText {
                            text: I18n.tr("Provider")
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        DankDropdown {
                            width: parent.width
                            options: root.providerIds
                            currentValue: root.provider
                            onValueChanged: value => root.setProvider(value)
                        }

                        Hint {
                            text: root.provider === "pollinations"
                                ? I18n.tr("Free and keyless. Prompts are sent as GET {Base URL}/{prompt}.")
                                : root.provider === "custom"
                                    ? I18n.tr("Any OpenAI-compatible API (OpenRouter, LM Studio, vLLM, Ollama /v1, ...).")
                                    : root.provider === "ollama"
                                        ? I18n.tr("Local Ollama server. No key needed.")
                                        : I18n.tr("Requires an API key from this provider.")
                        }

                        Hint { text: I18n.tr("Base URL") }
                        DankTextField {
                            width: parent.width
                            text: root.baseUrl
                            placeholderText: aiService.defaultsForProvider(root.provider).baseUrl
                            onEditingFinished: {
                                saveActiveField("baseUrl", text.trim())
                                Qt.callLater(() => aiService.refreshAvailableModels(true))
                            }
                        }

                        Hint { text: root.provider === "pollinations" ? I18n.tr("Access token (optional)") : I18n.tr("API key") + (root.keyRequired ? "" : " " + I18n.tr("(optional)")) }
                        DankTextField {
                            id: apiKeyField
                            width: parent.width
                            text: root.apiKey
                            echoMode: TextInput.Password
                            placeholderText: I18n.tr("Stored in plugin settings on disk")
                            onEditingFinished: {
                                saveActiveField("apiKey", text.trim())
                                Qt.callLater(() => aiService.refreshAvailableModels(true))
                            }
                        }

                        Hint { text: I18n.tr("Or read the key from an environment variable (recommended)") }
                        DankTextField {
                            width: parent.width
                            text: root.apiKeyEnvVar
                            placeholderText: root.provider === "openai" ? "OPENAI_API_KEY"
                                : root.provider === "anthropic" ? "ANTHROPIC_API_KEY"
                                : root.provider === "gemini" ? "GEMINI_API_KEY"
                                : root.provider === "pollinations" ? "POLLINATIONS_TOKEN" : "MY_API_KEY"
                            onEditingFinished: saveActiveField("apiKeyEnvVar", text.trim())
                        }

                        Hint { text: I18n.tr("Model") }
                        DankDropdown {
                            width: parent.width
                            visible: (aiService.availableModels?.length ?? 0) > 0
                            options: aiService.selectableModels || []
                            currentValue: (aiService.availableModels || []).indexOf(root.model) >= 0 ? root.model : ""
                            onValueChanged: value => {
                                saveActiveField("model", value)
                                aiService.setCurrentModel(value)
                            }
                        }
                        DankTextField {
                            width: parent.width
                            text: root.model
                            placeholderText: root.provider === "ollama" ? "llama3.2" : (aiService.defaultsForProvider(root.provider).model || "model name")
                            onEditingFinished: {
                                saveActiveField("model", text.trim())
                                aiService.setCurrentModel(text.trim())
                            }
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingM

                            DankButton {
                                text: aiService.modelsLoading ? I18n.tr("Testing…") : I18n.tr("Test connection")
                                iconName: "network_check"
                                enabled: !aiService.modelsLoading
                                onClicked: aiService.refreshAvailableModels(true)
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: aiService.modelDiscoveryStatusText()
                                font.pixelSize: Theme.fontSizeSmall
                                color: aiService.modelsError ? Theme.error : Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // Panel size
                    Card {
                        StyledText {
                            text: I18n.tr("Panel width: %1 px").arg(Math.round(root.panelWidth))
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                        Hint { text: I18n.tr("You can also drag the panel's left edge. Double-click the edge to reset.") }
                        DankSlider {
                            width: parent.width
                            height: 32
                            minimum: 360
                            maximum: 1400
                            step: 10
                            value: Math.round(root.panelWidth)
                            showValue: false
                            onSliderValueChanged: newValue => save("panelWidth", newValue)
                        }
                        DankButton {
                            text: I18n.tr("Reset width")
                            iconName: "restart_alt"
                            onClicked: save("panelWidth", 480)
                        }
                    }

                    // System prompt
                    Card {
                        StyledText {
                            text: I18n.tr("System Prompt")
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                        DankTextField {
                            width: parent.width
                            text: root.systemPrompt
                            placeholderText: I18n.tr("Instructions sent with every message")
                            onEditingFinished: save("systemPrompt", text)
                        }
                    }

                    // Behaviour
                    Card {
                        StyledText {
                            text: I18n.tr("Behavior")
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        ToggleRow {
                            title: I18n.tr("Remember conversation")
                            description: I18n.tr("Send earlier messages along with each prompt so the AI keeps context. With Pollinations, long chats are trimmed because the prompt lives in the URL.")
                            checked: root.includeHistory
                            onToggled: c => save("includeHistory", c)
                        }

                        ToggleRow {
                            visible: root.provider === "pollinations"
                            title: I18n.tr("Private requests")
                            description: I18n.tr("Ask Pollinations not to list your prompts in its public feed.")
                            checked: root.privateMode
                            onToggled: c => save("privateMode", c)
                        }

                        ToggleRow {
                            title: I18n.tr("Monospace Font")
                            description: I18n.tr("Use monospace font for AI replies (better for code)")
                            checked: root.useMonospace
                            onToggled: c => save("useMonospace", c)
                        }
                    }

                    // Generation
                    Card {
                        visible: root.provider !== "pollinations"

                        StyledText {
                            text: I18n.tr("Temperature: %1").arg(root.temperature.toFixed(2))
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                        Hint { text: I18n.tr("Controls randomness (0 = focused, 2 = creative). Ignored by some providers.") }
                        DankSlider {
                            width: parent.width
                            height: 32
                            minimum: 0
                            maximum: 200
                            step: 1
                            value: Math.round(root.temperature * 100)
                            showValue: false
                            onSliderValueChanged: newValue => save("temperature", newValue / 100)
                        }

                        StyledText {
                            text: I18n.tr("Max Tokens: %1").arg(root.maxTokens)
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                        Hint { text: I18n.tr("Maximum response length") }
                        DankSlider {
                            width: parent.width
                            height: 32
                            minimum: 128
                            maximum: 32768
                            step: 256
                            value: root.maxTokens
                            showValue: false
                            onSliderValueChanged: newValue => save("maxTokens", newValue)
                        }
                    }
                }
            }
        }
    }
}
