extends Node

const MOD_NAME_LOG = "SmartConnections"

var currently_hovered_window: WindowBase = null
var is_dragging_connection: bool = false

func _init():
    ModLoaderLog.info("Initializing Smart Connections mod", MOD_NAME_LOG)

func _ready():
    # Connect to connection signals to track when we're dragging
    Signals.connection_set.connect(_on_connection_state_changed)
    Signals.connection_droppped.connect(_on_connection_dropped)
    
    # Hook into all window mouse enter/exit events
    setup_window_hover_detection()
    
    ModLoaderLog.info("Smart Connections mod ready", MOD_NAME_LOG)

func setup_window_hover_detection():
    # Wait for desktop to be ready, then setup hover detection on all windows
    if Signals.desktop_ready.is_connected(_on_desktop_ready):
        return
    Signals.desktop_ready.connect(_on_desktop_ready)
    
    # Also listen for new windows being created
    Signals.window_initialized.connect(_on_window_initialized)

func _on_desktop_ready():
    # Setup hover detection for existing windows
    for window in get_all_windows():
        setup_window_hover(window)

func _on_window_initialized(window: WindowBase):
    # Setup hover detection for newly created windows
    setup_window_hover(window)

func get_all_windows() -> Array:
    var windows = []
    if Globals.desktop:
        # Windows are inside the "Windows" container, not direct children of desktop
        var windows_container = Globals.desktop.get_node_or_null("Windows")
        if windows_container:
            for child in windows_container.get_children():
                if child is WindowBase:
                    windows.append(child)
    return windows

func setup_window_hover(window: WindowBase):
    if not window:
        return
        
    # Connect mouse enter/exit signals for the window
    if not window.mouse_entered.is_connected(_on_window_mouse_entered.bind(window)):
        window.mouse_entered.connect(_on_window_mouse_entered.bind(window))
    
    if not window.mouse_exited.is_connected(_on_window_mouse_exited.bind(window)):
        window.mouse_exited.connect(_on_window_mouse_exited.bind(window))

func _on_window_mouse_entered(window: WindowBase):
    currently_hovered_window = window

func _on_window_mouse_exited(window: WindowBase):
    if currently_hovered_window == window:
        currently_hovered_window = null

func get_window_at_mouse_position() -> WindowBase:
    if not Globals.desktop:
        return null

    # Use global mouse position to match the coordinate system windows use
    var mouse_pos = Globals.desktop.get_global_mouse_position()

    # Check all windows to see if the mouse is over any of them
    # Go in reverse order to check top windows first
    var windows = get_all_windows()

    for i in range(windows.size() - 1, -1, -1):
        var window = windows[i]
        if is_mouse_over_window(window, mouse_pos):
            return window

    return null

func is_mouse_over_window(window: WindowBase, mouse_pos: Vector2) -> bool:
    # Calculate the window's rect from its position and size
    var window_rect = Rect2(window.global_position, window.size)
    return window_rect.has_point(mouse_pos)

func _on_connection_state_changed():
    # Update dragging state based on global connection state
    is_dragging_connection = !Globals.connecting.is_empty()

func _on_connection_dropped(connection_id: String, connection_type: int):
    # Find which window is under the mouse cursor
    var window_under_mouse = get_window_at_mouse_position()

    # If there's a window under the mouse while dropping a connection, try to auto-connect
    if window_under_mouse and not connection_id.is_empty():
        attempt_smart_connection(connection_id, connection_type, window_under_mouse)

func attempt_smart_connection(source_id: String, source_type: int, target_window: WindowBase):
    var source_container = Globals.desktop.get_resource(source_id)
    if not source_container:
        return

    # Find a compatible connector on the target window
    var target_container = find_compatible_connector(source_container, source_type, target_window)

    if target_container:
        # Create the connection
        if source_type == Utils.connections_types.OUTPUT:
            # Source is output, target should be input
            if target_container.input_id.is_empty() or can_replace_connection(target_container):
                create_connection(source_id, target_container.id)
        else:
            # Source is input, target should be output
            create_connection(target_container.id, source_id)

func find_compatible_connector(source_container: ResourceContainer, source_type: int, target_window: WindowBase) -> ResourceContainer:
    # Look through all containers in the target window
    for container in target_window.containers:
        if can_containers_connect(source_container, container, source_type):
            return container
    
    return null

func can_containers_connect(source: ResourceContainer, target: ResourceContainer, source_type: int) -> bool:
    # Prevent self-connections - a container cannot connect to itself
    if source.id == target.id:
        return false

    # Determine the connection direction
    if source_type == Utils.connections_types.OUTPUT:
        # Source is output, target should be input
        if not target.input_id.is_empty() and not can_replace_connection(target):
            return false
        return source.can_connect(target)
    else:
        # Source is input, target should be output
        if target.get_connector_color() == "black":  # No output
            return false
        return target.can_connect(source)

func can_replace_connection(container: ResourceContainer) -> bool:
    # Allow replacing connections if the user preference allows it
    # For now, we'll be conservative and not replace existing connections
    return false

func create_connection(output_id: String, input_id: String):
    # Use the game's existing connection creation system
    Signals.create_connection.emit(output_id, input_id)
    
    # Play connection sound
    Sound.play("connect")
    
    # Log the smart connection
    ModLoaderLog.info("Smart connection created: %s -> %s" % [output_id, input_id], MOD_NAME_LOG)
