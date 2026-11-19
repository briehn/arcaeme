extends Control

const CombatView = preload("res://scripts/combat.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")

@onready var session: NetworkSession = $Session
@onready var port_field: SpinBox = %Port
@onready var status_label: Label = %ConnectionStatus
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var leave_button: Button = %LeaveButton
@onready var combat_slot: Control = %CombatSlot

var _combat: CombatView


func _ready() -> void:
	port_field.value = NetworkSession.DEFAULT_PORT
	_combat = COMBAT_SCENE.instantiate()
	_combat.configure_network()
	_combat.network_card_requested.connect(session.submit_card)
	_combat.network_end_turn_requested.connect(session.submit_end_turn)
	combat_slot.add_child(_combat)
	session.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	status_label.text = session.message
	var connected_or_waiting := session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.JOINING,
		NetworkSession.Status.ACTIVE]
	host_button.disabled = connected_or_waiting
	join_button.disabled = connected_or_waiting
	port_field.editable = not connected_or_waiting
	leave_button.text = "Disconnect and Back to Menu" if connected_or_waiting else "Back to Menu"
	if session.snapshot.is_empty():
		if combat_slot.visible:
			_combat.clear_network_view()
		combat_slot.hide()
	else:
		_combat.display_network_snapshot(session.snapshot, session.can_submit())
		combat_slot.show()


func _on_host_pressed() -> void:
	session.host(int(port_field.value))


func _on_join_pressed() -> void:
	session.join(int(port_field.value))


func _on_leave_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
