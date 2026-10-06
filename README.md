# lush

A small, fast object-oriented programming library for Lua / LuaJIT with **multiple inheritance**, **C3 linearization**, cached method resolution, a `super` mechanism that works in diamond hierarchies, and **runtime-changeable inheritance**.

**Version:** 1.0

## Features

- Single and multiple inheritance, resolved with the C3 method resolution order (MRO), the same algorithm used by Python.
- Cooperative `super` that follows the MRO instead of naively calling "the parent".
- Fast lookups: resolved keys are memoized per class and automatically invalidated when a class changes.
- Classes can be modified at runtime. Adding, replacing, or removing a member updates every affected subclass.
- Inheritance can be rewired at runtime with automatic rollback if the new hierarchy is invalid.
- Metamethod support (`__tostring`, `__eq`, `__add`, ...).
- Subclass tracking uses weak references, so unused subclasses can be garbage collected.
- Safe on LuaJIT (guards against `cdata` triggering `__eq` when compared to `nil`).
- Zero dependencies, one file.

## Installation

Copy the file into your project and require it:

```lua
local lush = require("lush")
```

## Quick start

```lua
local lush = require("lush")

local Animal = lush.class(lush.Object)

function Animal.init(self, name)
    self.name = name
end

function Animal.speak(self)
    return self.name .. " makes a sound"
end

local Dog = lush.class(Animal)

function Dog.init(self, name, breed)
    lush.super(Dog, self).init(self, name)
    self.breed = breed
end

function Dog.speak(self)
    return lush.super(Dog, self).speak(self) .. ": woof!"
end

local rex = Dog:new("Rex", "Husky")
print(rex:speak())   --> Rex makes a sound: woof!
```

## API

The module returns a table with three members:

| Member | Description |
| --- | --- |
| `lush.class(...)` | Creates a new class that inherits from the given superclasses. |
| `lush.super(currentclass, instance)` | Returns the next declarations after `currentclass` in the MRO. |
| `lush.Object` | An optional root class providing `init` and `new`. |

### `lush.class(...)`

Creates and returns a class. Pass zero or more classes as superclasses, in priority order from left to right.

```lua
local A = lush.class()                -- no superclass, no Object
local B = lush.class(lush.Object)     -- single inheritance
local C = lush.class(B, SomeMixin)    -- multiple inheritance
```

Define members by assigning to the class. Reads fall through the MRO automatically.

```lua
function B.greet(self) return "hi" end
B.max_hp = 100                        -- non-function values are inherited too
```

Errors raised while creating a class:

| Error | Cause |
| --- | --- |
| `invalid superclass at argument N` | Argument N is not a lush class. |
| `redundant inheritance` | A listed superclass is already an ancestor of another listed superclass. |
| `cannot find a resolution for multiple inheritance` | The hierarchy has no consistent C3 order. |
| `cyclic inheritance` | The class would end up as its own ancestor. |

### `lush.Object`

A root class you can opt into. It is not required, but gives you the standard construction flow:

```lua
function Object.init(instance) end

function Object.new(class, ...)
    -- creates an instance, then calls init(instance, ...)
end
```

Create instances with `Class:new(...)`. Override `init` to set up your fields. If you create classes without `lush.Object`, you must provide your own `new`/`init` (or similar) construction logic. An instance's metatable is the class's resolved cache, so `instance.__class` gives you its class.

### `lush.super(currentclass, instance)`

Returns a table that resolves keys using only the classes **after** `currentclass` in the instance's MRO.

```lua
lush.super(Dog, self).speak(self)
```

Pass the class where the calling method is **defined**, not `self.__class`, otherwise subclasses would recurse infinitely.

You can pass either an instance or a class as the second argument.

Return values:

| Value | Meaning |
| --- | --- |
| a table | The rest of the MRO. Index it to find the next implementation. |
| `false` | `currentclass` is the last class in the MRO, so there is nothing above it. |
| `nil` | `currentclass` is not in the MRO of `instance` at all. |

Because of the `nil` case, `super` doubles as an `instanceof` check:

```lua
local function instanceof(obj, class)
    return lush.super(class, obj) ~= nil
end

print(instanceof(rex, Animal))   --> true
```

## Multiple inheritance

Linearization follows C3, so diamond hierarchies behave predictably and each base class is initialized once when everyone cooperates through `super`.

```lua
local Base = lush.class(lush.Object)
function Base.init(self)
    self.log = {"Base"}
end

local Left = lush.class(Base)
function Left.init(self)
    lush.super(Left, self).init(self)
    table.insert(self.log, "Left")
end

local Right = lush.class(Base)
function Right.init(self)
    lush.super(Right, self).init(self)
    table.insert(self.log, "Right")
end

local Bottom = lush.class(Left, Right)
function Bottom.init(self)
    lush.super(Bottom, self).init(self)
    table.insert(self.log, "Bottom")
end

local obj = Bottom:new()
print(table.concat(obj.log, ", "))   --> Base, Right, Left, Bottom
-- MRO: Bottom -> Left -> Right -> Base -> Object
```

## Changing inheritance at runtime

Every class has a `__superclasses` object. Call it with a new list of superclasses to rewire the class:

```lua
Dog.__superclasses(Animal, Swimmer)
```

All affected subclasses have their MRO and caches rebuilt. If the new hierarchy is invalid (cycle, redundancy, or no C3 order), the call raises an error and **everything is rolled back** to its previous state.

```lua
local ok, err = pcall(function()
    Animal.__superclasses(Dog)   -- would create a cycle
end)
print(ok, err)   --> false   cyclic inheritance
```

## Modifying classes at runtime

Assigning to a class key updates the class and invalidates all dependent caches, so methods can be patched or removed at any time:

```lua
function Animal.speak(self) return "..." end   -- subclasses without their own speak see this
Animal.speak = nil                             -- removes it again
```

## Metamethods

Keys starting with `__` are treated as metamethods and kept physically in the class's cache so Lua can find them on instances. They are inherited through the MRO like any other key.

```lua
local Vec = lush.class(lush.Object)

function Vec.init(self, x, y) self.x, self.y = x, y end
function Vec.__add(a, b) return Vec:new(a.x + b.x, a.y + b.y) end
function Vec.__tostring(v) return ("(%g, %g)"):format(v.x, v.y) end

print(Vec:new(1, 2) + Vec:new(3, 4))   --> (4, 6)
```

Metamethod support is intentionally included for completeness, but ordinary objects rarely need it.

## Reserved names

Do not assign to these internal keys on a class (except `__superclasses` via a call as shown above):

`__class`, `__declared`, `__cache`, `__orders`, `__super_cache`, `__subclass_map`, `__superclasses`, `__i`

## Notes and limitations

- **`nil` lookups are not cached.** Lua cannot distinguish a cached `nil` from a missing entry, so looking up a key that does not exist walks the MRO each time. Avoid hot-path lookups of undefined members.
- **`super` returns `false` at the top of the MRO.** Indexing `false` raises an error, so guard calls to `super` when you are not sure a parent implementation exists.
- **Class lookups go through the MRO.** A key is first found in the class that declares it, so shadowing works exactly like normal inheritance. Instance fields set on the object itself always take priority.
- **Subclass links are weak.** A class held only by its parent's subclass map can be garbage collected.
- **Redundant base lists are rejected.** `lush.class(Dog, Animal)` errors because `Animal` is already an ancestor of `Dog`. List only the classes you need.
