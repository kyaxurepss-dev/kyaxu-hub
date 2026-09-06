if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- Virtual Module Registry for executor execution without filesystem dependencies
local __modules = {}
local __cache = {}

local function defineModule(name, fn)
    __modules[name] = fn
end

local function requireModule(name)
    if __cache[name] then
        return __cache[name]
    end
    if not __modules[name] then
        error("Module not found in bundle: " .. tostring(name))
    end
    local module = {}
    __cache[name] = __modules[name](module) or module
    return __cache[name]
end

-- Global LPH Virtualization Bypass
loadstring("getfenv().LPH_NO_VIRTUALIZE = function(...) return ... end")()

-- ─── 1. KyaxuConfig ────────────────────────────────────────────────────────
defineModule("KyaxuConfig", function(module)
    local HttpService = game:GetService("HttpService")

    local KyaxuConfig = {
        ScriptVersion = "2.0.0",
        Author = "Potent",
        Discord = "https://discord.gg/8wqYvKBPWb",
        LoaderUrl = "https://raw.githubusercontent.com/kyaxurepss-dev/kyaxu-hub/refs/heads/main/KyaxuHub.lua",
        
        Settings = {
            Farm = {
                Enabled = false,
                LockedTargetUID = nil,
            },
            Filters = {
                FastMode = false,
                SelectedPetsOnly = false,
                MutatedOnly = false,
                IgnoreParasite = false,
                MinRarity = 0,
                MaxDistance = 6000,
            },
            Weights = {
                PurePayout = true,
                RarityWeight = 1.0,
                MutationWeight = 1.5,
                SizeWeight = 1.0,
                DistancePenalty = 1.0,
                DistanceFreeWithInstantTP = true,
            },
            Movement = {
                ApproachRadius = 9,
                MaxTripTime = 45,
                StopOnRollback = true,
                FastHopEnabled = true,
                StepDistance = 80,
                InstantTPEnabled = true,
                MinDistanceForTP = 400,
            },
            ServerHop = {
                FarmEverythingByItself = false,
                HopWhenEmpty = true,
                GracePeriod = 10,
                MinInterval = 15,
                MaxFruitlessHops = 15,
                SkipFullServers = true,
            },
            SelectedPets = {},
        }
    }

    local CONFIG_FOLDER = "KyaxuHub"
    local CONFIG_FILE = CONFIG_FOLDER .. "/config.json"

    function KyaxuConfig.Save()
        if not writefile then return end
        pcall(function()
            if isfolder and not isfolder(CONFIG_FOLDER) then
                makefolder(CONFIG_FOLDER)
            end
            local encoded = HttpService:JSONEncode(KyaxuConfig.Settings)
            writefile(CONFIG_FILE, encoded)
        end)
    end

    function KyaxuConfig.Load()
        if not (readfile and isfile and isfile(CONFIG_FILE)) then return end
        pcall(function()
            local raw = readfile(CONFIG_FILE)
            local decoded = HttpService:JSONDecode(raw)
            if type(decoded) == "table" then
                for category, values in pairs(decoded) do
                    if KyaxuConfig.Settings[category] and type(values) == "table" then
                        for k, v in pairs(values) do
                            KyaxuConfig.Settings[category][k] = v
                        end
                    end
                end
            end
        end)
    end

    KyaxuConfig.Load()
    return KyaxuConfig
end)

-- ─── 2. Utility.Signal ─────────────────────────────────────────────────────
defineModule("Utility.Signal", function(module)
    local Signal = {}
    Signal.__index = Signal

    function Signal.new()
        return setmetatable({ _listeners = {} }, Signal)
    end

    function Signal:Connect(fn)
        table.insert(self._listeners, fn)
        return {
            Disconnect = function()
                for i, listener in ipairs(self._listeners) do
                    if listener == fn then
                        table.remove(self._listeners, i)
                        break
                    end
                end
            end
        }
    end

    function Signal:Fire(...)
        for _, listener in ipairs(self._listeners) do
            task.spawn(listener, ...)
        end
    end

    return Signal
end)

-- ─── 3. Utility.Maid ───────────────────────────────────────────────────────
defineModule("Utility.Maid", function(module)
    local Maid = {}
    Maid.__index = Maid

    function Maid.new()
        return setmetatable({ _tasks = {} }, Maid)
    end

    function Maid:bind(taskOrConn)
        table.insert(self._tasks, taskOrConn)
    end

    function Maid:destroy()
        for _, t in ipairs(self._tasks) do
            if typeof(t) == "RBXScriptConnection" then
                t:Disconnect()
            elseif type(t) == "thread" then
                pcall(task.cancel, t)
            elseif type(t) == "function" then
                pcall(t)
            end
        end
        self._tasks = {}
    end

    return Maid
end)

-- ─── 4. Core.AntiCheat ─────────────────────────────────────────────────────
defineModule("Core.AntiCheat", function(module)
    local Players    = game:GetService("Players")
    local RunService = game:GetService("RunService")

    local DEFAULTS = {
        MaxStepSize        = 35,
        BaseStepDelay      = 0.050,
        JitterRange        = 0.025,
        GhostOffset        = 4.5,
        RemoteThrottle     = 0.14,
        LandingSettleTime  = 0.18,
        InstantTPChunkSize = 450,
    }

    local AntiCheat = {
        _remoteTimestamps = {},
        _cfg = DEFAULTS,
    }

    local function getRoot()
        local lp = Players.LocalPlayer
        if not lp then return nil end
        local char = lp.Character
        if not char then return nil end
        return char:FindFirstChild("HumanoidRootPart")
    end

    local function randRange(lo, hi)
        return lo + math.random() * (hi - lo)
    end

    local function posJitter(v, magnitude)
        return v + Vector3.new(
            randRange(-magnitude, magnitude),
            0,
            randRange(-magnitude, magnitude)
        )
    end

    function AntiCheat:Configure(overrides)
        for k, v in pairs(overrides) do
            self._cfg[k] = v
        end
    end

    function AntiCheat:HumanizedMove(targetPos, approachRadius, onStep)
        local root = getRoot()
        if not root then return false, "NoRoot" end

        approachRadius = approachRadius or 5
        local stepSize  = self._cfg.MaxStepSize
        local baseDelay = self._cfg.BaseStepDelay
        local jitter    = self._cfg.JitterRange

        local maxIter = 1200
        local iter = 0

        while iter < maxIter do
            iter = iter + 1
            root = getRoot()
            if not root then return false, "NoRoot" end

            local curPos = root.Position
            local delta  = targetPos - curPos
            local dist   = delta.Magnitude

            if dist <= approachRadius then break end

            local step    = delta.Unit * math.min(stepSize, dist)
            local nextPos = posJitter(curPos + step, 0.35)
            nextPos = Vector3.new(nextPos.X, targetPos.Y, nextPos.Z)

            local yaw = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
            root.CFrame = CFrame.new(nextPos) * CFrame.Angles(0, yaw, 0)

            if onStep then pcall(onStep, nextPos) end

            task.wait(randRange(baseDelay - jitter, baseDelay + jitter))
        end

        return iter < maxIter, iter >= maxIter and "Timeout" or nil
    end

    function AntiCheat:PhantomStep(targetPos)
        local root = getRoot()
        if not root then return false end

        local chunkSize = self._cfg.InstantTPChunkSize
        local settle    = self._cfg.LandingSettleTime

        local startPos  = root.Position
        local totalDist = (targetPos - startPos).Magnitude
        local chunks    = math.ceil(totalDist / chunkSize)

        for i = 1, chunks do
            root = getRoot()
            if not root then return false end

            local t        = i / chunks
            local chunkPos = startPos:Lerp(targetPos, t)
            chunkPos = posJitter(chunkPos, 1.2)

            root.CFrame = CFrame.new(chunkPos)
            task.wait(settle)
        end

        root = getRoot()
        if not root then return false end
        root.CFrame = CFrame.new(targetPos)
        task.wait(settle)

        return true
    end

    function AntiCheat:GhostFire(prompt)
        if not prompt or not prompt:IsA("ProximityPrompt") then return false end
        local root = getRoot()
        if not root then return false end

        local promptPart = prompt.Parent
        if not promptPart or not promptPart:IsA("BasePart") then
            pcall(fireproximityprompt, prompt)
            return true
        end

        local savedCFrame   = root.CFrame
        local triggerRadius = prompt.MaxActivationDistance or 10
        local ghostOffset   = self._cfg.GhostOffset

        local direction = (savedCFrame.Position - promptPart.Position)
        if direction.Magnitude < 0.01 then direction = Vector3.new(1, 0, 0) end

        local safeRadius = math.min(ghostOffset, triggerRadius - 0.5)
        local ghostPos   = promptPart.Position + direction.Unit * safeRadius

        root.CFrame = CFrame.new(ghostPos)
        RunService.Heartbeat:Wait()
        task.wait(0.05)

        pcall(fireproximityprompt, prompt)
        task.wait(prompt.HoldDuration + 0.15)

        root = getRoot()
        if root then root.CFrame = savedCFrame end

        return true
    end

    function AntiCheat:ThrottledFire(remote, ...)
        if not remote then return false end
        local now      = os.clock()
        local lastFire = self._remoteTimestamps[remote] or 0
        local minGap   = self._cfg.RemoteThrottle

        if (now - lastFire) < minGap then return false end
        self._remoteTimestamps[remote] = now

        task.wait(randRange(0, 0.04))

        if remote:IsA("RemoteEvent") then
            remote:FireServer(...)
        elseif remote:IsA("RemoteFunction") then
            return remote:InvokeServer(...)
        end
        return true
    end

    function AntiCheat:SafeDelivery(deliveryPos, config, teleportEngine)
        local _, root = teleportEngine:GetCharacter()
        if not root then return false end
        local dist = (deliveryPos - root.Position).Magnitude

        if dist > self._cfg.InstantTPChunkSize then
            return self:PhantomStep(deliveryPos)
        else
            return self:HumanizedMove(deliveryPos, config.Settings.Movement.ApproachRadius or 9)
        end
    end

    return AntiCheat
end)

-- ─── 5. Core.EggTracker ────────────────────────────────────────────────────
defineModule("Core.EggTracker", function(module)
    local Workspace = game:GetService("Workspace")
    local Players   = game:GetService("Players")

    local Signal = requireModule("Utility.Signal")
    local Maid   = requireModule("Utility.Maid")

    local EggTracker = {
        Updated       = Signal.new(),
        _activeEggs   = {},
        _placedEggs   = {},
        _inventoryEggs= {},
        _maid         = Maid.new(),
    }

    EggTracker.Zones = {
        { Name = "Forest",        Position = Vector3.new(605.0,  67.7, -326.5) },
        { Name = "Lake",          Position = Vector3.new(747.9,  67.6, -404.8) },
        { Name = "Desert",        Position = Vector3.new(949.8,  67.8, -320.2) },
        { Name = "Jungle",        Position = Vector3.new(1193.2, 67.7, -405.3) },
        { Name = "Snow",          Position = Vector3.new(1495.4, 68.1, -319.1) },
        { Name = "Volcano",       Position = Vector3.new(1871.4, 67.6, -399.7) },
        { Name = "Abyss Ocean",   Position = Vector3.new(2289.4, 67.4, -325.2) },
        { Name = "Prehistoric",   Position = Vector3.new(2817.8, 67.6, -394.2) },
        { Name = "Cosmic",        Position = Vector3.new(3399.8, 67.6, -323.1) },
        { Name = "Cherry Blossom",Position = Vector3.new(4031.5, 67.8, -392.4) },
        { Name = "Titan Temple",  Position = Vector3.new(4794.1, 68.1, -333.2) },
    }

    function EggTracker:GetZoneForPosition(pos)
        local closestZone = self.Zones[1]
        local minDistance = (pos - closestZone.Position).Magnitude
        for _, zone in ipairs(self.Zones) do
            local dist = (pos - zone.Position).Magnitude
            if dist < minDistance then
                minDistance = dist
                closestZone = zone
            end
        end
        return closestZone.Name, minDistance
    end

    function EggTracker:ExtractPromptPosition(prompt)
        local parent = prompt.Parent
        if not parent then return Vector3.new(0, 0, 0) end
        if parent:IsA("BasePart") then
            return parent.Position
        elseif parent:IsA("Model") then
            local primary = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart")
            if primary then return primary.Position end
        end
        return Vector3.new(0, 0, 0)
    end

    local function parseMutationCount(mutAttr)
        if type(mutAttr) == "number" then return mutAttr end
        if type(mutAttr) == "string" and mutAttr ~= "" then
            local count = 1
            for _ in mutAttr:gmatch(",") do count = count + 1 end
            return count
        end
        return 0
    end

    local function hasParasite(inst)
        if not inst then return false end
        if inst:GetAttribute("Parasite") == true then return true end
        if inst:FindFirstChild("Parasite") then return true end
        return false
    end

    function EggTracker:ScanPrompts()
        local foundPrompts = {}
        for _, desc in ipairs(Workspace:GetDescendants()) do
            if desc:IsA("ProximityPrompt") and desc.Name == "CarryAreaEgg" then
                local pos = self:ExtractPromptPosition(desc)
                local zoneName = self:GetZoneForPosition(pos)
                local parentModel = desc.Parent
                local eggName = zoneName .. " Egg"
                if parentModel and parentModel.Name ~= "SmartPromptPart" and parentModel.Name ~= "Part" then
                    eggName = parentModel.Name
                end

                local rarityAttr    = desc:GetAttribute("Rarity")    or (parentModel and parentModel:GetAttribute("Rarity"))    or 1
                local scaleAttr     = desc:GetAttribute("Scale")     or (parentModel and parentModel:GetAttribute("Scale"))     or 1.0
                local mutAttr       = desc:GetAttribute("Mutations") or (parentModel and parentModel:GetAttribute("Mutations")) or ""
                local uidAttr       = desc:GetAttribute("UID")       or (parentModel and parentModel:GetAttribute("UID"))       or desc:GetDebugId()
                local displayName   = desc:GetAttribute("DisplayName") or (parentModel and parentModel:GetAttribute("DisplayName")) or eggName
                local assetCategory = desc:GetAttribute("AssetCategory") or (parentModel and parentModel:GetAttribute("AssetCategory")) or "Unknown"

                local mutCount  = parseMutationCount(mutAttr)
                local rarityNum = typeof(rarityAttr) == "number" and rarityAttr or 1
                local basePayout = (rarityNum * 10) * (1 + (mutCount * 0.5)) * scaleAttr
                local parasite = hasParasite(desc) or hasParasite(parentModel)

                table.insert(foundPrompts, {
                    ID            = desc:GetDebugId(),
                    Prompt        = desc,
                    Position      = pos,
                    Zone          = zoneName,
                    Name          = displayName,
                    RawName       = eggName,
                    Rarity        = rarityNum,
                    Scale         = scaleAttr,
                    Mutations     = mutAttr,
                    MutationCount = mutCount,
                    BasePayout    = basePayout,
                    UID           = uidAttr,
                    AssetCategory = assetCategory,
                    HasParasite   = parasite,
                    Lifecycle     = "FIELD",
                    IsField       = true,
                })
            end
        end
        return foundPrompts
    end

    function EggTracker:ScanPlacedRenders()
        local placed = {}
        local renderFolder = Workspace:FindFirstChild("PlacedEggRenders")
        if not renderFolder then return placed end

        for _, inst in ipairs(renderFolder:GetChildren()) do
            if inst:IsA("Model") or inst:IsA("BasePart") then
                local pos = inst:IsA("Model") and inst.PrimaryPart and inst.PrimaryPart.Position
                            or (inst:IsA("BasePart") and inst.Position) or Vector3.new(0,0,0)
                local zoneName = self:GetZoneForPosition(pos)
                local uid       = inst:GetAttribute("UID") or inst:GetDebugId()
                local rarity    = inst:GetAttribute("Rarity") or 1
                local scale     = inst:GetAttribute("Scale") or 1.0
                local mutAttr   = inst:GetAttribute("Mutations") or ""
                local mutCount  = parseMutationCount(mutAttr)
                local parasite  = hasParasite(inst)
                local displayName = inst:GetAttribute("DisplayName") or inst.Name
                local assetCategory = inst:GetAttribute("AssetCategory") or "Unknown"
                local basePayout = (rarity * 10) * (1 + (mutCount * 0.5)) * scale

                placed[uid] = {
                    Instance      = inst,
                    UID           = uid,
                    Name          = displayName,
                    Zone          = zoneName,
                    Position      = pos,
                    Rarity        = rarity,
                    Scale         = scale,
                    Mutations     = mutAttr,
                    MutationCount = mutCount,
                    BasePayout    = basePayout,
                    AssetCategory = assetCategory,
                    HasParasite   = parasite,
                    Lifecycle     = "PLACED",
                }
            end
        end
        return placed
    end

    function EggTracker:ScanInventory()
        local player = Players.LocalPlayer
        if not player then return {} end

        local inventory = {}
        local containers = {}
        if player:FindFirstChild("Backpack") then table.insert(containers, player.Backpack) end
        if player.Character then table.insert(containers, player.Character) end

        for _, container in ipairs(containers) do
            for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") then
                    local itemType = item:GetAttribute("ItemType")
                    if itemType == "Asset" or item.Name:match("Egg") then
                        local uid         = item:GetAttribute("UID") or item:GetDebugId()
                        local displayName = item:GetAttribute("DisplayName") or item.Name
                        local category    = item:GetAttribute("AssetCategory") or item:GetAttribute("Category") or displayName
                        local scale       = item:GetAttribute("Scale") or 1.0
                        local weight      = item:GetAttribute("Weight") or 0.0
                        local mutAttr     = item:GetAttribute("Mutations") or item:GetAttribute("BaseMutation") or ""
                        local mutCount    = parseMutationCount(mutAttr)
                        local rarity      = item:GetAttribute("Rarity") or 1
                        local basePayout  = math.max(10, math.floor(weight / 10))
                        local parasite    = hasParasite(item)
                        local processed   = item:GetAttribute("PROCESSED") == true

                        inventory[uid] = {
                            Tool          = item,
                            UID           = uid,
                            Name          = displayName,
                            Category      = category,
                            Scale         = scale,
                            Weight        = weight,
                            Mutations     = mutAttr,
                            MutationCount = mutCount,
                            Rarity        = rarity,
                            BasePayout    = basePayout,
                            HasParasite   = parasite,
                            Container     = container.Name,
                            Lifecycle     = processed and "PROCESSED" or "INVENTORY",
                        }
                    end
                end
            end
        end
        return inventory
    end

    function EggTracker:Init()
        self._maid:bind(task.spawn(function()
            while true do
                self._activeEggs    = self:ScanPrompts()
                self._placedEggs    = self:ScanPlacedRenders()
                self._inventoryEggs = self:ScanInventory()
                self.Updated:Fire(self._activeEggs, self._inventoryEggs, self._placedEggs)
                task.wait(1.0)
            end
        end))
    end

    function EggTracker:GetActiveEggs() return self._activeEggs end
    function EggTracker:GetPlacedEggs() return self._placedEggs end
    function EggTracker:GetInventoryEggs() return self._inventoryEggs end

    function EggTracker:HasAnyEggs()
        if #self._activeEggs > 0 then return true end
        for _ in pairs(self._placedEggs) do return true end
        for _ in pairs(self._inventoryEggs) do return true end
        return false
    end

    function EggTracker:Destroy() self._maid:destroy() end

    return EggTracker
end)

-- ─── 6. Core.TargetRanker ──────────────────────────────────────────────────
defineModule("Core.TargetRanker", function(module)
    local TargetRanker = {}

    function TargetRanker.CalculateScore(egg, distance, config)
        local filters  = config.Settings.Filters
        local weights  = config.Settings.Weights
        local movement = config.Settings.Movement

        if filters.FastMode then return -distance end

        local score
        if weights.PurePayout then
            score = egg.BasePayout or 10
        else
            local rarityScore    = egg.Rarity        * (weights.RarityWeight   or 1.0)
            local mutationScore  = egg.MutationCount * (weights.MutationWeight or 1.5)
            local sizeScore      = egg.Scale         * (weights.SizeWeight     or 1.0)
            score = rarityScore + mutationScore + sizeScore
        end

        local isFreeDistance = weights.DistanceFreeWithInstantTP and movement.InstantTPEnabled
        if not isFreeDistance then
            local penalty = distance * (weights.DistancePenalty or 1.0) * 0.05
            score = score - penalty
        end

        return score
    end

    function TargetRanker.IsEligible(egg, distance, config)
        local filters      = config.Settings.Filters
        local selectedPets = config.Settings.SelectedPets or {}

        if filters.MaxDistance and filters.MaxDistance > 0 and distance > filters.MaxDistance then return false end
        if filters.MinRarity and filters.MinRarity > 0 and egg.Rarity < filters.MinRarity then return false end
        if filters.MutatedOnly and (egg.MutationCount or 0) <= 0 then return false end
        if filters.IgnoreParasite and egg.HasParasite then return false end

        if filters.SelectedPetsOnly then
            local petNameFound = false
            for petName, isSelected in pairs(selectedPets) do
                if isSelected and string.find(string.lower(egg.Name), string.lower(petName)) then
                    petNameFound = true
                    break
                end
            end
            if not petNameFound then return false end
        end

        return true
    end

    function TargetRanker.GetRankedTargets(eggs, playerPos, config)
        local rankedList = {}
        local lockedUID  = config.Settings.Farm.LockedTargetUID

        for _, egg in ipairs(eggs) do
            local dist = (egg.Position - playerPos).Magnitude
            if lockedUID and (egg.UID == lockedUID or egg.ID == lockedUID) then
                egg.Distance = dist
                egg.Score    = 999999
                table.insert(rankedList, egg)
            elseif TargetRanker.IsEligible(egg, dist, config) then
                egg.Distance = dist
                egg.Score    = TargetRanker.CalculateScore(egg, dist, config)
                table.insert(rankedList, egg)
            end
        end

        table.sort(rankedList, function(a, b) return a.Score > b.Score end)
        return rankedList
    end

    function TargetRanker.GetTopTargets(eggs, playerPos, config, limit)
        limit = limit or 8
        local ranked = TargetRanker.GetRankedTargets(eggs, playerPos, config)
        local top = {}
        for i = 1, math.min(#ranked, limit) do table.insert(top, ranked[i]) end
        return top
    end

    function TargetRanker.GetBestTarget(eggs, playerPos, config)
        local ranked = TargetRanker.GetRankedTargets(eggs, playerPos, config)
        return ranked[1]
    end

    return TargetRanker
end)

-- ─── 7. Core.TeleportEngine ────────────────────────────────────────────────
defineModule("Core.TeleportEngine", function(module)
    local Players = game:GetService("Players")

    local Signal    = requireModule("Utility.Signal")
    local AntiCheat = requireModule("Core.AntiCheat")

    local TeleportEngine = {
        RollbackDetected = Signal.new(),
        _rollbackCount   = 0,
        _lastExpectedPos = nil,
        _isTeleporting   = false,
    }

    function TeleportEngine:GetCharacter()
        local player = Players.LocalPlayer
        if not player then return nil, nil end
        local char = player.Character
        if not char then return nil, nil end
        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        return char, root, hum
    end

    function TeleportEngine:CheckRollback(expectedPos)
        local _, root = self:GetCharacter()
        if not root then return false end

        local currentPos = root.Position
        local dist = (currentPos - expectedPos).Magnitude
        if dist > 35 then
            self._rollbackCount = self._rollbackCount + 1
            if self._rollbackCount >= 2 then
                self.RollbackDetected:Fire(self._rollbackCount)
                return true
            end
        else
            self._rollbackCount = 0
        end
        return false
    end

    function TeleportEngine:FastHop(targetPos, config, onStep)
        local _, root = self:GetCharacter()
        if not root then return false end

        self._isTeleporting = true
        local approachRadius = config.Settings.Movement.ApproachRadius or 9

        AntiCheat:Configure({
            MaxStepSize = config.Settings.Movement.StepDistance or 28,
        })

        local success, err = AntiCheat:HumanizedMove(targetPos, approachRadius, onStep)
        self._isTeleporting = false

        if success and config.Settings.Movement.StopOnRollback then
            if self:CheckRollback(targetPos) then return false, "Rollback" end
        end

        return success, err
    end

    function TeleportEngine:InstantTP(targetPos, config)
        local _, root = self:GetCharacter()
        if not root then return false end
        return AntiCheat:PhantomStep(targetPos)
    end

    function TeleportEngine:TravelTo(targetPos, config, onStep)
        local _, root = self:GetCharacter()
        if not root then return false end

        local distance = (targetPos - root.Position).Magnitude
        local settings = config.Settings.Movement

        if settings.InstantTPEnabled and distance >= (settings.MinDistanceForTP or 400) then
            local success = self:InstantTP(targetPos, config)
            if success then return true end
        end

        if settings.FastHopEnabled then
            return self:FastHop(targetPos, config, onStep)
        end

        root.CFrame = CFrame.new(targetPos)
        return true
    end

    function TeleportEngine:Stop()
        self._isTeleporting = false
    end

    return TeleportEngine
end)

-- ─── 8. Core.FarmEngine ────────────────────────────────────────────────────
defineModule("Core.FarmEngine", function(module)
    local Workspace = game:GetService("Workspace")

    local Signal    = requireModule("Utility.Signal")
    local Maid      = requireModule("Utility.Maid")
    local AntiCheat = requireModule("Core.AntiCheat")

    local FarmEngine = {
        StateChanged = Signal.new(),
        StatsUpdated = Signal.new(),
        
        Stats = {
            Delivered = 0,
            PerSecond = 0,
            Failed = 0,
            Lost = 0,
            State = "IDLE",
            StuckSeconds = 0,
            CurrentTarget = nil,
        },
        
        _running = false,
        _stateStartTime = 0,
        _maid = Maid.new(),
    }

    FarmEngine.DeliveryPosition = Vector3.new(623.29, 75.02, 109.53)

    function FarmEngine:SetState(newState)
        self.Stats.State = newState
        self._stateStartTime = os.time()
        self.Stats.StuckSeconds = 0
        self.StateChanged:Fire(newState)
        self.StatsUpdated:Fire(self.Stats)
    end

    function FarmEngine:Start(config, eggTracker, targetRanker, teleportEngine)
        if self._running then return end
        self._running = true
        config.Settings.Farm.Enabled = true

        self._maid:bind(task.spawn(function()
            while self._running do
                local char, root = teleportEngine:GetCharacter()
                local playerPos = root and root.Position or Vector3.new(0,0,0)

                local elapsed = os.time() - self._stateStartTime
                self.Stats.StuckSeconds = elapsed
                local maxTripTime = config.Settings.Movement.MaxTripTime or 45

                if elapsed > maxTripTime and self.Stats.State ~= "IDLE" then
                    self:SetState("STUCK")
                    self.Stats.Failed = self.Stats.Failed + 1
                    task.wait(1.5)
                    self:SetState("SEARCHING")
                end

                if self.Stats.State == "IDLE" or self.Stats.State == "SEARCHING" or self.Stats.State == "STUCK" then
                    self:SetState("SEARCHING")
                    local activeEggs = eggTracker:GetActiveEggs()
                    local bestTarget = targetRanker.GetBestTarget(activeEggs, playerPos, config)

                    if bestTarget then
                        self.Stats.CurrentTarget = bestTarget
                        self:SetState("TRAVELING")

                        local success, err = teleportEngine:TravelTo(bestTarget.Position, config)
                        if success and self._running then
                            self:SetState("STEALING")

                            if bestTarget.Prompt then
                                AntiCheat:GhostFire(bestTarget.Prompt)
                            else
                                task.wait(1.2)
                            end

                            if self._running then
                                self:SetState("DELIVERING")
                                local destPos = self.DeliveryPosition
                                if Workspace:FindFirstChild("__OBJECTS") and Workspace.__OBJECTS:FindFirstChild("DeliveryHitbox") then
                                    destPos = Workspace.__OBJECTS.DeliveryHitbox.Position
                                end

                                AntiCheat:SafeDelivery(destPos, config, teleportEngine)

                                self:SetState("CLAIMING")
                                task.wait(1.0)

                                self.Stats.Delivered = self.Stats.Delivered + 1
                                self.Stats.PerSecond = math.floor((bestTarget.BasePayout or 50) / 5)
                                self:SetState("SEARCHING")
                            end
                        else
                            if err == "Rollback" and config.Settings.Movement.StopOnRollback then
                                self:Stop(config)
                                break
                            end
                            self.Stats.Lost = self.Stats.Lost + 1
                            self:SetState("SEARCHING")
                        end
                    else
                        self.Stats.CurrentTarget = nil
                        task.wait(1.0)
                    end
                end

                self.StatsUpdated:Fire(self.Stats)
                task.wait(0.5)
            end
        end))
    end

    function FarmEngine:Stop(config)
        self._running = false
        if config then config.Settings.Farm.Enabled = false end
        self:SetState("IDLE")
        self.Stats.CurrentTarget = nil
        self._maid:destroy()
        self._maid = Maid.new()
    end

    function FarmEngine:IsRunning() return self._running end

    return FarmEngine
end)

-- ─── 9. Features.ServerHop ────────────────────────────────────────────────
defineModule("Features.ServerHop", function(module)
    local TeleportService = game:GetService("TeleportService")
    local HttpService     = game:GetService("HttpService")
    local Players         = game:GetService("Players")

    local ServerHop = {
        _lastHopTime   = 0,
        _arrivalTime   = os.time(),
        _fruitlessHops = 0,
    }

    function ServerHop:QueueReExecution(loaderUrl)
        local queue = (rawget(_G, "queue_on_teleport"))
                   or (rawget(_G, "syn_queue_on_teleport"))
                   or (fluxus and fluxus.queue_on_teleport)
                   or (getgenv and getgenv().queue_on_teleport)

        if queue and loaderUrl and loaderUrl ~= "" then
            queue(([[
                repeat task.wait() until game:IsLoaded()
                task.wait(2)
                local ok, err = pcall(function()
                    loadstring(game:HttpGet(%q))()
                end)
                if not ok then warn("[Kyaxu] Re-execution failed:", err) end
            ]]):format(loaderUrl))
        end
    end

    function ServerHop:HopServer(config)
        local now         = os.time()
        local minInterval = config.Settings.ServerHop.MinInterval or 15

        if (now - self._lastHopTime) < minInterval then return false, "Rate limited" end

        self._lastHopTime = now
        self._fruitlessHops = self._fruitlessHops + 1

        local maxHops = config.Settings.ServerHop.MaxFruitlessHops or 15
        if self._fruitlessHops >= maxHops then
            config.Settings.ServerHop.FarmEverythingByItself = false
            config.Settings.ServerHop.HopWhenEmpty           = false
            warn("[Kyaxu] Auto Server Hop disarmed — max fruitless hops reached")
            return false, "Max hops exceeded"
        end

        self:QueueReExecution(config.LoaderUrl or "")

        local placeId    = game.PlaceId
        local skipFull   = config.Settings.ServerHop.SkipFullServers
        local serversUrl = ("https://games.roblox.com/v1/games/%d/servers/0?sortOrder=Asc&limit=100"):format(placeId)

        local hopped = false
        pcall(function()
            local raw  = game:HttpGet(serversUrl)
            local data = HttpService:JSONDecode(raw)
            if data and data.data then
                for _, server in ipairs(data.data) do
                    local isCurrent = server.id == game.JobId
                    local isFull    = skipFull and (server.playing >= server.maxPlayers)
                    if not isCurrent and not isFull then
                        TeleportService:TeleportToPlaceInstance(placeId, server.id, Players.LocalPlayer)
                        hopped = true
                        return
                    end
                end
            end
        end)

        if not hopped then
            TeleportService:Teleport(placeId, Players.LocalPlayer)
        end

        self._arrivalTime = os.time()
        return true
    end

    function ServerHop:CheckAndHop(eggTracker, config)
        local hopSettings = config.Settings.ServerHop

        if not (hopSettings.FarmEverythingByItself or hopSettings.HopWhenEmpty) then return end

        local grace = hopSettings.GracePeriod or 10
        if (os.time() - self._arrivalTime) < grace then return end

        if eggTracker:HasAnyEggs() then
            self._fruitlessHops = 0
            return
        end

        self:HopServer(config)
    end

    function ServerHop:ResetArrival() self._arrivalTime = os.time() end

    return ServerHop
end)

-- ─── 10. Features.PetCatalog ───────────────────────────────────────────────
defineModule("Features.PetCatalog", function(module)
    local PetCatalog = {}

    PetCatalog.Pets = {
        "Forest Bunny", "Forest Fox", "Forest Owl", "Forest Deer", "Forest Bear",
        "Forest Wolf", "Forest Squirrel", "Forest Raccoon", "Forest Hedgehog",
        "Forest Lynx", "Forest Boar", "Forest Beetle",
        "Lake Swan", "Lake Frog", "Lake Otter", "Lake Turtle", "Lake Heron",
        "Lake Crab", "Lake Newt", "Lake Pike", "Lake Duck", "Lake Catfish",
        "Desert Lark", "Desert Fox", "Desert Scorpion", "Desert Camel",
        "Desert Lizard", "Desert Cobra", "Desert Hawk", "Desert Meerkat",
        "Desert Vulture", "Desert Armadillo",
        "Jungle Tiger", "Jungle Parrot", "Jungle Monkey", "Jungle Gorilla",
        "Jungle Toucan", "Jungle Panther", "Jungle Chameleon", "Jungle Frog",
        "Jungle Sloth", "Jungle Anaconda",
        "Snow Wolf", "Ice Bear", "Snow Fox", "Snow Owl", "Snow Hare",
        "Arctic Seal", "Arctic Fox", "Snow Leopard", "Frost Dragon", "Ice Penguin",
        "Volcano Phoenix", "Lava Frog", "Lava Iguana", "Magma Snake",
        "Inferno Lion", "Flaming Bull", "Ember Cat", "Cinder Bat",
        "Molten Rhino", "Ash Falcon",
        "Abyss Leviathan", "Deep Sea Kraken", "Shadow Shark", "Abyss Jellyfish",
        "Deep Anglerfish", "Abyss Eel", "Shadow Manta", "Deep Nautilus",
        "Abyss Squid", "Shadow Turtle",
        "Prehistoric Raptor", "Ancient Mammoth", "Triceratops", "Pterodactyl",
        "Saber Tooth", "Prehistoric Turtle", "Ancient Beetle", "Fossil Crab",
        "Prehistoric Shark", "Ancient Centipede",
        "Cosmic Dragon", "Galactic Cat", "Nebula Whale", "Astral Elephant",
        "Celestial Pegasus", "Spectral Owl", "Storm Eagle", "Thunder Bird",
        "Rune Guardian", "Tectonic Rhino", "Void Serpent", "Stellar Fox",
        "Cherry Blossom Turtle", "Sakura Deer", "Moon Rabbit", "Sun Falcon",
        "Sakura Fox", "Blossom Koi", "Cherry Crane", "Petal Panda",
        "Sakura Tiger", "Blossom Beetle",
        "Titan Golem", "Crystal Beetle", "Royal Sphinx", "Swordfish",
        "Golden Fox", "Shadow Panther", "Venom Cobra", "Bird Egg",
        "Bronto", "Chillin Chilli", "Cyclops Gorilla", "Tropical Parrot",
        "Glitch Cat", "Blessed Unicorn",
    }

    function PetCatalog:GetPets() return self.Pets end

    function PetCatalog:Search(query)
        if not query or query == "" then return self.Pets end
        local queryLower = string.lower(query)
        local results = {}
        for _, petName in ipairs(self.Pets) do
            if string.find(string.lower(petName), queryLower, 1, true) then
                table.insert(results, petName)
            end
        end
        return results
    end

    function PetCatalog:SelectAll(config)
        config.Settings.SelectedPets = config.Settings.SelectedPets or {}
        for _, petName in ipairs(self.Pets) do config.Settings.SelectedPets[petName] = true end
    end

    function PetCatalog:ClearAll(config) config.Settings.SelectedPets = {} end

    function PetCatalog:TogglePet(petName, config)
        config.Settings.SelectedPets = config.Settings.SelectedPets or {}
        config.Settings.SelectedPets[petName] = not config.Settings.SelectedPets[petName]
        return config.Settings.SelectedPets[petName]
    end

    function PetCatalog:IsSelected(petName, config)
        return config.Settings.SelectedPets and config.Settings.SelectedPets[petName] == true
    end

    function PetCatalog:GetCount() return #self.Pets end

    return PetCatalog
end)

-- ─── 11. UI.FloatingButton ─────────────────────────────────────────────────
defineModule("UI.FloatingButton", function(module)
    local Players = game:GetService("Players")
    local CoreGui = game:GetService("CoreGui")

    local FloatingButton = {}

    function FloatingButton.Create(onToggle)
        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "KyaxuFloatingBtnGui"
        screenGui.ResetOnSpawn = false
        pcall(function() screenGui.Parent = CoreGui end)
        if not screenGui.Parent then screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, 44, 0, 44)
        btn.Position = UDim2.new(0, 15, 0.5, -22)
        btn.BackgroundColor3 = Color3.fromRGB(22, 25, 34)
        btn.Text = "🥚"
        btn.TextSize = 22
        btn.Parent = screenGui
        btn.Active = true
        btn.Draggable = true

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = btn

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(85, 170, 255)
        stroke.Thickness = 1.5
        stroke.Parent = btn

        btn.MouseButton1Click:Connect(onToggle)
        return btn
    end

    return FloatingButton
end)

-- ─── 12. UI.MainGui ────────────────────────────────────────────────────────
defineModule("UI.MainGui", function(module)
    local CoreGui          = game:GetService("CoreGui")
    local UserInputService = game:GetService("UserInputService")
    local Players          = game:GetService("Players")

    local FloatingButton = requireModule("UI.FloatingButton")
    local PetCatalog     = requireModule("Features.PetCatalog")

    local THEME = {
        BG           = Color3.fromRGB(16, 18, 24),
        PANEL        = Color3.fromRGB(22, 25, 34),
        SIDEBAR      = Color3.fromRGB(19, 22, 30),
        ROW          = Color3.fromRGB(30, 34, 46),
        ACCENT       = Color3.fromRGB(85, 170, 255),
        ACCENT_DIM   = Color3.fromRGB(50, 100, 160),
        GREEN        = Color3.fromRGB(72, 199, 116),
        RED          = Color3.fromRGB(220, 70, 70),
        YELLOW       = Color3.fromRGB(255, 215, 0),
        ORANGE       = Color3.fromRGB(255, 140, 0),
        MUTED        = Color3.fromRGB(100, 108, 135),
        TEXT         = Color3.fromRGB(230, 232, 240),
        TEXT_DIM     = Color3.fromRGB(160, 165, 185),
        STROKE       = Color3.fromRGB(38, 42, 58),
        TOGGLE_ON    = Color3.fromRGB(72, 199, 116),
        TOGGLE_OFF   = Color3.fromRGB(60, 65, 85),
    }

    local MainGui = { _visible = true }

    local function applyCorner(parent, radius)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, radius or 8)
        c.Parent = parent
        return c
    end

    local function applyStroke(parent, color, thickness)
        local s = Instance.new("UIStroke")
        s.Color = color or THEME.STROKE
        s.Thickness = thickness or 1
        s.Parent = parent
        return s
    end

    local function applyListLayout(parent, padding, alignment)
        local l = Instance.new("UIListLayout")
        l.Padding = UDim.new(0, padding or 8)
        l.SortOrder = Enum.SortOrder.LayoutOrder
        l.HorizontalAlignment = alignment or Enum.HorizontalAlignment.Left
        l.Parent = parent
        return l
    end

    local function applyPadding(parent, top, left, right, bottom)
        local p = Instance.new("UIPadding")
        p.PaddingTop    = UDim.new(0, top or 0)
        p.PaddingLeft   = UDim.new(0, left or 0)
        p.PaddingRight  = UDim.new(0, right or 0)
        p.PaddingBottom = UDim.new(0, bottom or 0)
        p.Parent = parent
        return p
    end

    local function makeFrame(parent, size, pos, color, zIndex)
        local f = Instance.new("Frame")
        f.Size = size
        f.Position = pos or UDim2.new(0, 0, 0, 0)
        f.BackgroundColor3 = color or THEME.PANEL
        f.BorderSizePixel = 0
        if zIndex then f.ZIndex = zIndex end
        f.Parent = parent
        return f
    end

    local function makeLabel(parent, text, size, pos, textSize, font, color, xAlign)
        local l = Instance.new("TextLabel")
        l.Size = size
        l.Position = pos or UDim2.new(0, 0, 0, 0)
        l.BackgroundTransparency = 1
        l.Text = text
        l.TextSize = textSize or 13
        l.Font = font or Enum.Font.GothamMedium
        l.TextColor3 = color or THEME.TEXT
        l.TextXAlignment = xAlign or Enum.TextXAlignment.Left
        l.TextWrapped = true
        l.Parent = parent
        return l
    end

    local function makeButton(parent, text, size, pos, bgColor, textColor, textSize, font)
        local b = Instance.new("TextButton")
        b.Size = size
        b.Position = pos or UDim2.new(0, 0, 0, 0)
        b.BackgroundColor3 = bgColor or THEME.ROW
        b.Text = text
        b.TextColor3 = textColor or THEME.TEXT
        b.TextSize = textSize or 13
        b.Font = font or Enum.Font.GothamMedium
        b.BorderSizePixel = 0
        b.AutoButtonColor = false
        b.Parent = parent
        return b
    end

    local function createToggle(parent, text, initialValue, onToggle, layoutOrder)
        local frame = makeFrame(parent, UDim2.new(1, 0, 0, 34), nil, THEME.ROW)
        frame.LayoutOrder = layoutOrder or 0
        applyCorner(frame, 6)
        makeLabel(frame, text, UDim2.new(1, -70, 1, 0), UDim2.new(0, 12, 0, 0), 12, Enum.Font.GothamMedium, THEME.TEXT)

        local val = initialValue
        local btn = makeButton(frame, val and "ON" or "OFF",
            UDim2.new(0, 52, 0, 24), UDim2.new(1, -62, 0.5, -12),
            val and THEME.TOGGLE_ON or THEME.TOGGLE_OFF,
            Color3.fromRGB(255,255,255), 11, Enum.Font.GothamBold)
        applyCorner(btn, 5)

        btn.MouseButton1Click:Connect(function()
            val = not val
            btn.Text = val and "ON" or "OFF"
            btn.BackgroundColor3 = val and THEME.TOGGLE_ON or THEME.TOGGLE_OFF
            onToggle(val)
        end)
        return frame
    end

    local function createSlider(parent, label, minVal, maxVal, stepVal, currentVal, onChange, layoutOrder)
        local frame = makeFrame(parent, UDim2.new(1, 0, 0, 52), nil, THEME.ROW)
        frame.LayoutOrder = layoutOrder or 0
        applyCorner(frame, 6)

        local headerRow = makeFrame(frame, UDim2.new(1, -16, 0, 22), UDim2.new(0, 8, 0, 6), Color3.fromRGB(0,0,0))
        headerRow.BackgroundTransparency = 1
        makeLabel(headerRow, label, UDim2.new(0.75, 0, 1, 0), nil, 11, Enum.Font.GothamMedium, THEME.TEXT_DIM)

        local valueLabel = makeLabel(headerRow, tostring(currentVal), UDim2.new(0.25, 0, 1, 0), UDim2.new(0.75, 0, 0, 0), 11, Enum.Font.GothamBold, THEME.ACCENT, Enum.TextXAlignment.Right)

        local trackBG = makeFrame(frame, UDim2.new(1, -16, 0, 6), UDim2.new(0, 8, 0, 36), THEME.STROKE)
        applyCorner(trackBG, 3)

        local fill = makeFrame(trackBG, UDim2.new(0, 0, 1, 0), nil, THEME.ACCENT)
        applyCorner(fill, 3)

        local thumb = makeButton(trackBG, "", UDim2.new(0, 14, 0, 14), UDim2.new(0, 0, 0.5, -7), THEME.ACCENT, THEME.TEXT, 0)
        applyCorner(thumb, 7)

        local function setValue(newVal)
            newVal = math.clamp(math.floor((newVal - minVal) / stepVal + 0.5) * stepVal + minVal, minVal, maxVal)
            local pct = (newVal - minVal) / (maxVal - minVal)
            fill.Size = UDim2.new(pct, 0, 1, 0)
            thumb.Position = UDim2.new(pct, -7, 0.5, -7)
            valueLabel.Text = tostring(newVal)
            currentVal = newVal
            onChange(newVal)
        end

        local initPct = (currentVal - minVal) / (maxVal - minVal)
        fill.Size = UDim2.new(initPct, 0, 1, 0)
        thumb.Position = UDim2.new(initPct, -7, 0.5, -7)

        local dragging = false
        thumb.MouseButton1Down:Connect(function() dragging = true end)
        trackBG.MouseButton1Down:Connect(function(_, _, x)
            dragging = true
            local rel = math.clamp((x - trackBG.AbsolutePosition.X) / trackBG.AbsoluteSize.X, 0, 1)
            setValue(minVal + rel * (maxVal - minVal))
        end)
        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
        end)
        UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local rel = math.clamp((input.Position.X - trackBG.AbsolutePosition.X) / trackBG.AbsoluteSize.X, 0, 1)
                setValue(minVal + rel * (maxVal - minVal))
            end
        end)

        return frame
    end

    local function createSectionHeader(parent, text, layoutOrder)
        local lbl = makeLabel(parent, text, UDim2.new(1, 0, 0, 20), nil, 11, Enum.Font.GothamBold, THEME.MUTED, Enum.TextXAlignment.Left)
        lbl.LayoutOrder = layoutOrder or 0
        lbl.BackgroundTransparency = 1
        applyPadding(lbl, 0, 2, 0, 0)
        return lbl
    end

    function MainGui:Init(config, farmEngine, eggTracker, targetRanker, teleportEngine, serverHop)
        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "KyaxuHubGui"
        screenGui.ResetOnSpawn = false
        pcall(function() screenGui.Parent = CoreGui end)
        if not screenGui.Parent then screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

        local mainFrame = makeFrame(screenGui, UDim2.new(0, 680, 0, 520), UDim2.new(0.5, -340, 0.5, -260), THEME.BG)
        mainFrame.Active = true
        mainFrame.Draggable = true
        applyCorner(mainFrame, 12)
        applyStroke(mainFrame, THEME.STROKE, 1.5)

        local header = makeFrame(mainFrame, UDim2.new(1, 0, 0, 46), nil, THEME.SIDEBAR)
        applyCorner(header, 12)
        makeLabel(header, "🥚  KYAXU HUB  v2.0", UDim2.new(0.5, 0, 1, 0), UDim2.new(0, 16, 0, 0), 17, Enum.Font.GothamBold, THEME.TEXT)

        local statusDot = makeFrame(header, UDim2.new(0, 8, 0, 8), UDim2.new(1, -90, 0.5, -4), THEME.MUTED)
        applyCorner(statusDot, 4)
        local statusText = makeLabel(header, "IDLE", UDim2.new(0, 60, 1, 0), UDim2.new(1, -80, 0, 0), 11, Enum.Font.GothamBold, THEME.MUTED)

        farmEngine.StateChanged:Connect(function(state)
            local color = THEME.MUTED
            if state == "TRAVELING" or state == "STEALING" or state == "DELIVERING" then color = THEME.GREEN
            elseif state == "STUCK" then color = THEME.RED
            elseif state == "SEARCHING" then color = THEME.ACCENT end
            statusDot.BackgroundColor3 = color
            statusText.TextColor3 = color
            statusText.Text = state
        end)

        local closeBtn = makeButton(header, "✕", UDim2.new(0, 28, 0, 28), UDim2.new(1, -40, 0.5, -14), THEME.ROW, THEME.TEXT_DIM, 13, Enum.Font.GothamBold)
        applyCorner(closeBtn, 6)
        closeBtn.MouseButton1Click:Connect(function()
            mainFrame.Visible = false
            self._visible = false
        end)

        local sidebar = makeFrame(mainFrame, UDim2.new(0, 148, 1, -56), UDim2.new(0, 8, 0, 50), THEME.SIDEBAR)
        applyCorner(sidebar, 10)
        applyListLayout(sidebar, 4)
        applyPadding(sidebar, 8, 6, 6, 8)

        local contentArea = makeFrame(mainFrame, UDim2.new(1, -170, 1, -56), UDim2.new(0, 162, 0, 50), THEME.PANEL)
        applyCorner(contentArea, 10)

        local tabs, tabBtns, activeTab = {}, {}, nil

        local function switchTab(name)
            for tabName, content in pairs(tabs) do content.Visible = (tabName == name) end
            for tabName, btn in pairs(tabBtns) do
                if tabName == name then
                    btn.BackgroundColor3 = THEME.ACCENT
                    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
                else
                    btn.BackgroundColor3 = THEME.ROW
                    btn.TextColor3 = THEME.TEXT_DIM
                end
            end
            activeTab = name
        end

        local function createTab(name, icon, order)
            local btn = makeButton(sidebar, icon .. "  " .. name, UDim2.new(1, 0, 0, 34), nil, THEME.ROW, THEME.TEXT_DIM, 12, Enum.Font.GothamMedium)
            btn.LayoutOrder = order
            btn.TextXAlignment = Enum.TextXAlignment.Left
            applyCorner(btn, 7)
            applyPadding(btn, 0, 10, 0, 0)

            local scroll = Instance.new("ScrollingFrame")
            scroll.Name = name .. "Tab"
            scroll.Size = UDim2.new(1, -16, 1, -14)
            scroll.Position = UDim2.new(0, 8, 0, 8)
            scroll.BackgroundTransparency = 1
            scroll.BorderSizePixel = 0
            scroll.ScrollBarThickness = 3
            scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
            scroll.Visible = false
            scroll.Parent = contentArea

            local list = applyListLayout(scroll, 7)
            list.HorizontalAlignment = Enum.HorizontalAlignment.Center
            applyPadding(scroll, 4, 0, 0, 8)

            btn.MouseButton1Click:Connect(function() switchTab(name) end)

            tabs[name]    = scroll
            tabBtns[name] = btn
            return scroll
        end

        -- TAB 1: Farm
        local farmTab = createTab("Farm", "🥚", 1)
        local farmBtn = makeButton(farmTab, "▶  START FARM", UDim2.new(1, 0, 0, 46), nil, THEME.GREEN, Color3.fromRGB(255,255,255), 15, Enum.Font.GothamBold)
        farmBtn.LayoutOrder = 1
        applyCorner(farmBtn, 8)
        farmBtn.MouseButton1Click:Connect(function()
            if farmEngine:IsRunning() then
                farmEngine:Stop(config)
                farmBtn.Text = "▶  START FARM"
                farmBtn.BackgroundColor3 = THEME.GREEN
            else
                farmEngine:Start(config, eggTracker, targetRanker, teleportEngine)
                farmBtn.Text = "⏹  STOP FARM"
                farmBtn.BackgroundColor3 = THEME.RED
            end
            config.Save()
        end)

        local statsPanel = makeFrame(farmTab, UDim2.new(1, 0, 0, 80), nil, THEME.ROW)
        statsPanel.LayoutOrder = 2
        applyCorner(statsPanel, 8)
        applyPadding(statsPanel, 8, 10, 10, 8)

        local statsGrid = Instance.new("Frame")
        statsGrid.Size = UDim2.new(1, 0, 1, 0)
        statsGrid.BackgroundTransparency = 1
        statsGrid.Parent = statsPanel
        local statsGridLayout = Instance.new("UIGridLayout")
        statsGridLayout.CellSize = UDim2.new(0.5, -4, 0, 28)
        statsGridLayout.CellPadding = UDim2.new(0, 8, 0, 6)
        statsGridLayout.Parent = statsGrid

        local statCells = {}
        local statDefs = {
            { key = "state",     label = "STATE",     val = "IDLE",  color = THEME.MUTED  },
            { key = "delivered", label = "DELIVERED",  val = "0",     color = THEME.GREEN  },
            { key = "pps",       label = "$/SECOND",   val = "0",     color = THEME.YELLOW },
            { key = "failed",    label = "FAILED",     val = "0",     color = THEME.MUTED  },
            { key = "lost",      label = "LOST",       val = "0",     color = THEME.ORANGE },
            { key = "stuck",     label = "STUCK",      val = "0s",    color = THEME.RED    },
        }
        for i, def in ipairs(statDefs) do
            local cell = makeFrame(statsGrid, UDim2.new(1, 0, 1, 0), nil, Color3.fromRGB(0,0,0))
            cell.BackgroundTransparency = 1
            cell.LayoutOrder = i
            makeLabel(cell, def.label, UDim2.new(1, 0, 0, 12), nil, 9, Enum.Font.GothamBold, THEME.MUTED)
            local valLbl = makeLabel(cell, def.val, UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 12), 13, Enum.Font.GothamBold, def.color)
            statCells[def.key] = { label = valLbl, color = def.color }
        end

        farmEngine.StatsUpdated:Connect(function(stats)
            if statCells.state then
                local stateColor = THEME.MUTED
                if stats.State == "TRAVELING" or stats.State == "STEALING" then stateColor = THEME.GREEN
                elseif stats.State == "STUCK" then stateColor = THEME.RED
                elseif stats.State == "SEARCHING" then stateColor = THEME.ACCENT
                elseif stats.State == "DELIVERING" then stateColor = THEME.YELLOW end
                statCells.state.label.Text = stats.State
                statCells.state.label.TextColor3 = stateColor
            end
            if statCells.delivered then statCells.delivered.label.Text = tostring(stats.Delivered) end
            if statCells.pps       then statCells.pps.label.Text = tostring(stats.PerSecond) end
            if statCells.failed    then statCells.failed.label.Text = tostring(stats.Failed) end
            if statCells.lost      then statCells.lost.label.Text = tostring(stats.Lost) end
            if statCells.stuck     then
                local secs = stats.StuckSeconds or 0
                statCells.stuck.label.Text = tostring(secs) .. "s"
                statCells.stuck.label.TextColor3 = secs > 15 and THEME.RED or THEME.MUTED
            end
        end)

        local clearLockBtn = makeButton(farmTab, "🔓  CLEAR TARGET LOCK", UDim2.new(1, 0, 0, 32), nil, THEME.ROW, THEME.TEXT_DIM, 12, Enum.Font.GothamMedium)
        clearLockBtn.LayoutOrder = 3
        applyCorner(clearLockBtn, 6)
        clearLockBtn.MouseButton1Click:Connect(function()
            config.Settings.Farm.LockedTargetUID = nil
            config.Save()
        end)

        -- TAB 2: Targets
        local targetsTab = createTab("Targets", "🎯", 2)
        makeLabel(targetsTab, "BEST TARGETS RIGHT NOW", UDim2.new(1, 0, 0, 20), nil, 11, Enum.Font.GothamBold, THEME.YELLOW).LayoutOrder = 1
        local cardsContainer = makeFrame(targetsTab, UDim2.new(1, 0, 0, 10), nil, Color3.fromRGB(0,0,0))
        cardsContainer.BackgroundTransparency = 1
        cardsContainer.LayoutOrder = 2
        cardsContainer.AutomaticSize = Enum.AutomaticSize.Y
        applyListLayout(cardsContainer, 5)

        local function buildTargetCards(activeEggs)
            for _, c in ipairs(cardsContainer:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
            local _, root = teleportEngine:GetCharacter()
            local playerPos = root and root.Position or Vector3.new(0,0,0)
            local topTargets = targetRanker.GetTopTargets(activeEggs, playerPos, config, 8)

            for idx, egg in ipairs(topTargets) do
                local isLocked = config.Settings.Farm.LockedTargetUID == egg.UID
                local card = makeFrame(cardsContainer, UDim2.new(1, 0, 0, 58), nil, isLocked and THEME.ACCENT_DIM or THEME.ROW)
                applyCorner(card, 8)
                if isLocked then applyStroke(card, THEME.ACCENT, 1.5) end

                local badge = makeFrame(card, UDim2.new(0, 26, 0, 26), UDim2.new(0, 8, 0.5, -13), isLocked and THEME.ACCENT or THEME.MUTED)
                applyCorner(badge, 5)
                makeLabel(badge, tostring(idx), UDim2.new(1,0,1,0), nil, 11, Enum.Font.GothamBold, THEME.TEXT, Enum.TextXAlignment.Center)

                local infoBlock = makeFrame(card, UDim2.new(1, -50, 1, -10), UDim2.new(0, 42, 0, 5), Color3.fromRGB(0,0,0))
                infoBlock.BackgroundTransparency = 1

                local nameStr = egg.Name or "Unknown"
                if egg.HasParasite then nameStr = "🦠 " .. nameStr end
                makeLabel(infoBlock, nameStr, UDim2.new(0.65, 0, 0, 16), nil, 12, Enum.Font.GothamBold, isLocked and Color3.fromRGB(255,255,255) or THEME.TEXT)
                makeLabel(infoBlock, "📍 " .. (egg.Zone or "?"), UDim2.new(0.35, 0, 0, 16), UDim2.new(0.65, 0, 0, 0), 10, Enum.Font.Gotham, THEME.TEXT_DIM, Enum.TextXAlignment.Right)

                local rarityStars = string.rep("⭐", math.min(egg.Rarity or 1, 5))
                local mutStr = "🧬 " .. tostring(egg.MutationCount or 0)
                local scaleStr = "📏 " .. string.format("%.1f", egg.Scale or 1.0)
                local distStr = "📐 " .. math.floor(egg.Distance or 0) .. "m"
                local payStr  = "💰 " .. math.floor(egg.BasePayout or 0) .. "/s"
                makeLabel(infoBlock, rarityStars .. "  " .. mutStr .. "  " .. scaleStr .. "  " .. distStr .. "  " .. payStr, UDim2.new(1, 0, 0, 14), UDim2.new(0, 0, 0, 20), 10, Enum.Font.Gotham, THEME.TEXT_DIM)

                local clickBtn = makeButton(card, "", UDim2.new(1,0,1,0), nil, Color3.fromRGB(0,0,0), THEME.TEXT, 0)
                clickBtn.BackgroundTransparency = 1
                clickBtn.ZIndex = card.ZIndex + 5
                clickBtn.MouseButton1Click:Connect(function()
                    config.Settings.Farm.LockedTargetUID = config.Settings.Farm.LockedTargetUID == egg.UID and nil or egg.UID
                    config.Save()
                    buildTargetCards(eggTracker:GetActiveEggs())
                end)
            end
        end

        eggTracker.Updated:Connect(function(activeEggs)
            if activeTab == "Targets" or activeTab == "Farm" then buildTargetCards(activeEggs) end
        end)

        -- TAB 3: Filters
        local filterTab = createTab("Filters", "🎚", 3)
        local lo = 0
        local function nextOrder() lo = lo + 1 return lo end
        createSectionHeader(filterTab, "EGG SELECTION MODE", nextOrder())
        createToggle(filterTab, "Fast Mode (closest egg)", config.Settings.Filters.FastMode, function(v) config.Settings.Filters.FastMode = v; config.Save() end, nextOrder())
        createToggle(filterTab, "Selected Pets Only", config.Settings.Filters.SelectedPetsOnly, function(v) config.Settings.Filters.SelectedPetsOnly = v; config.Save() end, nextOrder())
        createSectionHeader(filterTab, "EGG REQUIREMENTS", nextOrder())
        createToggle(filterTab, "Mutated Eggs Only", config.Settings.Filters.MutatedOnly, function(v) config.Settings.Filters.MutatedOnly = v; config.Save() end, nextOrder())
        createToggle(filterTab, "Ignore Eggs With Parasite 🦠", config.Settings.Filters.IgnoreParasite, function(v) config.Settings.Filters.IgnoreParasite = v; config.Save() end, nextOrder())
        createSectionHeader(filterTab, "RANGE & RARITY", nextOrder())
        createSlider(filterTab, "Minimum Rarity (0 = any)", 0, 25, 1, config.Settings.Filters.MinRarity, function(v) config.Settings.Filters.MinRarity = v; config.Save() end, nextOrder())
        createSlider(filterTab, "Maximum Target Distance", 200, 6000, 100, config.Settings.Filters.MaxDistance, function(v) config.Settings.Filters.MaxDistance = v; config.Save() end, nextOrder())

        -- TAB 4: Weights
        local weightTab = createTab("Weights", "📊", 4)
        lo = 0
        createSectionHeader(weightTab, "RANKING FORMULA", nextOrder())
        createToggle(weightTab, "Rank by Pure $/s Payout", config.Settings.Weights.PurePayout, function(v) config.Settings.Weights.PurePayout = v; config.Save() end, nextOrder())
        createSectionHeader(weightTab, "WEIGHT MULTIPLIERS", nextOrder())
        createSlider(weightTab, "Rarity Weight", 0, 3, 0.1, config.Settings.Weights.RarityWeight, function(v) config.Settings.Weights.RarityWeight = v; config.Save() end, nextOrder())
        createSlider(weightTab, "Mutation Weight", 0, 3, 0.1, config.Settings.Weights.MutationWeight, function(v) config.Settings.Weights.MutationWeight = v; config.Save() end, nextOrder())
        createSlider(weightTab, "Size Weight", 0, 3, 0.1, config.Settings.Weights.SizeWeight, function(v) config.Settings.Weights.SizeWeight = v; config.Save() end, nextOrder())
        createSlider(weightTab, "Distance Penalty", 0, 3, 0.1, config.Settings.Weights.DistancePenalty, function(v) config.Settings.Weights.DistancePenalty = v; config.Save() end, nextOrder())
        createToggle(weightTab, "Distance Free With Instant TP", config.Settings.Weights.DistanceFreeWithInstantTP, function(v) config.Settings.Weights.DistanceFreeWithInstantTP = v; config.Save() end, nextOrder())

        -- TAB 5: Movement
        local moveTab = createTab("Movement", "🏃", 5)
        lo = 0
        createSectionHeader(moveTab, "SAFETY", nextOrder())
        createToggle(moveTab, "Stop Farm on Server Rollback", config.Settings.Movement.StopOnRollback, function(v) config.Settings.Movement.StopOnRollback = v; config.Save() end, nextOrder())
        createSlider(moveTab, "Approach Radius (studs)", 3, 9, 1, config.Settings.Movement.ApproachRadius, function(v) config.Settings.Movement.ApproachRadius = v; config.Save() end, nextOrder())
        createSlider(moveTab, "Max Time Per Trip (s)", 20, 180, 5, config.Settings.Movement.MaxTripTime, function(v) config.Settings.Movement.MaxTripTime = v; config.Save() end, nextOrder())
        createSectionHeader(moveTab, "FAST TRAVEL", nextOrder())
        createToggle(moveTab, "Fast Hop Enabled", config.Settings.Movement.FastHopEnabled, function(v) config.Settings.Movement.FastHopEnabled = v; config.Save() end, nextOrder())
        createToggle(moveTab, "Instant TP Enabled", config.Settings.Movement.InstantTPEnabled, function(v) config.Settings.Movement.InstantTPEnabled = v; config.Save() end, nextOrder())
        createSlider(moveTab, "Min Distance for TP", 200, 4000, 50, config.Settings.Movement.MinDistanceForTP, function(v) config.Settings.Movement.MinDistanceForTP = v; config.Save() end, nextOrder())

        -- TAB 6: Server Hop
        local hopTab = createTab("Server Hop", "🌐", 6)
        lo = 0
        createSectionHeader(hopTab, "MASTER CONTROL", nextOrder())
        createToggle(hopTab, "FARM EVERYTHING BY ITSELF", config.Settings.ServerHop.FarmEverythingByItself, function(v) config.Settings.ServerHop.FarmEverythingByItself = v; config.Save() end, nextOrder())
        createToggle(hopTab, "Switch Server When Empty", config.Settings.ServerHop.HopWhenEmpty, function(v) config.Settings.ServerHop.HopWhenEmpty = v; config.Save() end, nextOrder())
        createToggle(hopTab, "Skip Full Servers", config.Settings.ServerHop.SkipFullServers, function(v) config.Settings.ServerHop.SkipFullServers = v; config.Save() end, nextOrder())
        createSectionHeader(hopTab, "TIMING", nextOrder())
        createSlider(hopTab, "Wait Before Giving Up (s)", 3, 30, 1, config.Settings.ServerHop.GracePeriod, function(v) config.Settings.ServerHop.GracePeriod = v; config.Save() end, nextOrder())
        createSlider(hopTab, "Min Interval Between Hops", 8, 60, 1, config.Settings.ServerHop.MinInterval, function(v) config.Settings.ServerHop.MinInterval = v; config.Save() end, nextOrder())
        createSlider(hopTab, "Hops Before Turning Off", 5, 60, 1, config.Settings.ServerHop.MaxFruitlessHops, function(v) config.Settings.ServerHop.MaxFruitlessHops = v; config.Save() end, nextOrder())

        -- TAB 7: Pets
        local petsTab = createTab("Pets", "🐾", 7)
        local searchBox = Instance.new("TextBox")
        searchBox.Size = UDim2.new(1, 0, 0, 32)
        searchBox.BackgroundColor3 = THEME.ROW
        searchBox.PlaceholderText = "🔍 Search pets..."
        searchBox.Text = ""
        searchBox.TextColor3 = THEME.TEXT
        searchBox.TextSize = 12
        searchBox.Font = Enum.Font.GothamMedium
        searchBox.LayoutOrder = 1
        searchBox.Parent = petsTab
        applyCorner(searchBox, 7)

        local btnBar = makeFrame(petsTab, UDim2.new(1, 0, 0, 30), nil, Color3.fromRGB(0,0,0))
        btnBar.BackgroundTransparency = 1
        btnBar.LayoutOrder = 2
        local selAllBtn = makeButton(btnBar, "SELECT ALL", UDim2.new(0.48, 0, 1, 0), nil, THEME.ACCENT_DIM, THEME.TEXT, 11, Enum.Font.GothamBold)
        applyCorner(selAllBtn, 6)
        local clrAllBtn = makeButton(btnBar, "CLEAR ALL", UDim2.new(0.48, 0, 1, 0), UDim2.new(0.52, 0, 0, 0), Color3.fromRGB(80, 45, 45), THEME.TEXT, 11, Enum.Font.GothamBold)
        applyCorner(clrAllBtn, 6)

        local petsGrid = makeFrame(petsTab, UDim2.new(1, 0, 0, 10), nil, Color3.fromRGB(0,0,0))
        petsGrid.BackgroundTransparency = 1
        petsGrid.AutomaticSize = Enum.AutomaticSize.Y
        petsGrid.LayoutOrder = 3

        local gridLayout = Instance.new("UIGridLayout")
        gridLayout.CellSize = UDim2.new(0, 130, 0, 30)
        gridLayout.CellPadding = UDim2.new(0, 6, 0, 6)
        gridLayout.Parent = petsGrid

        local function renderPets(query)
            for _, c in ipairs(petsGrid:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
            local petsList = PetCatalog:Search(query)
            for i = 1, math.min(#petsList, 60) do
                local petName = petsList[i]
                local isSel   = PetCatalog:IsSelected(petName, config)
                local pBtn = makeButton(petsGrid, petName, UDim2.new(1, 0, 1, 0), nil, isSel and THEME.TOGGLE_ON or THEME.ROW, Color3.fromRGB(255,255,255), 10, Enum.Font.GothamMedium)
                applyCorner(pBtn, 5)
                pBtn.MouseButton1Click:Connect(function()
                    local newState = PetCatalog:TogglePet(petName, config)
                    pBtn.BackgroundColor3 = newState and THEME.TOGGLE_ON or THEME.ROW
                    config.Save()
                end)
            end
        end

        renderPets("")
        searchBox:GetPropertyChangedSignal("Text"):Connect(function() renderPets(searchBox.Text) end)
        selAllBtn.MouseButton1Click:Connect(function() PetCatalog:SelectAll(config); renderPets(searchBox.Text); config.Save() end)
        clrAllBtn.MouseButton1Click:Connect(function() PetCatalog:ClearAll(config); renderPets(searchBox.Text); config.Save() end)

        -- TAB 8: Settings
        local settingsTab = createTab("Settings", "⚙", 8)
        local function infoRow(parent, label, value, lo2)
            local row = makeFrame(parent, UDim2.new(1, 0, 0, 34), nil, THEME.ROW)
            row.LayoutOrder = lo2 or 0
            applyCorner(row, 6)
            makeLabel(row, label, UDim2.new(0.45, 0, 1, 0), UDim2.new(0, 10, 0, 0), 11, Enum.Font.GothamMedium, THEME.TEXT_DIM)
            makeLabel(row, value, UDim2.new(0.55, -10, 1, 0), UDim2.new(0.45, 0, 0, 0), 11, Enum.Font.GothamBold, THEME.TEXT, Enum.TextXAlignment.Right)
            return row
        end

        infoRow(settingsTab, "Version", config.ScriptVersion or "2.0.0", 1)
        infoRow(settingsTab, "Author", config.Author or "Potent", 2)

        local discordBtn = makeButton(settingsTab, "📋  Copy Discord Link", UDim2.new(1, 0, 0, 34), nil, THEME.ACCENT_DIM, THEME.TEXT, 12, Enum.Font.GothamMedium)
        discordBtn.LayoutOrder = 3
        applyCorner(discordBtn, 7)
        discordBtn.MouseButton1Click:Connect(function()
            if setclipboard then
                setclipboard(config.Discord or "")
                discordBtn.Text = "✅  Copied!"
                task.delay(2, function() discordBtn.Text = "📋  Copy Discord Link" end)
            end
        end)

        FloatingButton.Create(function()
            self._visible = not self._visible
            mainFrame.Visible = self._visible
        end)

        switchTab("Farm")

        if config.Settings.Farm.Enabled then
            task.delay(0.5, function()
                farmEngine:Start(config, eggTracker, targetRanker, teleportEngine)
                farmBtn.Text = "⏹  STOP FARM"
                farmBtn.BackgroundColor3 = THEME.RED
            end)
        end

        return screenGui
    end

    return MainGui
end)

-- ─── 13. Main Orchestrator Execution ──────────────────────────────────────
local KyaxuConfig    = requireModule("KyaxuConfig")
local EggTracker     = requireModule("Core.EggTracker")
local TargetRanker   = requireModule("Core.TargetRanker")
local TeleportEngine = requireModule("Core.TeleportEngine")
local FarmEngine     = requireModule("Core.FarmEngine")
local AntiCheat      = requireModule("Core.AntiCheat")
local ServerHop      = requireModule("Features.ServerHop")
local PetCatalog     = requireModule("Features.PetCatalog")
local MainGui        = requireModule("UI.MainGui")

if not game:IsLoaded() then
    game.Loaded:Wait()
end

print("[Kyaxu Hub] Loading v" .. KyaxuConfig.ScriptVersion .. "...")

ServerHop:ResetArrival()
EggTracker:Init()

local gui = MainGui:Init(
    KyaxuConfig,
    FarmEngine,
    EggTracker,
    TargetRanker,
    TeleportEngine,
    ServerHop
)

EggTracker.Updated:Connect(function()
    ServerHop:CheckAndHop(EggTracker, KyaxuConfig)
end)

if KyaxuConfig.Settings.ServerHop.FarmEverythingByItself and not KyaxuConfig.Settings.Farm.Enabled then
    task.delay(KyaxuConfig.Settings.ServerHop.GracePeriod or 10, function()
        FarmEngine:Start(KyaxuConfig, EggTracker, TargetRanker, TeleportEngine)
    end)
end

print("[Kyaxu Hub] Initialized and running successfully!")

