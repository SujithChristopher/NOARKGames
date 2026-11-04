extends RefCounted
## Puts a message sent as CHUNKs back together (docs/PROTOCOL.md): the link's, and
## the pictures over the hotspot. A part 0, or an id not seen, starts a message, so a
## message that lost a part is replaced by the next one under its id.

# msg_id -> {index: part}; two chunked messages (a snapshot and a storage list)
# can be on the way at once.
var _chunks: Dictionary = {}


## One CHUNK. -> the whole message when this was its last part, otherwise empty.
func add(msg: PackedByteArray) -> PackedByteArray:
	if msg.size() < 4:
		return PackedByteArray()
	var id := msg[1]
	var total := msg[3]
	if msg[2] == 0 or not _chunks.has(id):
		_chunks[id] = {}
	var parts: Dictionary = _chunks[id]
	parts[msg[2]] = msg.slice(4)
	if parts.size() < total:
		return PackedByteArray()
	var whole := PackedByteArray()
	for i in total:
		if not parts.has(i):
			return PackedByteArray()
		whole.append_array(parts[i])
	_chunks.erase(id)
	return whole
