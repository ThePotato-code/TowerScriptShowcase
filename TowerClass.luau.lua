--!strict
--[[
	

	This script defines a single TowerClass object using metatable-based OOP.
	The tower continuously searches for enemies in range, checks line-of-sight,
	aims at the selected target, and attacks on a cooldown.

	Notes:
	- This script assumes enemies are stored under workspace.Enemies as Models.
	- Each enemy Model should have a PrimaryPart and a Humanoid for health.
	- This script assumes the Tower model has a PrimaryPart and a Part named "Spawn".
	
	- Bullets are purely visual.
	- The script is purely client sided with only a damage verification
]]

local TowerClass = {} -- The main class table; all methods and metamethods live here
TowerClass.__index = TowerClass -- Redirect index lookups to TowerClass so instances inherit all methods

--// Services
local RunService = game:GetService("RunService")         -- Used for the per-frame Heartbeat/RenderStepped loop
local RP = game:GetService("ReplicatedStorage")          -- Kept for potential future use (currently unused alias)
local TweenService = game:GetService("TweenService")     -- Drives the visual bullet animation
local Debris = game:GetService("Debris")                 -- Safety-cleanup for bullet parts if the tween is interrupted
local CollectionService = game:GetService("CollectionService") -- Retrieves all instances tagged "Enemy" for targeting
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Used to locate the ValidateTowerAttack remote

--// Remotes
local TowerRemotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Tower") -- Folder containing all tower-related RemoteEvents/Functions
local ValidateAttackRemote = TowerRemotes:WaitForChild("ValidateTowerAttack")         -- Remote the client fires to ask the server to validate and apply damage

--// Config typing (values passed into TowerClass.new)
type Configs = {
	Range: number,    -- How far (in studs) the tower can detect and attack enemies
	Damage: number,   -- Base damage dealt per shot before distance falloff is applied
	Price: number,    -- Purchase cost of this tower (used by a shop/placement system)
	Owner: Player,    -- The Player instance who owns/placed this tower
	Speed: number,    -- Visual bullet travel speed in studs per second (controls tween duration)
}

--// TowerClass instance type (helps strict mode + autocomplete)
export type TowerClass = typeof(setmetatable({} :: {
	Target: Model | any,                 -- The enemy Model currently being targeted (nil when idle)
	Range: number,                       -- Detection and attack range copied from Configs
	Damage: number,                      -- Base damage per shot copied from Configs
	Cooldown: number,                    -- Seconds remaining before the tower can fire again
	Price: number,                       -- Tower price copied from Configs
	Owner: Player,                       -- Owning player copied from Configs
	LastAttack: number,                  -- Reserved timestamp; not actively used yet
	Model: Model | any,                  -- The cloned tower Model placed in the world
	Speed: number,                       -- Bullet visual speed copied from Configs (default 100)
	func: RBXScriptConnection,           -- Stores the RenderStepped connection so it can be disconnected on cleanup
	LastSearchForTarget: number,         -- Timestamp of the last target scan; throttles scanning to every 0.2 s
	Tween: Tween,                        -- Reference to the most recent bullet tween; paused/destroyed on cleanup
	IsActive: boolean,                   -- Master on/off switch; false = tower skips all Update logic
}, TowerClass))

--[[
	Calculates distance between tower and enemy using their PrimaryParts.
	This is used for range checks and target sorting.
]]
local function CalculateDistance(Tower: Model, Enemy: Model): number
	assert(Tower.PrimaryPart, "Tower does not posses a primary part") -- Guard: crash early with a clear message instead of a cryptic nil error
	assert(Enemy.PrimaryPart, "Enemy does not posses a primary part") -- Guard: same protection for the enemy side

	return (Enemy.PrimaryPart.Position - Tower.PrimaryPart.Position).Magnitude -- Vector subtraction gives the displacement; .Magnitude gives the scalar distance
end

--[[
	Checks if an enemy is dead.
	We look for a Humanoid and check if its health is <= 0.
	If no humanoid exists, this returns false (enemy is treated as alive/invalid elsewhere).
]]
local function EnemyIsDead(Enemy: Model): boolean
	local hum = Enemy:FindFirstChildOfClass("Humanoid") -- Search the model for the first (and usually only) Humanoid
	return hum ~= nil and hum.Health <= 0               -- Enemy is dead only if a Humanoid exists AND its health has hit zero
end

--[[
	Returns the unit direction vector from tower to enemy.
	This is used for raycast direction (line-of-sight) and can be reused for projectiles although not here.
]]
local function CalculateDirection(Tower: Model, Enemy: Model): Vector3
	assert(Tower.PrimaryPart, "Tower does not posses a primary part") -- Guard: ensure the tower has a valid root part
	assert(Enemy.PrimaryPart, "Enemy does not posses a primary part") -- Guard: ensure the enemy has a valid root part

	return (Enemy.PrimaryPart.Position - Tower.PrimaryPart.Position).Unit -- Subtract positions to get the raw vector, then normalize to length 1 with .Unit
end

--[[
	Line-of-sight check between tower and enemy.
	We raycast from the tower's PrimaryPart toward the enemy depending on the range.
	FilterType = Exclude with {Tower} means we skip the tower's own parts when casting.

	If nothing is hit, or we hit something inside the enemy, we consider LOS clear.
]]
local function HasLineOfSight(Tower: Model, Enemy: Model, range: number): boolean | any
	local Start = Tower.PrimaryPart -- Ray origin: the tower's root part
	local End = Enemy.PrimaryPart   -- Ray destination reference: the enemy's root part
	if not Start or not End then    -- If either part is missing, we can't cast; return nil (falsy)
		return
	end

	local params = RaycastParams.new()                                     -- Create fresh raycast parameters for this check
	params.FilterType = Enum.RaycastFilterType.Exclude                     -- Exclude mode: the listed instances are ignored by the ray
	params.FilterDescendantsInstances = { Tower }                          -- Exclude the tower itself so the ray doesn't immediately self-intersect

	local dir = CalculateDirection(Tower, Enemy)                           -- Get the normalised direction vector toward the enemy
	local ray = workspace:Raycast(Start.Position, dir * range, params)    -- Cast the ray up to `range` studs in that direction

	return ray == nil or ray.Instance:IsDescendantOf(Enemy) -- LOS is clear if nothing was hit, OR if the first hit belongs to the enemy model itself
end

--[[
	Constructor.
	We clone the provided model so each tower instance has its own copy.
]]
function TowerClass.new(Model: Model, configs: Configs)
	local self = setmetatable({ -- Create a plain table and attach TowerClass as its metatable so it inherits all methods
		Target = nil,                  -- No target selected yet; SearchForTarget will fill this in
		Range = configs.Range,         -- Copy detection/attack range from configs
		Damage = configs.Damage,       -- Copy base damage from configs
		Price = configs.Price,         -- Copy purchase price from configs
		Owner = configs.Owner,         -- Copy owning player reference from configs

		LastAttack = 0,                -- Reserved for potential future cooldown stamping (not used in current logic)
		Model = Model:Clone(),         -- Clone the source model so this instance has its own independent copy

		func = nil,                    -- Will be set to the RenderStepped connection when Spawn() is called
		Cooldown = 0,                  -- Start at 0 so the tower can fire immediately after spawning

		ProjectileFunc = nil,          -- Reserved slot for a future projectile update connection
		Speed = configs.Speed or 100,  -- Use provided bullet speed, falling back to 100 studs/s if omitted

		IsActive = true,               -- Tower starts in the active (enabled) state
	}, TowerClass)

	return self -- Return the fully initialised instance to the caller
end

--[[
	Spawns the tower into the world.
	Starts a RenderStepped update loop that drives targeting, aiming, and attacking.
]]
function TowerClass.Spawn(self: TowerClass, SpawnCFrame: CFrame)
	self.Model:PivotTo(SpawnCFrame) -- Move (and rotate) the cloned model to the desired placement CFrame
	self.Model.Parent = workspace   -- Parent into workspace to make the model visible in the world

	self.LastSearchForTarget = tick() -- Initialise the throttle timer so the first scan isn't skipped

	-- Connect the per-frame update; dt (delta time) is passed in for cooldown and lerp calculations.
	self.func = RunService.RenderStepped:Connect(function(dt)
		self:Update(dt) -- Delegate all per-frame logic to the Update method
	end)
end

--[[
	Main update loop.
	- If inactive: do nothing.
	- If no target: occasionally search for one (every 0.2s).
	- If target exists: tick cooldown, attack when ready, and aim smoothly.
]]
function TowerClass.Update(self: TowerClass, dt: number)
	if not self.IsActive then -- If the tower has been disabled, skip all logic this frame
		return
	end

	-- Acquire a target if we currently have none.
	if not self.Target then
		if tick() - self.LastSearchForTarget >= 0.2 then -- Only scan every 0.2 s to avoid expensive per-frame sorting
			self.LastSearchForTarget = tick()             -- Reset the throttle timer
			self:SearchForTarget()                        -- Run the range + LOS scan and assign self.Target if found
		end
		return -- Nothing more to do until we have a target
	end

	-- We have a target; confirm it is still alive, in range, and valid.
	if self.Target and self:ValidateTarget() then
		-- Count down the remaining cooldown using real elapsed time.
		if self.Cooldown > 0 then
			self.Cooldown -= dt -- Subtract this frame's elapsed time from the remaining cooldown
		else
			self.Cooldown = 0.5 -- Reset cooldown to 0.5 s (defines the fire rate: 2 shots per second)
			self:Attack()       -- Fire at the validated target
		end

		-- Smoothly rotate the tower toward the target each frame regardless of fire readiness.
		self:AimAt(dt)
	end
end

--[[
	Performs an attack on the current target.
	
	- Visual bullet tween is spawned via PlayAnim().
	- If enemy dies, it is destroyed and target resets.
]]
function TowerClass.Attack(self: TowerClass)
	if not self:ValidateTarget() then -- Re-validate right before firing; target might have just died or left range
		return
	end

	-- Calculate the direction to the target (currently unused directly, reserved for ballistic projectiles).
	local Direction = CalculateDirection(self.Model, self.Target)
	_ = Direction -- Explicitly discard to silence the unused-variable warning under --!strict

	-- Compute damage with distance falloff applied.
	local CalculateDamage = self:CalculateDamage() -- Returns a rounded integer damage value

	-- Spawn the visual-only bullet tween toward the target.
	self:PlayAnim()

	-- Tell the server about the attack so it can re-validate range, cooldown, etc. and apply actual health reduction.
	ValidateAttackRemote:FireServer(CalculateDamage, self.Target, self.Model)

	-- If the humanoid is already at 0 HP client-side, clean up the enemy model immediately.
	if EnemyIsDead(self.Target) then
		self.Target:Destroy() -- Remove the enemy model from the workspace
		self.Target = nil     -- Clear the reference so the tower starts scanning for a new target
	end
end

--[[
	Searches for a target which has the tag "Enemy".
	We build a list of enemies within range (and with line-of-sight),
	then sort by closest distance, and pick the closest.
]]
function TowerClass.SearchForTarget(self: TowerClass)
	local CurrentEnemies = CollectionService:GetTagged("Enemy") -- Get every instance currently tagged "Enemy" in the game
	local EnemiesInRange: { Model } = {}                        -- Accumulator for enemies that pass range + LOS checks

	-- Iterate the tagged instances and filter down to valid candidates.
	for _, Enemy in ipairs(CurrentEnemies) do
		if Enemy:IsA("Model") then -- Only consider full Models (ignores any accidentally tagged non-models)
			local Distance = CalculateDistance(self.Model, Enemy) -- Measure studs between tower and this enemy

			-- Accept the enemy only if it's within attack range AND has an unobstructed line of sight.
			if Distance <= self.Range and HasLineOfSight(self.Model, Enemy, self.Range) then
				table.insert(EnemiesInRange, Enemy) -- Add to the candidate list for sorting
			end
		end
	end

	-- No valid targets found this scan; leave self.Target as nil and wait for the next throttled scan.
	if #EnemiesInRange == 0 then
		return
	end

	-- Sort candidates ascending by distance so index [1] is the closest enemy.
	table.sort(EnemiesInRange, function(a: Model, b: Model)
		return CalculateDistance(self.Model, a) < CalculateDistance(self.Model, b) -- Comparator: true when a is closer than b
	end)

	self.Target = EnemiesInRange[1] -- Assign the nearest valid enemy as the active target
end

--[[
	Validates the current target.
	This prevents errors if the target gets destroyed, loses its PrimaryPart,
	or walks out of range.
]]
function TowerClass.ValidateTarget(self: TowerClass)
	if not self.Target or not self.Target.Parent then -- Target is nil OR has been removed from the DataModel
		self.Target = nil  -- Ensure the field is explicitly nil (handles the "not self.Target" branch too)
		return false       -- Signal that validation failed
	end

	if not self.Target.PrimaryPart then -- PrimaryPart can be removed independently (e.g., ragdoll systems)
		self.Target = nil -- Drop the invalid target reference
		return false      -- Signal that validation failed
	end

	-- Drop the target if it has walked or been pushed outside the tower's attack range.
	if CalculateDistance(self.Model, self.Target) > self.Range then
		self.Target = nil -- Clear target; SearchForTarget will find a new one on the next throttled scan
		return false      -- Signal that validation failed
	end

	return true -- All checks passed; target is still valid
end

--[[
	Spawns a purely visual bullet that tweens from tower "Spawn" part to target.
	No hit detection is done here because damage is applied instantly in Attack().
]]
function TowerClass.PlayAnim(self: TowerClass)
	if not self:ValidateTarget() then -- Abort if the target became invalid between Attack() and PlayAnim()
		return
	end

	local BulletSpawn: Part = self.Model:FindFirstChild("Spawn") -- Find the designated bullet origin part on the tower model
	local TargetPrim = self.Target.PrimaryPart                   -- Cache the target's root part position as the tween goal
	if not BulletSpawn or not TargetPrim then                    -- If either part is missing, we can't animate; bail out
		return
	end

	local Goal = { Position = TargetPrim.Position }               -- Tween will move the bullet to the enemy's current position
	local Distance = CalculateDistance(self.Model, self.Target)   -- Distance is used to scale travel time proportionally

	-- Clamp travel time between 0.2 s (minimum visible) and 1.5 s (maximum for very far targets).
	local TravelTime = math.clamp(Distance / self.Speed, 0.2, 1.5)
	local TI = TweenInfo.new(TravelTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out) -- Linear easing gives a constant-speed bullet feel

	-- Create the bullet part inside workspace.Ignore so raycasts can easily exclude all bullets at once.
	local Bullet = Instance.new("Part", workspace.Ignore)
	Bullet.CanCollide = false             -- Bullet must not physically interact with anything
	Bullet.Anchored = true                -- Must be anchored so TweenService can control its position
	Bullet.Massless = true                -- Massless prevents it from affecting physics even briefly
	Bullet.Position = BulletSpawn.Position -- Start at the barrel/spawn part of the tower
	Bullet.Material = Enum.Material.Neon  -- Neon material makes the bullet glow for visibility
	Bullet.Color = Color3.new(1, 0, 0)    -- Bright red colour for easy identification
	Bullet.Size = Vector3.new(2, 2, 2)    -- 2×2×2 stud cube; resize to taste

	self.Tween = TweenService:Create(Bullet, TI, Goal) -- Create the position tween from spawn to target
	self.Tween:Play()                                   -- Begin the tween immediately

	-- Destroy the bullet part as soon as it reaches the target so we don't leak instances.
	self.Tween.Completed:Connect(function()
		Bullet:Destroy() -- Remove the bullet from the workspace when the tween finishes
	end)

	-- Fallback: Debris removes the bullet after (Distance / 2.5) seconds in case the tween is cancelled or interrupted.
	Debris:AddItem(Bullet, Distance / 2.5)
end

--[[
	Smoothly rotates the tower PrimaryPart to face the target.
	Lerp keeps turning smooth instead of snapping instantly.
]]
function TowerClass.AimAt(self: TowerClass, dt: number)
	local head = self.Model.PrimaryPart                    -- The part that physically rotates to face the enemy
	if not head or not self:ValidateTarget() then          -- Abort if the tower has no root part or the target is gone
		return
	end

	local headpos: Vector3 = head.Position                            -- Current world position of the tower's root part
	local targetpos: Vector3 = self.Target.PrimaryPart.Position       -- Current world position of the enemy's root part

	local desired = CFrame.lookAt(headpos, Vector3.new(targetpos.X, targetpos.Y, targetpos.Z)) -- Construct a CFrame at headpos oriented so +Z points at the target
	head.CFrame = head.CFrame:Lerp(desired, math.clamp(dt * 8, 0, 1)) -- Lerp from current rotation toward desired; dt*8 controls turn speed, clamped to [0,1]
end

--[[
	Damage falloff based on distance to the target.
	At max range, damage is reduced by up to 30%.
]]
function TowerClass.CalculateDamage(self: TowerClass): number
	if not self:ValidateTarget() then -- If there's no valid target, return base damage with no falloff
		return self.Damage
	end

	local Distance = CalculateDistance(self.Model, self.Target)  -- Measure current distance to the target
	local alpha = math.clamp(Distance / self.Range, 0, 1)        -- Normalise distance to [0, 1]: 0 = point-blank, 1 = max range
	local mult = 1 - 0.3 * alpha                                 -- Multiplier goes from 1.0 (full damage) down to 0.7 (30% reduction at max range)

	return math.round(self.Damage * mult) -- Apply multiplier and round to the nearest integer for clean damage numbers
end

--[[
	Cleans up tower resources:
	- Disconnects Heartbeat loop
	- Destroys tower model
	- Stops/destroys any active bullet tween
]]
function TowerClass.CleanUp(self: TowerClass)
	if self.func then          -- Only disconnect if a connection was ever established
		self.func:Disconnect() -- Stop the RenderStepped loop so this tower no longer receives updates
	end

	if self.Model then          -- Only destroy if the model reference is still valid
		self.Model:Destroy()    -- Remove the tower model from the workspace
	end

	if self.Tween then          -- Only touch the tween if one was ever created
		self.Tween:Pause()      -- Pause first to stop any in-progress animation immediately
		self.Tween:Destroy()    -- Release the Tween object and its internal connections
	end
end

--[[
	Enable tower updates/attacks.
]]
function TowerClass.Activate(self: TowerClass)
	self.IsActive = true -- Set the master switch to true; Update() will resume normal logic next frame
end

--[[
	Disable tower updates/attacks.
]]
function TowerClass.Disable(self: TowerClass)
	self.IsActive = false -- Set the master switch to false; Update() will return early every frame until re-activated
end

return TowerClass -- Export the class table so other scripts can require() it and call TowerClass.new()
