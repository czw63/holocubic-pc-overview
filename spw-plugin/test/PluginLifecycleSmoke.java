package test;

import com.czw.pcoverview.spw.SpwPcOverviewPlugin;
import org.pf4j.PluginWrapper;

public final class PluginLifecycleSmoke {
    public static void main(String[] args) throws Exception {
        PluginWrapper wrapper = new PluginWrapper("smoke");
        SpwPcOverviewPlugin plugin = new SpwPcOverviewPlugin(wrapper);
        plugin.start();
        System.out.println("PLUGIN_SMOKE_STARTED");
        Thread.sleep(12000L);
        plugin.stop();
        System.out.println("PLUGIN_SMOKE_STOPPED");
    }
}
