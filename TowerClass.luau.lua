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
	- THe script is purely client sided
]]

local TowerClass = {}
TowerClass.__index = TowerClass

--// Services
local RunService = game:GetService("RunService")
local RP = game:GetService("ReplicatedStorage")
local Networker = require(RP.Packages.Networker).server
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

--// Config typing (values passed into TowerClass.new)
type Configs = {
	Range: number,    -- how far the tower can detect / attack enemies
	Damage: number,   -- base damage per shot (before falloff)
	Price: number,    -- cost of the tower (for a shop system, etc.)
	Owner: Player,    -- player that owns/placed the tower
	Speed: number,    -- visual bullet speed (studs/sec-ish; used for tween duration)
}

--// TowerClass instance type (helps strict mode + autocomplete)
export type TowerClass = typeof(setmetatable({} :: {
	Target: Model | any,                 -- current target (enemy model)
	Range: number,                       -- detection range
	Damage: number,                      -- base damage
	Cooldown: number,                    -- time until next shot
	Price: number,                       -- tower price
	Owner: Player,                       -- tower owner
	LastAttack: number,                  -- (reserved) last attack time
	Model: Model | any,                  -- cloned tower model
	Speed: number,                       -- bullet visual speed
	func: RBXScriptConnection,           -- heartbeat connection
	LastSearchForTarget: number,         -- timer for throttling target searches
	Tween: Tween,                        -- current bullet tween (visual)
	IsActive: boolean,                   -- if false, tower stops updating/attacking
}, TowerClass))

--[[
	Calculates distance between tower and enemy using their PrimaryParts.
	This is used for range checks and target sorting.
]]
local function CalculateDistance(Tower: Model, Enemy: Model): number
	assert(Tower.PrimaryPart, "Tower does not posses a primary part")
	assert(Enemy.PrimaryPart, "Enemy does not posses a primary part")

	return (Enemy.PrimaryPart.Position - Tower.PrimaryPart.Position).Magnitude
end

--[[
	Checks if an enemy is dead.
	We look for a Humanoid and check if its health is <= 0.
	If no humanoid exists, this returns false (enemy is treated as alive/invalid elsewhere).
]]
local function EnemyIsDead(Enemy: Model): boolean
	local hum = Enemy:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health <= 0
end

--[[
	Returns the unit direction vector from tower to enemy.
	This is used for raycast direction (line-of-sight) and can be reused for projectiles altough not here.
]]
local function CalculateDirection(Tower: Model, Enemy: Model): Vector3
	assert(Tower.PrimaryPart, "Tower does not posses a primary part")
	assert(Enemy.PrimaryPart, "Enemy does not posses a primary part")

	return (Enemy.PrimaryPart.Position - Tower.PrimaryPart.Position).Unit
end

--[[
	Line-of-sight check between tower and enemy.
	We raycast from the tower's PrimaryPart toward the enemy depending on the range.
	FilterType = Include with {Enemy} means we only "care" about hits on the enemy model.

	If nothing is hit, or we hit something inside the enemy, we consider LOS true.
]]
local function HasLineOfSight(Tower: Model, Enemy: Model, range: number): boolean | any
	local Start = Tower.PrimaryPart
	local End = Enemy.PrimaryPart
	if not Start or not End then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { Tower }

	local dir = CalculateDirection(Tower, Enemy)
	local ray = workspace:Raycast(Start.Position, dir * range, params)

	return ray == nil or ray.Instance:IsDescendantOf(Enemy)
end

--[[
	Constructor.
	We clone the provided model so each tower instance has its own copy.
	
]]
function TowerClass.new(Model: Model, configs: Configs)
	local self = setmetatable({
		Target = nil,                  -- no target at the start
		Range = configs.Range,
		Damage = configs.Damage,
		Price = configs.Price,
		Owner = configs.Owner,

		LastAttack = 0,                -- reserved 
		Model = Model:Clone(),

		func = nil,                    -- heartbeat connection will be set on Spawn
		Cooldown = 0,                  -- can shoot immediately

		ProjectileFunc = nil,          -- reserved for future (e.g., projectile update)
		Speed = configs.Speed or 100,  -- visual bullet speed default

		IsActive = true,               -- tower starts enabled
	}, TowerClass)

	return self
end

--[[
	Spawns the tower into the world.
	Starts a Heartbeat update loop that drives targeting, aiming, and attacking.
]]
function TowerClass.Spawn(self: TowerClass, SpawnCFrame: CFrame)
	self.Model:PivotTo(SpawnCFrame)
	self.Model.Parent = workspace

	-- Throttle target searching so we don't sort/scan every frame.
	self.LastSearchForTarget = tick()

	-- Heartbeat runs each frame on the server; we use dt for cooldown timing.
	self.func = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)
end

--[[
	Main update loop.
	- If inactive: do nothing.
	- If no target: occasionally search for one (every 0.2s).
	- If target exists: tick cooldown, attack when ready, and aim smoothly.
]]
function TowerClass.Update(self: TowerClass, dt: number)
	if not self.IsActive then
		return
	end

	-- Acquire target if we don't currently have one.
	if not self.Target then
		if tick() - self.LastSearchForTarget >= 0.2 then
			self.LastSearchForTarget = tick()
			self:SearchForTarget()
		end
		return
	end

	-- If we have a target, make sure it's still valid.
	if self.Target and self:ValidateTarget() then
		-- Cooldown timer controls fire rate.
		if self.Cooldown > 0 then
			self.Cooldown -= dt
		else
			self.Cooldown = 0.5 -- fire rate (seconds between shots)
			self:Attack()
		end

		-- Smoothly rotate toward the target each frame.
		self:AimAt(dt)
	end
end

--[[
	Performs an attack on the current target.
	
	- Visual bullet tween is spawned via PlayAnim().
	- If enemy dies, it is destroyed and target resets.
]]
function TowerClass.Attack(self: TowerClass)
	if not self:ValidateTarget() then --Validating the target
		return
	end

	-- Direction is currently unused, but it's useful if you later add ballistic projectiles.
	local Direction = CalculateDirection(self.Model, self.Target)
	_ = Direction

	-- We require a Humanoid for damage.
	local TargetHum = assert(self.Target:FindFirstChildOfClass("Humanoid"), "Enemy Humanoid does not exist")

	-- Damage falloff is based on distance.
	local CalculateDamage = self:CalculateDamage()

	-- Visual bullet
	self:PlayAnim()

	-- Apply damage
	TargetHum.Health -= CalculateDamage

	-- Clean up dead enemies.
	if EnemyIsDead(self.Target) then
		self.Target:Destroy()
		self.Target = nil
	end
end

--[[
	Searches for a target from workspace.Enemies.
	We build a list of enemies within range (and with line-of-sight),
	then sort by closest distance, and pick the closest.
]]
function TowerClass.SearchForTarget(self: TowerClass)
	local CurrentEnemies = workspace.Enemies:GetChildren()
	local EnemiesInRange: { Model } = {}

	-- Iterate array returned by GetChildren()
	for _, Enemy in ipairs(CurrentEnemies) do
		if Enemy:IsA("Model") then
			local Distance = CalculateDistance(self.Model, Enemy)

			-- Range check + FoV check before accepting this enemy as a valid candidate.
			if Distance <= self.Range and HasLineOfSight(self.Model, Enemy, self.Range) then
				table.insert(EnemiesInRange, Enemy)
			end
		end
	end

	-- If nothing in range, bail out.
	if #EnemiesInRange == 0 then
		return
	end

	-- Sort by closest distance so EnemiesInRange[1] becomes the closest.
	table.sort(EnemiesInRange, function(a: Model, b: Model)
		return CalculateDistance(self.Model, a) < CalculateDistance(self.Model, b)
	end)

	self.Target = EnemiesInRange[1]
end

--[[
	Validates the current target.
	This prevents errors if the target gets destroyed, loses its PrimaryPart,
	or walks out of range.
]]
function TowerClass.ValidateTarget(self: TowerClass)
	if not self.Target or not self.Target.Parent then
		self.Target = nil
		return false
	end

	if not self.Target.PrimaryPart then
		self.Target = nil
		return false
	end

	-- If the enemy walks out of range, drop target and rescan later.
	if CalculateDistance(self.Model, self.Target) > self.Range then
		self.Target = nil
		return false
	end

	return true
end

--[[
	Spawns a purely visual bullet that tweens from tower "Spawn" part to target.
	No hit detection is done here because damage is applied instantly in Attack().
]]
function TowerClass.PlayAnim(self: TowerClass)
	if not self:ValidateTarget() then
		return
	end

	-- "Spawn" is used as the bullet origin.
	local BulletSpawn: Part = self.Model:FindFirstChild("Spawn")
	local TargetPrim = self.Target.PrimaryPart
	if not BulletSpawn or not TargetPrim then
		return
	end

	local Goal = { Position = TargetPrim.Position }
	local Distance = CalculateDistance(self.Model, self.Target)

	-- Travel time depends on distance and configured bullet speed.
	local TravelTime = math.clamp(Distance / self.Speed, 0.2, 1.5)
	local TI = TweenInfo.new(TravelTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

	-- We parent into workspace.Ignore so visuals are easy to manage/ignore in raycasts.
	local Bullet = Instance.new("Part", workspace.Ignore)
	Bullet.CanCollide = false
	Bullet.Anchored = true
	Bullet.Massless = true
	Bullet.Position = BulletSpawn.Position
	Bullet.Material = Enum.Material.Neon
	Bullet.Color = Color3.new(1, 0, 0)
	Bullet.Size = Vector3.new(2, 2, 2)

	self.Tween = TweenService:Create(Bullet, TI, Goal)
	self.Tween:Play()

	-- Destroy the bullet when the tween finishes.
	self.Tween.Completed:Connect(function()
		Bullet:Destroy()
	end)

	-- Safety cleanup in case something interrupts the tween.
	Debris:AddItem(Bullet, Distance / 2.5)
end

--[[
	Smoothly rotates the tower PrimaryPart to face the target.
	Lerp keeps turning smooth instead of snapping instantly.
]]
function TowerClass.AimAt(self: TowerClass, dt: number)
	local head = self.Model.PrimaryPart
	if not head or not self:ValidateTarget() then
		return
	end

	local headpos: Vector3 = head.Position
	local targetpos: Vector3 = self.Target.PrimaryPart.Position

	local desired = CFrame.lookAt(headpos, Vector3.new(targetpos.X, targetpos.Y, targetpos.Z))--the desired angle it should lerp to
	head.CFrame = head.CFrame:Lerp(desired, math.clamp(dt * 8, 0, 1)) --lerping the rotation
end

--[[
	Damage falloff based on distance to the target.
	At max range, damage is reduced by up to 30%.
]]
function TowerClass.CalculateDamage(self: TowerClass): number
	if not self:ValidateTarget() then
		return self.Damage
	end

	local Distance = CalculateDistance(self.Model, self.Target)
	local alpha = math.clamp(Distance / self.Range, 0, 1)
	local mult = 1 - 0.3 * alpha

	return math.round(self.Damage * mult)
end

--[[
	Cleans up tower resources:
	- Disconnects Heartbeat loop
	- Destroys tower model
	- Stops/destroys any active bullet tween
]]
function TowerClass.CleanUp(self: TowerClass)
	if self.func then
		self.func:Disconnect()
	end

	if self.Model then
		self.Model:Destroy()
	end

	if self.Tween then
		self.Tween:Pause()
		self.Tween:Destroy()
	end
end

--[[
	Enable tower updates/attacks.
]]
function TowerClass.Activate(self: TowerClass)
	self.IsActive = true
end

--[[
	Disable tower updates/attacks.
]]
function TowerClass.Disable(self: TowerClass)
	self.IsActive = false
end

return TowerClass



