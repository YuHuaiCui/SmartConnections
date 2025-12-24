extends Node
## Smart Connections Mod
## Automatically connects dropped connections to compatible containers on hovered windows.

const MOD_NAME = "SmartConnections"


func _init() -> void:
    ModLoaderLog.info("Initializing", MOD_NAME)


func _ready() -> void:
    Signals.connection_droppped.connect(_on_connection_dropped)
    ModLoaderLog.info("Ready", MOD_NAME)


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_connection_dropped(source_id: String, source_type: int) -> void:
    if source_id.is_empty():
        return

    var target_window := _get_window_at_mouse()
    if not target_window:
        return

    # Don't smart-connect within the same window
    var source_window := _get_container_window(source_id)
    if source_window == target_window:
        return

    _attempt_smart_connection(source_id, source_type, target_window)


# =============================================================================
# CONNECTION LOGIC
# =============================================================================

func _attempt_smart_connection(source_id: String, source_type: int, target_window: WindowBase) -> void:
    var source := Globals.desktop.get_resource(source_id) as ResourceContainer
    if not is_instance_valid(source):
        return

    var target := _find_compatible_container(source, source_type, target_window)
    if not target:
        return

    # Create connection with correct direction
    if source_type == Utils.connections_types.OUTPUT:
        if target.input_id.is_empty():  # Only connect if target has no input
            _create_connection(source_id, target.id)
    elif source_type == Utils.connections_types.INPUT:
        _create_connection(target.id, source_id)


func _find_compatible_container(source: ResourceContainer, source_type: int, window: WindowBase) -> ResourceContainer:
    if not "containers" in window:
        return null

    var containers = window.get("containers")
    if not containers:
        return null

    for container in containers:
        if _can_connect(source, container, source_type):
            return container

    return null


func _can_connect(source: ResourceContainer, target: ResourceContainer, source_type: int) -> bool:
    if not is_instance_valid(source) or not is_instance_valid(target):
        return false

    if source.id == target.id:
        return false

    if source_type == Utils.connections_types.OUTPUT:
        # Source OUTPUT -> Target INPUT
        if not _has_output_connector(source) or not _has_input_connector(target):
            return false
        if source.get_connector_color() == "black":
            return false
        if not target.input_id.is_empty():
            return false
        return source.can_connect(target)

    elif source_type == Utils.connections_types.INPUT:
        # Target OUTPUT -> Source INPUT
        if not _has_output_connector(target) or not _has_input_connector(source):
            return false
        if target.get_connector_color() == "black":
            return false
        return target.can_connect(source)

    return false


func _create_connection(output_id: String, input_id: String) -> void:
    var output := Globals.desktop.get_resource(output_id) as ResourceContainer
    var input := Globals.desktop.get_resource(input_id) as ResourceContainer

    if not _has_output_connector(output) or not _has_input_connector(input):
        return

    Signals.create_connection.emit(output_id, input_id)
    Sound.play("connect")
    ModLoaderLog.info("Connected: %s -> %s" % [output_id, input_id], MOD_NAME)


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

func _has_output_connector(container: ResourceContainer) -> bool:
    return is_instance_valid(container) and container.has_node("OutputConnector")


func _has_input_connector(container: ResourceContainer) -> bool:
    return is_instance_valid(container) and container.has_node("InputConnector")


func _get_container_window(container_id: String) -> WindowBase:
    var container := Globals.desktop.get_resource(container_id)
    if not is_instance_valid(container):
        return null

    var node: Node = container
    while node:
        if node is WindowBase:
            return node
        node = node.get_parent()
    return null


func _get_window_at_mouse() -> WindowBase:
    if not is_instance_valid(Globals.desktop):
        return null

    var mouse_pos := Globals.desktop.get_global_mouse_position()
    var windows_node := Globals.desktop.get_node_or_null("Windows")
    if not windows_node:
        return null

    # Check windows in reverse order (topmost first)
    var children := windows_node.get_children()
    for i in range(children.size() - 1, -1, -1):
        var window = children[i]
        if window is WindowBase and _is_point_in_window(window, mouse_pos):
            return window

    return null


func _is_point_in_window(window: WindowBase, point: Vector2) -> bool:
    return Rect2(window.global_position, window.size).has_point(point)
