--!strict
local TowerClass = {}
TowerClass.__index = TowerClass
local RunService = game:GetService("RunService")
local RP = game:GetService("ReplicatedStorage")
local Networker = require(RP.Packages.Networker).server
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

type Configs = {
	Range: number,
	Damage: number,
	Price: number,
	Owner: Player,
	Speed: number,
	
	
	
	
}

export type TowerClass = typeof(setmetatable({} :: {
	Target: Model |any,
	Range: number,
	Damage: number,
	Cooldown: number,
	Price: number,
	Owner: Player,
	LastAttack: number,
	Model:Model | any,
	Speed:number,
	func:RBXScriptConnection,
	LastSearchForTarget:number,
	Tween:Tween,
	IsActive:boolean,
	
},TowerClass))



local function CalculateDistance(Tower:Model,Enemy:Model): number
	assert(Tower.PrimaryPart,"Tower does not posses a primary part")
	assert(Enemy.PrimaryPart,"Enemy does not posses a primary part")
	
	return (Enemy.PrimaryPart.Position - Tower.PrimaryPart.Position).Magnitude
	
	
end

local function EnemyIsDead(Enemy:Model):boolean | any
	local hum = Enemy:FindFirstChildOfClass("Humanoid")
	
	
	return hum ~= nil and hum.Health <= 0
	
end

local function CalculateDirection(Tower:Model,Enemy:Model) : Vector3 
	assert(Tower.PrimaryPart,"Tower does not posses a primary part")
	assert(Enemy.PrimaryPart,"Enemy does not posses a primary part")
	
	return (Enemy.PrimaryPart.Position - Tower.PrimaryPart.Position).Unit
	
	
end

local function HasLineOfSight(Tower:Model,Enemy:Model,range:number):boolean|any
	local Start = Tower.PrimaryPart
	local End = Enemy.PrimaryPart
	if not Start or not End then return end 
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {Enemy}
	
	local dir = CalculateDirection(Tower,Enemy)
	local ray = workspace:Raycast(Start.Position,dir * range,params)
	
	return ray == nil or ray.Instance:IsDescendantOf(Enemy)
	
	
end

function TowerClass.new(Model:Model,configs:Configs)
	local self = setmetatable({
		Target = nil,
		Range = configs.Range,
		Damage = configs.Damage,
		Price = configs.Price,
		Owner = configs.Owner,
		LastAttack = 0,
		Model = Model:Clone(),
		func = nil,
		Cooldown = 0,		
		ProjectileFunc = nil,
		Speed = configs.Speed or 100,
		IsActive = true,
	},TowerClass)
	
		
	return self	
	
	
end

function TowerClass.Spawn(self:TowerClass,SpawnCFrame:CFrame)
	self.Model:PivotTo(SpawnCFrame)
	self.Model.Parent = workspace
	self.LastSearchForTarget = tick()
	self.func = RunService.Heartbeat:Connect(function(dt)
		self:Update(dt)
	end)
	
	
end

function TowerClass.Update(self:TowerClass,dt:number)
	if not self.IsActive then return end
	if not self.Target then
		if tick() - self.LastSearchForTarget >= .2 then
			self.LastSearchForTarget = tick()
			self:SearchForTarget()
			
		end
		
		
		return
			
	elseif self.Target and self:ValidateTarget() then
		
		if self.Cooldown > 0 then
			self.Cooldown -= dt
			
			
		else
			self.Cooldown = .5
			self:Attack()
			
		end
		self:AimAt(dt)
		
	end	
		
	
	
end

function TowerClass.Attack(self:TowerClass)
	if not self:ValidateTarget() then return end 
	
	local Direction = CalculateDirection(self.Model,self.Target)
	local TargetHum = assert(self.Target:FindFirstChildOfClass("Humanoid"),"Enemy Humanoid does not exist")
	local CalculateDamage = self:CalculateDamage()
	
	self:PlayAnim()
	
	
	TargetHum.Health -= CalculateDamage
	
	
	if EnemyIsDead(self.Target) then
		self.Target:Destroy()
		self.Target = nil
	end
end



function TowerClass.SearchForTarget(self:TowerClass)
	local CurrentEnemies = workspace.Enemies:GetChildren()
	local EnemiesInRange: {Model} = {}
	
	for i, Enemy in ipairs(CurrentEnemies) do
		if Enemy:IsA("Model") then
			local Distance = CalculateDistance(self.Model,Enemy)
			if Distance <= self.Range and HasLineOfSight(self.Model,Enemy,self.Range) then
				table.insert(EnemiesInRange,Enemy)
				
			end
			
		end
		
	end
	
	if #EnemiesInRange > 0 then
		
		table.sort(EnemiesInRange,function(a:Model,b:Model)
			return CalculateDistance(self.Model,a) < CalculateDistance(self.Model,b)
		end)
		
	else
		return	
	end		
	
	self.Target = EnemiesInRange[1]	
	
end

function TowerClass.ValidateTarget(self:TowerClass)
	if not self.Target or not self.Target.Parent then
		self.Target = nil
		return false
	end
	if not self.Target.PrimaryPart then
		self.Target = nil
		return false
		
	end
	
	if CalculateDistance(self.Model,self.Target) > self.Range then
		self.Target = nil
		return false
	end
	return true
end

function TowerClass.PlayAnim(self:TowerClass)
	if not self:ValidateTarget() then return end 
	local BulletSpawn:Part = self.Model:FindFirstChild("Spawn")
	local TargetPrim =  self.Target.PrimaryPart
	if not BulletSpawn or not TargetPrim then return end 
	
	local Goal = {Position = TargetPrim.Position}
	local Distance = CalculateDistance(self.Model,self.Target)
	local TravelTime = math.clamp(Distance / self.Speed, .2,1.5)
	local TI = TweenInfo.new(TravelTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	
	local Bullet = Instance.new("Part",workspace.Ignore)
	Bullet.CanCollide = false
	Bullet.Anchored = true
	Bullet.Massless = true
	Bullet.Position = BulletSpawn.Position
	Bullet.Material = Enum.Material.Neon
	Bullet.Color = Color3.new(1, 0, 0)
	Bullet.Size = Vector3.new(2,2,2)
	
	self.Tween = TweenService:Create(Bullet,TI,Goal)
	self.Tween:Play()
	self.Tween.Completed:Connect(function()
		Bullet:Destroy()
	end)
	
	Debris:AddItem(Bullet,Distance/ 2.5)
	
end

function TowerClass.AimAt(self:TowerClass,dt:number)
	local head = self.Model.PrimaryPart
	if not head or not self:ValidateTarget() then return end 
	
	local headpos:Vector3 = head.Position
	local targetpos:Vector3 = self.Target.PrimaryPart.Position
	
	local desired = CFrame.lookAt(headpos, Vector3.new(targetpos.X,targetpos.Y,targetpos.Z))
	head.CFrame = head.CFrame:Lerp(desired,math.clamp(dt * 8,0,1))
	
end

function TowerClass.CalculateDamage(self:TowerClass): number
	if not self:ValidateTarget() then return self.Damage end
	
	local Distance = CalculateDistance(self.Model,self.Target)
	local alpha = math.clamp(Distance / self.Range, 0, 1)
	local mult = 1 - 0.3 * alpha
	
	return math.round(self.Damage * mult)
	
	
	
end

function TowerClass.CleanUp(self:TowerClass)
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

function TowerClass.Activate(self:TowerClass)
	self.IsActive = true	
	
end

function TowerClass.Disable(self:TowerClass)
	self.IsActive = false
	
end

return TowerClass
