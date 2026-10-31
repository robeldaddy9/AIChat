import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Services
import "."

Item {
    id: root

    // Injected by PluginService
    property var pluginService: null
    property string pluginId: "aiChat"

    readonly property real minPanelWidth: 360
    readonly property real defaultPanelWidth: 480
    // Window width stays fixed at this size; only the panel inside it is resized.
    readonly property real maxPanelWidth: 1400

    // Shared by all screens and remembered between sessions
    property real panelWidth: defaultPanelWidth

    Component.onCompleted: {
        const saved = Number(PluginService.loadPluginData(pluginId, "panelWidth", defaultPanelWidth));
        panelWidth = clampWidth(saved);
    }

    function clampWidth(w) {
        if (!isFinite(w) || w <= 0)
            return defaultPanelWidth;
        return Math.max(minPanelWidth, Math.min(maxPanelWidth, Math.round(w)));
    }

    // Keep in sync when the width is changed from the settings slider.
    Connections {
        target: PluginService
        function onPluginDataChanged(pId) {
            if (pId !== root.pluginId)
                return;
            const w = root.clampWidth(Number(PluginService.loadPluginData(root.pluginId, "panelWidth", root.defaultPanelWidth)));
            if (w !== root.panelWidth)
                root.panelWidth = w;
        }
    }

    function toggle() {
        if (variants.instances.length > 0)
            variants.instances[0].toggle();
    }

    // Shared chat logic for all screens
    AIChatService {
        id: chatLogic
        pluginId: root.pluginId
    }

    Variants {
        id: variants
        model: Quickshell.screens

        delegate: DSlideout {
            id: slideout
            required property var modelData
            title: "AI Chat"
            slideoutWidth: Math.min(root.panelWidth, expandedWidthValue)
            expandable: true
            expandedWidthValue: Math.min(root.maxPanelWidth, modelData ? modelData.width : root.maxPanelWidth)

            content: AIChat {
                aiService: chatLogic

                onHideRequested: slideout.hide()

                // x = pointer position in the window; the panel is anchored to the right edge.
                onResizeDragged: sceneX => {
                    if (slideout.expandedWidth)
                        slideout.expandedWidth = false;
                    root.panelWidth = root.clampWidth(slideout.width - sceneX);
                }
                onResizeFinished: PluginService.savePluginData(root.pluginId, "panelWidth", root.panelWidth)
                onResizeReset: {
                    root.panelWidth = root.defaultPanelWidth;
                    PluginService.savePluginData(root.pluginId, "panelWidth", root.panelWidth);
                }
            }
        }
    }
}
