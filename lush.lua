-- library: lush
-- version: 1.0

-- this is necessary for every single subclass, because they might call super() and get proxies at any stage in the MRO, and subsequent access on the proxy might cache something. Not all proxies are shared, and redundant deletion is faster than checking which ones are shared to only invalidate partially further
local function invalidate_super_cache_once(class, k)
    local orders = class.__orders
    local super_cache = class.__super_cache

    -- proxies only appear from 1 to #orders - 2, since the last one point to nil, and second last one point to last one's __declared
    for i = 1, #orders - 2 do
        local proxy = super_cache[orders[i]]
        if proxy then
            proxy[k] = nil
        end
    end
end

local function invalidate_super_cache(class, k, visited)
    visited[class] = true
    invalidate_super_cache_once(class, k)

    for subclass, v in pairs(class.__subclass_map) do
        if not visited[subclass] then
            invalidate_super_cache(subclass, k, visited)
        end
    end
end

-- based on my benchmarks, recursion is faster than another breadth-first approach with same semantics
local function invalidate_cache(class, k, visited)
    -- track visited in case a child class inherits from 2 parent classes that both inherit from the same grandparent class, where with DFS, the child may be visited twice 
    visited[class] = true
    class.__cache[k] = nil

    for subclass, v in pairs(class.__subclass_map) do

        if not visited[subclass] then

            -- didn't override means their cache entry needs to be invalidated
            if subclass.__declared[k] == nil then
                invalidate_cache(subclass, k, visited)
                invalidate_super_cache_once(subclass, k)
            else
                -- otherwise only invalidate super_cache is necessary
                -- use a different recursion because invalidate_cache stops recursing
                invalidate_super_cache(subclass, k, visited)
            end

        end
    end
end

-- don't reassign internals like class, __declared, etc
local function declare_key(class, k, f)
    class.__declared[k] = f
    invalidate_cache(class, k, {})
end

-- invariant: class.__orders is never reassigned
local MRO_PROXY = {
    __index = function(proxy, k)
        local orders = proxy.__orders

        for i = proxy.__i, #orders do
            local v = orders[i].__declared[k]
            if v ~= nil then
                proxy[k] = v
                return v
            end
        end

        return nil
    end
}

-- false mean end of MRO, nil mean not found in MRO
-- both super(instance, currentclass) and super(class, currentclass) works
-- you can also use super() as instanceof via super(self, currentclass) ~= nil
local function next_superclass(instance, currentclass)
    return instance.class.__super_cache[currentclass]
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

local function count_tail(superclass, tail_map)
    local count = tail_map[superclass]
    if not count then
        count = 0
    end
    tail_map[superclass] = count + 1
end


local function resolve_inheritance(class)
    local superclasses = class.__superclasses
    local superclasses_n = #superclasses

    local super_cache = class.__super_cache

    -- book keeping
    if superclasses_n == 0 then
        super_cache[class] = false
        return
    end

    -- invariant: class should not appear as its own superclass
    for i = 1, superclasses_n do
        local superclass = superclasses[i]
        if superclass == class or superclass.__super_cache[class] ~= nil then
            error("cyclic inheritance")
        end
    end

    -- invariant: orders already assigned
    local orders = class.__orders

    
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
                error("redundant inheritance")
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

        for j = 2, #superclass_orders do
            count_tail(superclass_orders[j], tail_map)
        end

        superclasses_orders_cursor_map[superclass_orders] = 1
        superclasses_orders[i] = superclass_orders
    end

    for i = 2, superclasses_n do
        count_tail(superclasses[i], tail_map)
    end

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
        error("cannot find a resolution for multiple inheritance")
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
    -- because of the no redundancy invariant, the last superclass(since C3 prioritizes superclass from to right) is guaranteed to have the most sharable proxies possible
    local last_superclass = superclasses[superclasses_n]
    local last_superclass_orders = last_superclass.__orders
    local last_superclass_orders_n = #last_superclass_orders
    local last_superclass_super_cache = last_superclass.__super_cache


    local offset = orders_n - last_superclass_orders_n

    for i = last_superclass_orders_n - 2, 1, -1 do
        local superclass = last_superclass_orders[i]
        if superclass == orders[i + offset] then
            super_cache[superclass] = last_superclass_super_cache[superclass]
        else
            break
        end
    end



    -- create necessary new proxies
    for i = 2, orders_n - 2 do
        local superclass = orders[i]
        if super_cache[superclass] == nil then
            super_cache[superclass] = create_proxy(orders, i + 1)
        end
    end

end

local WEAK_K = {__mode = "k"}

local MRO_CACHE = {
    __index = function(cache, k)
        local class = cache.class
        local orders = class.__orders

        for i = 1, #orders do
            local v = orders[i].__declared[k]
            if v ~= nil then
                cache[k] = v
                return v
            end
        end

        return nil
    end
}

local SUPERCLASSES = {}

local function create_superclasses(class, ...)
    return setmetatable({__class = class, ...}, SUPERCLASSES)
end

local function create_class(...)
    local class = {
        __declared = {},
        __subclass_map = setmetatable({}, WEAK_K),
        __super_cache = {},
    }

    local cache = setmetatable({class = class}, MRO_CACHE)
    cache.__index = cache
    class.__cache = cache

    class.__superclasses = create_superclasses(class, ...)
    class.__orders = {class}
    resolve_inheritance(class)

    return setmetatable(class, {__index = cache, __newindex = declare_key})
end

--------------------------------------------------------------------------------------------------------------------------------
-- Change Inheritance
--------------------------------------------------------------------------------------------------------------------------------

-- reset class to the state prior to resolve inheritance
local function reset_class(class)

    -- reset cache, need to empty because instances' metatable is cache, can't just replace
    local declared = class.__declared
    local cache = class.__cache
    for k, v in pairs(cache) do
        if declared[k] == nil then
            -- if declared directly, cache entry is fine
            cache[k] = nil
        end
    end
    cache.class = class
    cache.__index = cache

    -- remove all old relationship
    local superclasses = class.__superclasses
    for i = 1, #superclasses do
        superclasses[i].__subclass_map[class] = nil
    end

    -- replace old orders & super cache, old proxy will not be synced
    class.__orders = {class}
    class.__super_cache = {}
end

local function reset_resolve_inheritance(class)
    reset_class(class)
    resolve_inheritance(class)
end

local function dependency_resolve_inheritance(class, root, visited)
    if visited[class] then
        return
    end
    visited[class] = true

    local orders = class.__orders

    for i = #orders, 2, -1 do
        local superclass = orders[i]
        if superclass.__super_cache[root] ~= nil then
            dependency_resolve_inheritance(superclass, root, visited)
        end
    end

    reset_resolve_inheritance(class)
end

local function explore_leaf_dependency_resolve_inheritance(class, root, visited)
    local subclass_map = class.__subclass_map

    if next(subclass_map) == nil then
        dependency_resolve_inheritance(class, root, visited)
        return
    end

    for subclass, v in pairs(subclass_map) do
        explore_leaf_dependency_resolve_inheritance(subclass, root, visited)
    end
end

function SUPERCLASSES.__call(superclasses, mode, ...)
    local class = superclasses.__class
    
    -- recursive
    if mode == "r" then
        class.__superclasses = create_superclasses(class, ...)
        explore_leaf_dependency_resolve_inheritance(class, class, {})
    else
        -- don't change subclasses
        class.__superclasses = create_superclasses(class, mode, ...)
        reset_resolve_inheritance(class)
    end
end


-- lua metamethods are not supported, because cache is lazy, metamethod requires the metamethod to be physically present in cache
--------------------------------------------------------------------------------------------------------------------------------
-- Built-in
--------------------------------------------------------------------------------------------------------------------------------
-- inherit from Object is opt-in, feel free to make your own life cycle/conventions
local Object = create_class()

local function noop() end
Object.construct = noop
Object.destruct = noop

function Object.allocate(class) return {} end

function Object.new(class, ...)
    local instance = setmetatable(class:allocate(), class.__cache)
    instance:construct(...)
    return instance
end

--------------------------------------------------------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------------------------------------------------------

return {
    class = create_class,
    super = next_superclass,
    Object = Object,
}
