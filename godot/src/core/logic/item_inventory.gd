class_name ItemInventory
extends RefCounted
## Generic inventory system — renderer-free and reusable across every subgame.
## Port of `src/game/inventory.ts`.
##
## A game registers an `ItemCatalog` (what items exist, how they stack, which
## slot they occupy and what stats they grant) and then drives one or more
## `ItemInventory` instances. All rules — stacking, moving, splitting,
## equipment, currency, weight and persistence — live here.
##
## Design goals (why the code looks the way it does):
##  - never throw on invalid input (bad indices / counts simply do nothing)
##  - never lose an item silently: every mutation returns what actually happened
##  - mutations are coarse (a click or a transfer), so small allocations are fine

signal changed(event: String)

const RARITY_ORDER := {"common": 0, "uncommon": 1, "rare": 2, "epic": 3, "legendary": 4}
const EQUIP_SLOTS := ["weapon", "offhand", "head", "chest", "legs", "feet", "hands", "ring", "amulet"]
const SNAPSHOT_VERSION := 1


class ItemStack:
	extends RefCounted
	var id: String
	var count: int
	## Optional per-stack state such as durability, charges or an enchantment.
	var data: Dictionary = {}

	func _init(item_id: String = "", item_count: int = 0, stack_data: Dictionary = {}) -> void:
		id = item_id
		count = item_count
		data = stack_data.duplicate()

	func clone() -> ItemStack:
		return ItemStack.new(id, count, data)

	## Plain, JSON-safe representation. Snapshots must not embed live objects,
	## otherwise they neither survive `JSON.stringify` nor `_sanitize()`.
	func to_dict() -> Dictionary:
		var out := {"id": id, "count": count}
		if not data.is_empty():
			out["data"] = data.duplicate()
		return out

	func _to_string() -> String:
		return "%s x%d" % [id, count]


static func is_equip_slot(value: String) -> bool:
	return value in EQUIP_SLOTS


static func is_rarity(value: String) -> bool:
	return RARITY_ORDER.has(value)


static func stack_data_equals(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key) or float(a[key]) != float(b[key]):
			return false
	return true


## True when two stacks can be merged into one (same id + same data).
static func stacks_mergeable(a: ItemStack, b: ItemStack) -> bool:
	return a.id == b.id and stack_data_equals(a.data, b.data)


## Registry of item definitions shared by every inventory of a game.
class Catalog:
	extends RefCounted
	var _items: Dictionary = {}

	func _init(definitions: Array = []) -> void:
		for def in definitions:
			register(def)

	func register(def: Dictionary) -> Dictionary:
		var normalized := normalize(def)
		_items[normalized["id"]] = normalized
		return normalized

	static func normalize(def: Dictionary) -> Dictionary:
		return {
			"id": str(def.get("id", "")),
			"name": str(def.get("name", "")),
			"description": str(def.get("description", "")),
			"icon": str(def.get("icon", "")),
			"rarity": str(def.get("rarity", "common")),
			"maxStack": maxi(1, int(def.get("maxStack", 1))),
			"slot": str(def.get("slot", "")),
			"stats": def.get("stats", {}),
			"weight": float(def.get("weight", 0.0)),
			"value": float(def.get("value", 0.0)),
			"tags": def.get("tags", []),
			"effect": def.get("effect", {}),
		}

	func has(id: String) -> bool:
		return _items.has(id)

	func size() -> int:
		return _items.size()

	## Registered definition or a safe fallback (never empty).
	func require(id: String) -> Dictionary:
		if _items.has(id):
			return _items[id]
		return normalize({"id": id, "name": id})

	func all() -> Array:
		return _items.values()

	func by_rarity(rarity: String) -> Array:
		return _items.values().filter(func(item: Dictionary) -> bool: return str(item["rarity"]) == rarity)

	func by_slot(slot: String) -> Array:
		return _items.values().filter(func(item: Dictionary) -> bool: return str(item["slot"]) == slot)

	func by_tag(tag: String) -> Array:
		return _items.values().filter(func(item: Dictionary) -> bool: return (item["tags"] as Array).has(tag))


var catalog: Catalog
var _capacity: int = 20
var _slots: Array = []
var _equipped: Dictionary = {}
var _gold: int = 0


func _init(options: Dictionary = {}) -> void:
	catalog = options.get("catalog", Catalog.new())
	_capacity = maxi(0, int(options.get("capacity", 20)))
	_slots = []
	_slots.resize(_capacity)
	for i in _capacity:
		_slots[i] = null
	for slot in EQUIP_SLOTS:
		_equipped[slot] = null
	_gold = maxi(0, int(options.get("currency", 0)))


# --- slots & queries --------------------------------------------------------

func capacity() -> int:
	return _capacity


func slots() -> Array:
	return _slots


func used_slots() -> int:
	var used := 0
	for stack in _slots:
		if stack != null:
			used += 1
	return used


func free_slots() -> int:
	return _capacity - used_slots()


func is_empty() -> bool:
	return used_slots() == 0


func is_full() -> bool:
	return used_slots() >= _capacity


## Stack at `index`, or `null` for an out-of-range/empty slot.
func get_slot(index: int) -> ItemStack:
	if not _valid(index):
		return null
	return _slots[index]


## First slot index holding `id`, or -1.
func find_item(id: String) -> int:
	for i in _slots.size():
		var stack: ItemStack = _slots[i]
		if stack != null and stack.id == id:
			return i
	return -1


func find_index(predicate: Callable) -> int:
	for i in _slots.size():
		var stack: ItemStack = _slots[i]
		if stack != null and predicate.call(stack, i):
			return i
	return -1


func find(predicate: Callable) -> ItemStack:
	var index := find_index(predicate)
	return _slots[index] if index >= 0 else null


## First empty slot index, or -1 when the inventory is full.
func first_empty() -> int:
	for i in _slots.size():
		if _slots[i] == null:
			return i
	return -1


## Total units of `id` across all slots.
func count(id: String) -> int:
	var total := 0
	for stack in _slots:
		if stack != null and stack.id == id:
			total += stack.count
	return total


func has(id: String, amount: int = 1) -> bool:
	return amount <= 0 or count(id) >= amount


## All stacks, in slot order, without the empty slots.
func stacks() -> Array:
	var result: Array = []
	for stack in _slots:
		if stack != null:
			result.append(stack)
	return result


func max_stack(id: String) -> int:
	return int(catalog.require(id)["maxStack"])


# --- adding -----------------------------------------------------------------

## Adds `amount` units of `id`, filling partial stacks first. Returns how many
## were added and how many remain.
func add(id: String, amount: int = 1, data: Dictionary = {}) -> Dictionary:
	var total: int = maxi(0, amount)
	if total <= 0:
		return {"added": 0, "remaining": 0}
	var limit := max_stack(id)
	var remaining := total
	var added := 0

	for i in _slots.size():
		if remaining <= 0:
			break
		var stack: ItemStack = _slots[i]
		if stack == null or stack.id != id or not stack_data_equals(stack.data, data):
			continue
		var room: int = limit - stack.count
		if room <= 0:
			continue
		var put: int = mini(room, remaining)
		stack.count += put
		remaining -= put
		added += put

	for i in _slots.size():
		if remaining <= 0:
			break
		if _slots[i] != null:
			continue
		var put: int = mini(limit, remaining)
		_slots[i] = ItemStack.new(id, put, data)
		remaining -= put
		added += put

	if added > 0:
		changed.emit("add")
	return {"added": added, "remaining": remaining}


func add_stack(stack: ItemStack) -> Dictionary:
	return add(stack.id, stack.count, stack.data)


# --- removing ---------------------------------------------------------------

## Removes up to `amount` units of `id` (highest slot index first).
func remove(id: String, amount: int = 1) -> int:
	var total: int = maxi(0, amount)
	if total <= 0:
		return 0
	var remaining := total
	for i in range(_slots.size() - 1, -1, -1):
		if remaining <= 0:
			break
		var stack: ItemStack = _slots[i]
		if stack == null or stack.id != id:
			continue
		var take: int = mini(stack.count, remaining)
		stack.count -= take
		remaining -= take
		if stack.count <= 0:
			_slots[i] = null
	var removed := total - remaining
	if removed > 0:
		changed.emit("remove")
	return removed


## Removes up to `amount` units from one slot.
func remove_at(index: int, amount: int = -1) -> ItemStack:
	if not _valid(index):
		return null
	var stack: ItemStack = _slots[index]
	if stack == null:
		return null
	var take: int = stack.count if amount < 0 else amount
	if take <= 0:
		return null
	var removed := ItemStack.new(stack.id, mini(take, stack.count), stack.data)
	var left := stack.count - removed.count
	if left <= 0:
		_slots[index] = null
	else:
		stack.count = left
	changed.emit("remove")
	return removed


## Directly sets a slot (used by editors / save loading).
func set_slot(index: int, stack: ItemStack) -> bool:
	if not _valid(index):
		return false
	_slots[index] = stack.clone() if stack != null else null
	changed.emit("change")
	return true


func clear() -> void:
	if is_empty():
		return
	for i in _slots.size():
		_slots[i] = null
	changed.emit("clear")


# --- moving / splitting -----------------------------------------------------

## Moves the stack at `from` to `to`. Same-id stacks merge (as much as fits);
## otherwise the two slots swap.
func move(from: int, to: int) -> bool:
	if not _valid(from) or not _valid(to) or from == to:
		return false
	var source: ItemStack = _slots[from]
	if source == null:
		return false
	var target: ItemStack = _slots[to]

	if target != null and stacks_mergeable(source, target):
		var room: int = max_stack(source.id) - target.count
		if room <= 0:
			return false
		var moved: int = mini(room, source.count)
		target.count += moved
		source.count -= moved
		if source.count <= 0:
			_slots[from] = null
		changed.emit("move")
		return true

	_slots[from] = target
	_slots[to] = source
	changed.emit("move")
	return true


## Swaps two slots unconditionally (both may be empty).
func swap(a: int, b: int) -> bool:
	if not _valid(a) or not _valid(b) or a == b:
		return false
	var tmp: ItemStack = _slots[a]
	_slots[a] = _slots[b]
	_slots[b] = tmp
	changed.emit("move")
	return true


## Splits `amount` units off the stack at `index` into the first free slot.
## Returns the new slot index, or -1 on failure.
func split(index: int, amount: int) -> int:
	if not _valid(index):
		return -1
	var stack: ItemStack = _slots[index]
	if stack == null:
		return -1
	var take := amount
	if take <= 0 or take >= stack.count:
		return -1
	var free := first_empty()
	if free < 0:
		return -1
	stack.count -= take
	_slots[free] = ItemStack.new(stack.id, take, stack.data)
	changed.emit("move")
	return free


## Moves `amount` units from one slot to another, merging/creating as needed.
func move_amount(from: int, to: int, amount: int) -> int:
	if not _valid(from) or not _valid(to) or from == to:
		return 0
	var source: ItemStack = _slots[from]
	if source == null:
		return 0
	var take: int = clampi(amount, 0, source.count)
	if take <= 0:
		return 0
	var target: ItemStack = _slots[to]
	if target != null and not stacks_mergeable(source, target):
		return 0

	var moved: int
	if target != null:
		var room: int = max_stack(source.id) - target.count
		moved = mini(room, take)
		if moved <= 0:
			return 0
		target.count += moved
	else:
		moved = take
		_slots[to] = ItemStack.new(source.id, moved, source.data)
	source.count -= moved
	if source.count <= 0:
		_slots[from] = null
	changed.emit("move")
	return moved


# --- sorting / compacting ---------------------------------------------------

## Removes gaps between stacks while keeping their relative order.
func compact() -> void:
	var write := 0
	var did_change := false
	for read in _slots.size():
		var stack: ItemStack = _slots[read]
		if stack == null:
			continue
		if read != write:
			_slots[write] = stack
			_slots[read] = null
			did_change = true
		write += 1
	if did_change:
		changed.emit("move")


## Sorts occupied stacks to the front; the default order is rarity (highest
## first), then name, then id — deterministic and locale-independent.
func sort(compare: Callable = Callable()) -> void:
	var filled: Array = []
	for stack in _slots:
		if stack != null:
			filled.append(stack)
	if compare.is_null():
		filled.sort_custom(_default_compare)
	else:
		filled.sort_custom(compare)
	for i in _slots.size():
		_slots[i] = filled[i] if i < filled.size() else null
	changed.emit("move")


func _default_compare(a: ItemStack, b: ItemStack) -> bool:
	var def_a: Dictionary = catalog.require(a.id)
	var def_b: Dictionary = catalog.require(b.id)
	if str(def_a["rarity"]) != str(def_b["rarity"]):
		return int(RARITY_ORDER[def_b["rarity"]]) < int(RARITY_ORDER[def_a["rarity"]])
	if str(def_a["name"]) != str(def_b["name"]):
		return str(def_a["name"]) < str(def_b["name"])
	return a.id < b.id


# --- weight & value ---------------------------------------------------------

func total_weight(include_equipment: bool = true) -> float:
	var weight := 0.0
	for stack in _slots:
		if stack != null:
			weight += float(catalog.require(stack.id)["weight"]) * float(stack.count)
	if include_equipment:
		for slot in EQUIP_SLOTS:
			var stack: ItemStack = _equipped[slot]
			if stack != null:
				weight += float(catalog.require(stack.id)["weight"]) * float(stack.count)
	return weight


func total_value(include_equipment: bool = true) -> float:
	var value := 0.0
	for stack in _slots:
		if stack != null:
			value += float(catalog.require(stack.id)["value"]) * float(stack.count)
	if include_equipment:
		for slot in EQUIP_SLOTS:
			var stack: ItemStack = _equipped[slot]
			if stack != null:
				value += float(catalog.require(stack.id)["value"]) * float(stack.count)
	return value


# --- currency ---------------------------------------------------------------

func currency() -> int:
	return _gold


func set_currency(value: int) -> void:
	var next: int = maxi(0, value)
	if next == _gold:
		return
	_gold = next
	changed.emit("currency")


## Adds (or, with a negative amount, subtracts) currency; never goes below 0.
func add_currency(amount: int) -> int:
	if amount == 0:
		return _gold
	_gold = maxi(0, _gold + amount)
	changed.emit("currency")
	return _gold


## Spends currency; returns false (and changes nothing) when too poor.
func spend(amount: int) -> bool:
	if amount < 0 or _gold < amount:
		return false
	if amount == 0:
		return true
	_gold -= amount
	changed.emit("currency")
	return true


# --- equipment --------------------------------------------------------------

## Equipped stack for a slot, or `null`.
func equipped_in(slot: String) -> ItemStack:
	return _equipped.get(slot, null)


## Snapshot of all equipped stacks (only non-empty slots are present).
func equipment() -> Dictionary:
	var result: Dictionary = {}
	for slot in EQUIP_SLOTS:
		var stack: ItemStack = _equipped[slot]
		if stack != null:
			result[slot] = stack.to_dict()
	return result


## Whether the stack at `index` exists and declares an equipment slot.
func can_equip(index: int) -> bool:
	var stack := get_slot(index)
	if stack == null:
		return false
	return str(catalog.require(stack.id)["slot"]) != ""


## Equips the item at `index`. An already-equipped item is swapped back into the
## freed slot, so nothing is ever lost.
func equip(index: int) -> bool:
	if not _valid(index):
		return false
	var stack: ItemStack = _slots[index]
	if stack == null:
		return false
	var slot := str(catalog.require(stack.id)["slot"])
	if slot == "":
		return false
	_slots[index] = null
	var previous: ItemStack = _equipped[slot]
	_equipped[slot] = stack
	if previous != null:
		_slots[index] = previous
	changed.emit("equip")
	return true


## Moves an equipped item back into the first free slot.
func unequip(slot: String) -> bool:
	var stack: ItemStack = _equipped.get(slot, null)
	if stack == null:
		return false
	var free := first_empty()
	if free < 0:
		return false
	_equipped[slot] = null
	_slots[free] = stack
	changed.emit("unequip")
	return true


## Sum of all numeric modifiers granted by equipped items.
func equipment_stats() -> Dictionary:
	var result: Dictionary = {}
	for slot in EQUIP_SLOTS:
		var stack: ItemStack = _equipped[slot]
		if stack == null:
			continue
		var stats: Dictionary = catalog.require(stack.id)["stats"]
		for key in stats:
			result[key] = float(result.get(key, 0.0)) + float(stats[key])
	return result


## Single aggregated modifier value (0 when nothing grants it).
func equipment_stat(key: String) -> float:
	var value := 0.0
	for slot in EQUIP_SLOTS:
		var stack: ItemStack = _equipped[slot]
		if stack == null:
			continue
		value += float((catalog.require(stack.id)["stats"] as Dictionary).get(key, 0.0))
	return value


# --- transferring -----------------------------------------------------------

## Moves up to `amount` units of `id` into another inventory.
func transfer_to(target: ItemInventory, id: String, amount: int = 1) -> int:
	var moved := 0
	for i in range(_slots.size() - 1, -1, -1):
		if moved >= amount:
			break
		var stack: ItemStack = _slots[i]
		if stack == null or stack.id != id:
			continue
		var want: int = mini(stack.count, amount - moved)
		var result: Dictionary = target.add(id, want, stack.data)
		if int(result["added"]) <= 0:
			break
		stack.count -= int(result["added"])
		if stack.count <= 0:
			_slots[i] = null
		moved += int(result["added"])
	if moved > 0:
		changed.emit("remove")
	return moved


## Moves a whole slot into another inventory.
func transfer_stack_to(target: ItemInventory, index: int) -> int:
	if not _valid(index):
		return 0
	var stack: ItemStack = _slots[index]
	if stack == null:
		return 0
	var result: Dictionary = target.add(stack.id, stack.count, stack.data)
	if int(result["added"]) <= 0:
		return 0
	stack.count -= int(result["added"])
	if stack.count <= 0:
		_slots[index] = null
	changed.emit("remove")
	return int(result["added"])


# --- persistence ------------------------------------------------------------

## Immutable, JSON-safe snapshot of the whole inventory.
func to_json() -> Dictionary:
	var slot_list: Array = []
	for stack in _slots:
		slot_list.append(null if stack == null else stack.to_dict())
	return {
		"version": SNAPSHOT_VERSION,
		"capacity": _capacity,
		"currency": _gold,
		"slots": slot_list,
		"equipment": equipment(),
	}


## Restores a snapshot. Malformed entries are skipped instead of throwing, so a
## corrupt save can never crash the game.
func load_json(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var capacity: int = maxi(0, int(snapshot.get("capacity", _capacity)))
	resize(capacity)

	var saved: Array = snapshot.get("slots", [])
	for i in _slots.size():
		_slots[i] = _sanitize(saved[i] if i < saved.size() else null)

	var saved_equipment: Dictionary = snapshot.get("equipment", {})
	for slot in EQUIP_SLOTS:
		_equipped[slot] = _sanitize(saved_equipment.get(slot, null))

	_gold = maxi(0, int(snapshot.get("currency", 0)))
	changed.emit("change")


static func from_json(options: Dictionary, snapshot: Dictionary) -> ItemInventory:
	var inventory := ItemInventory.new(options)
	inventory.load_json(snapshot)
	return inventory


## Changes the slot count; items in removed slots are dropped, never shifted.
func resize(capacity: int) -> bool:
	var next: int = maxi(0, capacity)
	if next == _capacity:
		return false
	for i in range(_capacity, next):
		_slots.append(null)
	_slots.resize(next)
	_capacity = next
	changed.emit("change")
	return true


func _valid(index: int) -> bool:
	return index >= 0 and index < _slots.size()


## Validates one untrusted stack from a save file.
static func _sanitize(value: Variant) -> ItemStack:
	# Accept a live stack as well, so a snapshot taken in memory restores
	# instead of silently emptying the inventory.
	if value is ItemStack:
		var stack: ItemStack = value
		return stack.clone() if stack.count > 0 else null
	if not (value is Dictionary):
		return null
	var dict: Dictionary = value
	var id := str(dict.get("id", ""))
	if id.length() == 0:
		return null
	var count := int(dict.get("count", 0))
	if count <= 0:
		return null
	var data: Dictionary = {}
	var raw: Variant = dict.get("data", {})
	if raw is Dictionary:
		for key in raw:
			var entry: Variant = (raw as Dictionary)[key]
			if entry is int or entry is float:
				data[key] = float(entry)
	return ItemStack.new(id, count, data)
