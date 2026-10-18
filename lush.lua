-- library: lush
-- version: 1.0



local function index_cache(class, k)
    return class.__cache[k]
end

--------------------------------------------------------------------------------------------------------------------------------
-- luajit stuff
--------------------------------------------------------------------------------------------------------------------------------
-- normally lua needs two tables to have the same __eq in their metatable, however this is necessary in because in luajit, cdata can trigger __eq when compared to any value, including nil. technically debug.metatable can also cause __eq to run in normal lua, so either way this is necessary in places where you define things, the internals don't use it, they are not intended to be modified by you.
local function is_nil(v)
    return rawequal(v, nil)
end


local IN_USE_STRUCT
--------------------------------------------------------------------------------------------------------------------------------

-- this is necessary for every single subclass, because they might call super() and get proxies at any stage in the MRO, and subsequent access on the proxy might cache something.
local function invalidate_super_cache_once(class, k, root)
    local orders = class.__orders
    local super_cache = class.__super_cache

    -- proxies only appear from 1 to #orders - 2, since the last one point to nil, and second last one point to last one's __declared
    for i = 1, #orders - 2 do
        -- invariant: proxies always exist from 1 to #orders - 2
        local superclass = orders[i]
        if superclass == root then
            break
        end

        super_cache[superclass][k] = nil
    end
end

local function invalidate_super_cache(class, k, root, visited)
    
    visited[class] = 2
    invalidate_super_cache_once(class, k, root)
    

    for subclass, v in pairs(class.__subclass_map) do
        if not visited[subclass] then
            invalidate_super_cache(subclass, k, root, visited)
        end
    end
end

local function recurse_modify_cache(invalidate_cache, class, k, root, visited)

    -- track visited in case a child class inherits from 2 parent classes that both inherit from the same grandparent class, where with DFS, the child may be visited twice 
    visited[class] = 1

    for subclass, v in pairs(class.__subclass_map) do

        -- guard for struct class
        if getmetatable(subclass) == IN_USE_STRUCT then
            error("ancestor classes cannot be modified(unless has no effect) if a descendant is a struct class")
        end

        if not visited[subclass] then

            -- didn't override means their cache entry needs to be invalidated
            if is_nil(subclass.__declared[k]) then
                invalidate_super_cache_once(subclass, k, root)
                invalidate_cache(subclass, k, root, visited)
            else
                -- because something is declared by this subclass, so the root's change does not affect subsequent structs in this branch, so no need to check IN_USE_STRUCT
                -- otherwise only invalidate super_cache is necessary
                -- use a different recursion because invalidate_cache stops recursing
                invalidate_super_cache(subclass, k, root, visited) -- refresh_cache shares this branching because C3 guarantees that the subclass's cache has either this class's entry(because it declared it) or a sibling class's entry, so the root class's entry being changed is never relevant, thus can also just invalidate_super_cache()
            end

        end
    end
end

local function invalidate_cache_once(class, k)
    class.__cache[k] = nil
end

local function invalidate_cache(class, k, root, visited)
    invalidate_cache_once(class, k)
    recurse_modify_cache(invalidate_cache, class, k, root, visited)
end

-- nil cannot be cached unfortunately, because it is the same as deletion, and if you use an alternative like false, the behavior of code using it can change
-- hypothetically you can make a nil_cache, but usually it's not meaningful if your instance fields are properly occupied
local function memoize(cache, k, orders, i)
    for j = i, #orders do
        local v = orders[j].__declared[k]
        if not is_nil(v) then
            cache[k] = v
            return v
        end
    end
    return nil
end

local function refresh_cache_once(class, k)
    local cache = class.__cache
    if is_nil(memoize(cache, k, class.__orders, 1)) then
        if k == "__index" then
            cache[k] = cache -- rewire __index to itself
        else
            cache[k] = nil
        end
    end
end

local function refresh_cache(class, k, root, visited)
    refresh_cache_once(class, k)
    recurse_modify_cache(refresh_cache, class, k, root, visited)
end



local function is_metamethod(k)
    return type(k) == "string" and k:sub(1, 2) == "__"
end

local function safe_visit_modify_cache(modify_cache_once, modify_cache, visited, class, k, declared, original)
    local success, message = pcall(modify_cache, class, k, class, visited)
    if not success then
        declared[k] = original

        for subclass, v in pairs(visited) do
            -- only if it's a normal/type 1 change, it needs to be fixed.
            if visited[subclass] == 1 then
                modify_cache_once(subclass, k)
            end
            
        end

        error(message, 3)
    end
end

-- don't reassign internals like __class, __declared, __i, etc
local function declare_key(class, k, f)
    local declared = class.__declared
    local original = declared[k]

    declared[k] = f

    local visited = {}

    -- metamethods needs to be physically in cache everytime to work
    if is_metamethod(k) then
        safe_visit_modify_cache(refresh_cache_once, refresh_cache, visited, class, k, declared, original)
    else
        safe_visit_modify_cache(invalidate_cache_once, invalidate_cache, visited, class, k, declared, original)
    end
end

-- class.__orders might be reassigned, proxy won't sync, be aware
local MRO_PROXY = {
    __index = function(proxy, k)
        return memoize(proxy, k, proxy.__orders, proxy.__i)
    end,
}

-- returns false mean end of MRO, returns nil mean not found in MRO
-- both super(currentclass, instance) and super(currentclass, class) works
local function next_superclass(currentclass, instance)
    return instance.__class.__super_cache[currentclass]
end

-- inclusive i
local function create_proxy(orders, i)
    return setmetatable({__i = i, __orders = orders}, MRO_PROXY)
end

local function remove_at(array, i, n)
    for j = i + 1, n do
		array[j - 1] = array[j]
	end
	array[n] = nil
	return n - 1
end

local function count_tails(superclass_orders, superclass_orders_n, tail_map)
    for i = 2, superclass_orders_n do
        local superclass = superclass_orders[i]
        local count = tail_map[superclass]
        if count then
            tail_map[superclass] = count + 1
        else
            tail_map[superclass] = 1
        end
    end
end

-- assumption: cache is empty when this run, though it will still work if cache is not empty
local function warm_cache_metamethod(cache, orders)
    -- IMPORTANT: includes class itself, resolve_inheritance populates metamethods to cache
    for i = #orders, 1, -1 do
        for k, v in pairs(orders[i].__declared) do
            if is_metamethod(k) then
                cache[k] = v
            end
        end
    end
end

local function resolve_inheritance(class)
    local superclasses = class.__superclasses
    local superclasses_n = #superclasses

    -- invariant: class.__super_cache is set to {[class] = false} before calling resolve_inheritance(class)
    local super_cache = class.__super_cache

    if superclasses_n == 0 then
        return
    end

    -- invariant: class should not appear as its own superclass
    for i = 1, superclasses_n do
        local superclass = superclasses[i]
        if superclass.__super_cache[class] ~= nil then
            error("cyclic inheritance", 0)
        end
    end

    -- invariant: orders already assigned
    local orders = class.__orders
    local cache = class.__cache

    
    if superclasses_n == 1 then

        local superclass = superclasses[1]

        local superclass_orders = superclass.__orders
        local superclass_super_cache = superclass.__super_cache

        local superclass_orders_n = #superclass_orders

        for i = 1, superclass_orders_n - 1 do
            local inner_superclass = superclass_orders[i]
            orders[i + 1] = inner_superclass
            super_cache[inner_superclass] = superclass_super_cache[inner_superclass]
        end

        local lastclass = superclass_orders[superclass_orders_n]
        orders[superclass_orders_n + 1] = lastclass
        super_cache[lastclass] = false

        if superclass_orders_n == 1 then
            super_cache[class] = superclass.__declared
        else
            super_cache[superclass_orders[superclass_orders_n - 1]] = lastclass.__declared
            super_cache[class] = create_proxy(orders, 2)
        end

        superclass.__subclass_map[class] = true

        return
    end

    -- invariant: no redundancy
    for i = 1, superclasses_n - 1 do
        local superclass_super_cache = superclasses[i].__super_cache
        for j = i + 1, superclasses_n do
            if superclass_super_cache[superclasses[j]] ~= nil then
                error("redundant inheritance", 0)
            end
        end
    end

    -- invariant: class.__orders is always set to {class} before calling resolve_inheritance(class)
    local orders_n = 1
    
    local superclasses_orders_cursor_map = {[superclasses] = 1}
    local superclasses_orders = {}
    local superclasses_orders_n = superclasses_n + 1

    local tail_map = {}

    for i = 1, superclasses_n do
        local superclass = superclasses[i]
        superclass.__subclass_map[class] = true 

        local superclass_orders = superclass.__orders

        count_tails(superclass_orders, #superclass_orders, tail_map)

        superclasses_orders_cursor_map[superclass_orders] = 1
        superclasses_orders[i] = superclass_orders
    end

    count_tails(superclasses, superclasses_n, tail_map)

    superclasses_orders[superclasses_orders_n] = superclasses
    
    local i = 1

    repeat

        local superclass_orders = superclasses_orders[i]
        local cursor = superclasses_orders_cursor_map[superclass_orders]
        local head = superclass_orders[cursor]

        if tail_map[head] then
            i = i + 1
        else

            local j = 1
            
            while j <= superclasses_orders_n do
                local inner_superclass_orders = superclasses_orders[j]
                local inner_cursor = superclasses_orders_cursor_map[inner_superclass_orders]

                if inner_superclass_orders[inner_cursor] == head then

                    if #inner_superclass_orders == inner_cursor then
                        superclasses_orders_n = remove_at(superclasses_orders, j, superclasses_orders_n)
                    else
                        inner_cursor = inner_cursor + 1
                        superclasses_orders_cursor_map[inner_superclass_orders] = inner_cursor

                        local new_head = inner_superclass_orders[inner_cursor]
                        local count = tail_map[new_head]

                        if count == 1 then
                            tail_map[new_head] = nil
                        else
                            tail_map[new_head] = count - 1
                        end

                        j = j + 1
                    end

                else
                    j = j + 1
                end

                
            end

            orders_n = orders_n + 1
            orders[orders_n] = head

            i = 1
            
        end


    until i > superclasses_orders_n

    -- invariant: C3 errors if class(superclass, subclass), so even if the redundancy test passed, this will ensure it
    if superclasses_orders_n > 0 then
        error("cannot find a resolution for multiple inheritance", 0)
    end



    super_cache[class] = create_proxy(orders, 2)

    local lastclass = orders[orders_n]
    super_cache[lastclass] = false

    local secondlastclass = orders[orders_n - 1]
    super_cache[secondlastclass] = lastclass.__declared

    -- lastclass, secondlastclass, class are 3 cases that are all handled for super_cache, can return early if no more proxies needed
    if orders_n == 3 then
        return
    end


    
    -- reuse proxy if possible
    -- because of the no redundancy invariant, the last superclass(since C3 prioritizes superclass from left to right) is guaranteed to have the most sharable proxies possible
    local last_superclass = superclasses[superclasses_n]
    local last_superclass_orders = last_superclass.__orders
    local last_superclass_orders_n = #last_superclass_orders
    local last_superclass_super_cache = last_superclass.__super_cache


    local offset = orders_n - last_superclass_orders_n
    local leftovers_n = math.min(offset, orders_n - 2)

    for i = last_superclass_orders_n - 2, 1, -1 do
        
        local j = i + offset
        local superclass = orders[j]
        
        if superclass == last_superclass_orders[i] then

            super_cache[superclass] = last_superclass_super_cache[superclass]

        else
            -- handle j since superclass is already grabbed
            super_cache[superclass] = create_proxy(orders, j + 1)

            leftovers_n = j - 1

            break

        end
    end

    for i = 2, leftovers_n do
        super_cache[orders[i]] = create_proxy(orders, i + 1)
    end
end

local WEAK_K = {__mode = "k"}


local MRO_CACHE = {
    __index = function(cache, k)
        return memoize(cache, k, cache.__class.__orders, 1)
    end
}


local CLASS = {
    __index = index_cache,
    __newindex = declare_key,
}


local function set_superclasses_subclass_map_pair(superclasses, class, value)
    for i = 1, #superclasses do
        superclasses[i].__subclass_map[class] = value
    end
end

local function resolve_inheritance_warm_cache_metamethod(class)
    resolve_inheritance(class)
    warm_cache_metamethod(class.__cache, class.__orders)
end

-- creates a new class without inheriting from Object
local function create_class(...)
    local class = {
        __declared = {},
        __subclass_map = setmetatable({}, WEAK_K),
    }

    local cache = setmetatable({__class = class}, MRO_CACHE)
    cache.__index = cache
    class.__cache = cache

    local superclasses = {...}
    class.__superclasses = superclasses

    class.__orders = {class}
    class.__super_cache = {[class] = false}

    local success, message = pcall(resolve_inheritance_warm_cache_metamethod, class)
    if not success then
        set_superclasses_subclass_map_pair(superclasses, class, nil)
        error(message, 2)
    end

    return setmetatable(class, CLASS)
end

--------------------------------------------------------------------------------------------------------------------------------
-- Change Inheritance
--------------------------------------------------------------------------------------------------------------------------------

local function reset_cache(class)
    -- reset cache, need to empty because instances' metatable is cache, can't just replace
    local cache = class.__cache

    for k, v in pairs(cache) do
        cache[k] = nil
    end

    cache.__class = class
    cache.__index = cache -- this is fine because warm_cache_metamethod will override __index if it is declared
end

local function reset_class(class)
    reset_cache(class)

    -- replace old orders & super cache, old proxy will not be synced
    class.__orders = {class}
    class.__super_cache = {[class] = false}
end

local function reset_resolve_inheritance_warm_cache_metamethod(class)

    -- struct in use guard
    if getmetatable(class) == IN_USE_STRUCT then
        error("struct/ancestor class cannot have inheritance changed after in use", 0)
    end
    

    reset_class(class)
    resolve_inheritance_warm_cache_metamethod(class)
end

local function store_visited_rollback(class, visited)
    local orders = class.__orders
    orders.__super_cache = class.__super_cache -- temporary, removed later
    visited[class] = orders
end

local function dependency_reset_resolve_inheritance_warm_cache_metamethod(class, root, visited)
    if visited[class] then
        return
    end
    
    local orders = class.__orders

    for i = #orders, 2, -1 do
        local superclass = orders[i]
        if superclass.__super_cache[root] ~= nil and not visited[superclass] then
            store_visited_rollback(superclass, visited)
            reset_resolve_inheritance_warm_cache_metamethod(superclass)
        end
    end

    store_visited_rollback(class, visited)
    reset_resolve_inheritance_warm_cache_metamethod(class)
end

local function explore_leaf_dependency_reset_resolve_inheritance_warm_cache_metamethod(class, root, visited, traversed)
    if traversed[class] then
        return
    end

    traversed[class] = true


    local subclass_map = class.__subclass_map

    if next(subclass_map) == nil then
        dependency_reset_resolve_inheritance_warm_cache_metamethod(class, root, visited)
        return
    end

    for subclass, v in pairs(subclass_map) do
        explore_leaf_dependency_reset_resolve_inheritance_warm_cache_metamethod(subclass, root, visited, traversed)
    end
end

local function rollback_visited(visited)
    for class, orders in pairs(visited) do
        local super_cache = orders.__super_cache
        orders.__super_cache = nil

        class.__orders = orders
        class.__super_cache = super_cache

        reset_cache(class)
        warm_cache_metamethod(class.__cache, orders) -- cache is not restored, because it is derived information, so if you were doing some rawget() or rawset() with cache, unexpected behavior can occur, __cache is something internal, not really recommended to work with directly
    end
end

-- drop superclasses of the class and rebuild(including descendants of the class), optionally provide new superclasses
local function orphan_class(class, ...)
    local superclasses = class.__superclasses
    local superclasses_n = #superclasses

    local new_superclasses = {...}
    
    -- if they are identical, no change is necessary
    if #new_superclasses == superclasses_n then
        local identical = true
        for i = 1, superclasses_n do
            if new_superclasses[i] ~= superclasses[i] then
                identical = false
                break
            end
        end
        if identical then
            return
        end
    end

    class.__superclasses = new_superclasses

    -- remove all old relationship
    set_superclasses_subclass_map_pair(superclasses, class, nil)

    local visited = {}

    local success, message = pcall(explore_leaf_dependency_reset_resolve_inheritance_warm_cache_metamethod, class, class, visited, {})
    if success then

        for inner_class, inner_orders in pairs(visited) do
            inner_orders.__super_cache = nil
        end

    else
        rollback_visited(visited)

        -- remove all new relationship
        set_superclasses_subclass_map_pair(new_superclasses, class, nil)

        -- restore all old relationship
        set_superclasses_subclass_map_pair(superclasses, class, true)

        class.__superclasses = superclasses

        error(message, 2)
    end
end





--------------------------------------------------------------------------------------------------------------------------------
-- Built-in
--------------------------------------------------------------------------------------------------------------------------------
-- I explicitly added metamethod support, so it works. but I don't recommend you to use it too much, because sometimes the implicit behavior can be unexpected.

---@class Object
local Object = create_class()

-- constructor to initialize a blank instance, if you override new this will not be automatically called
function Object.init(instance) end

-- returns a newly created instance
---@generic T
---@param class T
---@return T
function Object.new(class, ...)
    local cache = class.__cache
    local instance = setmetatable({}, cache)
    cache.init(instance, ...)
    return instance
end



-- extension for luajit's cdata
local success, ffi = pcall(require, "ffi")

local function to_struct_name(class)
    return "struct _" .. tostring(class):match("table: (%w+)") -- table: 0xabcd
end

--[[
-- struct types are lazily evaluated, but safety is not guaranteed

local U = struct({
    x = "int(*)[5]" -- use luajit's ffi syntax for ctypes, this is a pointer to an array of 5 ints
}, Object)

local V = struct({
    y = U -- when the table is directly provided, 
}, Object)

-- this will not properly update U, because reading V's __metatype causes it to be evaluated
-- which in turn evaluates U prior to the assignment since it has U as one of its field, evaluated structs are considered in-use and not intended to be modified, but then you modified its internal __schema, which is not supported
-- U.__schema.x = ffi.typeof("$[5]", V.__metatype)

local A = struct({}, Object)
local B = struct({a_ptr = A("*")}, Object)

A.__schema.b_ptr = B("*") -- recursive pointers work fine, because non-anonymous structs are forward declared yet not evaluated

local a = A:new()
a.b_ptr = B:new()
a.b_ptr.a_ptr = a
]]

-- not recommended to pcall, but it will work because redundant cdef of incomplete struct declaration is harmless in C
-- if you need additional functionality, you can override new() with custom logic directly.
local function resolve_struct(class)
    -- remove the STRUCT mt
    setmetatable(class, nil)

    local cache = class.__cache

    local accumulated_schema = {}
    local orders = class.__orders

    for i = #orders, 1, -1 do
        local superclass = orders[i]
        local inner_schema = rawget(superclass, "__schema") -- not guaranteed to exist, avoid trigger index_cache
        if inner_schema then
            for k, v in pairs(inner_schema) do
                accumulated_schema[k] = v
            end
        end

        -- luajit states modification to metatable used for metatype is prohibited, so copy everything to cache ahead of time.
        -- see https://github.com/LuaJIT/LuaJIT/issues/41 for details
        for k, v in pairs(superclass.__declared) do
            cache[k] = v
        end
    end

    
    local anonymous = accumulated_schema[0]
    local attribute = accumulated_schema[1]

    -- avoid interfering with pairs()
    accumulated_schema[0] = nil
    accumulated_schema[1] = nil
    

    local keys = {}
    local keys_n = 0

    local array_map = {}
    local ctype_map = {}

    local struct_name = "struct "

    -- by default class uses address as name to handle self pointer or mutually recursive pointer, which is permanent in ffi's cdef space
    -- if you guarantees it can be expressed anonymously, toggle it in [0]

    if not anonymous then -- [0] may store a boolean to toggle anonymous behavior
        struct_name = to_struct_name(class)
        -- cdef is already done in create_struct
    end

    local array = {struct_name, "{"}
    local n = 2

    for k, ctype in pairs(accumulated_schema) do

        local inner_ctype = ctype
        local ctype_t = type(ctype)

        if ctype_t == "string" then
            
            inner_ctype = ffi.typeof(ctype)

        elseif ctype_t == "table" then -- assumption: a lush class is given
        
            inner_ctype = ctype.__metatype
        end

        keys_n = keys_n + 1
        keys[keys_n] = k

        ctype_map[k] = inner_ctype
    end

    table.sort(keys, function(a, b)
		local actype = ctype_map[a]
		local bctype = ctype_map[b]

		local aalign = ffi.alignof(actype)
		local balign = ffi.alignof(bctype)

		if aalign ~= balign then
			return aalign > balign
		end

		local asize = ffi.sizeof(actype)
		local bsize = ffi.sizeof(bctype)

		if asize ~= bsize then
			return asize > bsize
		end

		return a < b
    end)


    local ctypes = {}
    local ctypes_n = 0

    for i = 1, keys_n do
        local k = keys[i]

        ctypes_n = ctypes_n + 1
        ctypes[ctypes_n] = ctype_map[k]
        
        n = n + 1
        array[n] = "$"

        n = n + 1
        array[n] = " "

        n = n + 1
        array[n] = array_map[k] or k

        n = n + 1
        array[n] = ";"
    end

    n = n + 1
    array[n] = "}"


    n = n + 1
    array[n] = attribute

    -- unpack is a global in luajit
    local metatype = ffi.metatype(ffi.typeof(table.concat(array), unpack(ctypes, 1, ctypes_n)), cache)
    class.__metatype = metatype

    -- freeze class, internals are still mutable since in lua it is difficult to enforce immutability, but it's not supported
    setmetatable(class, IN_USE_STRUCT)

    return metatype
end

local function resolve_struct_new(class)
    local cache = class.__cache
    local init = cache.init -- struct is immutable after in-use, so this is fine

    local metatype

    local function new(inner_class, ...)
        local instance = metatype()
        init(instance, ...)
        return instance
    end

    class.new = new
    metatype = resolve_struct(class)

    return new, metatype
end

local function concat_struct_name(class, ...)
    if class.__schema[0] then -- anonymous
        return nil
    end
    return table.concat({to_struct_name(class), ...})
end

-- local declared at top
IN_USE_STRUCT = {
    __index = index_cache,
    __newindex = function(class, k, v)
        error("struct cannot be modified after in use", 2)
    end,
    __call = concat_struct_name
}

local STRUCT = {
    __index = function(class, k)
        if k == "__metatype" then
            local metatype

            if class.__super_cache[Object] == nil then
                metatype = resolve_struct(class)
            else
                local new
                new, metatype = resolve_struct_new(class)
            end

            return metatype
        end

        return class.__cache[k]
    end,

    __newindex = declare_key,

    __call = concat_struct_name,
}

local function create_struct(schema, ...)
    local class = create_class(...)
    setmetatable(class, nil) -- remove CLASS mt

    class.__schema = schema

    if class.__super_cache[Object] ~= nil then -- inherits Object

        -- this is not polymorphic, inner_class is disposed
        function class.new(inner_class, ...)
            return resolve_struct_new(class)(class, ...)
        end
    end

    local anonymous = schema[0]

    if not anonymous then
        local struct_name = to_struct_name(class)
        ffi.cdef(struct_name) -- luajit allows omitting trailing ;
    end

    return setmetatable(class, STRUCT)
end

--------------------------------------------------------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------------------------------------------------------

return {
    class = create_class,
    super = next_superclass,
    orphan = orphan_class,
    Object = Object,

    struct = create_struct,
}
