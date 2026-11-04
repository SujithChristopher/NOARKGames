extends RefCounted
## Joins the board's hotspot through the GdAndroidBLE plugin (Android's
## WifiNetworkSpecifier): one tap on the tablet the first time for a network,
## automatic after that. While joined, the app's sockets use that network.

signal joined
signal lost
signal failed(reason: String)

var _plugin


## null off Android, where the machine's own Wi-Fi settings join the network.
static func find():
	if Engine.has_singleton("GdAndroidBLE"):
		return new(Engine.get_singleton("GdAndroidBLE"))
	return null


func _init(plugin) -> void:
	_plugin = plugin
	_plugin.wifi_joined.connect(func(): joined.emit())
	_plugin.wifi_lost.connect(func(): lost.emit())
	_plugin.wifi_failed.connect(func(reason: String): failed.emit(reason))


## bssid "" asks for any access point of that name, and then Android asks the user
## every time: it skips that only for one exact access point.
func join(ssid: String, password: String, bssid: String) -> void:
	_plugin.wifi_join(ssid, password, bssid)


func leave() -> void:
	_plugin.wifi_leave()
