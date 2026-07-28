class_name ClassicInventoryOpcodeRuntime
extends RefCounted

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func resume_item_check(possessed: bool) -> Dictionary:
	if runtime.pending_item_check.is_empty():
		return _result(
			"_error_result",
			["No classic item check is waiting for a response"]
		)
	var item_check: Dictionary = runtime.pending_item_check
	runtime.pending_item_check = {}
	var values: Array = item_check["values"]
	match str(item_check.get("kind", "")):
		"possession_branch":
			if possessed:
				var possessed_result := _branch_item_possession_target(
					values,
					int(values[3]),
					bool(item_check.get("gosub", false))
				)
				if str(possessed_result.get("status", "")) != "continue":
					return possessed_result
				return _run()
			match int(values[2]):
				0:
					var missing_result := _branch_item_possession_target(
						values,
						int(values[4]),
						bool(item_check.get("gosub", false))
					)
					if str(missing_result.get("status", "")) != "continue":
						return missing_result
					return _run()
				1:
					return _run()
				2:
					runtime.call("_clear_control_flow")
					return _result("_yield_result", [
						"show_text",
						{
							"messageId": int(values[4]),
							"message": _bundle().get_message(int(values[4])),
						},
					])
				_:
					return _halt(
						"Item possession branch has invalid failure mode %d"
						% int(values[2])
					)
		"result_branch":
			var test_mode := int(values[1])
			if test_mode not in [0, 1]:
				return _halt(
					"Item result branch has invalid test mode %d" % test_mode
				)
			var should_branch := (test_mode == 0 and not possessed) \
				or (test_mode == 1 and possessed)
			if not should_branch:
				return _run()
			var branch_result := _result(
				"_branch_from_extra_code",
				[values, false]
			)
			if str(branch_result.get("status", "")) != "continue":
				return branch_result
			return _run()
		"charge_branch":
			var target_id := int(values[3]) if possessed else int(values[4])
			if target_id == -1:
				return _run()
			var charge_branch_result := _branch_item_possession_target(
				values,
				target_id,
				bool(item_check.get("gosub", false))
			)
			if str(charge_branch_result.get("status", "")) != "continue":
				return charge_branch_result
			return _run()
		_:
			return _halt("Classic item check has an invalid continuation")


func resume_wealth_payment(paid: bool) -> Dictionary:
	if runtime.pending_wealth_payment.is_empty():
		return _result(
			"_error_result",
			["No classic wealth payment is waiting for a response"]
		)
	var payment: Dictionary = runtime.pending_wealth_payment
	runtime.pending_wealth_payment = {}
	var values: Array = payment["values"]
	if not paid and int(values[1]) == -1:
		runtime.call("_set_cursor", runtime.current_trigger, 7)
		return _run()
	var test_mode := int(values[1])
	var should_branch := test_mode == 2 \
		or (test_mode == 0 and not paid) \
		or (test_mode == 1 and paid)
	if not should_branch:
		return _run()
	var branch_result := _result(
		"_branch_from_extra_code",
		[values, false]
	)
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func _execute_take_gold(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Take Gold action references missing Extra Code row %d"
			% extra_code_id
		)
	var authored_amount := int(values[0])
	runtime.pending_wealth_payment = {
		"extraCodeId": extra_code_id,
		"values": values,
	}
	return _result("_yield_result", [
		"take_party_wealth",
		{
			"extraCodeId": extra_code_id,
			"currency": 0 if authored_amount > 0 else 1,
			"amount": abs(authored_amount),
			"warningId": 50,
		},
	])


func _execute_load_shop(
	signed_shop_id: int,
	accept_ranges: Array = []
) -> Dictionary:
	var shop_id: int = abs(signed_shop_id)
	var shop: Dictionary = _bundle().get_shop(shop_id)
	if shop.is_empty():
		return _halt("Shop action references missing shop %d" % shop_id)
	shop = runtime.runtime_state.get_effective_shop(shop)
	var item_texts: Array = []
	if accept_ranges.is_empty():
		var seen_item_ids: Dictionary = {}
		for item_id_value: Variant in shop.get("itemIds", []):
			var item_id: int = abs(int(item_id_value))
			if item_id == 0 or seen_item_ids.has(item_id):
				continue
			seen_item_ids[item_id] = true
			var item_text := _bundle().get_item_text(item_id)
			if not item_text.is_empty():
				item_texts.append(item_text)
	else:
		item_texts.assign(_bundle().item_texts_by_id.values())
	var shop_accept_ranges := [0, 0, 0, 0] \
		if accept_ranges.is_empty() else accept_ranges.duplicate()
	return _result("_yield_result", [
		"load_shop",
		{
			"shopId": shop_id,
			"shop": shop,
			"itemTexts": item_texts,
			"openImmediately": signed_shop_id < 0,
			"acceptRanges": shop_accept_ranges,
		},
	])


func _execute_shop_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Shop mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var shop_id := int(values[0])
	var shop := _bundle().get_shop(shop_id)
	if shop.is_empty():
		return _halt(
			"Shop mutation references missing shop %d" % shop_id
		)
	var inflation_delta := int(values[1])
	var item_id := int(values[2])
	var quantity_delta := int(values[3])
	var effective: Dictionary = runtime.runtime_state.alter_shop(
		shop,
		inflation_delta,
		item_id,
		quantity_delta
	)
	return _result("_yield_result", [
		"alter_shop",
		{
			"extraCodeId": extra_code_id,
			"shopId": shop_id,
			"shop": effective,
			"inflationDelta": inflation_delta,
			"itemId": item_id,
			"quantityDelta": quantity_delta,
		},
	])


func _execute_restricted_shop(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Restricted shop action references missing Extra Code row %d"
			% extra_code_id
		)
	return _execute_load_shop(int(values[0]), [
		int(values[1]),
		int(values[2]),
		int(values[3]),
		int(values[4]),
	])


func _execute_item_possession_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Item possession branch references missing Extra Code row %d"
			% extra_code_id
		)
	runtime.pending_item_check = {
		"kind": "possession_branch",
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_item",
		{
			"extraCodeId": extra_code_id,
			"itemId": abs(int(values[0])),
			"itemTexts": _item_texts_for_ids([values[0]]),
		},
	])


func _execute_item_charge_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 5:
		return _halt(
			"Item-charge branch references malformed Extra Code row %d"
			% extra_code_id
		)
	if int(values[1]) < 0 or int(values[1]) > 2:
		return _halt(
			"Item-charge branch has invalid target mode %d" % int(values[1])
		)
	runtime.pending_item_check = {
		"kind": "charge_branch",
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_item",
		{
			"extraCodeId": extra_code_id,
			"itemId": abs(int(values[0])),
			"minimumCharges": int(values[2]),
			"itemTexts": _item_texts_for_ids([values[0]]),
		},
	])


func _execute_item_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Item mutation references missing Extra Code row %d"
			% extra_code_id
		)
	return _result("_yield_result", [
		"alter_party_items",
		{
			"extraCodeId": extra_code_id,
			"itemId": abs(int(values[0])),
			"maxMatches": int(values[1]),
			"operation": int(values[2]),
			"chargeDelta": int(values[3]),
			"replacementItemId": abs(int(values[4])),
			"itemTexts": _item_texts_for_ids([values[0], values[4]]),
		},
	])


func _execute_item_result_branch(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Item result branch references missing Extra Code row %d"
			% extra_code_id
		)
	var test_mode := int(values[1])
	if test_mode not in [0, 1, 2]:
		return _halt(
			"Item result branch has invalid test mode %d" % test_mode
		)
	if test_mode == 2:
		return _result("_branch_from_extra_code", [values, false])
	runtime.pending_item_check = {
		"kind": "result_branch",
		"values": values,
	}
	return _result("_yield_result", [
		"check_party_item",
		{
			"extraCodeId": extra_code_id,
			"itemId": abs(int(values[0])),
			"itemTexts": _item_texts_for_ids([values[0]]),
		},
	])


func _branch_item_possession_target(
	values: Array,
	target: int,
	gosub: bool
) -> Dictionary:
	match int(values[1]):
		0:
			return _result(
				"_branch_to_extra_action_point",
				[target, gosub, 0]
			)
		1, 2:
			if gosub:
				var push_result := _result("_push_call_frame")
				if str(push_result.get("status", "")) != "continue":
					return push_result
			return _result("_execute_encounter", [
				"simple" if int(values[1]) == 1 else "complex",
				target,
			])
		_:
			return _halt(
				"Item possession branch has invalid target mode %d"
				% int(values[1])
			)


func _item_texts_for_ids(item_ids: Array) -> Array:
	var item_texts: Array = []
	var included_ids: Dictionary = {}
	for item_id_value: Variant in item_ids:
		var item_id: int = abs(int(item_id_value))
		if item_id == 0 or included_ids.has(item_id):
			continue
		included_ids[item_id] = true
		var item_text := _bundle().get_item_text(item_id)
		if not item_text.is_empty():
			item_texts.append(item_text)
	return item_texts


func _execute_treasure(treasure_id: int) -> Dictionary:
	var treasure := _bundle().get_treasure(treasure_id)
	if treasure.is_empty():
		return _halt("Missing treasure record %d" % treasure_id)
	var item_texts: Array = []
	var item_ids: Variant = treasure.get("itemIds", [])
	if item_ids is Array:
		for item_id_value: Variant in item_ids:
			var item_id: int = abs(int(item_id_value))
			if item_id == 0:
				continue
			var item_text := _bundle().get_item_text(item_id)
			if not item_text.is_empty():
				item_texts.append(item_text)
	return _result("_yield_result", [
		"give_treasure",
		{
			"treasureId": treasure_id,
			"treasure": treasure,
			"itemTexts": item_texts,
			"lootMode": 1,
		},
	])


func _execute_currency_clear(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Currency-clear action references missing Extra Code row %d"
			% extra_code_id
		)
	var currency := int(values[0]) - 1
	if currency < 0 or currency > 2:
		return _halt(
			"Currency-clear action has invalid currency %d" % int(values[0])
		)
	return _result("_yield_result", [
		"clear_party_currency",
		{
			"extraCodeId": extra_code_id,
			"currency": currency,
			"selectedOnly": int(values[1]) != 0,
		},
	])


func _execute_random_items(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Random-item action references missing Extra Code row %d"
			% extra_code_id
		)
	var authored_count := int(values[0])
	var count := randi_range(1, absi(authored_count)) \
		if authored_count < 0 else authored_count
	var first_item_id := int(values[1])
	var last_item_id := int(values[2])
	if count < 0 or count > 20:
		return _halt(
			"Random-item action count must be between 0 and 20"
		)
	if first_item_id <= 0 or last_item_id < first_item_id:
		return _halt("Random-item action has an invalid item range")
	var item_ids: Array[int] = []
	var item_texts: Array = []
	var seen_texts: Dictionary = {}
	for _item_index: int in range(count):
		var item_id := randi_range(first_item_id, last_item_id)
		item_ids.append(item_id)
		var item_text := _bundle().get_item_text(item_id)
		if not item_text.is_empty() and not seen_texts.has(item_id):
			seen_texts[item_id] = true
			item_texts.append(item_text)
	return _result("_yield_result", [
		"give_treasure",
		{
			"extraCodeId": extra_code_id,
			"treasureId": -1,
			"treasure": {
				"id": -1,
				"itemIds": item_ids,
				"exp": 0,
				"gold": 0,
				"gems": 0,
				"jewelry": 0,
			},
			"itemTexts": item_texts,
			"lootMode": 1,
			"randomItemCount": count,
			"randomItemRange": [first_item_id, last_item_id],
		},
	])


func _bundle() -> ClassicCampaignBundle:
	return runtime.bundle


func _values(extra_code_id: int) -> Array:
	return runtime.call("_extra_code_values", extra_code_id)


func _run() -> Dictionary:
	return runtime.run_until_yield()


func _halt(message: String) -> Dictionary:
	return _result("_halt_with_error", [message])


func _result(method_name: String, arguments := []) -> Dictionary:
	if runtime == null or not runtime.has_method(method_name):
		return {
			"status": "error",
			"message": "Classic inventory runtime requires '%s'" % method_name,
		}
	var value: Variant = runtime.callv(method_name, arguments)
	if value is Dictionary:
		return value
	return {
		"status": "error",
		"message": "Classic inventory operation '%s' returned invalid state" \
			% method_name,
	}
