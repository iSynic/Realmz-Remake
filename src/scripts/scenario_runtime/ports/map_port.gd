class_name MapPort
extends DelegatingScenarioPort

const COMMANDS := [
	"query_location",
	"query_time",
	"redraw_map",
	"set_map_tile",
	"set_trigger_percent",
	"teleport",
	"shift_party_position",
	"alter_game_time",
	"set_camping_permission",
	"update_exploration_status",
	"set_view_direction",
	"set_view_mode",
	"set_map_darkness",
	"set_random_encounter_rect",
	"set_land_look",
	"give_map",
	"back_up_party",
]
const OPERATIONS := {
	"query_location": "_query_location",
	"query_time": "_query_time",
	"redraw_map": "_redraw_map",
	"set_map_tile": "_set_map_tile",
	"set_trigger_percent": "_set_trigger_percent",
	"teleport": "_teleport_classic_party",
	"shift_party_position": "_shift_party_position",
	"alter_game_time": "_alter_game_time",
	"set_camping_permission": "_set_camping_permission",
	"update_exploration_status": "_update_exploration_status",
	"set_view_direction": "_set_view_direction",
	"set_view_mode": "_set_view_mode",
	"set_map_darkness": "_set_map_darkness",
	"set_random_encounter_rect": "_set_random_encounter_rect",
	"set_land_look": "_set_land_look",
	"give_map": "_give_player_map",
	"back_up_party": "_back_up_party",
}


func port_id() -> String:
	return "core.map"


func service_operation(command_id: String) -> String:
	return str(OPERATIONS.get(command_id, ""))


func owned_command_ids() -> PackedStringArray:
	return PackedStringArray(COMMANDS)


func execute(command_id: String, request: Dictionary) -> Dictionary:
	var routed_request := request.duplicate(true)
	if command_id == "alter_game_time" and routed_request.has("seconds"):
		var modifier_result := await apply_rule_modifiers(
			"time-advance",
			float(routed_request.get("seconds", 0)),
			{
				"minimum": 0.0,
				"commandId": command_id,
				"request": routed_request.duplicate(true),
			}
		)
		if str(modifier_result.get("status", "")) != "ok":
			return modifier_result
		routed_request["seconds"] = maxi(
			0,
			roundi(float(modifier_result.get("value", 0)))
		)
	return await super.execute(command_id, routed_request)
