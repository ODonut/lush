-- library: lush
-- version: 1.0

-- normally lua needs two tables to have the same __eq in their metatable, however this is necessary in because in luaJIT, cdata can trigger __eq when compared to nil
local function is_nil(v)
    return rawequal(v, nil)
end

-- this is necessary for every single subclass, because they might call super() and get proxies at any stage in the MRO, and subsequent access on the proxy might cache something.
local function invalidate_super_cache_once(class, k, root)
    local orders = class.__orders
    local super_cache = class.__super_cache

    local proxy = super_cache[root]

    -- proxies only appear from 1 to #orders - 2, since the last one point to nil, and second last one point to last one's __declared
    -- exploiting the fact that proxy may store __i, since only super proxies prior to the root's next super proxy and including root's own super proxy needs invalidation (super_cache[root] gets next proxy after root, so minus 1 is necessary so that the upper bound of the loop includes root's proxy but not touch the proxy after it)
    -- this can be optimzied since if root has at least 1 superclass, it will be guaranteed that proxy after root cannot be false, and if root has at least 2 superclasses, it will be guranteed that the proxy after root is a real proxy with __i, not __declared, but based on my benchmarks the difference is negligible so I won't duplicate the code here.
    -- this is not a ternary operator, if either one of proxy or proxy.__i is falsey(since __declared has no __i), #orders - 1 gets chosen
    for i = 1, (proxy and proxy.__i or #orders - 1) - 1 do
        -- invariant: proxies always exist from 1 to #orders - 2
        super_cache[orders[i]][k] = nil
    end
end

local function invalidate_super_cache(class, k, root, visited)

    visited[class] = true
    invalidate_super_cache_once(class, k, root)
    

    for subclass, v in pairs(class.__subclass_map) do
        if not visited[subclass] then
            invalidate_super_cache(subclass, k, root, visited)
        end
    end
end

local function recurse_modify_cache(invalidate_cache, class, k, root, visited)

    -- track visited in case a child class inherits from 2 parent classes that both inherit from the same grandparent class, where with DFS, the child may be visited twice 
    visited[class] = true

    for subclass, v in pairs(class.__subclass_map) do

        if not visited[subclass] then

            -- didn't override means their cache entry needs to be invalidated
            if is_nil(subclass.__declared[k]) then
                invalidate_super_cache_once(subclass, k, root)
                invalidate_cache(subclass, k, root, visited)
            else
                -- otherwise only invalidate super_cache is necessary
                -- use a different recursion because invalidate_cache stops recursing
                invalidate_super_cache(subclass, k, root, visited) -- refresh_cache shares this branching because C3 guarantees that the subclass's cache has either this class's entry(because it declared it) or a sibling class's entry, so the root class's entry being changed is never relevant, thus can also just invalidate_super_cache()
            end

        end
    end
end

local function invalidate_cache(class, k, root, visited)
    class.__cache[k] = nil
    recurse_modify_cache(invalidate_cache, class, k, root, visited)
end

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

local function refresh_cache(class, k, root, visited)
    memoize(class.__cache, k, class.__orders, 1)
    recurse_modify_cache(refresh_cache, class, k, root, visited)
end

local function is_metamethod(k)
    return type(k) == "string" and k:sub(1, 2) == "__"
end

-- don't reassign internals like __class, __declared, __i, etc
local function declare_key(class, k, f)
    class.__declared[k] = f

    -- metamethods needs to be physically in cache everytime to work
    if is_metamethod(k) then

        refresh_cache(class, k, class, {})

    else

        invalidate_cache(class, k, class, {})
    end
end


local WEAK_KV = {__mode = "kv"}

local proxy_self_cache = setmetatable({}, WEAK_KV)

-- call_method is not coroutine safe, use manual super(currentclass, instance).method(instance, ...) if it matters
local function call_method(proxy, k, ...)
    return proxy[k](proxy_self_cache[proxy], ...)
end

-- class.__orders might be reassigned, proxy won't sync, be aware
local MRO_PROXY = {
    __index = function(proxy, k)
        return memoize(proxy, k, proxy.__orders, proxy.__i)
    end,
    __call = call_method,
}

-- false mean end of MRO, nil mean not found in MRO
-- both super(currentclass, instance) and super(currentclass, class) works
-- you can also use super() as instanceof via super(currentclass, instance) ~= nil
local function next_superclass(currentclass, instance)
    local proxy = instance.__class.__super_cache[currentclass]
    proxy_self_cache[proxy] = instance
    return proxy
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
local function warm_cache_metamethod(cache, orders, orders_n)
    -- IMPORTANT: includes class itself, resolve_inheritance populates metamethods to cache
    for i = orders_n, 1, -1 do
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
    local leftovers_n = orders_n - 2

    for i = last_superclass_orders_n - 2, 1, -1 do
        
        local j = i + offset
        local superclass = orders[j]
        
        if superclass == last_superclass_orders[i] then

            super_cache[superclass] = last_superclass_super_cache[superclass]

        else
            -- handle j since superclass is already grabbed
            super_cache[superclass] = create_proxy(orders, j + 1)

            leftovers_n = j - 1

        end
    end

    -- create necessary new proxies for everything prior to leftovers_n, since everything after leftovers_n is handled
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

local SUPERCLASSES = {}

local function create_superclasses(class, ...)
    return setmetatable({[0] = class, ...}, SUPERCLASSES)
end

-- syntax sugar for __new
local function create_instance(class, ...)
    return class:__new(...)
end

local DECLARED = {
    __call = call_method
}

local CLASS = {
    __index = function(class, k)
        return class.__cache[k]
    end,
    __newindex = declare_key,
    __call = create_instance,
}

local function create_class(...)
    local class = {
        __declared = setmetatable({}, DECLARED),
        __subclass_map = setmetatable({}, WEAK_K),
    }

    local cache = setmetatable({__class = class}, MRO_CACHE)
    cache.__index = cache
    class.__cache = cache

    class.__superclasses = create_superclasses(class, ...)
    class.__orders = {class}
    class.__super_cache = {[class] = false}
    resolve_inheritance(class)

    return setmetatable(class, CLASS)
end

--------------------------------------------------------------------------------------------------------------------------------
-- Change Inheritance
--------------------------------------------------------------------------------------------------------------------------------

-- reset class to the state prior to resolve inheritance
local function reset_class(class)

    -- reset cache, need to empty because instances' metatable is cache, can't just replace
    local cache = class.__cache

    for k, v in pairs(cache) do
        cache[k] = nil
    end

    cache.__class = class
    cache.__index = cache -- this is fine because in resolve_inheritance, if there is a __index declared, warm_cache_metamethod will override __index

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

function SUPERCLASSES.__call(superclasses, mode, ...)
    local class = superclasses[0]

    -- recursive
    if mode == "r" then
        class.__superclasses = create_superclasses(class, ...)

        local subclasses = {class}
        local i = 1
        local subclasses_n = 1
        local visited = {}

        -- this works because of the no redundancy invariant in resolve inheritance, if B and C inherits from A, D inherits from B and C, since no redundancy guarantees D cannot inherit from A, thus BFS works
        while i <= subclasses_n do
            local subclass = subclasses[i]
            i = i + 1

            if not visited[subclass] then
                visited[subclass] = true
                reset_resolve_inheritance(subclass)

                for inner_subclass in pairs(subclass.__subclass_map) do
                    subclasses_n = subclasses_n + 1
                    subclasses[subclasses_n] = inner_subclass
                end
            end
        end
    else
        class.__superclasses = create_superclasses(class, mode, ...)
        reset_resolve_inheritance(class)
    end
end



--------------------------------------------------------------------------------------------------------------------------------
-- Built-in
--------------------------------------------------------------------------------------------------------------------------------
-- I explicitly added metamethod support, so it works

-- invariant: instance does not have the same field directly, and is under standard metatable, this no longer works for cdata metatype, because getmetatable returns a string of the metatype
-- I don't really have a workaround for it, __metatable does not work since getmetatable(cdata) always return ffi, so you have to manually figure out it by capturing an upvalue
-- exploiting the fact that instance's metatable for Object is directly cache itself, so no extra information needs to be stored

local function dispatch_index(cache, instance, k)
    local v = cache[k]
    if type(v) == "table" then
        local get = v.__get
        if is_nil(get) then
            if not is_nil(v.__set) then
                error("property " .. tostring(k) .. " is set only")
            end
        else
            if type(get) == "function" then
                return get(instance)
            else
                error("invalid non-function getter")
            end
        end
    end
    return v
end

local function dispatch_newindex(cache,instance, k, x)
    local v = cache[k]
    if type(v) == "table" then
        local set = v.__set
        if is_nil(set) then
            if not is_nil(v.__get) then
                error("property " .. tostring(k) .. " is get only")
            end
        else
            if type(set) == "function" then
                set(instance, x)
                return
            else
                error("invalid non-function setter")
            end
        end

    end
    rawset(instance, k, x)
end

-- root Object class, opt-in
local Object = create_class()

-- accessor sugar, works across inheritance unless you override __index or __newindex
function Object.__index(instance, k)
    return dispatch_index(getmetatable(instance), instance, k)
end

function Object.__newindex(instance, k, x)
   return dispatch_newindex(getmetatable(instance), instance, k, x) 
end

function Object.__init(instance) end

function Object.__new(class, ...)
    local cache = class.__cache
    local instance = setmetatable({}, cache)
    cache.__init(instance, ...)
    return instance
end

--------------------------------------------------------------------------------------------------------------------------------
-- Cdata work around
--------------------------------------------------------------------------------------------------------------------------------
-- if you made __cache the metatype table of your ctype, do not use ctype() directly, because the name __new lush uses is its own initialization metamethod in cdata, instead use ffi.new(ctype) which ignores __new

local function curry_dispatch_index(cache)
    return function(instance, k)
        return dispatch_index(cache, instance, k)
    end
end

local function curry_dispatch_newindex(cache)
    return function(instance, k, x)
        return dispatch_newindex(cache, instance, k, x)
    end
end

local success, ffi = pcall(require, "ffi")

local function curry_new(ctype, ...)
    return function(class, ...)
        local instance = ffi.new(ctype)
        instance:__init(...)
        return instance
    end
end

--------------------------------------------------------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------------------------------------------------------

return {
    class = create_class,
    super = next_superclass,
    Object = Object,

    cd_index = curry_dispatch_index,
    cd_newindex = curry_dispatch_newindex,
    c_new = curry_new,
}
