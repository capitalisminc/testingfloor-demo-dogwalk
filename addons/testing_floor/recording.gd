class_name TestingFloorRecording
extends RefCounted
## The desktop app's recording handoff: parsing, precedence and leases.
##
## A handoff is a JSON object from the launch argument `--testing-floor=<JSON>` or
## from the editor sidecar `recording-payload.json`. A parsed handoff is a
## Dictionary with `recording_uuid`, `telemetry_directory`, `playtest_id` (0 when
## absent), `suppress_qr`, `lease_version`, `telemetry_requested`,
## `lease_expires_at_unix_ms` and `editor_pid`. An empty Dictionary means none.

const LAUNCH_PREFIX := "--testing-floor="
const MAX_AGE_MS := 12 * 60 * 60 * 1000
## The desktop app renews a 5-second lease every second, so a later expiry comes
## from a broken handoff.
const MAX_LEASE_AHEAD_MS := 30000


## The handoff in [param text], or an empty Dictionary when it is malformed, has no
## recording UUID, or is older than 12 hours without a live lease.
static func parse(text: String, now_ms: int) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	var value: Dictionary = json.data
	var uuid := str(value.get("recording_uuid", "")).strip_edges() if value.get("recording_uuid") is String else ""
	if uuid.is_empty():
		return {}
	var recording := {
		"recording_uuid": uuid,
		"telemetry_directory": str(value.get("telemetry_directory", "")).strip_edges() if value.get("telemetry_directory") is String else "",
		"playtest_id": maxi(0, _integer(value.get("playtest_id"))),
		"suppress_qr": value.get("suppress_qr", true) if value.get("suppress_qr") is bool else true,
		"lease_version": _integer(value.get("lease_version")),
		"telemetry_requested": value.get("telemetry_requested") == true,
		"lease_expires_at_unix_ms": _integer(value.get("lease_expires_at_unix_ms")),
		"editor_pid": _integer(value.get("editor_pid")),
	}
	var created := _integer(value.get("created_at_unix_ms"))
	if created > 0 and created < now_ms - MAX_AGE_MS and not has_active_lease(recording, now_ms):
		return {}
	return recording


## Which recording a Play run belongs to. A lease sidecar wins over the launch
## argument even after its lease expires, so expiry suspends the association
## instead of reviving an older launch. Otherwise a valid launch argument wins
## over a sidecar without a lease. In an editor ([param editor_pid] is not 0), a
## handoff that names another editor's process is ignored from either source.
static func resolve(sidecar: String, launch_argument: String, editor_pid: int, now_ms: int) -> Dictionary:
	var from_sidecar := _for_editor(parse(sidecar, now_ms), editor_pid)
	if not from_sidecar.is_empty() and from_sidecar.lease_version != 0:
		return from_sidecar
	var from_launch := _for_editor(parse(launch_argument, now_ms), editor_pid)
	return from_launch if not from_launch.is_empty() else from_sidecar


## The JSON after `--testing-floor=` in [param arguments], or an empty string.
static func launch_argument(arguments: PackedStringArray) -> String:
	for argument in arguments:
		if argument.begins_with(LAUNCH_PREFIX):
			return argument.trim_prefix(LAUNCH_PREFIX)
	return ""


## A capture is running: `lease_version` 1 that expires after now and no more than
## 30 seconds later.
static func has_live_lease(recording: Dictionary, now_ms: int) -> bool:
	var expires: int = recording.get("lease_expires_at_unix_ms", 0)
	return recording.get("lease_version", 0) == 1 and expires > now_ms and expires <= now_ms + MAX_LEASE_AHEAD_MS


## A live lease that also requests telemetry and names a telemetry directory, as
## recording-only editor collection needs.
static func has_active_lease(recording: Dictionary, now_ms: int) -> bool:
	return recording.get("telemetry_requested", false) and not str(recording.get("telemetry_directory", "")).is_empty() \
		and has_live_lease(recording, now_ms)


static func _for_editor(recording: Dictionary, editor_pid: int) -> Dictionary:
	if editor_pid == 0 or recording.is_empty() or recording.editor_pid <= 0 or recording.editor_pid == editor_pid:
		return recording
	return {}


static func _integer(value: Variant) -> int:
	if value is int:
		return value
	if value is float and is_finite(value) and absf(value) < 9.0e18:
		return int(value)
	return 0
