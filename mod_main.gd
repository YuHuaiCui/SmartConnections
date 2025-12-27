extends Node
## Smart Connections Mod
## Automatically connects dropped connections to compatible containers on hovered windows.

const MOD_NAME = "SmartConnections"
const MOD_VERSION = "1.0.5"


func _init() -> void:
    ModLoaderLog.info("Initializing", MOD_NAME)


func _ready() -> void:
    Signals.connection_droppped.connect(_on_connection_dropped)
    # Note: We don't connect to delete_connection here because the game's
    # ResourceContainer already handles it. Connecting here would cause
    # double remove_output calls and potential signal disconnect crashes.
    ModLoaderLog.info("Ready - v%s" % MOD_VERSION, MOD_NAME)


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

    # Don't smart-connect if user is hovering over a connector button
    # (let the game's native connector_button handler deal with it)
    if _is_hovering_connector(target_window):
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
    # Handle 1-to-1 input connections: delete existing connection first if present
    # Use call_deferred to let the game's connector_button handlers run first,
    # preventing duplicate connections when dropping directly on a connector
    if source_type == Utils.connections_types.OUTPUT:
        # Source OUTPUT -> Target INPUT
        # Skip if already connected to this exact source (avoid unnecessary delete+recreate)
        if target.input_id == source_id:
            return
        if not target.input_id.is_empty():
            # Target already has an input, delete the old connection first
            _delete_connection(target.input_id, target.id)
        _create_connection.call_deferred(source_id, target.id)
    elif source_type == Utils.connections_types.INPUT:
        # Target OUTPUT -> Source INPUT
        # Skip if already connected to this exact source (avoid unnecessary delete+recreate)
        if source.input_id == target.id:
            return
        if not source.input_id.is_empty():
            # Source already has an input, delete the old connection first
            _delete_connection(source.input_id, source.id)
        _create_connection.call_deferred(target.id, source_id)


func _find_compatible_container(source: ResourceContainer, source_type: int, window: WindowBase) -> ResourceContainer:
    if not "containers" in window:
        return null

    var containers = window.get("containers")
    if not containers or containers.is_empty():
        return null

    for container in containers:
        # Skip invalid containers (might have been freed)
        if not is_instance_valid(container):
            continue
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
        # Black connector on either side blocks connections
        if source.get_connector_color() == "black" or target.get_connector_color() == "black":
            return false
        # Note: We allow connections even if target has an existing input,
        # since _attempt_smart_connection will delete the old connection first
        return source.can_connect(target)

    elif source_type == Utils.connections_types.INPUT:
        # Target OUTPUT -> Source INPUT
        if not _has_output_connector(target) or not _has_input_connector(source):
            return false
        # Black connector on either side blocks connections
        if target.get_connector_color() == "black" or source.get_connector_color() == "black":
            return false
        return target.can_connect(source)

    return false


func _delete_connection(output_id: String, input_id: String) -> void:
    # Verify the old output container still exists before emitting delete
    var old_output := Globals.desktop.get_resource(output_id) as ResourceContainer
    if not is_instance_valid(old_output):
        return
    # Verify the connection actually exists in the output's outputs_id array
    if not old_output.outputs_id.has(input_id):
        return
    Signals.delete_connection.emit(output_id, input_id)
    ModLoaderLog.info("Deleted: %s -> %s" % [output_id, input_id], MOD_NAME)


func _create_connection(output_id: String, input_id: String) -> void:
    var output := Globals.desktop.get_resource(output_id) as ResourceContainer
    var input := Globals.desktop.get_resource(input_id) as ResourceContainer

    if not is_instance_valid(output) or not is_instance_valid(input):
        return

    if not _has_output_connector(output) or not _has_input_connector(input):
        return

    # Prevent duplicate connections
    if output.outputs_id.has(input_id):
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


func _is_hovering_connector(window: WindowBase) -> bool:
    # Check if user is directly hovering over any connector button in this window
    if not "containers" in window:
        return false

    var containers = window.get("containers")
    if not containers:
        return false

    for container in containers:
        if not is_instance_valid(container):
            continue
        # Check both input and output connectors
        var input_connector = container.get_node_or_null("InputConnector")
        if is_instance_valid(input_connector) and input_connector.hovering:
            return true
        var output_connector = container.get_node_or_null("OutputConnector")
        if is_instance_valid(output_connector) and output_connector.hovering:
            return true

    return false
