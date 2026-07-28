class_name ClassicPresentationOpcodeRuntime
extends RefCounted

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func _execute_random_text(extra_code_id: int) -> Dictionary:
	var values: Array = runtime.call(
		"_extra_code_values",
		extra_code_id
	)
	if values.is_empty():
		return _result(
			"_halt_with_error",
			[
				"Random text action references missing Extra Code row %d"
				% extra_code_id,
			]
		)
	var first_message_id := int(values[0])
	var last_message_id := int(values[1])
	var message_id := randi_range(first_message_id, last_message_id)
	return _result("_yield_result", [
		"show_text",
		{
			"extraCodeId": extra_code_id,
			"messageRange": [first_message_id, last_message_id],
			"messageId": message_id,
			"message": runtime.bundle.get_message(message_id),
		},
	])


func _execute_scrolling_text(resource_id: int) -> Dictionary:
	var scrolling_text: Dictionary = runtime.bundle.get_scrolling_text(
		resource_id
	)
	if scrolling_text.is_empty():
		return _result(
			"_halt_with_error",
			[
				"Scrolling text resource %d is unavailable"
				% abs(resource_id),
			]
		)
	return _result("_yield_result", [
		"show_scrolling_text",
		{
			"resourceId": abs(resource_id),
			"scrollingText": scrolling_text,
		},
	])


func _result(method_name: String, arguments := []) -> Dictionary:
	if runtime == null or not runtime.has_method(method_name):
		return {
			"status": "error",
			"message": "Classic presentation runtime requires '%s'" \
				% method_name,
		}
	var value: Variant = runtime.callv(method_name, arguments)
	if value is Dictionary:
		return value
	return {
		"status": "error",
		"message": "Classic presentation operation '%s' returned invalid state" \
			% method_name,
	}
