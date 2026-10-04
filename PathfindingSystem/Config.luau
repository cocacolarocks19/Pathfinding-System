local Config = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	WaypointSpacing = 4,

	-- Movement & Safety Settings
	StuckTimeout = 1.5,

	-- Visual Settings
	Visuals = {
		Enabled = false,
		WaypointSize = 0.6,
		WaypointColor = Color3.fromRGB(0, 255, 150),
		JumpWaypointColor = Color3.fromRGB(255, 170, 0),
		ShowPathLines = true,
		PathLineColor = Color3.fromRGB(0, 170, 255),
		PathLineThickness = 0.15,
		AutoClearDelay = 3,
	},

	-- Modular State Registry & Default Parameters
	States = {
		Idle = {
			Enabled = true,
			WalkSpeed = 0,
			Animation = "IdleAnim",
		},

		Wander = {
			Enabled = true,
			WalkSpeed = 8,
			WanderRadius = 25,
			WaitTimeAtDestination = 2.0,
			RaycastLength = 6,
		},

		Patrol = {
			Enabled = true,
			WalkSpeed = 8,
			WaitTimeAtWaypoint = 1.5,
			WaypointReachDistance = 3,
			RaycastLength = 6,
		},

		WaypointFollow = {
			Enabled = true,
			WalkSpeed = 12,
			WaypointReachDistance = 3,
			WaitTimeAtWaypoint = 0, -- 0 for continuous Tower Defense movement
			Loop = false, -- Set to true for repeating paths, false for TD end-of-path
			RaycastLength = 6,
		},

		Chasing = {
			Enabled = true,
			WalkSpeed = 14,
			DetectionRange = 40,
			RaycastLength = 8,
			LoseTargetDistance = 55,
		},

		Attack = {
			Enabled = true,
			WalkSpeed = 0,
			AttackRange = 4.5,
			AttackCooldown = 1.2,
			Damage = 10,
		},

		Flee = {
			Enabled = true,
			WalkSpeed = 16,
			FleeHealthThreshold = 0.25,
			FleeDistance = 50,
			RaycastLength = 6,
		},

		Search = {
			Enabled = true,
			WalkSpeed = 10,
			SearchDuration = 5.0,
			RaycastLength = 6,
		},
	},
}

return Config
