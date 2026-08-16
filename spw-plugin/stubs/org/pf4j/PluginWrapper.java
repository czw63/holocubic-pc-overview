package org.pf4j;

public class PluginWrapper {
    private final String pluginId;

    public PluginWrapper(String pluginId) {
        this.pluginId = pluginId;
    }

    public String getPluginId() {
        return pluginId;
    }
}
