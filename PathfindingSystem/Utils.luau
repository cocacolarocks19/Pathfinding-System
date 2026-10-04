local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local Utils = {}

function Utils.ParseWaypoints(waypointsInput: any): { Vector3 }
	if not waypointsInput then
		return {}
	end

	local parsed: { Vector3 } = {}

	if typeof(waypointsInput) == "Instance" then
		local children = waypointsInput:GetChildren()
		table.sort(children, function(a, b)
			local numA = tonumber(a.Name:match("%d+")) or 0
			local numB = tonumber(b.Name:match("%d+")) or 0
			if numA ~= numB then
				return numA < numB
			end
			return a.Name < b.Name
		end)

		for _, child in ipairs(children) do
			if child:IsA("BasePart") then
				table.insert(parsed, child.Position)
			elseif child:IsA("Attachment") then
				table.insert(parsed, child.WorldPosition)
			end
		end
	elseif type(waypointsInput) == "table" then
		for _, entry in ipairs(waypointsInput) do
			if typeof(entry) == "Vector3" then
				table.insert(parsed, entry)
			elseif typeof(entry) == "Instance" and entry:IsA("BasePart") then
				table.insert(parsed, entry.Position)
			elseif typeof(entry) == "Instance" and entry:IsA("Attachment") then
				table.insert(parsed, entry.WorldPosition)
			end
		end
	end

	return parsed
end

function Utils.GetRaycastSteeringDirection(originPart: BasePart, targetPosition: Vector3, rayLength: number?): Vector3
	local length = rayLength or 6
	local origin = originPart.Position

	-- 1. Flatten direction to XZ plane to prevent angled ground raycasts
	local flatTarget = Vector3.new(targetPosition.X, origin.Y, targetPosition.Z)
	local offset = flatTarget - origin
	local distance = offset.Magnitude

	-- Guard against zero-length vectors when NPC is at the target position
	if distance < 0.1 then
		return originPart.CFrame.LookVector
	end

	local desiredDir = offset.Unit

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { originPart.Parent }

	-- 2. Direct Forward Raycast
	local forwardHit = Workspace:Raycast(origin, desiredDir * length, params)
	if not forwardHit then
		return desiredDir
	end

	-- 3. Multi-Angle Whisker Sweeps (30°, 60°, 90° Left and Right)
	local whiskerAngles = { 30, -30, 60, -60, 90, -90 }
	local bestDir: Vector3? = nil
	local maxClearance = 0

	for _, angle in ipairs(whiskerAngles) do
		local whiskerDir = (CFrame.Angles(0, math.rad(angle), 0) * CFrame.new(Vector3.zero, desiredDir)).LookVector
		local hit = Workspace:Raycast(origin, whiskerDir * length, params)

		if not hit then
			-- Unobstructed corridor found; steer immediately
			return whiskerDir
		else
			-- Track direction with maximum distance before obstacle contact
			local clearance = (hit.Position - origin).Magnitude
			if clearance > maxClearance then
				maxClearance = clearance
				bestDir = whiskerDir
			end
		end
	end

	-- 4. Fallback to direction with highest spatial clearance if surrounded
	return bestDir or desiredDir
end

function Utils.DrawDebugPathLine(ownerModel: Model, startPos: Vector3, endPos: Vector3, visualConfig: table?)
	local cfg = visualConfig or {}
	if cfg.Enabled == false then
		Utils.ClearDebugWaypoints(ownerModel)
		return
	end

	local mainFolder = Workspace:FindFirstChild("PathDebug")
	if not mainFolder then
		mainFolder = Instance.new("Folder")
		mainFolder.Name = "PathDebug"
		mainFolder.Parent = Workspace
	end

	local id = ownerModel:GetAttribute("DebugId")
	if not id then
		id = HttpService:GenerateGUID(false)
		ownerModel:SetAttribute("DebugId", id)
	end

	local subFolder = mainFolder:FindFirstChild(id)
	if not subFolder then
		subFolder = Instance.new("Folder")
		subFolder.Name = id
		subFolder.Parent = mainFolder
	end

	local sphere = subFolder:FindFirstChild("TargetMarker") :: BasePart?
	if not sphere then
		sphere = Instance.new("Part")
		sphere.Name = "TargetMarker"
		sphere.Shape = Enum.PartType.Ball
		sphere.Material = Enum.Material.Neon
		sphere.Anchored = true
		sphere.CanCollide = false
		sphere.CastShadow = false
		sphere.Parent = subFolder
	end

	sphere.Size = Vector3.new(cfg.WaypointSize or 0.6, cfg.WaypointSize or 0.6, cfg.WaypointSize or 0.6)
	sphere.Color = cfg.WaypointColor or Color3.fromRGB(0, 255, 150)
	sphere.Position = endPos

	if cfg.ShowPathLines ~= false then
		local distance = (endPos - startPos).Magnitude
		local line = subFolder:FindFirstChild("PathLine") :: BasePart?

		if distance > 0.1 then
			if not line then
				line = Instance.new("Part")
				line.Name = "PathLine"
				line.Material = Enum.Material.Neon
				line.Anchored = true
				line.CanCollide = false
				line.CastShadow = false
				line.Parent = subFolder
			end

			local thickness = cfg.PathLineThickness or 0.15
			line.Size = Vector3.new(thickness, thickness, distance)
			line.CFrame = CFrame.lookAt(startPos, endPos) * CFrame.new(0, 0, -distance / 2)
			line.Color = cfg.PathLineColor or Color3.fromRGB(0, 170, 255)
		elseif line then
			line:Destroy()
		end
	end
end

function Utils.ClearDebugWaypoints(ownerModel: Model?)
	local mainFolder = Workspace:FindFirstChild("PathDebug")
	if not mainFolder then
		return
	end

	if ownerModel then
		local id = ownerModel:GetAttribute("DebugId")
		if id then
			local subFolder = mainFolder:FindFirstChild(id)
			if subFolder then
				subFolder:Destroy()
			end
		end
	else
		mainFolder:ClearAllChildren()
	end
end

function Utils.GetClosestPlayer(originPosition: Vector3, maxDistance: number?): (Player?, number)
	local closestPlayer = nil
	local shortestDistance = maxDistance or math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				local dist = (char.HumanoidRootPart.Position - originPosition).Magnitude
				if dist < shortestDistance then
					shortestDistance = dist
					closestPlayer = player
				end
			end
		end
	end

	return closestPlayer, shortestDistance
end

return Utils
