local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local DefaultConfig = require(script.Parent.Config)
local Utils = require(script.Parent.Utils)

local Server = {}
Server.__index = Server

Server.Config = DefaultConfig
Server.ActiveEnemies = {} :: { [Model]: any }

local function deepCopy(t: table): table
	local copy = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			copy[k] = deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

local function mergeConfigs(customConfig: table?, baseConfig: table): table
	if not customConfig then
		return baseConfig
	end
	local merged = deepCopy(baseConfig)
	for key, value in pairs(customConfig) do
		if type(value) == "table" and type(merged[key]) == "table" then
			merged[key] = mergeConfigs(value, merged[key])
		else
			merged[key] = value
		end
	end
	return merged
end

function Server.SetConfig(newConfig: table)
	Server.Config = mergeConfigs(newConfig, Server.Config)
end

function Server.new(model: Model, enemyData: table?)
	local self = setmetatable({}, Server)
	self.Model = model
	self.Humanoid = model:WaitForChild("Humanoid") :: Humanoid
	self.Root = model:WaitForChild("HumanoidRootPart") :: BasePart

	self.EnemyData = enemyData or {}

	local instanceConfig = deepCopy(Server.Config)
	if self.EnemyData.Config then
		instanceConfig = mergeConfigs(self.EnemyData.Config, instanceConfig)
	end
	if self.EnemyData.States then
		instanceConfig.States = mergeConfigs(self.EnemyData.States, instanceConfig.States)
	end
	-- Merge custom visual configurations from EnemyData
	if self.EnemyData.Visuals then
		instanceConfig.Visuals = mergeConfigs(self.EnemyData.Visuals, instanceConfig.Visuals)
	end
	self.Config = instanceConfig

	self.CurrentState = "Idle"

	local rawWaypoints = self.EnemyData.Waypoints or self.EnemyData.PatrolWaypoints
	self.Waypoints = Utils.ParseWaypoints(rawWaypoints)

	self.CurrentWaypointIndex = 1
	self.StateTimer = os.clock()
	self.LastAttackTime = 0
	self.WanderTarget = nil :: Vector3?
	self.LastKnownTargetPos = nil :: Vector3?
	self.SearchStartTime = 0
	self.AITask = nil :: thread?

	return self
end

function Server:SteerTo(targetPos: Vector3, targetPlayerOrRayLength: (Player | number)?, rayLength: number?)
	local actualTargetPlayer: Player? = nil
	local actualRayLength: number? = nil

	if typeof(targetPlayerOrRayLength) == "Instance" and targetPlayerOrRayLength:IsA("Player") then
		actualTargetPlayer = targetPlayerOrRayLength
		actualRayLength = rayLength
	elseif typeof(targetPlayerOrRayLength) == "number" then
		actualRayLength = targetPlayerOrRayLength
	else
		actualRayLength = rayLength
	end

	local steerDir = Utils.GetRaycastSteeringDirection(self.Root, targetPos, actualRayLength)
	self.Humanoid:MoveTo(self.Root.Position + (steerDir * 8))

	if self.Config and self.Config.Visuals and self.Config.Visuals.Enabled then
		CollectionService:AddTag(self.Model, "PathfindingNPC")

		local visuals = self.Config.Visuals
		if visuals.PathLineColor then
			self.Model:SetAttribute("DebugLineColor", visuals.PathLineColor)
		end
		if visuals.WaypointColor then
			self.Model:SetAttribute("DebugWaypointColor", visuals.WaypointColor)
		end
		if visuals.WaypointSize then
			self.Model:SetAttribute("DebugWaypointSize", visuals.WaypointSize)
		end
		if visuals.PathLineThickness then
			self.Model:SetAttribute("DebugLineThickness", visuals.PathLineThickness)
		end
		if visuals.ShowPathLines ~= nil then
			self.Model:SetAttribute("DebugShowPathLines", visuals.ShowPathLines)
		end

		local lastPos = self.Model:GetAttribute("DebugTargetPos") :: Vector3?
		local lastEntity = self.Model:GetAttribute("DebugTargetEntity") :: string?
		local currentEntity = actualTargetPlayer and actualTargetPlayer.Name or nil

		if not lastPos or (lastPos - targetPos).Magnitude > 0.5 then
			self.Model:SetAttribute("DebugTargetPos", targetPos)
		end
		if lastEntity ~= currentEntity then
			self.Model:SetAttribute("DebugTargetEntity", currentEntity)
		end
	else
		CollectionService:RemoveTag(self.Model, "PathfindingNPC")
		self.Model:SetAttribute("DebugTargetPos", nil)
		self.Model:SetAttribute("DebugTargetEntity", nil)
		self.Model:SetAttribute("DebugLineColor", nil)
		self.Model:SetAttribute("DebugWaypointColor", nil)
		self.Model:SetAttribute("DebugWaypointSize", nil)
		self.Model:SetAttribute("DebugLineThickness", nil)
		self.Model:SetAttribute("DebugShowPathLines", nil)
	end
end

function Server:SetState(newState: string)
	if self.CurrentState == newState then
		return
	end
	self.CurrentState = newState
	self.StateTimer = os.clock()
end

function Server:Stop()
	if self.AITask then
		task.cancel(self.AITask)
		self.AITask = nil
	end
	self.CurrentState = "Idle"
	self.Humanoid:MoveTo(self.Root.Position)

	CollectionService:RemoveTag(self.Model, "PathfindingNPC")
	self.Model:SetAttribute("DebugTargetPos", nil)
	self.Model:SetAttribute("DebugTargetEntity", nil)
	Utils.ClearDebugWaypoints(self.Model)
end

function Server:Start()
	if self.AITask then
		return
	end

	self.AITask = task.spawn(function()
		while self.Model.Parent and self.Humanoid.Health > 0 do
			local states = self.Config.States
			local healthRatio = self.Humanoid.Health / self.Humanoid.MaxHealth

			local chaseCfg = states.Chasing or {}
			local isChasing = (self.CurrentState == "Chasing" or self.CurrentState == "Attack")
			local maxDetectionDist = if isChasing
				then (chaseCfg.LoseTargetDistance or chaseCfg.DetectionRange or 40)
				else (chaseCfg.DetectionRange or 40)

			local targetChar: Model? = nil
			local dist: number = math.huge

			-- If IgnorePlayers is set (standard for Tower Defense), skip character detection
			if not self.EnemyData.IgnorePlayers then
				local targetCallback = self.EnemyData.TargetCallback
					or function()
						local player, pDist = Utils.GetClosestPlayer(self.Root.Position, maxDetectionDist)
						return player and player.Character, pDist
					end

				targetChar, dist = targetCallback(self)
			end

			local targetHumanoid = targetChar and targetChar:FindFirstChildOfClass("Humanoid")
			if not targetHumanoid or targetHumanoid.Health <= 0 or dist > maxDetectionDist then
				targetChar = nil
				targetHumanoid = nil
			end

			local targetRoot = targetChar and (targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?)

			-- 1. FSM Transitions
			local fleeCfg = states.Flee
			local attackCfg = states.Attack
			local searchCfg = states.Search
			local patrolCfg = states.Patrol
			local waypointCfg = states.WaypointFollow
			local wanderCfg = states.Wander

			if fleeCfg and fleeCfg.Enabled and healthRatio <= fleeCfg.FleeHealthThreshold and targetRoot then
				self:SetState("Flee")
			elseif targetRoot and targetHumanoid then
				self.LastKnownTargetPos = targetRoot.Position

				if attackCfg and attackCfg.Enabled and dist <= attackCfg.AttackRange then
					self:SetState("Attack")
				elseif chaseCfg and chaseCfg.Enabled then
					self:SetState("Chasing")
				end
			else
				if self.CurrentState == "Chasing" or self.CurrentState == "Attack" then
					if not targetHumanoid then
						self.LastKnownTargetPos = nil
					elseif self.LastKnownTargetPos and searchCfg and searchCfg.Enabled then
						self.SearchStartTime = os.clock()
						self:SetState("Search")
					else
						self.LastKnownTargetPos = nil
					end
				end

				if self.CurrentState == "Search" then
					if os.clock() - self.SearchStartTime >= (searchCfg and searchCfg.SearchDuration or 5) then
						self.LastKnownTargetPos = nil
					end
				end

				if not self.LastKnownTargetPos then
					if waypointCfg and waypointCfg.Enabled and #self.Waypoints > 0 then
						self:SetState("WaypointFollow")
					elseif patrolCfg and patrolCfg.Enabled and #self.Waypoints > 1 then
						self:SetState("Patrol")
					elseif wanderCfg and wanderCfg.Enabled then
						self:SetState("Wander")
					else
						self:SetState("Idle")
					end
				end
			end

			-- 2. State Execution
			if self.CurrentState == "Idle" then
				local cfg = states.Idle or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 0
				self.Humanoid:MoveTo(self.Root.Position)

				CollectionService:RemoveTag(self.Model, "PathfindingNPC")
				self.Model:SetAttribute("DebugTargetPos", nil)
				self.Model:SetAttribute("DebugTargetEntity", nil)
			elseif self.CurrentState == "WaypointFollow" then
				local cfg = states.WaypointFollow or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 12
				local targetPoint = self.Waypoints[self.CurrentWaypointIndex] or self.Root.Position
				local distToPoint = (
					Vector3.new(targetPoint.X, self.Root.Position.Y, targetPoint.Z) - self.Root.Position
				).Magnitude

				if distToPoint <= (cfg.WaypointReachDistance or 3) then
					if os.clock() - self.StateTimer >= (cfg.WaitTimeAtWaypoint or 0) then
						if self.CurrentWaypointIndex < #self.Waypoints then
							self.CurrentWaypointIndex += 1
							self.StateTimer = os.clock()
						else
							-- End of path reached
							if cfg.Loop then
								self.CurrentWaypointIndex = 1
								self.StateTimer = os.clock()
							else
								if self.EnemyData.OnReachedEnd then
									self.EnemyData.OnReachedEnd(self.Model, self)
								else
									-- Default TD Behavior: Destroy mob upon reaching base
									self.Model:Destroy()
								end
								break
							end
						end
					end
				else
					self:SteerTo(targetPoint, cfg.RaycastLength)
				end
			elseif self.CurrentState == "Patrol" then
				local cfg = states.Patrol or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 8
				local targetPoint = self.Waypoints[self.CurrentWaypointIndex] or self.Root.Position
				local distToPoint = (
					Vector3.new(targetPoint.X, self.Root.Position.Y, targetPoint.Z) - self.Root.Position
				).Magnitude

				if distToPoint <= (cfg.WaypointReachDistance or 3) then
					self.Humanoid:MoveTo(self.Root.Position)
					if os.clock() - self.StateTimer >= (cfg.WaitTimeAtWaypoint or 1.5) then
						self.CurrentWaypointIndex = (self.CurrentWaypointIndex % #self.Waypoints) + 1
						self.StateTimer = os.clock()
					end
				else
					self.StateTimer = os.clock()
					self:SteerTo(targetPoint, cfg.RaycastLength)
				end
			elseif self.CurrentState == "Wander" then
				local cfg = states.Wander or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 8

				if not self.WanderTarget or (self.Root.Position - self.WanderTarget).Magnitude <= 3 then
					self.Humanoid:MoveTo(self.Root.Position)
					if os.clock() - self.StateTimer >= (cfg.WaitTimeAtDestination or 2) then
						local radius = cfg.WanderRadius or 25
						local offset = Vector3.new(math.random(-radius, radius), 0, math.random(-radius, radius))
						self.WanderTarget = self.Root.Position + offset
						self.StateTimer = os.clock()
					end
				else
					self:SteerTo(self.WanderTarget, cfg.RaycastLength)
				end
			elseif self.CurrentState == "Chasing" then
				local cfg = states.Chasing or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 14
				if targetRoot and targetChar then
					local targetPlayer = Players:GetPlayerFromCharacter(targetChar)
					self:SteerTo(targetRoot.Position, targetPlayer, cfg.RaycastLength)
				end
			elseif self.CurrentState == "Search" then
				local cfg = states.Search or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 10
				if self.LastKnownTargetPos then
					self:SteerTo(self.LastKnownTargetPos, cfg.RaycastLength)
				end
			elseif self.CurrentState == "Flee" then
				local cfg = states.Flee or {}
				self.Humanoid.WalkSpeed = cfg.WalkSpeed or 16
				if targetRoot then
					local awayDir = (self.Root.Position - targetRoot.Position).Unit
					local fleePos = self.Root.Position + (awayDir * (cfg.FleeDistance or 50))
					self:SteerTo(fleePos, cfg.RaycastLength)
				end
			elseif self.CurrentState == "Attack" then
				local cfg = states.Attack or {}
				self.Humanoid:MoveTo(self.Root.Position)

				if targetRoot and targetHumanoid then
					self.Root.CFrame = CFrame.lookAt(
						self.Root.Position,
						Vector3.new(targetRoot.Position.X, self.Root.Position.Y, targetRoot.Position.Z)
					)

					local now = os.clock()
					if now - self.LastAttackTime >= (cfg.AttackCooldown or 1) then
						self.LastAttackTime = now

						if self.EnemyData.OnAttack then
							self.EnemyData.OnAttack(self.Model, targetChar, cfg.Damage or 10)
						else
							targetHumanoid:TakeDamage(cfg.Damage or 10)
						end
					end
				end
			end

			task.wait(0.05)
		end
	end)
end

function Server.Register(enemyModel: Model, enemyData: table?)
	if not enemyModel or Server.ActiveEnemies[enemyModel] then
		return
	end

	local instance = Server.new(enemyModel, enemyData)
	instance:Start()

	Server.ActiveEnemies[enemyModel] = instance

	local function cleanup()
		Server.Unregister(enemyModel)
	end

	instance.Humanoid.Died:Once(cleanup)
	enemyModel.Destroying:Once(cleanup)

	return instance
end

function Server.Unregister(enemyModel: Model)
	local instance = Server.ActiveEnemies[enemyModel]
	if instance then
		instance:Stop()
		Server.ActiveEnemies[enemyModel] = nil
	end
end

return Server
