-- library: lush
-- version: 1.0

-- this is necessary for every single subclass, because they might call super() and get proxies at any stage in the MRO, and subsequent access on the proxy might cache something.
local function invalidate_super_cache_once(class, k)
    local orders = class.__orders
    local super_cache = class.__super_cache

    -- proxies only appear from 1 to #orders - 2, since the last one point to nil, and second last one point to last one's __declared
    for i = 1, #orders - 2 do
        -- invariant: proxies always exist from 1 to #orders - 2
        super_cache[orders[i]][k] = nil
    end
end

local function invalidate_super_cache(class, k, visited)

    invalidate_super_cache_once(class, k)
    visited[class] = true

    for subclass, v in pairs(class.__subclass_map) do
        if not visited[subclass] then
            invalidate_super_cache(subclass, k, visited)
        end
    end
end

-- based on my benchmarks, recursion is faster than another breadth-first approach
local function recurse_modify_cache(invalidate_cache, class, k, visited)

    -- track visited in case a child class inherits from 2 parent classes that both inherit from the same grandparent class, where with DFS, the child may be visited twice 
    visited[class] = true

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

local function invalidate_cache(class, k, visited)
    class.__cache[k] = nil
    recurse_modify_cache(invalidate_cache, class, k, visited)
end

local function memoize(cache, k, orders, i)
    for j = i, #orders do
        local v = orders[j].__declared[k]
        if v ~= nil then
            cache[k] = v
            return v
        end
    end
    return nil
end

local function refresh_cache(class, k, visited)
    memoize(class.__cache, k, class.__orders, 1)
    recurse_modify_cache(refresh_cache, class, k, visited)
end

local function is_metamethod(k)
    return type(k) == "string" and k:sub(1, 2) == "__"
end

-- don't reassign internals like __class, __declared, etc
local function declare_key(class, k, f)
    class.__declared[k] = f

    -- metamethods needs to be physically in cache everytime to work
    if is_metamethod(k) then

        refresh_cache(class, k, {})

    else

        invalidate_cache(class, k, {})
    end
end

-- class.__orders might be reassigned, proxy won't sync, be aware
local MRO_PROXY = {
    __index = function(proxy, k)
        return memoize(proxy, k, proxy.__orders, proxy.__i)
    end
}

-- false mean end of MRO, nil mean not found in MRO
-- both super(instance, currentclass) and super(class, currentclass) works
-- you can also use super() as instanceof via super(self, currentclass) ~= nil
local function next_superclass(instance, currentclass)
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

local function count_tail(superclass, tail_map)
    local count = tail_map[superclass]
    if not count then
        count = 0
    end
    tail_map[superclass] = count + 1
end

-- invariant: cache is empty when this run
local function warm_cache_metamethod(cache, orders, orders_n)
    -- IMPORTANT: includes class itself, resolve_inheritance populates metamethods to cache
    for i = 1, orders_n do
        for k, v in pairs(orders[i].__declared) do
            if is_metamethod(k) and rawget(cache, k) == nil then
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
            error("cyclic inheritance")
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


        -- handle metamethod
        warm_cache_metamethod(cache, orders, superclass_orders_n + 1)

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


    -- handle metamethod
    warm_cache_metamethod(cache, orders, orders_n)



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
        return memoize(cache, k, cache.__class.__orders, 1)
    end
}

local SUPERCLASSES = {}

local function create_superclasses(class, ...)
    return setmetatable({[0] = class, ...}, SUPERCLASSES)
end

local function create_class(...)
    local class = {
        __declared = {},
        __subclass_map = setmetatable({}, WEAK_K),
    }

    local cache = setmetatable({__class = class}, MRO_CACHE)
    cache.__index = cache
    class.__cache = cache

    class.__superclasses = create_superclasses(class, ...)
    class.__orders = {class}
    class.__super_cache = {[class] = false}
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
    cache.__class = class
    cache.__index = cache

    -- remove all old relationship
    local superclasses = class.__superclasses
    for i = 1, #superclasses do
        superclasses[i].__subclass_map[class] = nil
    end

    -- replace old orders & super cache, old proxy will not be synced
    class.__orders = {class}
    class.__super_cache = {[class] = false}
end

local function reset_resolve_inheritance(class)
    reset_class(class)
    resolve_inheritance(class)
end

local function shrink_level(subclasses, i, level_n, subclasses_n)
    subclasses[i] = subclasses[level_n]
    subclasses[level_n] = subclasses[subclasses_n]
    subclasses[subclasses_n] = nil
    return level_n - 1, subclasses_n - 1
end

function SUPERCLASSES.__call(superclasses, mode, ...)
    local class = superclasses[0]
    
    -- recursive
    if mode == "r" then
        class.__superclasses = create_superclasses(class, ...)

        local subclasses = {class}
        local subclasses_n = 1
        local visited = {}
        
        -- this works because of the no redundancy invariant in resolve inheritance, if B and C inherits from A, D inherits from B and C, since no redundancy guarantees D cannot inherit from A, thus BFS works
        repeat
            local level_n = subclasses_n
            local i = 1

            repeat
                local subclass = subclasses[i]
                if visited[subclass] then
                    level_n, subclasses_n = shrink_level(subclasses, i, level_n, subclasses_n)
                else
                    visited[subclass] = true
                    reset_resolve_inheritance(subclass)

                    local subclass_subclass_map = subclass.__subclass_map
                    local firstclass = next(subclass_subclass_map)
                    if firstclass == nil then
                        level_n, subclasses_n = shrink_level(subclasses, i, level_n, subclasses_n)
                    else
                        subclasses[i] = firstclass

                        for inner_subclass, v in next, subclass_subclass_map, firstclass do
                            subclasses_n = subclasses_n + 1
                            subclasses[subclasses_n] = inner_subclass
                        end

                        i = i + 1
                    end
                end

            until i > level_n
            
        until subclasses_n == 0

    else
        -- does not change subclasses
        class.__superclasses = create_superclasses(class, mode, ...)
        reset_resolve_inheritance(class)
    end
end


--------------------------------------------------------------------------------------------------------------------------------
-- Built-in
--------------------------------------------------------------------------------------------------------------------------------
-- I explicitly added metamethod support
-- inherit from Object is opt-in, feel free to make your own life cycle/conventions
local Object = create_class()

function Object.allocate(class) return {} end
function Object.construct(instance) end

function Object.new(class, ...)
    local cache = class.__cache
    local instance = setmetatable(cache.allocate(class), cache)
    cache.construct(instance, ...)
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
