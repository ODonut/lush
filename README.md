# lush

A small object-oriented programming library for Lua with **multiple inheritance (C3 linearization)**, **cached method lookup**, **metamethod inheritance**, **runtime re-parenting**, and optional **LuaJIT FFI struct classes**.

Version 1.0

## Features

- Single and multiple inheritance, resolved with C3 linearization (the same MRO algorithm Python uses)
- `super()` that follows the MRO, so cooperative multiple inheritance works in diamonds
- Per-class lookup cache: inherited members are resolved once, and the cache is invalidated automatically when you redefine members at runtime
- Metamethods (`__add`, `__tostring`, `__call`, ...) are inherited and overridable like any other member
- `orphan()` to change a class's parents after creation, with rollback if the new hierarchy is invalid
- `struct()` (LuaJIT only) to define classes backed by FFI `cdata`, with inheritance of fields and methods
- Clear errors for cyclic, redundant, or unresolvable inheritance

## Quick start

```lua
local lush   = require("lush")
local class  = lush.class
local Object = lush.Object

local Animal = class(Object)

function Animal:init(name)
    self.name = name
end

function Animal:speak()
    return self.name .. " makes a sound"
end

local Dog = class(Animal)

function Dog:speak()
    return self.name .. " barks"
end

local d = Dog:new("Rex")
print(d:speak())  --> Rex barks
```

`class(...)` takes any number of superclasses. Methods and fields are declared by assigning to the class (`function Dog:speak()` is just `Dog.speak = function ...`). Instances are created with `Class:new(...)`, which calls `init`.

> **Note:** `class()` does not inherit from `Object` automatically. Pass `Object` (or a class that inherits it) if you want `new` and `init`.

## Classes

### Creating a class

```lua
local Base    = class(Object)       -- inherits Object
local Derived = class(Base)         -- single inheritance
local Mixed   = class(Base, Other)  -- multiple inheritance
local Bare    = class()             -- no parents, no Object (no `new`)
```

### Instances

`Object.new(class, ...)` creates an empty table whose metatable is the class's internal cache, then calls `init(instance, ...)`. If you override `new`, `init` is not called for you.

```lua
function Point:init(x, y)
    self.x, self.y = x, y
end

local p = Point:new(1, 2)
```

### Overriding and redefining at runtime

Assigning to a class declares the key on that class. Assigning `nil` removes the declaration, so lookups fall back to the parents. Caches of the class and all its descendants are updated automatically, so redefining a method on a parent takes effect everywhere immediately.

```lua
function Animal:speak() return "..." end   -- existing Dogs see the new version
```

## Inheritance

### Multiple inheritance and the MRO

Superclasses are searched in C3 order. For `class(B, C)` where `B` and `C` both inherit `A`, the order is `D, B, C, A, Object`.

### `super(currentclass, instance_or_class)`

Returns the next entry in the MRO after `currentclass`, for the class of the given instance (or the class itself). Index it to get the next implementation, and pass `self` explicitly.

```lua
local super = lush.super

local A = class(Object)
function A:hello() print("A") end

local B = class(A)
function B:hello() print("B"); super(B, self).hello(self) end

local C = class(A)
function C:hello() print("C"); super(C, self).hello(self) end

local D = class(B, C)
function D:hello() print("D"); super(D, self).hello(self) end

D:new():hello()  --> D, B, C, A
```

Return values of `super`:

| Value | Meaning |
|-------|---------|
| table | Lookup target for the rest of the MRO. Index it to find the next definition. |
| `false` | `currentclass` is the last class in the MRO. |
| `nil` | `currentclass` is not in the MRO of that class. |

Always pass the class in which the method is *defined* as `currentclass`, not `self.__class`.

### Inheritance errors

`class()` raises an error if the hierarchy is invalid:

| Message | Cause |
|---------|-------|
| `cyclic inheritance` | A class would end up as its own ancestor |
| `redundant inheritance` | A superclass is listed alongside one of its own descendants, e.g. `class(Child, Parent)` |
| `cannot find a resolution for multiple inheritance` | No consistent C3 order exists |

### Changing inheritance: `orphan(class, ...)`

Drops all current superclasses of `class` and optionally attaches new ones. The class and all of its descendants are rebuilt. If the new hierarchy is invalid, everything is rolled back and the error is rethrown.

```lua
local orphan = lush.orphan

orphan(Dog)            -- Dog now has no parents
orphan(Dog, Pet, Dog2) -- Dog now inherits Pet and Dog2
```

Instance metatables stay valid across `orphan`, since the cache tables are reused.

## Metamethods

Any key beginning with `__` is treated as a metamethod. These are copied into the class cache (which is the instances' metatable), inherited through the MRO, and overridable by subclasses.

```lua
local Vec = class(Object)

function Vec:init(x, y) self.x, self.y = x, y end

function Vec.__add(a, b)
    return Vec:new(a.x + b.x, a.y + b.y)
end

function Vec:__tostring()
    return "(" .. self.x .. ", " .. self.y .. ")"
end

print(Vec:new(1, 2) + Vec:new(3, 4))  --> (4, 6)
```

Be careful with `__index` and `__newindex`. If you declare `__index` as a function, instance lookups no longer go through the cache, so inherited methods won't be found unless your function handles them. Metamethod support is intentionally explicit, but use it sparingly: implicit behavior can be surprising.

## Structs (LuaJIT only)

`struct(field_map, ...)` creates a class whose instances are FFI `cdata`. It requires LuaJIT's `ffi` module.

```lua
local struct = lush.struct

local Point = struct({
    x = "double",
    y = "double",
}, Object)

function Point:init(x, y)
    self.x, self.y = x, y
end

function Point:length()
    return math.sqrt(self.x ^ 2 + self.y ^ 2)
end

local p = Point:new(3, 4)
print(p:length())  --> 5
```

### Field types

Each value in `field_map` can be:

- a string in LuaJIT ctype syntax (`"int"`, `"double"`, `"int(*)[5]"`)
- an existing ctype object (from `ffi.typeof`)
- another lush struct class, embedded by value

Fields from all struct ancestors are merged, with the nearest class winning on name conflicts. Fields are laid out sorted by alignment (descending), then size (descending), then name, so layout is deterministic and not in declaration order.

### Special entries

| Key | Meaning |
|-----|---------|
| `field_map[0] = true` | Declare the struct anonymously instead of as a named, forward-declared struct. Only use this if the struct doesn't need self or mutual references. |
| `field_map[1] = "..."` | An attribute string appended after the struct body, e.g. `"__attribute__((packed))"`. |

### Pointers and recursive structs

Calling a named struct class returns its C type name, with any arguments appended. This lets you write pointers to structs that are still being defined:

```lua
local A = struct({}, Object)
local B = struct({ a_ptr = A("*") }, Object)

A.__field_map.b_ptr = B("*")   -- legal because neither is in use yet

local a = A:new()
a.b_ptr = B:new()
a.b_ptr.a_ptr = a
```

Anonymous structs return `nil` when called.

### Structs without `Object`

If a struct does not inherit `Object`, it has no `new`. Use the metatype directly:

```lua
local S = struct({ n = "int" })
local ctor = S.__metatype
local s = ctor()
```

`init` is not called in this case.

### Lazy evaluation and "in use"

The underlying C struct and metatype are created lazily, the first time `__metatype` is read or `new` is called. At that point the class is **in use** and frozen:

- assigning a member raises `struct cannot be modified after in use`
- `orphan` raises `struct cannot have inheritance changed after in use`
- modifying an *ancestor* of an in-use struct raises `ancestor classes cannot be modified if a descendant is a struct class`

LuaJIT forbids changing a metatype's metatable after it's bound, which is why everything is copied into the cache up front. Define all methods and metamethods **before** the first `new`.

Note that a struct's `field_map` is internal data. Mutating it after the struct (or any struct that embeds it) has been evaluated is not supported.

## LuaJIT and `nil` comparison

In LuaJIT, `cdata` can trigger `__eq` when compared with any value, including `nil`. The library's internals avoid this, but in your own code, use `rawequal(v, nil)` when `v` might be an instance of a struct class.

## API reference

| Function | Description |
|----------|-------------|
| `lush.class(...)` | Create a class with the given superclasses |
| `lush.super(currentclass, instance_or_class)` | Next entry in the MRO after `currentclass` |
| `lush.orphan(class, ...)` | Drop parents and optionally attach new ones, rebuilding descendants |
| `lush.Object` | Base class providing `new` and an empty `init` |
| `lush.struct(field_map, ...)` | Create an FFI struct class (LuaJIT only) |
| `Object.new(class, ...)` | Create an instance and call `init` |
| `Object.init(instance, ...)` | Constructor hook, empty by default |

## Behavior notes and limitations

- **`nil` is never cached.** A missing key is looked up through the whole MRO every time. Make sure instance fields are initialized in `init` if you test for them often.
- **Reserved names.** Keys such as `__class`, `__declared`, `__cache`, `__orders`, `__super_cache`, `__subclass_map`, `__superclasses`, `__field_map`, and `__metatype` are used internally. Don't assign to them.
- **Internals are not a public API.** In particular, the cache is derived data; writing to it with `rawset` is unsupported, and it is rebuilt (not restored) when `orphan` rolls back.
- **Subclass tracking is weak.** Classes are held weakly by their parents, so unreferenced subclasses can be garbage collected.
- **Don't recurse through `Object.new` with a different class** in a struct: struct `new` is not polymorphic, and the class passed in is ignored.

## License

Add your license here.
