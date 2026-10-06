# Cooperative `super` and Multiple Inheritance in lush

This guide covers how to use multiple inheritance well with lush: how cooperative `super` works, how to forward arguments, how to structure a hierarchy so you never have to guard `super` calls, and when multiple inheritance is (and isn't) the right tool.

It assumes you have read the main README.

## 1. The core idea: `super` means "next in the MRO"

In single inheritance, `super` means "my parent". In multiple inheritance it does **not**. `lush.super(Class, self)` means "the next class after `Class` in the MRO of `self`'s actual class".

```lua
local lush = require("lush")

local A = lush.class(lush.Object)
local B = lush.class(A)
local C = lush.class(A)
local D = lush.class(B, C)
-- MRO of D: D -> B -> C -> A -> Object
```

Inside `B`, `lush.super(B, self)` for an instance of `D` resolves through **`C`**, not `A`. `B` does not know `C` exists, and doesn't need to. That is what makes diamonds work: every class calls `super`, and each class in the MRO runs exactly once.

This only works if every class in the chain cooperates, which leads to the rules below.

## 2. The rules of cooperation

1. **Always pass the class where the method is defined** to `super`, never `self.__class`. Using `self.__class` makes subclasses resolve to themselves and recurse forever.
2. **Always forward the call**, even if you think you're the last class. Another class may be inserted after you in some other subclass's MRO.
3. **Forward everything you don't own.** Consume only the arguments you understand, pass the rest on.
4. **Don't assume who is next.** Never call a specific parent by name (`Animal.init(self, ...)`) in a cooperative hierarchy. That bypasses the MRO and breaks diamonds, running some classes twice and others not at all.
5. **Make every cooperative class end at the same root** (section 5), so the chain always has a defined end.

## 3. Forwarding arguments

Constructors are where cooperation gets difficult, because each class in the MRO might need different arguments and you don't know which classes sit around you. There are two practical patterns.

### Pattern A: forward varargs (`...`)

Use this when the hierarchy is mostly linear, or when the argument order is well defined. Each class takes the leading arguments it needs and forwards the remainder.

```lua
local Animal = lush.class(lush.Object)

function Animal.init(self, name, ...)
    lush.super(Animal, self).init(self, ...)
    self.name = name
end

local Dog = lush.class(Animal)

function Dog.init(self, name, breed, ...)
    lush.super(Dog, self).init(self, name, ...)
    self.breed = breed
end

local rex = Dog:new("Rex", "Husky")
```

Always forwarding `...` means a subclass can add more arguments later without rewriting its parents.

**Limitation:** positional arguments are consumed in order, so every class must agree on the order. In a diamond like `D(B, C)`, `B` would have to know how many arguments `C` consumes, and it can't, because `B` doesn't know `C` exists. Positional varargs become fragile as soon as sibling classes (classes that aren't ancestors of each other) each take their own arguments.

### Pattern B: a table that mimics `**kwargs` (recommended for multiple inheritance)

Pass a single table of named options. Each class reads only the keys it cares about and forwards the **same table** unchanged.

```lua
local Named = lush.class(lush.Object)

function Named.init(self, opts)
    lush.super(Named, self).init(self, opts)
    self.name = opts.name or "unnamed"
end

local Positioned = lush.class(lush.Object)

function Positioned.init(self, opts)
    lush.super(Positioned, self).init(self, opts)
    self.x = opts.x or 0
    self.y = opts.y or 0
end

local Thing = lush.class(Named, Positioned)

local t = Thing:new({name = "crate", x = 4})
print(t.name, t.x, t.y)   --> crate 4 0
```

Why this works well:

- Order doesn't matter. `Named` and `Positioned` never need to know about each other.
- Adding a new mixin with new options doesn't change anyone else's signature.
- Defaults live next to the code that uses them (`opts.x or 0`).
- Unknown keys are harmless. They pass through and are ignored.

Tips:

- **Don't remove keys from `opts`** as you consume them unless you control the whole hierarchy. Other classes may need them.
- **Don't mutate `opts`** in general. If you must add or change a key for the classes after you, copy first.
- Use `opts.x == nil` rather than `opts.x or default` when `false` is a valid value.
- You can mix styles: take a few positional arguments, then the table, as in `init(self, name, opts)`. The table still gets forwarded.

### Where to call `super` in `init`

Calling `super` first means the classes after you have already set up their fields by the time your code runs, so you can rely on them:

```lua
function Player.init(self, opts)
    lush.super(Player, self).init(self, opts)   -- parents and mixins set up first
    self.hp = self.max_hp                        -- safe to use what they set
end
```

Call `super` last (or around your own work) only when you need to set something before the other classes see it. For teardown methods such as `destroy`, do the reverse: do your own cleanup first, then call `super`, so cleanup unwinds in reverse order of setup.

## 4. Cooperative methods other than `init`

The same pattern works for any method that every class may want to contribute to: `update`, `destroy`, `describe`, `serialize`, event hooks, and so on.

```lua
function Movable.update(self, dt)
    self.x = self.x + self.speed * dt
    lush.super(Movable, self).update(self, dt)
end
```

The question is what happens at the end of the chain. `lush.Object` defines `init` but nothing else. For `init` that's fine, because `Object.init` is a no-op. For any other method, the last `super` call would find nothing, and calling `nil` throws an error. And if `super` is called from the last class in the MRO, it returns `false`, and indexing that throws as well.

You can guard every call:

```lua
local nextclass = lush.super(Movable, self)
if nextclass and nextclass.update then nextclass.update(self, dt) end
```

but that is noisy, easy to forget, and defeats the point of cooperation. The better solution is a root class.

## 5. Recommended: your own root class with no-op methods

Create one root class for your project (or module) that declares every cooperative method as a no-op, and make every class in the hierarchy, including mixins, inherit from it.

```lua
local Base = lush.class(lush.Object)

-- Terminal implementations: this is where the chain ends, so they do NOT call super.
function Base.update(self, dt) end
function Base.destroy(self) end
function Base.describe(self) return "" end   -- return the "neutral element"
```

Now every other class can call `super` unconditionally, with no guard.

For methods that return values, make the root return the **neutral value** for combining results: `""` for string concatenation, `0` for sums, `{}` for list merging, `true` for "all must agree", and so on. Then each class can combine its own result with whatever `super` returns without special-casing the end of the chain.

### Why every class must inherit from the root

The root only terminates the chain if it comes last in every MRO. C3 guarantees this when all your classes inherit (directly or indirectly) from it. If a mixin doesn't, it can end up after the root, where it is never reached:

```lua
local Loose = lush.class()                -- BAD: doesn't inherit from Base
local Thing = lush.class(Entity, Loose)
-- MRO: Thing -> Entity -> Base -> Object -> Loose
-- Base's no-ops never call super, so Loose is silently skipped.
```

```lua
local Mixin = lush.class(Base)            -- GOOD
local Thing = lush.class(Entity, Mixin)
-- MRO: Thing -> Entity -> Mixin -> Base -> Object
```

Rules of thumb for the root:

- The root's cooperative methods are **terminal**: they don't call `super`.
- Add a no-op to the root **before** any class starts cooperating on that method name.
- `init` is already covered by `lush.Object.init`, which ignores any arguments. If you want stricter behavior (for example, warning about unrecognized `opts` keys), define your own terminal `Base.init`.
- Keep the root small. It should declare the hooks, not contain behavior.

## 6. A complete example

```lua
local lush = require("lush")
local super = lush.super

-- Root: terminal no-ops for every cooperative method
local Base = lush.class(lush.Object)
function Base.update(self, dt) end
function Base.describe(self) return "" end

-- Core entity
local Entity = lush.class(Base)

function Entity.init(self, opts)
    super(Entity, self).init(self, opts)
    self.name = opts.name or "entity"
end

function Entity.describe(self)
    return "name=" .. self.name .. super(Entity, self).describe(self)
end

-- Mixin: movement
local Movable = lush.class(Base)

function Movable.init(self, opts)
    super(Movable, self).init(self, opts)
    self.x = opts.x or 0
    self.speed = opts.speed or 1
end

function Movable.update(self, dt)
    self.x = self.x + self.speed * dt
    super(Movable, self).update(self, dt)
end

function Movable.describe(self)
    return " x=" .. self.x .. super(Movable, self).describe(self)
end

-- Mixin: health
local Damageable = lush.class(Base)

function Damageable.init(self, opts)
    super(Damageable, self).init(self, opts)
    self.hp = opts.hp or 100
end

function Damageable.describe(self)
    return " hp=" .. self.hp .. super(Damageable, self).describe(self)
end

-- Compose
local Player = lush.class(Entity, Movable, Damageable)
-- MRO: Player -> Entity -> Movable -> Damageable -> Base -> Object

local p = Player:new({name = "hero", hp = 150, speed = 2})
p:update(0.5)
print(p:describe())   --> name=hero x=1.0 hp=150
```

Notice:

- `Entity`, `Movable`, and `Damageable` never reference each other.
- Every `super` call is unguarded because `Base` terminates every chain.
- `Damageable` doesn't define `update` at all. Lookup through `super` skips classes that don't declare the method and finds the next one that does.
- `describe` builds its result by combining its own text with whatever `super` returns, finishing with `Base`'s neutral `""`.

## 7. Appropriate applications of multiple inheritance

Multiple inheritance works best when the parents represent **independent capabilities** that combine without stepping on each other.

**Good fits**

- **Mixins / traits:** small classes that add one capability, such as `Serializable`, `Observable` (event emitter), `Comparable`, `Cloneable`, `Timestamped`, `Loggable`. They extend `Base`, carry little or no state of their own, and cooperate through hooks.
- **Orthogonal entity components:** in games and simulations, combining `Positioned`, `Drawable`, `Damageable`, `Collidable` into concrete entity types.
- **Role / interface composition:** a class that is genuinely several things at once, such as a `File` that is both `Readable` and `Writable`.
- **Cross-cutting concerns:** validation, logging, caching, or lifecycle hooks layered over existing classes via cooperative `init`, `update`, or `destroy`.
- **Plugin-style extension:** assembling a final class from a base plus a list of feature classes, since `lush.class(...)` accepts any number of parents.

**Poor fits (consider composition instead)**

- **"Has-a" relationships.** If you would write `self.engine`, a `Car` should hold an `Engine`, not inherit from it.
- **Parents that overlap heavily** in state or in the same method names with different meanings. The MRO will resolve the conflict, but the result is hard to reason about.
- **Deep hierarchies.** Prefer shallow ones: one real base plus a handful of mixins.
- **Mixins that depend on each other's fields** without saying so. If `Movable` needs `self.hp`, either make that an explicit dependency (inherit from the class that provides it) or don't depend on it.
- **Classes with incompatible constructor protocols.** Mixing positional-argument classes in a diamond is error-prone; use the `opts` table pattern, or compose.

## 8. Pitfalls checklist

| Pitfall | Symptom | Fix |
| --- | --- | --- |
| Calling a parent by name (`Animal.init(self)`) | Classes run twice or are skipped in diamonds | Use `lush.super(Class, self)` |
| `super(self.__class, self)` | Infinite recursion in subclasses | Pass the class where the method is defined |
| Not forwarding `...` / `opts` | Later classes get no arguments, fields stay `nil` | Always forward everything you don't own |
| Mixin not inheriting from the root | Mixin methods silently never run, or `super` returns `false` | Make every mixin inherit from the root |
| Cooperative method missing on the root | `attempt to call a nil value` at the end of the chain | Add a terminal no-op to the root first |
| Using fields set by another class before `super(init)` returns | Unexpected `nil` | Call `super` first in `init` |
| Mutating the shared `opts` table | One class's consumption breaks another's | Treat `opts` as read-only; copy if you must change it |
| Listing a class and its ancestor (`class(Dog, Animal)`) | `redundant inheritance` error | List only the classes you need |
| Conflicting parent order across classes | `cannot find a resolution for multiple inheritance` | Use a consistent parent order across your hierarchy |
