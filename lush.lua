-- lush
-- version 1.0

-- this is necessary for every single subclass, because they might call super() and get proxies at any stage in the MRO
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

local function invalidate_super_cache(class, k)
    invalidate_super_cache_once(class, k)

    for subclass, v in pairs(class.__subclass_map) do
        invalidate_super_cache(subclass, k)
    end
end

local function invalidate_cache(class, k)
    class.__cache[k] = nil

    for subclass, v in pairs(class.__subclass_map) do
        if subclass.__declared[k] == nil then
            invalidate_cache(subclass, k)
            invalidate_super_cache_once(subclass, k)
        else
            -- use a different recursion because invalidate_cache stops recursing
            invalidate_super_cache(subclass, k)
        end
    end
end

-- don't reassign internals like class, __declared, etc
local function declare_key(class, k, f)
    class.__declared[k] = f
    invalidate_cache(class, k)
end


local MRO_PROXY = {
    __index = function(proxy, k)
        local orders = proxy.__class.__orders

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
local function next_superclass(instance, class)
    return instance.class.__super_cache[class]
end

local function create_proxy(class, i)
    return setmetatable({__i = i + 1, __class = class}, MRO_PROXY)
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

-- C3 fails anyway if you give duplicate superclasses, so I didn't write checks for it
local function resolve_inheritance(class)
    local superclasses = class.__superclasses
    local superclasses_n = #superclasses

    if superclasses_n == 0 then
        return
    end

    local orders = class.__orders
    local super_cache = class.__super_cache
    
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
            super_cache[class] = create_proxy(class, 1)
        end

        superclass.__subclass_map[class] = true

        return
    end

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

    if superclasses_orders_n > 0 then
        error("cannot find a resolution for multiple inheritance")
    end

    super_cache[class] = create_proxy(class, 1)

    local lastclass = orders[orders_n]
    super_cache[lastclass] = false

    local secondlastclass = orders[orders_n - 1]
    super_cache[secondlastclass] = lastclass.__declared

    -- lastclass, secondlastclass, class are 3 cases that are all handled for super_cache
    if orders_n == 3 then
        return
    end


    -- reuse proxy if possible
    for i = 1, superclasses_n do
        local superclass = superclasses[i]
        local superclass_orders = superclass.__orders
        local superclass_super_cache = superclass.__super_cache

        local superclass_orders_n = #superclass_orders
        local offset = orders_n - superclass_orders_n

        if superclass_orders[superclass_orders_n] == lastclass and superclass_orders[superclass_orders_n - 1] == secondlastclass then

            
            local leftover_count = orders_n

            for j = superclass_orders_n - 2, 1, -1 do
                local inner_superclass = superclass_orders[j]
                if inner_superclass == orders[j + offset] then
                    super_cache[inner_superclass] = superclass_super_cache[inner_superclass]
                    leftover_count = leftover_count - 1
                else
                    break
                end
            end

            if leftover_count == 3 then
                return
            end

        end
    end

    -- create proxies for those that cannot be reused
    for i = 2, orders_n - 2 do
        local superclass = orders[i]
        if super_cache[superclass] == nil then
            super_cache[superclass] = create_proxy(class, i)
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

local MRO_SUPERCLASSES

local function create_superclasses(class, ...)
    return setmetatable({[0] = class, ...}, MRO_SUPERCLASSES)
end

local function propagate_superclass_change(class)
    local cache = class.__cache -- cannot reassign cache, because instance need the same ref
    for k, v in pairs(class.__cache) do
        cache[k] = nil
    end
    cache.class = class
    cache.__index = cache

    class.__super_cache = {}
    class.__orders = {class}
    resolve_inheritance(class)

    for subclass, v in pairs(class.__subclass_map) do
        propagate_superclass_change(subclass)
    end
end

MRO_SUPERCLASSES = {
    -- if you wanted to make class inherit itself, I am not stopping you
    __call = function(superclasses, ...)
        local class = superclasses[0]

        for i = 1, #superclasses do
            superclasses[i].__subclass_map[class] = nil
        end

        class.__superclasses = create_superclasses(class, ...)

        propagate_superclass_change(class)
    end
}

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


-- lua metamethods are not supported
--------------------------------------------------------------------------------------------------------------------------------
-- Built-in
--------------------------------------------------------------------------------------------------------------------------------

local Object = create_class()

function noop() end
Object.construct = noop
Object.destruct = noop

function Object:allocate() return {} end

function Object:new(...)
    local instance = setmetatable(self:allocate(), self.__cache)
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
