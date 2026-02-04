local WsExplorer = {}

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local ws = nil
local connected = false
local subscriptions = {}
local idCounter = 0

local env = {
    getnilinstances = getnilinstances,
    getloadedmodules = getloadedmodules,
    decompile = decompile,
    getproperties = getproperties,
    gethiddenproperties = gethiddenproperties,
    getscriptbytecode = getscriptbytecode,
    getconnections = getconnections,
    getcallbackvalue = getcallbackvalue,
    getrawmetatable = getrawmetatable,
    hookfunction = hookfunction,
    isreadonly = isreadonly,
    setreadonly = setreadonly,
    getgc = getgc,
    getupvalues = getupvalues,
    setupvalue = setupvalue,
    getinfo = getinfo or debug.info,
}

local function generateId()
    idCounter = idCounter + 1
    return idCounter
end

local function safeToString(value)
    local s, r = pcall(tostring, value)
    return s and r or "???"
end

local function safeIsA(inst, className)
    local s, r = pcall(function() return inst:IsA(className) end)
    return s and r
end

local function serializeValue(value, depth)
    depth = depth or 0
    if depth > 3 then return {type = "truncated"} end

    local t = typeof(value)

    if t == "nil" then
        return {type = "nil"}
    elseif t == "boolean" then
        return {type = "boolean", value = value}
    elseif t == "number" then
        return {type = "number", value = value}
    elseif t == "string" then
        return {type = "string", value = value}
    elseif t == "Instance" then
        local name = safeToString(value)
        local className = ""
        pcall(function() className = value.ClassName end)
        return {type = "Instance", className = className, name = name}
    elseif t == "Vector3" then
        return {type = "Vector3", x = value.X, y = value.Y, z = value.Z}
    elseif t == "Vector2" then
        return {type = "Vector2", x = value.X, y = value.Y}
    elseif t == "CFrame" then
        return {type = "CFrame", components = {value:GetComponents()}}
    elseif t == "Color3" then
        return {type = "Color3", r = value.R, g = value.G, b = value.B}
    elseif t == "BrickColor" then
        return {type = "BrickColor", name = value.Name}
    elseif t == "UDim" then
        return {type = "UDim", scale = value.Scale, offset = value.Offset}
    elseif t == "UDim2" then
        return {type = "UDim2", xScale = value.X.Scale, xOffset = value.X.Offset, yScale = value.Y.Scale, yOffset = value.Y.Offset}
    elseif t == "Rect" then
        return {type = "Rect", minX = value.Min.X, minY = value.Min.Y, maxX = value.Max.X, maxY = value.Max.Y}
    elseif t == "Ray" then
        return {type = "Ray", origin = {value.Origin.X, value.Origin.Y, value.Origin.Z}, direction = {value.Direction.X, value.Direction.Y, value.Direction.Z}}
    elseif t == "Enum" then
        return {type = "Enum", value = tostring(value)}
    elseif t == "EnumItem" then
        return {type = "EnumItem", enum = tostring(value.EnumType), name = value.Name, value = value.Value}
    elseif t == "NumberSequence" or t == "ColorSequence" then
        return {type = t, keypoints = #value.Keypoints}
    elseif t == "NumberRange" then
        return {type = "NumberRange", min = value.Min, max = value.Max}
    elseif t == "table" then
        if depth > 1 then return {type = "table"} end
        local result = {}
        local count = 0
        for k, v in pairs(value) do
            if count >= 20 then break end
            result[safeToString(k)] = serializeValue(v, depth + 1)
            count = count + 1
        end
        return {type = "table", value = result}
    elseif t == "function" then
        return {type = "function"}
    elseif t == "thread" then
        return {type = "thread"}
    else
        return {type = t, string = safeToString(value)}
    end
end

local serviceCache = {}
local function isService(inst)
    local className = inst.ClassName
    if serviceCache[className] ~= nil then
        return serviceCache[className]
    end
    local s, r = pcall(function() return game:GetService(className) == inst end)
    serviceCache[className] = s and r
    return serviceCache[className]
end

local function getInstancePath(obj)
    if not obj then return "" end

    local parts = {}
    local curObj = obj
    local depth = 0

    while curObj and depth < 50 do
        if curObj == game then
            table.insert(parts, 1, "game")
            break
        end

        local curName = safeToString(curObj)
        local indexName

        if curName:match("^[%a_][%w_]*$") then
            indexName = "." .. curName
        else
            indexName = '["' .. curName:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"]'
        end

        local parObj
        pcall(function() parObj = curObj.Parent end)

        if parObj == game and isService(curObj) then
            indexName = ':GetService("' .. curObj.ClassName .. '")'
        end

        table.insert(parts, 1, indexName)
        curObj = parObj
        depth = depth + 1
    end

    local path = table.concat(parts)
    if path == "" then
        path = "nil:" .. safeToString(obj)
    end

    return path
end

local function getInstanceFromPath(path)
    if not path or path == "" then return nil end

    if path:sub(1, 4) == "nil:" then
        local targetName = path:sub(5)
        if env.getnilinstances then
            local s, nilInsts = pcall(env.getnilinstances)
            if s then
                for _, inst in ipairs(nilInsts) do
                    if safeToString(inst) == targetName then
                        return inst
                    end
                end
            end
        end
        return nil
    end

    local fn = loadstring("return " .. path)
    if fn then
        local s, result = pcall(fn)
        if s and typeof(result) == "Instance" then
            return result
        end
    end
    return nil
end

local function getInstanceInfoFast(inst)
    if not inst then return nil end

    local info = {
        id = generateId()
    }

    pcall(function() info.name = inst.Name end)
    pcall(function() info.className = inst.ClassName end)

    info.name = info.name or safeToString(inst)
    info.className = info.className or "Unknown"

    local s, children = pcall(function() return inst:GetChildren() end)
    info.childCount = s and #children or 0

    if safeIsA(inst, "LuaSourceContainer") then
        info.isScript = true
        if safeIsA(inst, "LocalScript") or safeIsA(inst, "Script") then
            pcall(function() info.disabled = inst.Disabled end)
        end
    end

    return info
end

local function getInstanceInfo(inst)
    if not inst then return nil end

    local info = getInstanceInfoFast(inst)
    if not info then return nil end

    info.path = getInstancePath(inst)

    pcall(function()
        info.parent = inst.Parent and getInstancePath(inst.Parent) or nil
    end)

    pcall(function()
        if safeIsA(inst, "BasePart") then
            info.position = {inst.Position.X, inst.Position.Y, inst.Position.Z}
            info.size = {inst.Size.X, inst.Size.Y, inst.Size.Z}
        end
    end)

    return info
end

local function getChildren(inst)
    if not inst then return {} end

    local children = {}
    local s, kids = pcall(function() return inst:GetChildren() end)
    if not s then return {} end

    for _, child in ipairs(kids) do
        local info = getInstanceInfo(child)
        if info then
            table.insert(children, info)
        end
    end
    return children
end

local function getTree(inst, depth)
    if not inst then return nil end
    depth = depth or 1

    local info = getInstanceInfo(inst)
    if not info then return nil end

    if depth > 0 then
        info.children = {}
        local s, kids = pcall(function() return inst:GetChildren() end)
        if s then
            for _, child in ipairs(kids) do
                local childTree = getTree(child, depth - 1)
                if childTree then
                    table.insert(info.children, childTree)
                end
            end
        end
    end

    return info
end

local defaultProps = {"Name", "Parent", "ClassName", "Archivable"}

local classPropMap = {
    BasePart = {"Position", "Size", "CFrame", "Orientation", "Anchored", "CanCollide", "Transparency", "Color", "Material"},
    Part = {"Shape"},
    MeshPart = {"MeshId", "TextureID"},
    Model = {"PrimaryPart"},
    Humanoid = {"Health", "MaxHealth", "WalkSpeed", "JumpPower"},
    GuiObject = {"Position", "Size", "AnchorPoint", "Visible", "BackgroundColor3", "BackgroundTransparency"},
    TextLabel = {"Text", "TextColor3", "TextSize", "Font"},
    TextButton = {"Text", "TextColor3", "TextSize", "Font"},
    ImageLabel = {"Image", "ImageColor3", "ImageTransparency"},
    Sound = {"SoundId", "Volume", "Playing", "Looped"},
    Script = {"Disabled"},
    LocalScript = {"Disabled"},
    ObjectValue = {"Value"},
    StringValue = {"Value"},
    IntValue = {"Value"},
    NumberValue = {"Value"},
    BoolValue = {"Value"},
}

local function getProperties(inst)
    if not inst then return {} end

    local props = {}
    local propsToRead = {}

    for _, p in ipairs(defaultProps) do
        propsToRead[p] = true
    end

    for class, classProps in pairs(classPropMap) do
        if safeIsA(inst, class) then
            for _, p in ipairs(classProps) do
                propsToRead[p] = true
            end
        end
    end

    if env.getproperties then
        local s, allProps = pcall(env.getproperties, inst)
        if s and type(allProps) == "table" then
            for _, p in ipairs(allProps) do
                propsToRead[p] = true
            end
        end
    end

    for propName in pairs(propsToRead) do
        local success, value = pcall(function() return inst[propName] end)
        if success then
            props[propName] = serializeValue(value)
        end
    end

    return props
end

local function setProperty(inst, propName, value)
    if not inst then return false, "Instance not found" end
    local success, err = pcall(function() inst[propName] = value end)
    return success, err
end

local function searchInstances(query, options)
    options = options or {}
    local results = {}
    local maxResults = options.maxResults or 10000
    local searchIn = options.searchIn or game
    local caseSensitive = options.caseSensitive or false
    local searchClassName = options.searchClassName or false

    if type(searchIn) == "string" then
        searchIn = getInstanceFromPath(searchIn) or game
    end

    local lowerQuery = not caseSensitive and query:lower() or query

    local function matches(inst)
        local name = safeToString(inst)
        local checkName = caseSensitive and name or name:lower()

        if checkName:find(lowerQuery, 1, true) then
            return true
        end

        if searchClassName then
            local className = ""
            pcall(function() className = inst.ClassName end)
            className = caseSensitive and className or className:lower()
            if className:find(lowerQuery, 1, true) then
                return true
            end
        end

        return false
    end

    local checked = 0
    local function search(inst)
        if #results >= maxResults then return end

        if matches(inst) then
            table.insert(results, getInstanceInfo(inst))
        end

        checked = checked + 1
        if checked % 200 == 0 then
            task.wait()
        end

        local s, kids = pcall(function() return inst:GetChildren() end)
        if s then
            for _, child in ipairs(kids) do
                if #results >= maxResults then return end
                search(child)
            end
        end
    end

    search(searchIn)

    return results
end

local function getNilInstances()
    if not env.getnilinstances then return {} end

    local results = {}
    local s, nilInsts = pcall(env.getnilinstances)
    if not s or type(nilInsts) ~= "table" then return {} end

    for i, inst in ipairs(nilInsts) do
        if i % 100 == 0 then task.wait() end
        local info = getInstanceInfo(inst)
        if info then
            table.insert(results, info)
        end
    end

    return results
end

local function getLoadedModules()
    if not env.getloadedmodules then return {} end

    local results = {}
    local s, modules = pcall(env.getloadedmodules)
    if not s or type(modules) ~= "table" then return {} end

    for i, mod in ipairs(modules) do
        if i % 50 == 0 then task.wait() end
        if safeIsA(mod, "ModuleScript") then
            local info = getInstanceInfo(mod)
            if info then
                table.insert(results, info)
            end
        end
    end

    return results
end

local function getServices()
    local services = {}
    local serviceNames = {
        "Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage",
        "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer",
        "Teams", "SoundService", "Chat", "HttpService", "RunService", "UserInputService",
        "TweenService", "Debris", "MarketplaceService", "TeleportService",
        "CollectionService", "TextService"
    }

    for _, name in ipairs(serviceNames) do
        local s, service = pcall(function() return game:GetService(name) end)
        if s and service then
            table.insert(services, {
                name = name,
                className = service.ClassName,
                path = 'game:GetService("' .. name .. '")'
            })
        end
    end

    return services
end

local function decompileScript(inst)
    if not inst then return nil, "Instance not found" end
    if not env.decompile then return nil, "Decompile not available" end

    local s, source = pcall(env.decompile, inst)
    if s then
        return source
    else
        return nil, tostring(source)
    end
end

local function getScriptBytecode(inst)
    if not inst then return nil, "Instance not found" end
    if not env.getscriptbytecode then return nil, "getscriptbytecode not available" end

    local s, bytecode = pcall(env.getscriptbytecode, inst)
    if s then
        return bytecode
    else
        return nil, tostring(bytecode)
    end
end

local function getSignalConnections(inst, signalName)
    if not inst or not env.getconnections then return {} end

    local s1, signal = pcall(function() return inst[signalName] end)
    if not s1 or not signal then return {} end

    local s2, cons = pcall(env.getconnections, signal)
    if not s2 then return {} end

    local results = {}
    for i, con in ipairs(cons) do
        if i % 50 == 0 then task.wait() end
        table.insert(results, {
            index = i,
            enabled = con.Enabled,
            foreignState = con.ForeignState,
        })
    end

    return results
end

local function sendMessage(msgType, data)
    if not connected or not ws then return end

    local msg = {
        type = msgType,
        data = data,
        timestamp = os.clock()
    }

    local s, encoded = pcall(function() return HttpService:JSONEncode(msg) end)
    if s then
        pcall(function() ws:Send(encoded) end)
    end
end

local messageHandlers = {}

messageHandlers["ping"] = function(payload, respond)
    respond("pong", {timestamp = os.clock()})
end

messageHandlers["getTree"] = function(payload, respond)
    local path = payload.path or "game"
    local depth = payload.depth or 1
    local inst = getInstanceFromPath(path)
    respond("tree", {path = path, tree = getTree(inst, depth)})
end

messageHandlers["getChildren"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    respond("children", {path = payload.path, children = getChildren(inst)})
end

messageHandlers["getProperties"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    respond("properties", {path = payload.path, properties = getProperties(inst)})
end

messageHandlers["setProperty"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    local success, err = setProperty(inst, payload.property, payload.value)
    respond("propertySet", {path = payload.path, property = payload.property, success = success, error = err})
end

messageHandlers["search"] = function(payload, respond)
    local results = searchInstances(payload.query or "", payload.options or {})
    respond("searchResults", {query = payload.query, results = results, count = #results})
end

messageHandlers["getInstance"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    respond("instance", {path = payload.path, info = getInstanceInfo(inst)})
end

messageHandlers["getNil"] = function(payload, respond)
    local nilInsts = getNilInstances()
    respond("nilInstances", {instances = nilInsts, count = #nilInsts})
end

messageHandlers["getLoadedModules"] = function(payload, respond)
    local modules = getLoadedModules()
    respond("loadedModules", {modules = modules, count = #modules})
end

messageHandlers["getServices"] = function(payload, respond)
    respond("services", {services = getServices()})
end

messageHandlers["decompile"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    local source, err = decompileScript(inst)
    respond("decompiled", {path = payload.path, source = source, error = err, success = source ~= nil})
end

messageHandlers["getBytecode"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    local bytecode, err = getScriptBytecode(inst)
    respond("bytecode", {path = payload.path, bytecode = bytecode, error = err, success = bytecode ~= nil})
end

messageHandlers["getConnections"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    local cons = getSignalConnections(inst, payload.signal)
    respond("connections", {path = payload.path, signal = payload.signal, connections = cons})
end

messageHandlers["clone"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    if not inst then
        respond("cloned", {path = payload.path, success = false, error = "Instance not found"})
        return
    end

    local s, cloned = pcall(function() return inst:Clone() end)
    if s and cloned then
        if payload.parent then
            local parent = getInstanceFromPath(payload.parent)
            if parent then cloned.Parent = parent end
        end
        respond("cloned", {path = payload.path, newPath = getInstancePath(cloned), success = true})
    else
        respond("cloned", {path = payload.path, success = false, error = tostring(cloned)})
    end
end

messageHandlers["destroy"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    if not inst then
        respond("destroyed", {path = payload.path, success = false, error = "Instance not found"})
        return
    end

    local s, err = pcall(function() inst:Destroy() end)
    respond("destroyed", {path = payload.path, success = s, error = err})
end

messageHandlers["execute"] = function(payload, respond)
    local fn, compileErr = loadstring(payload.code)
    if not fn then
        respond("executeResult", {success = false, error = compileErr})
        return
    end

    local results = {pcall(fn)}
    local serializedResults = {}
    for i = 2, math.min(#results, 10) do
        table.insert(serializedResults, serializeValue(results[i]))
    end
    respond("executeResult", {success = results[1], results = serializedResults, error = not results[1] and results[2] or nil})
end

messageHandlers["getGameInfo"] = function(payload, respond)
    respond("gameInfo", {
        gameId = game.GameId,
        placeId = game.PlaceId,
        placeVersion = game.PlaceVersion,
        jobId = game.JobId,
    })
end

messageHandlers["getPlayerInfo"] = function(payload, respond)
    local player = Players.LocalPlayer
    if player then
        respond("playerInfo", {
            name = player.Name,
            displayName = player.DisplayName,
            userId = player.UserId,
        })
    else
        respond("playerInfo", {error = "LocalPlayer not found"})
    end
end

messageHandlers["fireServer"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    if inst and safeIsA(inst, "RemoteEvent") then
        local s, err = pcall(function() inst:FireServer(table.unpack(payload.args or {})) end)
        respond("fired", {path = payload.path, success = s, error = err})
    else
        respond("fired", {path = payload.path, success = false, error = "RemoteEvent not found"})
    end
end

messageHandlers["invokeServer"] = function(payload, respond)
    local inst = getInstanceFromPath(payload.path)
    if inst and safeIsA(inst, "RemoteFunction") then
        local results = {pcall(function() return inst:InvokeServer(table.unpack(payload.args or {})) end)}
        if results[1] then
            local serializedResults = {}
            for i = 2, #results do
                table.insert(serializedResults, serializeValue(results[i]))
            end
            respond("invoked", {path = payload.path, success = true, results = serializedResults})
        else
            respond("invoked", {path = payload.path, success = false, error = results[2]})
        end
    else
        respond("invoked", {path = payload.path, success = false, error = "RemoteFunction not found"})
    end
end

local function handleMessage(raw)
    local s, msg = pcall(function() return HttpService:JSONDecode(raw) end)
    if not s or not msg or not msg.type then return end

    local msgType = msg.type
    local payload = msg.data or {}
    local requestId = msg.requestId

    local function respond(respType, respData)
        respData = respData or {}
        respData.requestId = requestId
        sendMessage(respType, respData)
    end

    local handler = messageHandlers[msgType]
    if handler then
        local s2, err = pcall(handler, payload, respond)
        if not s2 then
            respond("error", {error = tostring(err), originalType = msgType})
        end
    end
end

local EXPLORER_PORT = 21574

function WsExplorer.connect(url)
    if connected then
        WsExplorer.disconnect()
    end

    url = url or ("ws://127.0.0.1:" .. EXPLORER_PORT)

    local success, socket = pcall(function() return WebSocket.connect(url) end)
    if not success or not socket then
        error("Failed to connect to WebSocket: " .. tostring(socket))
    end

    ws = socket
    connected = true

    ws.OnMessage:Connect(function(msg)
        task.spawn(handleMessage, msg)
    end)

    ws.OnClose:Connect(function()
        connected = false
        ws = nil
        for subId, sub in pairs(subscriptions) do
            for _, con in ipairs(sub.connections or {}) do
                pcall(function() con:Disconnect() end)
            end
        end
        table.clear(subscriptions)
    end)

    sendMessage("connected", {
        gameId = game.GameId,
        placeId = game.PlaceId,
        placeVersion = game.PlaceVersion,
        jobId = game.JobId,
        executor = identifyexecutor and identifyexecutor() or "unknown",
        timestamp = os.clock()
    })

    return WsExplorer
end

function WsExplorer.disconnect()
    if ws then
        for _, sub in pairs(subscriptions) do
            for _, con in ipairs(sub.connections or {}) do
                pcall(function() con:Disconnect() end)
            end
        end
        table.clear(subscriptions)
        pcall(function() ws:Close() end)
    end
    ws = nil
    connected = false
end

function WsExplorer.isConnected()
    return connected
end

WsExplorer.connect()

return WsExplorer
