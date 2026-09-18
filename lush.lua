-- this is necessary for every single subclass, because they might call super() and get proxies at any stage in the MRO, and subsequent access on the proxy might cache something. Not all proxies are shared, and redundant deletion is faster than checking which ones are shared to only invalidate partially further
local function invalidate_super_cache_once(class, k)
    local orders = class.__orders
    local super_cache = class.__super_cache

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

-- invariant: class will not appear in its own superclasses, because of the way the API is designed
local function resolve_inheritance(class)
    local superclasses = class.__superclasses
    local superclasses_n = #superclasses

    local super_cache = class.__super_cache

    -- book keeping
    if superclasses_n == 0 then
        super_cache[class] = false
        return
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
    -- because of the no redundancy invariant, no superclass can have contain another superclass's orders[1 to #orders - 2], which is the mid segment relative to class.__orders, so there is never going to be a case where one superclass can share all of its proxies, thus early return in the loop because all sharable proxies are gathered from the superclasses will never be needed
    for i = superclasses_n, 1, -1 do
        local superclass = superclasses[i]
        local superclass_orders = superclass.__orders
        local superclass_super_cache = superclass.__super_cache

        local superclass_orders_n = #superclass_orders

        if superclass_orders[superclass_orders_n] == lastclass and superclass_orders[superclass_orders_n - 1] == secondlastclass then

            local offset = orders_n - superclass_orders_n

            for j = superclass_orders_n - 2, 1, -1 do
                local inner_superclass = superclass_orders[j]
                if inner_superclass == orders[j + offset] then
                    super_cache[inner_superclass] = superclass_super_cache[inner_superclass]
                else
                    break
                end
            end

            -- can break after finding the first one in reverse, because for example:
            --[[
                superclass_orders_1: A, B, C, D
                superclass_orders_2: X, Y, B, C, D

                orders: class, A, X, Y, B, C, D

                this shows given any 2 superclass_orders that partially shares the ancestry, because C3 prioritizes the left-side of superclasses, so the right-side always end up in the later portion of class.__orders
                thus the most you can share is the first one with the same last 2 classes when searching in reverse

                superclass_orders_1: A, B, C
                superclass_orders_2: O, P, Q

                orders: class, A, B, C, O, P, Q

                later superclass_orders that does not partially share any ancestry simply renders all previous partially shared ancestries unsharable
            ]]

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

local function create_class(...)
    local class = {
        __declared = {},
        __subclass_map = setmetatable({}, WEAK_K),
        __super_cache = {},
        __superclasses = {...}
    }

    local cache = setmetatable({class = class}, MRO_CACHE)
    cache.__index = cache
    class.__cache = cache

    class.__orders = {class}
    resolve_inheritance(class)

    return setmetatable(class, {__index = cache, __newindex = declare_key})
end


-- lua metamethods are not supported, because cache is lazy, metamethod requires the metamethod to be physically present in cache
--------------------------------------------------------------------------------------------------------------------------------
-- Built-in
--------------------------------------------------------------------------------------------------------------------------------
-- inherit from Object is opt-in, feel free to make your own life cycle/conventions
local Object = create_class()

function noop() end
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
