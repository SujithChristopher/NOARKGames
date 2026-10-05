extends Node
## Talks to agent.py, the background program that tells the server which patient
## is training on this device (the patient lock), so no other device can train
## the same patient at the same time.
##
##   login (dose screen confirm)  start(pid)    claim the patient; refused while another device has them
##   a trial ends                 trial_ended() renew the claim, refresh the patient list
##   logout / app closes          stop()        release the patient
##
## agent.py listens on 127.0.0.1:5055. If it is not running at startup it is
## launched, and it stays up after the app closes (it is meant to run all day).
## A network fault never stops therapy: when the agent or the server cannot be
## reached, start() lets the login through.
## The debug patient (vvv) is not a real patient, so nothing is sent in debug.

const AGENT_SCRIPT := "agent.py"
const URL := "http://127.0.0.1:5055"
const TIMEOUT := 6.0   # the agent waits up to 3 s for the server per lock request

var patient: String = ""   # the patient this device holds, "" when none


func _ready() -> void:
	# The close request pauses the tree while it waits; the release must still go out.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _enabled():
		_ensure_running()


func _enabled() -> bool:
	return not Settings.get_value("debug", false) and not OS.has_feature("android")


## Claims pid. Returns {"ok": true} or {"ok": false, "message": "..."} when
## another device is training them (then do not start the session).
func start(pid: String) -> Dictionary:
	if not _enabled():
		return {"ok": true}
	var reply := await _call("/start?patient=" + pid.uri_encode())
	if reply.get("code", 0) == 409:
		var body: Dictionary = reply["body"]
		return {"ok": false, "message": body.get("message", "%s is training on another device." % pid)}
	if reply.is_empty():
		push_warning("[agent] not reachable: %s logged in without the patient lock" % pid)
	patient = pid
	return {"ok": true}


## A trial just ended: renews the claim. Does not wait for the reply.
func trial_ended() -> void:
	if not _enabled() or patient == "":
		return
	var reply := await _call("/trial-ended")
	var lost = reply.get("body", {}).get("lost")
	if lost:
		push_warning("[agent] %s was taken by another device: %s" % [patient, lost])


## Releases the held patient. Await it before quitting so the request goes out.
func stop() -> void:
	if not _enabled() or patient == "":
		return
	patient = ""
	await _call("/stop")


func _ensure_running() -> void:
	if not (await _call("/status")).is_empty():
		return
	var path: String = GlobalScript.project_file(AGENT_SCRIPT)
	var pid := OS.create_process(GlobalScript.python(), [path])
	if pid <= 0:
		push_error("[agent] could not start %s" % path)
	else:
		print("[agent] started %s" % path)


## GET path on the agent. Returns {"code": int, "body": Dictionary}, or {} if it
## could not be reached.
func _call(path: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT
	add_child(req)
	if req.request(URL + path) != OK:
		req.queue_free()
		return {}
	var res: Array = await req.request_completed   # [result, code, headers, body]
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS:
		return {}
	var body = JSON.parse_string(res[3].get_string_from_utf8())
	return {"code": res[1], "body": body if body is Dictionary else {}}
