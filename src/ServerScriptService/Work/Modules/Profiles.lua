local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local ProfileStore = require(ServerScriptService.Dependencies.ProfileStore)

local PROFILE_TEMPLATE = {
   version = 1,
   placement = {
      version = 2,
      objects = {},
      zones = {
         version = 1,
         unlocked = {},
      },
   },
   Inventory = {
      version = 1,
      placementItems = {},
   },
   Offline = {
      lastTimestamp = 0,
      pendingBase = 0,
      pendingRaw = 0,
      hasGamepass = false,
   },
   BrainrotProgress = {
      version = 3,
      score = 0,
      defeated = {},
      defeatedIndex = {},
      highestTier = 0,
      lastBoss = "",
      currentWave = 1,
   },
   Money = 10000000,
}

local PlayerStore = ProfileStore.New("PlayerStore28", PROFILE_TEMPLATE)

export type Profile = {
   Data: any,
   AddUserId: (self: Profile, userId: number) -> (),
   Reconcile: (self: Profile) -> (),
   Save: (self: Profile) -> (),
   EndSession: (self: Profile) -> (),
   OnSessionEnd: RBXScriptSignal,
}

local Profiles: { [Player]: Profile } = {}

local ProfileManager = {}
ProfileManager.ProfileLoaded = Signal.new()
ProfileManager.ProfileReleased = Signal.new()

local function releaseProfile(player: Player, reason: string?)
   local profile = Profiles[player]
   if not profile then
      return
   end

   Profiles[player] = nil
   ProfileManager.ProfileReleased:Fire(player, profile, reason)
   profile:EndSession()
end

local function onSessionEnd(player: Player)
   Profiles[player] = nil
   ProfileManager.ProfileReleased:Fire(player, nil, "SessionEnded")
   if player.Parent == Players then
      player:Kick("Profile session ended. Please rejoin.")
   end
end

local function playerAdded(player: Player)
   local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
      Cancel = function()
         return player.Parent ~= Players
      end,
   })

   if not profile then
      player:Kick("Profile load failed. Please rejoin.")
      return
   end

   profile:AddUserId(player.UserId)
   profile:Reconcile()

   profile.OnSessionEnd:Connect(function()
      onSessionEnd(player)
   end)

   if player.Parent ~= Players then
      profile:EndSession()
      return
   end

   Profiles[player] = profile
   print(profile.Data)
   ProfileManager.ProfileLoaded:Fire(player, profile)
end

function ProfileManager.GetProfile(player: Player): Profile?
   return Profiles[player]
end

function ProfileManager.GetProfileData(player: Player)
   local profile = Profiles[player]
   return profile and profile.Data or nil
end

function ProfileManager.WithProfile(player: Player, handler)
   local profile = Profiles[player]
   if not profile then
      return nil
   end

   return handler(profile)
end

function ProfileManager.Mutate(player: Player, callback)
   local profile = Profiles[player]
   if not profile then
      return nil
   end

   local result = callback(profile.Data)
   return result
end

function ProfileManager.Release(player: Player, reason: string?)
   releaseProfile(player, reason)
end

local function onPlayerRemoving(player: Player)
   ProfileManager.Release(player, "PlayerRemoving")
end

for _, player in Players:GetPlayers() do
   task.spawn(playerAdded, player)
end

Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

game:BindToClose(function()
   for player, profile in Profiles do
      Profiles[player] = nil
      profile:Save()
      profile:EndSession()
   end
end)

return ProfileManager