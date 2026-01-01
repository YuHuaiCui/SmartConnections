extends Node
## Smart Connections Mod
## Automatically connects dropped connections to compatible containers on hovered windows.

const MOD_NAME = "SmartConnections"
const MOD_VERSION = "1.0.6"

# Enable debug logging for troubleshooting
const DEBUG_MODE = false

# Group window scene path for type detection
const GROUP_WINDOW_SCENE = "res://scenes/windows/window_group.tscn"


func _init() -> void:
    ModLoaderLog.info("Initializing", MOD_NAME)


func _ready() -> void:
    Signals.connection_droppped.connect(_on_connection_dropped)
    # Note: We don't connect to delete_connection here because the game's
    # ResourceContainer already handles it. Connecting here would cause
    # double remove_output calls and potential signal disconnect crashes.
    ModLoaderLog.info("Ready - v%s" % MOD_VERSION, MOD_NAME)


func _log_debug(message: String) -> void:
    if DEBUG_MODE:
        ModLoaderLog.info("[DEBUG] %s" % message, MOD_NAME)


# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_connection_dropped(source_id: String, source_type: int) -> void:
    if source_id.is_empty():
        _log_debug("Skipped: source_id is empty")
        return

    # Validate desktop is ready
    if not is_instance_valid(Globals.desktop):
        _log_debug("Skipped: Globals.desktop is not valid")
        return

    var target_window := _get_window_at_mouse()
    if not target_window:
        _log_debug("Skipped: no target window at mouse position")
        return

    # Don't smart-connect if user is hovering over a connector button
    # (let the game's native connector_button handler deal with it)
    if _is_hovering_connector(target_window):
        _log_debug("Skipped: hovering over connector in target window")
        return

    # Find source container - try direct lookup first, then fallback to scene search
    var source := _find_container_by_id(source_id)
    if not is_instance_valid(source):
        _log_debug("Skipped: could not find source container with id '%s'" % source_id)
        return

    # Don't smart-connect within the same window
    var source_window := _get_window_from_container(source)
    if source_window == target_window:
        _log_debug("Skipped: source and target are the same window")
        return

    # If target is a group window (empty containers), find the actual window inside it
    if _is_group_window(target_window):
        _log_debug("Target '%s' is a group window, looking for enclosed windows..." % target_window.name)
        var enclosed_window := _get_window_inside_group(target_window, source_window)
        if enclosed_window:
            _log_debug("Found enclosed window: '%s'" % enclosed_window.name)
            target_window = enclosed_window
        else:
            _log_debug("No valid enclosed window found in group")
            return

    _attempt_smart_connection(source, source_type, target_window)

# =============================================================================
# CONNECTION LOGIC
# =============================================================================

func _attempt_smart_connection(source: ResourceContainer, source_type: int, target_window: WindowBase) -> void:
    var target := _find_compatible_container(source, source_type, target_window)
    if not target:
        _log_debug("No compatible container found in target window '%s'" % target_window.name)
        return

    _log_debug("Found compatible target: %s (id: %s)" % [target.name, target.id])

    # Create connection with correct direction
    # Handle 1-to-1 input connections: delete existing connection first if present
    # Use call_deferred to let the game's connector_button handlers run first,
    # preventing duplicate connections when dropping directly on a connector
    if source_type == Utils.connections_types.OUTPUT:
        # Source OUTPUT -> Target INPUT
        # Skip if already connected to this exact source (avoid unnecessary delete+recreate)
        if target.input_id == source.id:
            _log_debug("Skipped: already connected")
            return
        if not target.input_id.is_empty():
            # Target already has an input, delete the old connection first
            _delete_connection(target.input_id, target.id)
        _create_connection.call_deferred(source.id, target.id)
    elif source_type == Utils.connections_types.INPUT:
        # Target OUTPUT -> Source INPUT
        # Skip if already connected to this exact source (avoid unnecessary delete+recreate)
        if source.input_id == target.id:
            _log_debug("Skipped: already connected")
            return
        if not source.input_id.is_empty():
            # Source already has an input, delete the old connection first
            _delete_connection(source.input_id, source.id)
        _create_connection.call_deferred(target.id, source.id)


func _find_compatible_container(source: ResourceContainer, source_type: int, window: WindowBase) -> ResourceContainer:
    if not "containers" in window:
        _log_debug("Window '%s' has no 'containers' property" % window.name)
        return null

    var containers = window.get("containers")
    if not containers or containers.is_empty():
        _log_debug("Window '%s' containers array is empty" % window.name)
        return null

    _log_debug("Checking %d containers in window '%s'" % [containers.size(), window.name])

    for container in containers:
        # Skip invalid containers (might have been freed)
        if not is_instance_valid(container):
            _log_debug("  - Skipped invalid container")
            continue
        var can_conn := _can_connect(source, container, source_type)
        _log_debug("  - Container '%s' (id: %s): can_connect=%s" % [container.name, container.id, can_conn])
        if can_conn:
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


## Find a container by ID, with fallback to scanning all windows if direct lookup fails.
## This handles cases where the resources dictionary might be out of sync (e.g., after portal).
func _find_container_by_id(container_id: String) -> ResourceContainer:
    # First try direct lookup from desktop resources dictionary
    var container := Globals.desktop.get_resource(container_id)
    if is_instance_valid(container):
        return container

    _log_debug("Direct lookup failed for '%s', trying scene scan..." % container_id)

    # Fallback: scan all windows for a container with matching ID
    var windows_node := Globals.desktop.get_node_or_null("Windows")
    if not windows_node:
        return null

    for window in windows_node.get_children():
        if not window is WindowBase:
            continue
        if not "containers" in window:
            continue
        var containers = window.get("containers")
        if not containers:
            continue
        for cont in containers:
            if is_instance_valid(cont) and cont.id == container_id:
                _log_debug("Found container via scene scan in window '%s'" % window.name)
                # Re-register the container to fix the resources dictionary
                _try_reregister_container(cont)
                return cont

    return null


## Try to re-register a container that might be missing from the resources dictionary.
func _try_reregister_container(container: ResourceContainer) -> void:
    if not is_instance_valid(container):
        return
    var existing := Globals.desktop.get_resource(container.id)
    if not is_instance_valid(existing):
        _log_debug("Re-registering container '%s'" % container.id)
        Signals.register_resource.emit(container.id, container)


## Get the parent window of a container by walking up the scene tree.
func _get_window_from_container(container: ResourceContainer) -> WindowBase:
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


## Check if a window is a group window (visual container with no resource containers).
func _is_group_window(window: WindowBase) -> bool:
    if not is_instance_valid(window):
        return false
    # Check if it's the group window scene type
    if window.scene_file_path == GROUP_WINDOW_SCENE:
        return true
    # Fallback: check if it has empty containers (groups don't have ResourceContainers)
    if "containers" in window:
        var containers = window.get("containers")
        if containers == null or containers.is_empty():
            # Also verify it's not just an uninitialized window by checking the name pattern
            if window.name.begins_with("group"):
                return true
    return false


## Find the topmost window inside a group that's under the mouse cursor.
## Excludes the source window to prevent self-connections.
## Handles nested groups recursively.
func _get_window_inside_group(group_window: WindowBase, source_window: WindowBase) -> WindowBase:
    if not is_instance_valid(Globals.desktop):
        return null

    var mouse_pos := Globals.desktop.get_global_mouse_position()
    var windows_node := Globals.desktop.get_node_or_null("Windows")
    if not windows_node:
        return null

    var group_rect := Rect2(group_window.global_position, group_window.size)
    var best_window: WindowBase = null
    var best_z_index: int = -1

    # Find all windows that are inside the group and under the mouse
    var children := windows_node.get_children()
    for i in range(children.size()):
        var window = children[i]
        if not window is WindowBase:
            continue
        if window == group_window:
            continue
        if window == source_window:
            continue

        # Check if window is enclosed by the group
        var window_rect := Rect2(window.global_position, window.size)
        if not group_rect.encloses(window_rect):
            continue

        # Check if mouse is over this window
        if not _is_point_in_window(window, mouse_pos):
            continue

        # If this is a nested group, recursively search inside it
        if _is_group_window(window):
            _log_debug("  Found nested group '%s', searching inside..." % window.name)
            var nested_result := _get_window_inside_group(window, source_window)
            if nested_result:
                # Use this result if it has a higher z-index
                var nested_index := windows_node.get_children().find(nested_result)
                if nested_index > best_z_index:
                    best_z_index = nested_index
                    best_window = nested_result
            continue

        # Check if window has containers
        if not "containers" in window:
            continue
        var containers = window.get("containers")
        if not containers or containers.is_empty():
            continue

        # Use the child index as a proxy for z-order (later = on top)
        if i > best_z_index:
            best_z_index = i
            best_window = window

    return best_window
