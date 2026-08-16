package org.pf4j;

public abstract class Plugin {
    protected final PluginWrapper wrapper;

    public Plugin(PluginWrapper wrapper) {
        this.wrapper = wrapper;
    }

    public PluginWrapper getWrapper() {
        return wrapper;
    }

    public void start() {
    }

    public void stop() {
    }

    public void delete() {
    }
}
