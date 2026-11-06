class_name ToolBar
extends PanelContainer
## Колонка инструментов слева. Если по высоте не помещается — в две колонки.

const TOOLS: Array[Dictionary] = [
	{"tool": AppState.Tool.BRUSH, "icon": "brush", "tip": "Кисть: рисует материалом"},
	{"tool": AppState.Tool.ERASER, "icon": "eraser", "tip": "Ластик (ПКМ — всегда ластик)"},
	{"tool": AppState.Tool.HEAT, "icon": "heat", "tip": "Нагрев"},
	{"tool": AppState.Tool.COOL, "icon": "cool", "tip": "Охлаждение"},
	{"tool": AppState.Tool.NEUTRON, "icon": "neutron", "tip": "Источник нейтронов"},
]

var state: AppState
var _grid: GridContainer
var _buttons: Array[Button] = []


func setup(app_state: AppState) -> void:
	state = app_state
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme_type_variation = &"CompactPanel"
	_grid = GridContainer.new()
	_grid.columns = 1
	_grid.add_theme_constant_override("h_separation", UiKit.GAP)
	_grid.add_theme_constant_override("v_separation", UiKit.GAP)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_grid)
	var group := ButtonGroup.new()
	for t in TOOLS:
		var b := UiKit.icon_button(str(t["icon"]), str(t["tip"]), true)
		b.button_group = group
		b.pressed.connect(_on_tool.bind(int(t["tool"])))
		_grid.add_child(b)
		_buttons.append(b)
	sync()


func sync() -> void:
	for i in _buttons.size():
		_buttons[i].set_pressed_no_signal(int(TOOLS[i]["tool"]) == state.tool)


## Подобрать число колонок под доступную высоту.
func fit_height(avail: float) -> void:
	var n := _buttons.size()
	var cols := 1
	while cols < n:
		var rows := ceili(float(n) / float(cols))
		var need := rows * UiKit.TOUCH + (rows - 1) * UiKit.GAP + 10.0
		if need <= avail:
			break
		cols += 1
	if _grid.columns != cols:
		_grid.columns = cols
		reset_size()


func _on_tool(t: int) -> void:
	state.tool = t as AppState.Tool
	state.notify()
