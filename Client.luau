local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ClientPathfinder = {}
local LocalPlayer = Players.LocalPlayer

local MAX_DEBUG_DISTANCE_SQ = 80 * 80 -- 6400 studs squared
local UPDATE_INTERVAL = 1 / 30 -- Throttle rendering to 30 FPS

type VisualCache = {
	model: Model,
	root: BasePart?,
	sphere: Part,
	line: Part,
	destroyConn: RBXScriptConnection?,
}

local activeNPCs: { VisualCache } = {}
local npcMap: { [Model]: VisualCache } = {}
local mainFolder: Folder? = nil

local function getMainFolder(): Folder
	if not mainFolder or not mainFolder.Parent then
		mainFolder = Workspace:FindFirstChild("PathDebug") :: Folder?
		if not mainFolder then
			local folder = Instance.new("Folder")
			folder.Name = "PathDebug"
			folder.Parent = Workspace
			mainFolder = folder
		end
	end
	return mainFolder
end

local function addNPC(model: Model)
	if npcMap[model] then
		return
	end

	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local parentFolder = getMainFolder()

	local sphere = Instance.new("Part")
	sphere.Name = "TargetMarker"
	sphere.Shape = Enum.PartType.Ball
	sphere.Material = Enum.Material.Neon
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CastShadow = false
	sphere.Size = Vector3.new(0.6, 0.6, 0.6)
	sphere.Color = Color3.fromRGB(0, 255, 150)
	sphere.Transparency = 1
	sphere.Parent = parentFolder

	local line = Instance.new("Part")
	line.Name = "PathLine"
	line.Material = Enum.Material.Neon
	line.Anchored = true
	line.CanCollide = false
	line.CastShadow = false
	line.Size = Vector3.new(0.15, 0.15, 1)
	line.Color = Color3.fromRGB(0, 170, 255)
	line.Transparency = 1
	line.Parent = parentFolder

	local cache: VisualCache = {
		model = model,
		root = root,
		sphere = sphere,
		line = line,
		destroyConn = nil,
	}

	cache.destroyConn = model.Destroying:Connect(function()
		ClientPathfinder.RemoveNPC(model)
	end)

	npcMap[model] = cache
	table.insert(activeNPCs, cache)
end

function ClientPathfinder.RemoveNPC(model: Model)
	local cache = npcMap[model]
	if not cache then
		return
	end

	npcMap[model] = nil
	for i = #activeNPCs, 1, -1 do
		if activeNPCs[i] == cache then
			table.remove(activeNPCs, i)
			break
		end
	end

	if cache.destroyConn then
		cache.destroyConn:Disconnect()
		cache.destroyConn = nil
	end

	cache.sphere:Destroy()
	cache.line:Destroy()
end

function ClientPathfinder.Init()
	CollectionService:GetInstanceAddedSignal("PathfindingNPC"):Connect(function(instance)
		if instance:IsA("Model") then
			addNPC(instance)
		end
	end)

	CollectionService:GetInstanceRemovedSignal("PathfindingNPC"):Connect(function(instance)
		if instance:IsA("Model") then
			ClientPathfinder.RemoveNPC(instance)
		end
	end)

	for _, instance in ipairs(CollectionService:GetTagged("PathfindingNPC")) do
		if instance:IsA("Model") then
			addNPC(instance)
		end
	end

	local lastUpdate = 0

	RunService.RenderStepped:Connect(function(deltaTime)
		lastUpdate += deltaTime
		if lastUpdate < UPDATE_INTERVAL then
			return
		end
		lastUpdate = 0

		local char = LocalPlayer.Character
		local myRoot = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?

		if not myRoot then
			for i = 1, #activeNPCs do
				local cache = activeNPCs[i]
				if cache.sphere.Transparency ~= 1 then
					cache.sphere.Transparency = 1
				end
				if cache.line.Transparency ~= 1 then
					cache.line.Transparency = 1
				end
			end
			return
		end

		local myPos = myRoot.Position

		for i = 1, #activeNPCs do
			local cache = activeNPCs[i]
			local model = cache.model
			local npcRoot = cache.root or (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
			cache.root = npcRoot

			local targetPos = model:GetAttribute("DebugTargetPos") :: Vector3?
			local targetEntity = model:GetAttribute("DebugTargetEntity") :: string?

			-- Fetch custom visual attributes or fall back to defaults
			local lineColor = (model:GetAttribute("DebugLineColor") :: Color3?) or Color3.fromRGB(0, 170, 255)
			local waypointColor = (model:GetAttribute("DebugWaypointColor") :: Color3?) or Color3.fromRGB(0, 255, 150)
			local waypointSize = (model:GetAttribute("DebugWaypointSize") :: number?) or 0.6
			local lineThickness = (model:GetAttribute("DebugLineThickness") :: number?) or 0.15
			local showPathLines = model:GetAttribute("DebugShowPathLines")
			if showPathLines == nil then
				showPathLines = true
			end

			if targetPos and npcRoot then
				local startPos = npcRoot.Position
				local offset = startPos - myPos
				local distSq = offset:Dot(offset)

				if distSq <= MAX_DEBUG_DISTANCE_SQ then
					local endPos = targetPos
					if targetEntity and targetEntity == LocalPlayer.Name then
						endPos = myPos
					end

					local vec = endPos - startPos
					local distance = vec.Magnitude

					cache.sphere.Transparency = 0
					cache.sphere.Position = endPos
					cache.sphere.Size = Vector3.new(waypointSize, waypointSize, waypointSize)
					cache.sphere.Color = waypointColor

					if showPathLines and distance > 0.3 then
						cache.line.Transparency = 0.2
						cache.line.Color = lineColor
						local lookCFrame = CFrame.lookAt(startPos, endPos)
						if lookCFrame == lookCFrame then
							cache.line.Size = Vector3.new(lineThickness, lineThickness, distance)
							cache.line.CFrame = lookCFrame * CFrame.new(0, 0, -distance / 2)
						end
					else
						if cache.line.Transparency ~= 1 then
							cache.line.Transparency = 1
						end
					end
				else
					if cache.sphere.Transparency ~= 1 then
						cache.sphere.Transparency = 1
					end
					if cache.line.Transparency ~= 1 then
						cache.line.Transparency = 1
					end
				end
			else
				if cache.sphere.Transparency ~= 1 then
					cache.sphere.Transparency = 1
				end
				if cache.line.Transparency ~= 1 then
					cache.line.Transparency = 1
				end
			end
		end
	end)
end

return ClientPathfinder
