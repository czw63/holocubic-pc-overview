local config = {}

config.host = "192.168.1.100"
config.port = 8088
config.udp_port = 8090
config.cover = true
config.spectrum = true
config.refresh_ms = 33
config.full_refresh_ms = 500
config.weather_location = ""
config.timezone = "CST-8"
config.serial_log = true

config.timeout_ms = 6000
config.reconnect_ms = 2000
config.stale_ms = 5000

config.accent_color = 0x35D0BA
config.cpu_color = 0x46C7FF
config.gpu_color = 0x62E493
config.mem_color = 0xF2B84B

return config
