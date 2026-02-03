local WsExplorer = {}

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ws = nil
local connected = false
local nodes = {}
local nilMap = {}
local nilCons = {}
local subscriptions = {}
local connections = {}
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

local ffa = game.FindFirstAncestorWhichIsA
local getDescendants = game.GetDescendants
local isa = game.IsA

local function generateId()
    idCounter = idCounter + 1
    return idCounter
end

local function safeToString(value)
    local s, r = pcall(tostring, value)
    return s and r or "???"
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
        return {type = "Instance", className = value.ClassName, name = safeToString(value), path = getInstancePath(value)}
    elseif t == "Vector3" then
        return {type = "Vector3", x = value.X, y = value.Y, z = value.Z}
    elseif t == "Vector2" then
        return {type = "Vector2", x = value.X, y = value.Y}
    elseif t == "CFrame" then
        local components = {value:GetComponents()}
        return {type = "CFrame", components = components}
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
    elseif t == "NumberSequence" then
        local keypoints = {}
        for _, kp in ipairs(value.Keypoints) do
            table.insert(keypoints, {time = kp.Time, value = kp.Value, envelope = kp.Envelope})
        end
        return {type = "NumberSequence", keypoints = keypoints}
    elseif t == "ColorSequence" then
        local keypoints = {}
        for _, kp in ipairs(value.Keypoints) do
            table.insert(keypoints, {time = kp.Time, r = kp.Value.R, g = kp.Value.G, b = kp.Value.B})
        end
        return {type = "ColorSequence", keypoints = keypoints}
    elseif t == "NumberRange" then
        return {type = "NumberRange", min = value.Min, max = value.Max}
    elseif t == "table" then
        local result = {}
        for k, v in pairs(value) do
            result[safeToString(k)] = serializeValue(v, depth + 1)
        end
        return {type = "table", value = result}
    elseif t == "function" then
        return {type = "function"}
    elseif t == "thread" then
        return {type = "thread"}
    elseif t == "userdata" then
        return {type = "userdata", string = safeToString(value)}
    else
        return {type = t, string = safeToString(value)}
    end
end

function getInstancePath(obj)
    if not obj then return "" end

    local path = ""
    local curObj = obj

    while curObj do
        if curObj == game then
            path = "game" .. path
            break
        end

        local curName = safeToString(curObj)
        local indexName

        if curName:match("^[%a_][%w_]*$") then
            indexName = "." .. curName
        else
            local cleanName = curName:gsub("\\", "\\\\"):gsub('"', '\\"')
            indexName = '["' .. cleanName .. '"]'
        end

        local parObj = curObj.Parent
        if parObj then
            local fc = parObj:FindFirstChild(curName)
            if parObj == game then
                local className = curObj.ClassName
                local isService = pcall(function() return game:GetService(className) end)
                if isService then
                    indexName = ':GetService("' .. className .. '")'
                end
            end
        end

        path = indexName .. path
        curObj = parObj
    end

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
            for _, inst in ipairs(env.getnilinstances()) do
                if safeToString(inst) == targetName then
                    return inst
                end
            end
        end
        return nil
    end

    local fn, err = loadstring("return " .. path)
    if fn then
        local s, result = pcall(fn)
        if s and typeof(result) == "Instance" then
            return result
        end
    end
    return nil
end

local function getInstanceInfo(inst)
    if not inst then return nil end

    local info = {
        name = safeToString(inst),
        className = inst.ClassName,
        path = getInstancePath(inst),
        childCount = #inst:GetChildren(),
        id = generateId()
    }

    pcall(function()
        info.parent = inst.Parent and getInstancePath(inst.Parent) or nil
    end)

    pcall(function()
        if isa(inst, "BasePart") then
            info.position = {inst.Position.X, inst.Position.Y, inst.Position.Z}
            info.size = {inst.Size.X, inst.Size.Y, inst.Size.Z}
        end
    end)

    pcall(function()
        if isa(inst, "LuaSourceContainer") then
            info.isScript = true
            if isa(inst, "LocalScript") or isa(inst, "Script") then
                info.disabled = inst.Disabled
            end
        end
    end)

    return info
end

local function getChildren(inst)
    if not inst then return {} end

    local children = {}
    for _, child in ipairs(inst:GetChildren()) do
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
        for _, child in ipairs(inst:GetChildren()) do
            local childTree = getTree(child, depth - 1)
            if childTree then
                table.insert(info.children, childTree)
            end
        end
    end

    return info
end

local function getProperties(inst)
    if not inst then return {} end

    local props = {}
    local className = inst.ClassName

    local defaultProps = {
        "Name", "Parent", "ClassName", "Archivable"
    }

    local classPropMap = {
        BasePart = {"Position", "Size", "CFrame", "Orientation", "Anchored", "CanCollide", "Transparency", "Color", "Material", "BrickColor", "Reflectance", "Massless", "RootPriority"},
        Part = {"Shape"},
        MeshPart = {"MeshId", "TextureID"},
        Model = {"PrimaryPart", "WorldPivot"},
        Humanoid = {"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight", "AutoRotate"},
        Player = {"UserId", "DisplayName", "Team", "Character", "AccountAge"},
        GuiObject = {"Position", "Size", "AnchorPoint", "Visible", "BackgroundColor3", "BackgroundTransparency", "BorderColor3", "BorderSizePixel", "ZIndex", "LayoutOrder", "Rotation"},
        TextLabel = {"Text", "TextColor3", "TextSize", "Font", "TextScaled", "TextWrapped", "TextXAlignment", "TextYAlignment"},
        TextButton = {"Text", "TextColor3", "TextSize", "Font"},
        TextBox = {"Text", "PlaceholderText", "ClearTextOnFocus"},
        ImageLabel = {"Image", "ImageColor3", "ImageTransparency", "ScaleType"},
        ImageButton = {"Image", "ImageColor3", "ImageTransparency"},
        Frame = {},
        ScrollingFrame = {"CanvasSize", "CanvasPosition", "ScrollBarThickness"},
        Sound = {"SoundId", "Volume", "Pitch", "Playing", "Looped", "TimePosition", "TimeLength"},
        Animation = {"AnimationId"},
        Animator = {},
        Script = {"Source", "Disabled"},
        LocalScript = {"Source", "Disabled"},
        ModuleScript = {"Source"},
        RemoteEvent = {},
        RemoteFunction = {},
        BindableEvent = {},
        BindableFunction = {},
        ObjectValue = {"Value"},
        StringValue = {"Value"},
        IntValue = {"Value"},
        NumberValue = {"Value"},
        BoolValue = {"Value"},
        Color3Value = {"Value"},
        BrickColorValue = {"Value"},
        Vector3Value = {"Value"},
        CFrameValue = {"Value"},
        Camera = {"CameraType", "CameraSubject", "FieldOfView", "Focus", "CFrame"},
        Lighting = {"Ambient", "Brightness", "ColorShift_Bottom", "ColorShift_Top", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "GlobalShadows", "OutdoorAmbient", "ShadowSoftness", "ClockTime", "GeographicLatitude", "TimeOfDay", "FogColor", "FogEnd", "FogStart"},
        Workspace = {"CurrentCamera", "Gravity", "FallenPartsDestroyHeight"},
        ReplicatedStorage = {},
        ServerStorage = {},
        StarterGui = {"ResetPlayerGuiOnSpawn", "ShowDevelopmentGui"},
        StarterPack = {},
        StarterPlayer = {"CameraMaxZoomDistance", "CameraMinZoomDistance", "CameraMode", "HealthDisplayDistance", "NameDisplayDistance"},
        Teams = {},
        TeleportService = {},
        Decal = {"Texture", "Face", "Color3", "Transparency"},
        Texture = {"Texture", "Face", "StudsPerTileU", "StudsPerTileV"},
        SpawnLocation = {"TeamColor", "AllowTeamChangeOnTouch", "Duration", "Enabled", "Neutral"},
        Seat = {"Occupant", "Disabled"},
        VehicleSeat = {"Occupant", "MaxSpeed", "Steer", "Throttle", "Torque", "TurnSpeed"},
        Tool = {"CanBeDropped", "Enabled", "Grip", "ManualActivationOnly", "RequiresHandle", "ToolTip"},
        Weld = {"C0", "C1", "Part0", "Part1"},
        WeldConstraint = {"Part0", "Part1", "Enabled"},
        Motor6D = {"C0", "C1", "Part0", "Part1", "CurrentAngle", "DesiredAngle", "MaxVelocity"},
        Attachment = {"CFrame", "Position", "Orientation", "Axis", "SecondaryAxis", "Visible"},
        Beam = {"Attachment0", "Attachment1", "Color", "Enabled", "FaceCamera", "LightEmission", "LightInfluence", "Segments", "Texture", "TextureLength", "TextureMode", "TextureSpeed", "Transparency", "Width0", "Width1", "ZOffset"},
        ParticleEmitter = {"Color", "Enabled", "LightEmission", "LightInfluence", "Rate", "RotSpeed", "Rotation", "Size", "Speed", "SpreadAngle", "Texture", "Transparency", "ZOffset"},
        PointLight = {"Brightness", "Color", "Enabled", "Range", "Shadows"},
        SpotLight = {"Angle", "Brightness", "Color", "Enabled", "Face", "Range", "Shadows"},
        SurfaceLight = {"Angle", "Brightness", "Color", "Enabled", "Face", "Range", "Shadows"},
        Fire = {"Color", "Enabled", "Heat", "SecondaryColor", "Size"},
        Smoke = {"Color", "Enabled", "Opacity", "RiseVelocity", "Size"},
        Sparkles = {"Color", "Enabled", "SparkleColor"},
        Explosion = {"BlastPressure", "BlastRadius", "Position", "Visible"},
        BodyForce = {"Force"},
        BodyVelocity = {"MaxForce", "P", "Velocity"},
        BodyPosition = {"D", "MaxForce", "P", "Position"},
        BodyGyro = {"CFrame", "D", "MaxTorque", "P"},
        BillboardGui = {"Adornee", "AlwaysOnTop", "Enabled", "ExtentsOffset", "ExtentsOffsetWorldSpace", "LightInfluence", "MaxDistance", "Size", "SizeOffset", "StudsOffset", "StudsOffsetWorldSpace"},
        SurfaceGui = {"Adornee", "AlwaysOnTop", "Enabled", "Face", "LightInfluence", "PixelsPerStud", "SizingMode", "ZOffset"},
        ScreenGui = {"DisplayOrder", "Enabled", "IgnoreGuiInset", "ResetOnSpawn"},
        UIListLayout = {"FillDirection", "HorizontalAlignment", "Padding", "SortOrder", "VerticalAlignment"},
        UIGridLayout = {"CellPadding", "CellSize", "FillDirection", "FillDirectionMaxCells", "HorizontalAlignment", "SortOrder", "StartCorner", "VerticalAlignment"},
        UICorner = {"CornerRadius"},
        UIPadding = {"PaddingBottom", "PaddingLeft", "PaddingRight", "PaddingTop"},
        UIScale = {"Scale"},
        UIStroke = {"ApplyStrokeMode", "Color", "Enabled", "LineJoinMode", "Thickness", "Transparency"},
        UIGradient = {"Color", "Enabled", "Offset", "Rotation", "Transparency"},
    }

    local propsToRead = {}
    for _, p in ipairs(defaultProps) do
        propsToRead[p] = true
    end

    for class, classProps in pairs(classPropMap) do
        if pcall(function() return isa(inst, class) end) and isa(inst, class) then
            for _, p in ipairs(classProps) do
                propsToRead[p] = true
            end
        end
    end

    if env.getproperties then
        local s, allProps = pcall(env.getproperties, inst)
        if s then
            for _, p in ipairs(allProps) do
                propsToRead[p] = true
            end
        end
    end

    if env.gethiddenproperties then
        local s, hiddenProps = pcall(env.gethiddenproperties, inst)
        if s then
            for _, p in ipairs(hiddenProps) do
                propsToRead[p] = true
            end
        end
    end

    for propName in pairs(propsToRead) do
        local success, value = pcall(function()
            return inst[propName]
        end)
        if success then
            props[propName] = serializeValue(value)
        end
    end

    return props
end

local function setProperty(inst, propName, value)
    if not inst then return false, "Instance not found" end

    local success, err = pcall(function()
        inst[propName] = value
    end)

    return success, err
end

local function searchInstances(query, options)
    options = options or {}
    local results = {}
    local maxResults = options.maxResults or 100
    local searchIn = options.searchIn or game
    local caseSensitive = options.caseSensitive or false
    local searchClassName = options.searchClassName or false
    local searchPath = options.searchPath or false

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
            local className = caseSensitive and inst.ClassName or inst.ClassName:lower()
            if className:find(lowerQuery, 1, true) then
                return true
            end
        end

        if searchPath then
            local path = getInstancePath(inst)
            local checkPath = caseSensitive and path or path:lower()
            if checkPath:find(lowerQuery, 1, true) then
                return true
            end
        end

        return false
    end

    local function search(inst)
        if #results >= maxResults then return end

        if matches(inst) then
            table.insert(results, getInstanceInfo(inst))
        end

        for _, child in ipairs(inst:GetChildren()) do
            if #results >= maxResults then return end
            search(child)
        end
    end

    search(searchIn)

    if env.getnilinstances and (searchIn == game or options.includeNil) then
        for _, inst in ipairs(env.getnilinstances()) do
            if #results >= maxResults then break end
            if matches(inst) then
                table.insert(results, getInstanceInfo(inst))
            end
        end
    end

    return results
end

local function getNilInstances()
    if not env.getnilinstances then return {} end

    local results = {}
    local nilInsts = env.getnilinstances()

    for _, inst in ipairs(nilInsts) do
        table.insert(results, getInstanceInfo(inst))
    end

    return results
end

local function getLoadedModules()
    if not env.getloadedmodules then return {} end

    local results = {}
    local modules = env.getloadedmodules()

    for _, mod in ipairs(modules) do
        table.insert(results, getInstanceInfo(mod))
    end

    return results
end

local function getServices()
    local services = {}
    local serviceNames = {
        "Workspace", "Players", "Lighting", "ReplicatedFirst", "ReplicatedStorage",
        "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer",
        "Teams", "SoundService", "Chat", "LocalizationService", "TestService",
        "HttpService", "RunService", "UserInputService", "ContextActionService",
        "TweenService", "Debris", "PhysicsService", "PathfindingService",
        "MarketplaceService", "TeleportService", "SocialService", "PolicyService",
        "VRService", "HapticService", "AssetService", "BadgeService",
        "CollectionService", "GamePassService", "InsertService", "MemoryStoreService",
        "NetworkClient", "ProximityPromptService", "TextService", "VoiceChatService"
    }

    for _, name in ipairs(serviceNames) do
        local s, service = pcall(function()
            return game:GetService(name)
        end)
        if s and service then
            table.insert(services, {
                name = name,
                className = service.ClassName,
                path = getInstancePath(service)
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
        return nil, source
    end
end

local function getScriptBytecode(inst)
    if not inst then return nil, "Instance not found" end
    if not env.getscriptbytecode then return nil, "getscriptbytecode not available" end

    local s, bytecode = pcall(env.getscriptbytecode, inst)
    if s then
        return bytecode
    else
        return nil, bytecode
    end
end

local function getSignalConnections(inst, signalName)
    if not inst then return {} end
    if not env.getconnections then return {} end

    local signal = inst[signalName]
    if not signal then return {} end

    local s, cons = pcall(env.getconnections, signal)
    if not s then return {} end

    local results = {}
    for i, con in ipairs(cons) do
        local info = {
            index = i,
            enabled = con.Enabled,
            foreignState = con.ForeignState,
        }
        if con.Function then
            local fInfo = env.getinfo and env.getinfo(con.Function) or debug.info and {source = debug.info(con.Function, "s")}
            if fInfo then
                info.source = fInfo.source
                info.line = fInfo.currentline or fInfo.linedefined
            end
        end
        table.insert(results, info)
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

    local encoded = HttpService:JSONEncode(msg)
    pcall(function()
        ws:Send(encoded)
    end)
end

local function handleMessage(raw)
    local s, msg = pcall(function()
        return HttpService:JSONDecode(raw)
    end)

    if not s or not msg or not msg.type then return end

    local msgType = msg.type
    local payload = msg.data or {}
    local requestId = msg.requestId

    local function respond(respType, respData)
        respData = respData or {}
        respData.requestId = requestId
        sendMessage(respType, respData)
    end

    if msgType == "ping" then
        respond("pong", {timestamp = os.clock()})

    elseif msgType == "getTree" then
        local path = payload.path or "game"
        local depth = payload.depth or 1
        local inst = getInstanceFromPath(path)
        local tree = getTree(inst, depth)
        respond("tree", {path = path, tree = tree})

    elseif msgType == "getChildren" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        local children = getChildren(inst)
        respond("children", {path = path, children = children})

    elseif msgType == "getProperties" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        local props = getProperties(inst)
        respond("properties", {path = path, properties = props})

    elseif msgType == "getProperty" then
        local path = payload.path
        local propName = payload.property
        local inst = getInstanceFromPath(path)
        if inst then
            local s, value = pcall(function() return inst[propName] end)
            respond("property", {path = path, property = propName, value = serializeValue(value), success = s})
        else
            respond("property", {path = path, property = propName, success = false, error = "Instance not found"})
        end

    elseif msgType == "setProperty" then
        local path = payload.path
        local propName = payload.property
        local value = payload.value
        local inst = getInstanceFromPath(path)
        local success, err = setProperty(inst, propName, value)
        respond("propertySet", {path = path, property = propName, success = success, error = err})

    elseif msgType == "search" then
        local query = payload.query
        local options = payload.options or {}
        local results = searchInstances(query, options)
        respond("searchResults", {query = query, results = results, count = #results})

    elseif msgType == "getInstance" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        local info = getInstanceInfo(inst)
        respond("instance", {path = path, info = info})

    elseif msgType == "getPath" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        if inst then
            respond("path", {path = getInstancePath(inst)})
        else
            respond("path", {path = nil, error = "Instance not found"})
        end

    elseif msgType == "getNil" then
        local nilInsts = getNilInstances()
        respond("nilInstances", {instances = nilInsts, count = #nilInsts})

    elseif msgType == "getLoadedModules" then
        local modules = getLoadedModules()
        respond("loadedModules", {modules = modules, count = #modules})

    elseif msgType == "getServices" then
        local services = getServices()
        respond("services", {services = services})

    elseif msgType == "decompile" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        local source, err = decompileScript(inst)
        respond("decompiled", {path = path, source = source, error = err, success = source ~= nil})

    elseif msgType == "getBytecode" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        local bytecode, err = getScriptBytecode(inst)
        respond("bytecode", {path = path, bytecode = bytecode, error = err, success = bytecode ~= nil})

    elseif msgType == "getConnections" then
        local path = payload.path
        local signalName = payload.signal
        local inst = getInstanceFromPath(path)
        local cons = getSignalConnections(inst, signalName)
        respond("connections", {path = path, signal = signalName, connections = cons})

    elseif msgType == "clone" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        if inst then
            local s, cloned = pcall(function() return inst:Clone() end)
            if s and cloned then
                if payload.parent then
                    local parent = getInstanceFromPath(payload.parent)
                    if parent then
                        cloned.Parent = parent
                    end
                end
                respond("cloned", {path = path, newPath = getInstancePath(cloned), success = true})
            else
                respond("cloned", {path = path, success = false, error = cloned})
            end
        else
            respond("cloned", {path = path, success = false, error = "Instance not found"})
        end

    elseif msgType == "destroy" then
        local path = payload.path
        local inst = getInstanceFromPath(path)
        if inst then
            local s, err = pcall(function() inst:Destroy() end)
            respond("destroyed", {path = path, success = s, error = err})
        else
            respond("destroyed", {path = path, success = false, error = "Instance not found"})
        end

    elseif msgType == "setParent" then
        local path = payload.path
        local newParentPath = payload.parent
        local inst = getInstanceFromPath(path)
        local newParent = getInstanceFromPath(newParentPath)
        if inst then
            local s, err = pcall(function() inst.Parent = newParent end)
            respond("parentSet", {path = path, newParent = newParentPath, success = s, error = err})
        else
            respond("parentSet", {path = path, success = false, error = "Instance not found"})
        end

    elseif msgType == "create" then
        local className = payload.className
        local parentPath = payload.parent
        local properties = payload.properties or {}
        local parent = getInstanceFromPath(parentPath)

        local s, inst = pcall(function()
            local newInst = Instance.new(className)
            for propName, propValue in pairs(properties) do
                newInst[propName] = propValue
            end
            newInst.Parent = parent
            return newInst
        end)

        if s then
            respond("created", {className = className, path = getInstancePath(inst), success = true})
        else
            respond("created", {className = className, success = false, error = inst})
        end

    elseif msgType == "execute" then
        local code = payload.code
        local fn, compileErr = loadstring(code)
        if fn then
            local results = {pcall(fn)}
            local serializedResults = {}
            for i = 2, #results do
                table.insert(serializedResults, serializeValue(results[i]))
            end
            respond("executeResult", {success = results[1], results = serializedResults, error = not results[1] and results[2] or nil})
        else
            respond("executeResult", {success = false, error = compileErr})
        end

    elseif msgType == "subscribe" then
        local path = payload.path
        local events = payload.events or {"ChildAdded", "ChildRemoved", "Changed"}
        local inst = getInstanceFromPath(path)

        if not inst then
            respond("subscribed", {path = path, success = false, error = "Instance not found"})
            return
        end

        local subId = generateId()
        subscriptions[subId] = {path = path, connections = {}}

        for _, eventName in ipairs(events) do
            local signal = inst[eventName]
            if signal and typeof(signal) == "RBXScriptSignal" then
                local con = signal:Connect(function(...)
                    local args = {...}
                    local serializedArgs = {}
                    for _, arg in ipairs(args) do
                        table.insert(serializedArgs, serializeValue(arg))
                    end
                    sendMessage("event", {
                        subscriptionId = subId,
                        path = path,
                        event = eventName,
                        args = serializedArgs
                    })
                end)
                table.insert(subscriptions[subId].connections, con)
            end
        end

        respond("subscribed", {path = path, subscriptionId = subId, success = true})

    elseif msgType == "unsubscribe" then
        local subId = payload.subscriptionId
        if subscriptions[subId] then
            for _, con in ipairs(subscriptions[subId].connections) do
                con:Disconnect()
            end
            subscriptions[subId] = nil
            respond("unsubscribed", {subscriptionId = subId, success = true})
        else
            respond("unsubscribed", {subscriptionId = subId, success = false, error = "Subscription not found"})
        end

    elseif msgType == "getDescendants" then
        local path = payload.path
        local maxDepth = payload.maxDepth or 10
        local inst = getInstanceFromPath(path)

        if not inst then
            respond("descendants", {path = path, success = false, error = "Instance not found"})
            return
        end

        local results = {}
        local function collect(obj, depth)
            if depth > maxDepth then return end
            for _, child in ipairs(obj:GetChildren()) do
                table.insert(results, getInstanceInfo(child))
                collect(child, depth + 1)
            end
        end
        collect(inst, 1)

        respond("descendants", {path = path, descendants = results, count = #results, success = true})

    elseif msgType == "findFirstChild" then
        local path = payload.path
        local name = payload.name
        local recursive = payload.recursive or false
        local inst = getInstanceFromPath(path)

        if inst then
            local found = inst:FindFirstChild(name, recursive)
            if found then
                respond("found", {path = path, name = name, result = getInstanceInfo(found), success = true})
            else
                respond("found", {path = path, name = name, result = nil, success = true})
            end
        else
            respond("found", {path = path, success = false, error = "Instance not found"})
        end

    elseif msgType == "findFirstChildOfClass" then
        local path = payload.path
        local className = payload.className
        local inst = getInstanceFromPath(path)

        if inst then
            local found = inst:FindFirstChildOfClass(className)
            if found then
                respond("found", {path = path, className = className, result = getInstanceInfo(found), success = true})
            else
                respond("found", {path = path, className = className, result = nil, success = true})
            end
        else
            respond("found", {path = path, success = false, error = "Instance not found"})
        end

    elseif msgType == "getGameInfo" then
        respond("gameInfo", {
            gameId = game.GameId,
            placeId = game.PlaceId,
            placeVersion = game.PlaceVersion,
            jobId = game.JobId,
            creatorId = game.CreatorId,
            creatorType = tostring(game.CreatorType),
        })

    elseif msgType == "getPlayerInfo" then
        local player = Players.LocalPlayer
        if player then
            respond("playerInfo", {
                name = player.Name,
                displayName = player.DisplayName,
                userId = player.UserId,
                accountAge = player.AccountAge,
                membershipType = tostring(player.MembershipType),
                character = player.Character and getInstancePath(player.Character) or nil,
                team = player.Team and player.Team.Name or nil,
            })
        else
            respond("playerInfo", {error = "LocalPlayer not found"})
        end

    elseif msgType == "fireServer" then
        local path = payload.path
        local args = payload.args or {}
        local inst = getInstanceFromPath(path)

        if inst and inst:IsA("RemoteEvent") then
            local s, err = pcall(function()
                inst:FireServer(table.unpack(args))
            end)
            respond("fired", {path = path, success = s, error = err})
        else
            respond("fired", {path = path, success = false, error = "RemoteEvent not found"})
        end

    elseif msgType == "invokeServer" then
        local path = payload.path
        local args = payload.args or {}
        local inst = getInstanceFromPath(path)

        if inst and inst:IsA("RemoteFunction") then
            local results = {pcall(function()
                return inst:InvokeServer(table.unpack(args))
            end)}
            if results[1] then
                local serializedResults = {}
                for i = 2, #results do
                    table.insert(serializedResults, serializeValue(results[i]))
                end
                respond("invoked", {path = path, success = true, results = serializedResults})
            else
                respond("invoked", {path = path, success = false, error = results[2]})
            end
        else
            respond("invoked", {path = path, success = false, error = "RemoteFunction not found"})
        end
    end
end

local EXPLORER_PORT = 21574
local DEBUG = true

local function debugLog(...)
    if DEBUG then
        print("[WsExplorer]", ...)
    end
end

function WsExplorer.connect(url)
    if connected then
        WsExplorer.disconnect()
    end

    url = url or ("ws://127.0.0.1:" .. EXPLORER_PORT)
    debugLog("Attempting to connect to:", url)

    local WebSocket = (syn and syn.websocket) or (fluxus and fluxus.websocket) or WebSocket
    if not WebSocket then
        debugLog("ERROR: WebSocket not available in this executor")
        error("WebSocket not available in this executor")
    end

    debugLog("WebSocket API found, connecting...")

    local success, socket = pcall(function()
        return WebSocket.connect(url)
    end)

    if not success or not socket then
        error("Failed to connect to WebSocket: " .. tostring(socket))
    end

    ws = socket
    connected = true

    ws.OnMessage:Connect(function(msg)
        local s, err = pcall(handleMessage, msg)
        if not s then
            warn("[WsExplorer] Error handling message:", err)
        end
    end)

    ws.OnClose:Connect(function()
        connected = false
        ws = nil
        for subId, sub in pairs(subscriptions) do
            for _, con in ipairs(sub.connections) do
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
        for subId, sub in pairs(subscriptions) do
            for _, con in ipairs(sub.connections) do
                pcall(function() con:Disconnect() end)
            end
        end
        table.clear(subscriptions)

        pcall(function()
            ws:Close()
        end)
    end
    ws = nil
    connected = false
end

function WsExplorer.isConnected()
    return connected
end

function WsExplorer.send(msgType, data)
    sendMessage(msgType, data)
end

function WsExplorer.getInstancePath(inst)
    return getInstancePath(inst)
end

function WsExplorer.getInstanceFromPath(path)
    return getInstanceFromPath(path)
end

function WsExplorer.getInstanceInfo(inst)
    return getInstanceInfo(inst)
end

function WsExplorer.getProperties(inst)
    return getProperties(inst)
end

function WsExplorer.search(query, options)
    return searchInstances(query, options)
end

WsExplorer.connect()

return WsExplorer
