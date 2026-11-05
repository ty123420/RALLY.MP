-- ============================================================================
-- RallyMP — BeamNG v0.40+ Pause Menu Rally Selector, Cross-Map & 2P Sync
-- Place at: BeamMP-Server/Resources/Server/RallyMP/main.lua
--
-- KEY CAPABILITIES:
--   • Zero ServerConfig.toml Map Editing: Dynamically updates MP.Set(MP.Settings.Map)
--     and transitions both players across ANY official or modded BeamNG map.
--   • Live CEF MainGEUI Pause Menu Tab + Vue 3 SFCs: Press ESC -> click "Rally Mode"
--     at the top of the Pause Menu (or type /rally in chat anytime).
--   • Partner Ready-Check State Machine: Either player proposes a Rally Loop,
--     Rally Stage, or Freeroam Map; partner confirms Ready (solo auto-approves).
--   • Per-Launch Vehicle Mode: Proposer chooses "own_mp_car" (synced BeamMP car
--     carried across maps) or "stage_preset_car" (official NGRC/Stage rally car).
--   • Full Native Rally Sync: 2-Car (+4.8m Service Bay) & Shared Co-Driver,
--     1-Car-Per-Driver Prop Isolation, Instant 3D Partner Spawns (Zero Orange Blobs),
--     Always-Solid Collisions, WRC +60s vs Simultaneous Clock, & NGRC Leaderboard.
-- ============================================================================

local CONFIG = {
  commandPrefix = "/rally",
  pauseMenuRallyTabOnly = true,
  enableDynamicCrossMapSync = true,
  freeroamMingleOnNewMap = false,
  unlockAllGameMapsCatalog = true,
  unlockNativeRallyFeatures = true,
  defaultVehicleChoice = "host_chooses", -- "host_chooses" | "own_mp_car" | "stage_preset_car"
  requirePartnerReadyCheck = true,
  readyCheckTimeoutSec = 30,
  supportBothParticipationModes = true,
  defaultParticipationMode = "two_car", -- "two_car" | "codriver"
  codriverMuteAiVoicepack = true,
  codriverClickToCallVoice = true,
  codriverHideDriverNotes = true,
  codriverDespawnExtraCarAndLockCam = true,
  codriverWritableTrackNotes = true,
  defaultRoadbookStyle = "grassroots_notepad", -- "digital_roadbook" | "grassroots_notepad"
  defaultCodriverPersonality = "pro_descriptive",
  roadbookNotesPerPage = 5,
  allowRallyLoop = true,
  allowRallyStage = true,
  toggleableLaunchMode = true,
  defaultLaunchMode = "wrc_staggered", -- "wrc_staggered" | "simultaneous_ghost"
  staggerSlotSeconds = 60,
  clockSkipPolicy = "consensus_both", -- "consensus_both" | "host_authority" | "independent_slot"
  enableRttClockSync = true,
  strictSingleVehicleSync = true,
  immediatePartnerSpawnFlush = true,
  collisionPolicy = "always_solid", -- "always_solid" | "ghost_launch_only" | "always_ghost"
  enableFalseStartPenalty = true,
  ngrcHardcoreRepairOff = false,
  injectEndScreenLeaderboard = true
}

local function encodeJson(tbl)
  if Util and Util.JsonEncode then
    return Util.JsonEncode(tbl)
  end
  local function ser(val)
    local t = type(val)
    if t == "number" then return tostring(val)
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "string" then
      return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "table" then
      local isArr = (#val > 0)
      local parts = {}
      if isArr then
        for i = 1, #val do parts[#parts + 1] = ser(val[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        for k, v in pairs(val) do
          parts[#parts + 1] = '"' .. tostring(k) .. '":' .. ser(v)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    end
    return "null"
  end
  return ser(tbl)
end

local function decodeJson(raw)
  if type(raw) ~= "string" or raw == "" then return {} end
  if Util and Util.JsonDecode then
    local ok, res = pcall(Util.JsonDecode, raw)
    if ok and type(res) == "table" then return res end
  end
  -- Pure-Lua fallback JSON object/array parser so server never fails if Util.JsonDecode is absent
  local pos = 1
  local len = #raw
  local function skipWs()
    while pos <= len do
      local c = raw:sub(pos, pos)
      if c == " " or c == "\t" or c == "\r" or c == "\n" then pos = pos + 1 else break end
    end
  end
  local parseVal
  local function parseStr()
    pos = pos + 1 -- skip opening "
    local out = {}
    while pos <= len do
      local c = raw:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(out)
      elseif c == "\\" then
        pos = pos + 1
        local esc = raw:sub(pos, pos)
        if esc == "n" then out[#out + 1] = "\n"
        elseif esc == "r" then out[#out + 1] = "\r"
        elseif esc == "t" then out[#out + 1] = "\t"
        else out[#out + 1] = esc end
        pos = pos + 1
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  local function parseObj()
    pos = pos + 1
    local obj = {}
    skipWs()
    if raw:sub(pos, pos) == "}" then pos = pos + 1; return obj end
    while pos <= len do
      skipWs()
      if raw:sub(pos, pos) ~= '"' then break end
      local k = parseStr()
      skipWs()
      if raw:sub(pos, pos) == ":" then pos = pos + 1 end
      skipWs()
      obj[k] = parseVal()
      skipWs()
      local sep = raw:sub(pos, pos)
      if sep == "," then pos = pos + 1
      elseif sep == "}" then pos = pos + 1; break
      else break end
    end
    return obj
  end
  local function parseArr()
    pos = pos + 1
    local arr = {}
    skipWs()
    if raw:sub(pos, pos) == "]" then pos = pos + 1; return arr end
    while pos <= len do
      skipWs()
      arr[#arr + 1] = parseVal()
      skipWs()
      local sep = raw:sub(pos, pos)
      if sep == "," then pos = pos + 1
      elseif sep == "]" then pos = pos + 1; break
      else break end
    end
    return arr
  end
  parseVal = function()
    skipWs()
    local c = raw:sub(pos, pos)
    if c == '"' then return parseStr()
    elseif c == "{" then return parseObj()
    elseif c == "[" then return parseArr()
    elseif raw:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif raw:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif raw:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local numStr = raw:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if numStr and #numStr > 0 then
        pos = pos + #numStr
        return tonumber(numStr)
      end
      pos = pos + 1
      return nil
    end
  end
  local okP, parsed = pcall(parseVal)
  if okP and type(parsed) == "table" then return parsed end
  return {}
end

local function nowMs()
  return math.floor(os.clock() * 1000)
end

local function nowEpochSec()
  return os.time()
end

local function extractLevelFromMapPath(mapPath)
  if type(mapPath) ~= "string" or mapPath == "" then return "" end
  local m = mapPath:lower():match("/levels/([^/]+)/")
  return m or ""
end

local SESSION = {
  status = "FREEROAM", -- "FREEROAM" | "FREEROAM_STAGED" | "READY_CHECK" | "MAP_SWITCHING" | "START_SCREEN" | "LOOP_ACTIVE" | "STAGE_STAGING" | "STAGE_ACTIVE" | "RECCE_ACTIVE"
  currentLevel = "",
  participationMode = CONFIG.defaultParticipationMode,
  launchMode = CONFIG.defaultLaunchMode,
  lastVehicleMode = (CONFIG.defaultVehicleChoice == "stage_preset_car") and "stage_preset_car" or "own_mp_car",
  recceEnabled = false,
  activeMissionId = nil,
  activeMissionDir = nil,
  activeMissionName = nil,
  activeMissionType = nil,
  stagedMission = nil,        -- Staged rally mission held in Freeroam Mingle on newly loaded maps
  pendingCrewRequest = nil,   -- Pre-event Co-Pilot & Driver pairing request
  pendingProposal = nil,      -- Active Partner Ready-Check proposal
  pendingMissionLaunch = nil, -- Queued mission when auto-switching maps first
  levelReadyPlayers = {},     -- [playerId] = levelName
  activeVehicleByPlayer = {}, -- [playerId] = authoritative single vehId
  participants = {},          -- [1] = Slot 1, [2] = Slot 2
  rttMs = {},
  stagedAtSS = {},
  skipVotes = {},
  endedPlayers = {},          -- [playerId] = true once that player's native mission has stopped
  activeUserSettings = nil,
  activeProposerId = nil,
  activeProposerName = nil,
  allMaps = {},
  globalMissions = {},
  splits = {},
  standings = {},
  trackNotes = {}             -- [sanitizedTrackKey] = { trackKey, notes = {...}, updatedBy }
}

local function sanitizeTrackKey(rawKey)
  local s = tostring(rawKey or "default_track"):lower():gsub("[^a-z0-9_%-]", "_")
  if s == "" then s = "default_track" end
  return s:sub(1, 96)
end

local function getServerTrackNotesPath(trackKey)
  return "Resources/Server/RallyMP/pacenotes_" .. sanitizeTrackKey(trackKey) .. ".json"
end

local function loadServerTrackNotes(trackKey)
  local sKey = sanitizeTrackKey(trackKey)
  if SESSION.trackNotes[sKey] ~= nil then
    if SESSION.trackNotes[sKey] == false then return nil end
    return SESSION.trackNotes[sKey]
  end
  if io and type(io.open) == "function" then
    local okF, f = pcall(io.open, getServerTrackNotesPath(sKey), "r")
    if okF and f then
      local raw = f:read("*a")
      f:close()
      local parsed = decodeJson(raw)
      if type(parsed) == "table" then
        if parsed.reset == true then
          SESSION.trackNotes[sKey] = false
          return nil
        elseif type(parsed.notes) == "table" and #parsed.notes > 0 then
          SESSION.trackNotes[sKey] = parsed
          return parsed
        end
      end
    end
  end
  return nil
end

local function saveServerTrackNotes(trackKey, recordOrNil)
  local sKey = sanitizeTrackKey(trackKey)
  if not recordOrNil then
    SESSION.trackNotes[sKey] = false
    if io and type(io.open) == "function" then
      local okF, f = pcall(io.open, getServerTrackNotesPath(sKey), "w")
      if okF and f then
        f:write('{"reset":true}')
        f:close()
      end
    end
    return
  end
  SESSION.trackNotes[sKey] = recordOrNil
  if io and type(io.open) == "function" then
    local okF, f = pcall(io.open, getServerTrackNotesPath(sKey), "w")
    if okF and f then
      f:write(encodeJson(recordOrNil))
      f:close()
    end
  end
end

-- Walking avatars (unicycle) must NEVER become the "active rally car" nor trigger pruning of the player's real car
local function isUnicyclePayload(rawData)
  if type(rawData) ~= "string" or rawData == "" then return false end
  local lower = rawData:lower()
  return (lower:find('"jbm":"unicycle"', 1, true) or lower:find('"jbeam":"unicycle"', 1, true)
    or lower:find('"unicycle"', 1, true) or lower:find('unicycle.pc', 1, true)) and true or false
end

local function despawnPlayerAllServerVehicles(playerId)
  if not playerId or not MP or not MP.GetPlayerVehicles then return end
  local vehs = MP.GetPlayerVehicles(playerId)
  if type(vehs) == "table" then
    for vid, vdata in pairs(vehs) do
      if MP.RemoveVehicle and not isUnicyclePayload(vdata) then
        local ok = pcall(MP.RemoveVehicle, playerId, vid)
        if not ok and tonumber(vid) then
          pcall(MP.RemoveVehicle, playerId, tonumber(vid))
        end
      end
    end
  end
  SESSION.activeVehicleByPlayer[playerId] = nil
end

local function resolveAllowedVehicleMode(requested)
  if CONFIG.defaultVehicleChoice == "own_mp_car" then
    return "own_mp_car"
  elseif CONFIG.defaultVehicleChoice == "stage_preset_car" then
    return "stage_preset_car"
  end
  return (requested == "stage_preset_car") and "stage_preset_car" or "own_mp_car"
end

local function isServerPropOrAvatarPayload(rawData)
  if not CONFIG.strictSingleVehicleSync or type(rawData) ~= "string" or rawData == "" then
    return false
  end
  local lower = rawData:lower()
  if lower:find("simple_traffic", 1, true) or lower:find("van_ambulance_parked", 1, true) or lower:find("_parked.pc", 1, true) then
    return true
  end

  return false
end

local function prunePlayerExtraVehicles(playerId, keepVehId)
  if not CONFIG.strictSingleVehicleSync or keepVehId == nil then return end
  local vehicles = MP.GetPlayerVehicles and MP.GetPlayerVehicles(playerId) or nil
  if type(vehicles) ~= "table" then return end
  local keepStr = tostring(keepVehId)
  for vid, vdata in pairs(vehicles) do
    if tostring(vid) ~= keepStr and not isUnicyclePayload(vdata) then
      if MP.RemoveVehicle then
        local ok = pcall(MP.RemoveVehicle, playerId, vid)
        if not ok and tonumber(vid) then
          pcall(MP.RemoveVehicle, playerId, tonumber(vid))
        end
      end
    end
  end
end

local function getPrimaryServerVehId(playerId)
  local vehicles = MP.GetPlayerVehicles(playerId)
  if not vehicles then return "" end
  local preferred = SESSION.activeVehicleByPlayer[playerId]
  if preferred ~= nil then
    if vehicles[preferred] ~= nil or vehicles[tostring(preferred)] ~= nil or (tonumber(preferred) and vehicles[tonumber(preferred)] ~= nil) then
      return tostring(playerId) .. "-" .. tostring(preferred)
    end
  end
  local bestVid = nil
  local bestNum = -1
  for vehId, vehData in pairs(vehicles) do
    if not isServerPropOrAvatarPayload(vehData) then
      local n = tonumber(vehId) or 0
      if bestVid == nil or n >= bestNum then
        bestVid = vehId
        bestNum = n
      end
    end
  end
  if bestVid ~= nil then
    return tostring(playerId) .. "-" .. tostring(bestVid)
  end
  return ""
end

local function broadcastCrew(eventName, tbl)
  local encoded = encodeJson(tbl)
  for _, pid in ipairs(SESSION.participants) do
    MP.TriggerClientEvent(pid, eventName, encoded)
  end
end

local function pruneDisconnectedParticipants()
  if not MP or type(MP.GetPlayers) ~= "function" then return end
  local ok, connected = pcall(MP.GetPlayers)
  if not ok or type(connected) ~= "table" then return end

  local connectedByNum = {}
  local sortedConnectedPids = {}
  for k, name in pairs(connected) do
    local numK = tonumber(k)
    if numK ~= nil and name ~= nil then
      connectedByNum[numK] = true
      sortedConnectedPids[#sortedConnectedPids + 1] = numK
    end
  end
  table.sort(sortedConnectedPids)

  local alive = {}
  local seen = {}
  for _, pid in ipairs(SESSION.participants) do
    local numPid = tonumber(pid) or pid
    if connectedByNum[numPid] or connected[pid] ~= nil or connected[tostring(pid)] ~= nil then
      if not seen[numPid] then
        seen[numPid] = true
        alive[#alive + 1] = numPid
      end
    else
      SESSION.stagedAtSS[pid] = nil
      SESSION.skipVotes[pid] = nil
      SESSION.levelReadyPlayers[pid] = nil
      SESSION.activeVehicleByPlayer[pid] = nil
    end
  end

  -- Auto-enroll up to 2 connected players so SESSION.participants stays complete across plugin reloads
  for _, numPid in ipairs(sortedConnectedPids) do
    if #alive >= 2 then break end
    if not seen[numPid] then
      seen[numPid] = true
      alive[#alive + 1] = numPid
    end
  end

  SESSION.participants = alive
end

local function ensureParticipant(playerId)
  local normId = tonumber(playerId) or playerId
  pruneDisconnectedParticipants()
  for _, pid in ipairs(SESSION.participants) do
    if tonumber(pid) == tonumber(normId) then return true end
  end
  if #SESSION.participants >= 2 then return false end
  SESSION.participants[#SESSION.participants + 1] = normId
  return true
end

local syncPeerState

local function getIdleOrStagedStatus()
  if SESSION.stagedMission ~= nil then
    return "FREEROAM_STAGED"
  end
  return "FREEROAM"
end

local function isPlayerAllowedToControlStaged(playerId)
  local staged = SESSION.stagedMission
  if not staged then return false end
  if #SESSION.participants <= 1 then return true end
  if tonumber(staged.proposerId) == tonumber(playerId) then return true end
  local proposerStillConnected = false
  for _, pid in ipairs(SESSION.participants) do
    if tonumber(pid) == tonumber(staged.proposerId) then
      proposerStillConnected = true
      break
    end
  end
  if not proposerStillConnected and SESSION.participants[1] and tonumber(SESSION.participants[1]) == tonumber(playerId) then
    return true
  end
  return false
end

local function checkProposalExpiry(skipBroadcast)
  if SESSION.pendingProposal and nowEpochSec() >= (SESSION.pendingProposal.expiresAtEpoch or 0) then
    local expiredTitle = SESSION.pendingProposal.title or "Rally Proposal"
    SESSION.pendingProposal = nil
    if SESSION.status == "READY_CHECK" then SESSION.status = getIdleOrStagedStatus() end
    MP.SendChatMessage(-1, "[RallyMP] Ready check expired for: " .. tostring(expiredTitle))
    if not skipBroadcast and syncPeerState then
      syncPeerState()
    end
    return true
  end
  return false
end

syncPeerState = function()
  pruneDisconnectedParticipants()
  checkProposalExpiry(true)

  -- Check pending crew request expiry
  if SESSION.pendingCrewRequest and nowEpochSec() >= (SESSION.pendingCrewRequest.expiresAtEpoch or 0) then
    local fromName = SESSION.pendingCrewRequest.fromPlayerName or "Player"
    SESSION.pendingCrewRequest = nil
    MP.SendChatMessage(-1, "[RallyMP] Crew pairing request from " .. tostring(fromName) .. " expired.")
  end
  local peers = {}
  for idx, pid in ipairs(SESSION.participants) do
    local role = (SESSION.participationMode == "codriver" and idx == 2) and "CO-DRIVER" or ("CAR " .. tostring(idx))
    peers[#peers + 1] = {
      slot = idx,
      playerId = tonumber(pid) or pid,
      name = MP.GetPlayerName(pid) or ("Player " .. tostring(pid)),
      role = role,
      staged = SESSION.stagedAtSS[pid] == true,
      skipVoted = SESSION.skipVotes[pid] ~= nil,
      rttMs = SESSION.rttMs[pid] or 0,
      serverVehId = getPrimaryServerVehId(pid)
    }
  end

  local recipients = {}
  local seenRecip = {}
  if MP and type(MP.GetPlayers) == "function" then
    local okP, connected = pcall(MP.GetPlayers)
    if okP and type(connected) == "table" then
      for k, _ in pairs(connected) do
        local pid = tonumber(k) or k
        if not seenRecip[pid] then
          seenRecip[pid] = true
          recipients[#recipients + 1] = pid
        end
      end
    end
  end
  for _, pid in ipairs(SESSION.participants) do
    local normPid = tonumber(pid) or pid
    if not seenRecip[normPid] then
      seenRecip[normPid] = true
      recipients[#recipients + 1] = normPid
    end
  end

  local allConnectedPlayers = {}
  for _, rpid in ipairs(recipients) do
    local rRole = "PADDOCK"
    local rSlot = nil
    if SESSION.participants[1] and tonumber(SESSION.participants[1]) == tonumber(rpid) then
      rRole = "DRIVER_1"
      rSlot = 1
    elseif SESSION.participants[2] and tonumber(SESSION.participants[2]) == tonumber(rpid) then
      rRole = (SESSION.participationMode == "codriver") and "CODRIVER" or "DRIVER_2"
      rSlot = 2
    end
    allConnectedPlayers[#allConnectedPlayers + 1] = {
      playerId = tonumber(rpid) or rpid,
      name = MP.GetPlayerName(rpid) or ("Player " .. tostring(rpid)),
      role = rRole,
      slot = rSlot,
      pingMs = SESSION.rttMs[rpid] or 18,
      isReady = (SESSION.stagedAtSS[rpid] == true) or (rSlot ~= nil),
      serverVehId = getPrimaryServerVehId(rpid)
    }
  end

  local prop = SESSION.pendingProposal
  local staged = SESSION.stagedMission
  for _, targetPid in ipairs(recipients) do
    -- Always serialize boolean false instead of nil when no proposal/staged event is active so JSON never omits keys
    local perPlayerProposal = false
    if prop then
      local isProposer = (tonumber(prop.proposerId) == tonumber(targetPid))
      local remSec = math.max(1, (prop.expiresAtEpoch or (nowEpochSec() + CONFIG.readyCheckTimeoutSec)) - nowEpochSec())
      perPlayerProposal = {
        id = tostring(prop.id),
        actionType = prop.actionType or "mission",
        proposerId = tonumber(prop.proposerId) or prop.proposerId,
        proposerName = prop.proposerName or "Driver",
        isProposer = isProposer,
        canAccept = (not isProposer) or (#SESSION.participants <= 1),
        title = prop.title or "",
        missionId = prop.missionId or "",
        missionType = prop.missionType or "",
        levelName = prop.levelName or "",
        vehicleMode = prop.vehicleMode or "own_mp_car",
        timeoutSec = CONFIG.readyCheckTimeoutSec,
        remainingSec = remSec
      }
    end

    local perPlayerStaged = false
    if staged then
      perPlayerStaged = {
        missionId = staged.missionId or "",
        missionDir = staged.missionDir or "",
        title = staged.missionName or staged.missionId or "",
        missionType = staged.missionType or "rallyLoop",
        levelName = staged.levelName or SESSION.currentLevel or "",
        vehicleMode = staged.vehicleMode or SESSION.lastVehicleMode,
        proposerId = tonumber(staged.proposerId) or staged.proposerId,
        proposerName = staged.proposerName or "Driver",
        isProposer = isPlayerAllowedToControlStaged(targetPid)
      }
    end

    local perPlayerCrewReq = false
    if SESSION.pendingCrewRequest then
      local cReq = SESSION.pendingCrewRequest
      local isFrom = (tonumber(cReq.fromPlayerId) == tonumber(targetPid))
      local isTo = (tonumber(cReq.toPlayerId) == tonumber(targetPid))
      local rem = math.max(1, (cReq.expiresAtEpoch or (nowEpochSec() + 30)) - nowEpochSec())
      perPlayerCrewReq = {
        id = tostring(cReq.id),
        type = cReq.type,
        fromPlayerId = tonumber(cReq.fromPlayerId) or cReq.fromPlayerId,
        fromPlayerName = cReq.fromPlayerName or "Player",
        toPlayerId = tonumber(cReq.toPlayerId) or cReq.toPlayerId,
        toPlayerName = cReq.toPlayerName or "Player",
        targetRole = (cReq.type == "challenge_driver") and "DRIVER_2" or "CODRIVER",
        isSender = isFrom,
        isTarget = isTo,
        remainingSec = rem,
        stageContext = (staged and (staged.missionName or staged.missionId)) or nil
      }
    end

    MP.TriggerClientEvent(targetPid, "NativeRally_PeerState", encodeJson({
      connectedPlayers = allConnectedPlayers,
      pendingCrewRequest = perPlayerCrewReq,
      status = SESSION.status,
      yourPlayerId = tonumber(targetPid) or targetPid,
      currentLevel = SESSION.currentLevel,
      recceEnabled = SESSION.recceEnabled,
      participationMode = SESSION.participationMode,
      launchMode = SESSION.launchMode,
      defaultVehicleChoice = CONFIG.defaultVehicleChoice,
      lastVehicleMode = SESSION.lastVehicleMode,
      requirePartnerReadyCheck = CONFIG.requirePartnerReadyCheck,
      staggerSlotSeconds = CONFIG.staggerSlotSeconds,
      activeMissionId = SESSION.activeMissionId or "",
      activeMissionName = SESSION.activeMissionName or "",
      activeMissionType = SESSION.activeMissionType or "",
      hasStagedMission = (staged ~= nil),
      stagedMission = perPlayerStaged,
      hasPendingProposal = (prop ~= nil),
      pendingProposal = perPlayerProposal,
      peers = peers
    }))
  end
end

local function broadcastPeerStandings()
  local list = {}
  for idx, pid in ipairs(SESSION.participants) do
    local st = SESSION.standings[pid]
    if st then
      list[#list + 1] = {
        slot = idx,
        playerId = pid,
        name = st.name,
        stageTimes = st.stageTimes,
        penaltySec = st.penaltySec,
        totalSec = st.totalSec,
        completed = st.completed
      }
    end
  end
  broadcastCrew("NativeRally_PeerStandings", { competitors = list })
end

local function findMapEntry(levelQuery)
  if not levelQuery or levelQuery == "" then return nil end
  local q = tostring(levelQuery):lower()
  for _, m in ipairs(SESSION.allMaps) do
    if tostring(m.levelName):lower() == q or tostring(m.title):lower():find(q, 1, true) then
      return m
    end
  end
  return {
    levelName = q,
    title = levelQuery,
    mapInfoPath = "/levels/" .. q .. "/info.json",
    misFilePath = "/levels/" .. q .. "/main.level.json"
  }
end

local function launchNativeMissionNow(missionId, missionDir, missionName, missionType, vehicleMode, userSettings)
  if #SESSION.participants == 0 then return end
  local resolvedVehMode = resolveAllowedVehicleMode(vehicleMode)
  SESSION.lastVehicleMode = resolvedVehMode
  SESSION.stagedMission = nil
  SESSION.status = "START_SCREEN"
  SESSION.activeMissionId = missionId
  SESSION.activeMissionDir = missionDir or ("/gameplay/missions/" .. tostring(missionId))
  SESSION.activeMissionName = missionName or missionId
  SESSION.activeMissionType = missionType or "rallyLoop"
  SESSION.stagedAtSS = {}
  SESSION.skipVotes = {}
  SESSION.endedPlayers = {}
  SESSION.activeUserSettings = userSettings or {}
  SESSION.splits = {}
  SESSION.standings = {}

  local driverServerVehId = getPrimaryServerVehId(SESSION.participants[1])

  -- In Shared Co-Driver mode, despawn Slot 2's extra separate vehicle on server & client before seating into Car 1
  if SESSION.participationMode == "codriver" and CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.participants[2] then
    local coPid = SESSION.participants[2]
    despawnPlayerAllServerVehicles(coPid)
    MP.TriggerClientEvent(coPid, "NativeRally_DespawnCoDriverCars", "{}")
  end

  local savedTrackRecord = loadServerTrackNotes(missionId)

  for idx, pid in ipairs(SESSION.participants) do
    SESSION.splits[pid] = {}
    SESSION.standings[pid] = {
      name = MP.GetPlayerName(pid) or ("Player " .. tostring(pid)),
      stageTimes = {},
      penaltySec = 0,
      totalSec = 0,
      completed = false
    }

    local role = (SESSION.participationMode == "codriver" and idx == 2) and "CODRIVER" or "DRIVER"
    local slotOffsetSec = 0
    if SESSION.participationMode == "two_car" and SESSION.launchMode == "wrc_staggered" and idx == 2 then
      slotOffsetSec = CONFIG.staggerSlotSeconds
    end

    MP.TriggerClientEvent(pid, "NativeRally_ExecuteLaunch", encodeJson({
      missionId = missionId,
      missionDir = SESSION.activeMissionDir,
      missionName = SESSION.activeMissionName,
      missionType = SESSION.activeMissionType,
      vehicleMode = resolvedVehMode,
      userSettings = userSettings or {},
      slot = idx,
      role = role,
      participationMode = SESSION.participationMode,
      launchMode = SESSION.launchMode,
      slotOffsetSec = slotOffsetSec,
      enableFalseStarts = CONFIG.enableFalseStartPenalty,
      repairOnRecovery = not CONFIG.ngrcHardcoreRepairOff,
      driverServerVehId = driverServerVehId
    }))

    if role == "CODRIVER" and savedTrackRecord and type(savedTrackRecord.notes) == "table" then
      MP.TriggerClientEvent(pid, "NativeRally_TrackNotesData", encodeJson(savedTrackRecord))
    end
  end

  syncPeerState()
  broadcastPeerStandings()
  local vehLabel = (resolvedVehMode == "stage_preset_car") and "Stage Preset Car" or "Own Synced MP Car"
  print("[RallyMP] Launching mission '" .. tostring(SESSION.activeMissionName) .. "' (" .. vehLabel .. ")")
  MP.SendChatMessage(-1, "[RallyMP] Launching " .. SESSION.activeMissionName .. " (" .. vehLabel .. ")")
end

-- Dynamically switches BeamMP Server + both clients to ANY map without editing ServerConfig.toml
local function switchServerAndClientsMap(targetLevel, mapInfoPath, misFilePath, pendingMission)
  if not CONFIG.enableDynamicCrossMapSync then
    MP.SendChatMessage(-1, "[RallyMP] Dynamic cross-map switching is disabled in config.")
    return
  end

  local cleanLevel = tostring(targetLevel):lower()
  local infoPath = (mapInfoPath and mapInfoPath ~= "") and mapInfoPath or ("/levels/" .. cleanLevel .. "/info.json")

  if MP.Settings and MP.Settings.Map then
    pcall(MP.Set, MP.Settings.Map, infoPath)
  end

  for _, pid in ipairs(SESSION.participants) do
    local vehs = MP.GetPlayerVehicles(pid)
    if vehs then
      for vid, _ in pairs(vehs) do
        if MP.RemoveVehicle then pcall(MP.RemoveVehicle, pid, vid) end
      end
    end
  end

  SESSION.status = "MAP_SWITCHING"
  SESSION.currentLevel = cleanLevel
  SESSION.activeMissionId = nil
  SESSION.levelReadyPlayers = {}
  SESSION.activeVehicleByPlayer = {}
  SESSION.pendingMissionLaunch = pendingMission

  MP.TriggerClientEvent(-1, "NativeRally_SwitchMap", encodeJson({
    levelName = cleanLevel,
    mapInfoPath = infoPath,
    misFilePath = misFilePath or ("/levels/" .. cleanLevel .. "/main.level.json"),
    vehicleMode = pendingMission and pendingMission.vehicleMode or SESSION.lastVehicleMode,
    pendingMissionName = pendingMission and pendingMission.missionName or "",
    pendingMissionId = pendingMission and pendingMission.missionId or "",
    pendingMissionDir = pendingMission and pendingMission.missionDir or "",
    pendingMissionType = pendingMission and pendingMission.missionType or ""
  }))

  syncPeerState()
  if pendingMission then
    print("[RallyMP] Auto-switching map to '" .. cleanLevel .. "' -> queuing " .. tostring(pendingMission.missionName))
    MP.SendChatMessage(-1, "[RallyMP] Auto-switching map to '" .. cleanLevel .. "' -> queuing " .. tostring(pendingMission.missionName) .. "...")
  else
    print("[RallyMP] Switching players to '" .. cleanLevel .. "'")
    MP.SendChatMessage(-1, "[RallyMP] Switching both players to '" .. cleanLevel .. "' (zero ServerConfig.toml edits needed)...")
  end
end

local function executeApprovedProposal(prop)
  if not prop then return end
  if prop.participationMode and CONFIG.supportBothParticipationModes then
    SESSION.participationMode = (prop.participationMode == "codriver") and "codriver" or "two_car"
  end
  if prop.launchMode and CONFIG.toggleableLaunchMode then
    SESSION.launchMode = (prop.launchMode == "simultaneous_ghost") and "simultaneous_ghost" or "wrc_staggered"
  end

  if prop.actionType == "start_staged" then
    local staged = SESSION.stagedMission
    local mId = (staged and staged.missionId) or prop.missionId
    if not mId or mId == "" then return end
    local mDir = (staged and staged.missionDir) or prop.missionDir
    local mName = (staged and staged.missionName) or prop.title or mId
    local mType = (staged and staged.missionType) or prop.missionType or "rallyLoop"
    local uSet = (staged and staged.userSettings) or prop.userSettings or {}
    local vMode = resolveAllowedVehicleMode(prop.vehicleMode or (staged and staged.vehicleMode))
    SESSION.stagedMission = nil
    launchNativeMissionNow(mId, mDir, mName, mType, vMode, uSet)
    return
  end

  if prop.actionType == "map" then
    SESSION.stagedMission = nil
    local mapEntry = findMapEntry(prop.levelName)
    switchServerAndClientsMap(mapEntry.levelName, mapEntry.mapInfoPath, mapEntry.misFilePath, nil)
    return
  end

  local reqLvl = prop.levelName and tostring(prop.levelName):lower() or ""
  if reqLvl == "" and prop.missionId and prop.missionId:find("/") then
    reqLvl = prop.missionId:match("^([^/]+)"):lower()
  end

  if SESSION.currentLevel == "" and MP.Get and MP.Settings and MP.Settings.Map then
    local okM, cfgMap = pcall(MP.Get, MP.Settings.Map)
    if okM and cfgMap then SESSION.currentLevel = extractLevelFromMapPath(cfgMap) end
  end

  local resolvedVehMode = resolveAllowedVehicleMode(prop.vehicleMode)
  if reqLvl ~= "" and reqLvl ~= SESSION.currentLevel and CONFIG.enableDynamicCrossMapSync then
    SESSION.stagedMission = nil
    local mapEntry = findMapEntry(reqLvl)
    switchServerAndClientsMap(reqLvl, mapEntry.mapInfoPath, mapEntry.misFilePath, {
      missionId = prop.missionId,
      missionDir = prop.missionDir,
      missionName = prop.title or prop.missionId,
      missionType = prop.missionType or "rallyLoop",
      levelName = reqLvl,
      vehicleMode = resolvedVehMode,
      userSettings = prop.userSettings or {},
      proposerId = prop.proposerId,
      proposerName = prop.proposerName,
      holdInFreeroam = false
    })
    return
  end

  SESSION.stagedMission = nil
  launchNativeMissionNow(prop.missionId, prop.missionDir, prop.title or prop.missionId, prop.missionType, resolvedVehMode, prop.userSettings)
end

local function createOrExecuteProposal(playerId, prop)
  local normPid = tonumber(playerId) or playerId
  ensureParticipant(normPid)
  prop.proposerId = normPid
  prop.proposerName = MP.GetPlayerName(normPid) or ("Player " .. tostring(normPid))
  prop.vehicleMode = resolveAllowedVehicleMode(prop.vehicleMode)
  prop.id = tostring(nowEpochSec()) .. "_" .. tostring(math.random(1000, 9999))
  prop.expiresAtEpoch = nowEpochSec() + CONFIG.readyCheckTimeoutSec

  if not CONFIG.requirePartnerReadyCheck or #SESSION.participants <= 1 then
    SESSION.pendingProposal = nil
    executeApprovedProposal(prop)
    return
  end

  SESSION.pendingProposal = prop
  SESSION.status = "READY_CHECK"
  syncPeerState()

  local vehDesc = (prop.vehicleMode == "stage_preset_car") and "Stage Preset Car" or "Own MP Car"
  if prop.actionType == "start_staged" then
    MP.SendChatMessage(-1, "[RallyMP] " .. prop.proposerName .. " is ready to START '" .. tostring(prop.title) .. "' (" .. vehDesc .. ")! Partner: click Accept & Ready at top of screen, press Alt+A, or type /accept.")
  else
    MP.SendChatMessage(-1, "[RallyMP] " .. prop.proposerName .. " invited partner to '" .. tostring(prop.title) .. "' (" .. vehDesc .. "). Partner: click Accept & Ready at top of screen, press Alt+A, or type /accept.")
  end
end

local function checkSimultaneousStageRelease()
  if SESSION.launchMode ~= "simultaneous_ghost" then return end
  local needed = (SESSION.participationMode == "codriver") and 1 or #SESSION.participants
  if needed == 0 then return end

  local count = 0
  for idx, pid in ipairs(SESSION.participants) do
    if SESSION.participationMode ~= "codriver" or idx == 1 then
      if SESSION.stagedAtSS[pid] then count = count + 1 end
    end
  end
  if count < needed then return end

  SESSION.stagedAtSS = {}
  SESSION.status = "STAGE_ACTIVE"
  local releaseServerMs = nowMs() + 750

  broadcastCrew("NativeRally_ReleaseSimultaneousCountdown", {
    serverNowMs = nowMs(),
    releaseServerMs = releaseServerMs
  })
  syncPeerState()
end

-- Event Handlers
function onClockProbe(playerId, rawData)
  local req = decodeJson(rawData)
  if req.lastRttMs and tonumber(req.lastRttMs) then
    SESSION.rttMs[playerId] = math.floor(tonumber(req.lastRttMs))
  end
  MP.TriggerClientEvent(playerId, "NativeRally_ClockAck", encodeJson({
    clientSentMs = req.clientSentMs or 0,
    serverNowMs = nowMs()
  }))
end

function onHostCatalog(playerId, rawData)
  local data = decodeJson(rawData)
  if data.currentLevel and data.currentLevel ~= "" and SESSION.status ~= "MAP_SWITCHING" then
    SESSION.currentLevel = tostring(data.currentLevel):lower()
  end
  if type(data.maps) == "table" and #data.maps > 0 then
    SESSION.allMaps = data.maps
  end
  if type(data.missions) == "table" and #data.missions > 0 then
    SESSION.globalMissions = data.missions
  end
  syncPeerState()
end

function onClientLevelReady(playerId, rawData)
  ensureParticipant(playerId)
  local data = decodeJson(rawData)
  local lvl = tostring(data.level or ""):lower()
  if lvl ~= "" then
    SESSION.levelReadyPlayers[playerId] = lvl
    if SESSION.currentLevel == "" or SESSION.status ~= "MAP_SWITCHING" then
      SESSION.currentLevel = lvl
    end
  end

  if SESSION.status == "MAP_SWITCHING" and SESSION.currentLevel ~= "" then
    local readyCount = 0
    for _, pid in ipairs(SESSION.participants) do
      if SESSION.levelReadyPlayers[pid] == SESSION.currentLevel then
        readyCount = readyCount + 1
      end
    end

    if readyCount >= #SESSION.participants then
      local queued = SESSION.pendingMissionLaunch
      SESSION.pendingMissionLaunch = nil
      if queued then
        SESSION.stagedMission = queued
        SESSION.status = "FREEROAM_STAGED"
        syncPeerState()
        local savedTrackRecord = loadServerTrackNotes(queued.missionId)
        broadcastCrew("NativeRally_PreloadStagedNotes", {
          missionId = queued.missionId,
          missionDir = queued.missionDir or ("/gameplay/missions/" .. tostring(queued.missionId)),
          missionName = queued.missionName or queued.missionId,
          missionType = queued.missionType or "rallyLoop",
          levelName = SESSION.currentLevel,
          savedNotes = (savedTrackRecord and type(savedTrackRecord.notes) == "table") and savedTrackRecord.notes or false
        })
        print("[RallyMP] Arrived on '" .. SESSION.currentLevel .. "' — Freeroam Rally Course placed for '" .. tostring(queued.missionName) .. "'!")
        MP.SendChatMessage(-1, "[RallyMP] Arrived on '" .. SESSION.currentLevel .. "' — Freeroam Rally Course placed for '" .. tostring(queued.missionName) .. "'! Course placed & spawned at start point! Change spawn: /rally car (rally config), /rally foot (walk on foot), /rally startline. Ready? Click Start or type /start.")
      else
        SESSION.status = "FREEROAM"
        syncPeerState()
        MP.SendChatMessage(-1, "[RallyMP] Both players arrived on '" .. SESSION.currentLevel .. "'! Press ESC -> Rally Mode (or type " .. CONFIG.commandPrefix .. ") anytime.")
      end
    end
  else
    syncPeerState()
  end
end

function onProposeEvent(playerId, rawData)
  local req = decodeJson(rawData)
  if req.currentLevel and tostring(req.currentLevel) ~= "" and SESSION.status ~= "MAP_SWITCHING" then
    SESSION.currentLevel = tostring(req.currentLevel):lower()
  end
  local actionType = tostring(req.actionType or "mission")
  if actionType == "map" then
    if not req.levelName or req.levelName == "" then return end
    createOrExecuteProposal(playerId, {
      actionType = "map",
      title = "Freeroam Map: " .. tostring(req.levelName),
      levelName = tostring(req.levelName):lower(),
      vehicleMode = req.vehicleMode or SESSION.lastVehicleMode
    })
    return
  end

  if not req.missionId or req.missionId == "" then return end
  local mType = tostring(req.missionType or "rallyStage")
  if mType == "rallyLoop" and not CONFIG.allowRallyLoop then
    MP.SendChatMessage(playerId, "[RallyMP] rallyLoop missions are disabled in server config.")
    return
  end
  if mType == "rallyStage" and not CONFIG.allowRallyStage then
    MP.SendChatMessage(playerId, "[RallyMP] rallyStage missions are disabled in server config.")
    return
  end

  createOrExecuteProposal(playerId, {
    actionType = "mission",
    missionId = tostring(req.missionId),
    missionDir = req.missionDir,
    title = tostring(req.missionName or req.missionId),
    missionType = mType,
    levelName = tostring(req.levelName or ""),
    vehicleMode = req.vehicleMode,
    participationMode = req.participationMode,
    launchMode = req.launchMode,
    userSettings = req.userSettings or {}
  })
end

function onRespondProposal(playerId, rawData)
  local normPid = tonumber(playerId) or playerId
  ensureParticipant(normPid)

  if checkProposalExpiry(false) then
    return
  end

  local prop = SESSION.pendingProposal
  if not prop then
    syncPeerState()
    return
  end

  local req = decodeJson(rawData)
  local decision = tostring(req.decision or ""):lower()
  local isProposer = (tonumber(prop.proposerId) == tonumber(normPid))
  local responderName = MP.GetPlayerName(normPid) or ("Player " .. tostring(normPid))

  if decision == "cancel" then
    SESSION.pendingProposal = nil
    if SESSION.status == "READY_CHECK" then SESSION.status = getIdleOrStagedStatus() end
    syncPeerState()
    MP.SendChatMessage(-1, "[RallyMP] " .. tostring(responderName) .. " cancelled the Rally invite.")
    return
  end

  if decision == "decline" then
    SESSION.pendingProposal = nil
    if SESSION.status == "READY_CHECK" then SESSION.status = getIdleOrStagedStatus() end
    syncPeerState()
    MP.SendChatMessage(-1, "[RallyMP] " .. tostring(responderName) .. " declined invite: " .. tostring(prop.title))
    return
  end

  if isProposer and #SESSION.participants > 1 then
    MP.SendChatMessage(normPid, "[RallyMP] Invite already sent! Waiting for your partner to click Accept & Ready (or click Cancel Invite).")
    syncPeerState()
    return
  end

  if decision == "accept" then
    SESSION.pendingProposal = nil
    syncPeerState()
    print("[RallyMP] Partner '" .. tostring(responderName) .. "' accepted '" .. tostring(prop.title) .. "'")
    MP.SendChatMessage(-1, "[RallyMP] Partner Ready confirmed! Starting " .. tostring(prop.title) .. "...")
    executeApprovedProposal(prop)
  end
end

local function requestStartStagedEvent(playerId, vehicleModeOverride)
  ensureParticipant(playerId)
  local staged = SESSION.stagedMission
  if not staged then
    MP.SendChatMessage(playerId, "[RallyMP] No staged Rally event is currently waiting in Freeroam. Open ESC -> Rally Mode (or type " .. CONFIG.commandPrefix .. ") to choose a stage.")
    return
  end
  if not isPlayerAllowedToControlStaged(playerId) then
    MP.SendChatMessage(playerId, "[RallyMP] Waiting on event proposer (" .. tostring(staged.proposerName or "Proposer") .. ") to start '" .. tostring(staged.missionName) .. "'.")
    return
  end
  if vehicleModeOverride and CONFIG.defaultVehicleChoice == "host_chooses" then
    staged.vehicleMode = resolveAllowedVehicleMode(vehicleModeOverride)
  end
  createOrExecuteProposal(playerId, {
    actionType = "start_staged",
    missionId = staged.missionId,
    missionDir = staged.missionDir,
    title = staged.missionName or staged.missionId,
    missionType = staged.missionType or "rallyLoop",
    levelName = staged.levelName or SESSION.currentLevel,
    vehicleMode = staged.vehicleMode or SESSION.lastVehicleMode,
    participationMode = SESSION.participationMode,
    launchMode = SESSION.launchMode,
    userSettings = staged.userSettings or {}
  })
end

local function clearStagedEvent(playerId)
  local staged = SESSION.stagedMission
  if not staged then return end
  if not isPlayerAllowedToControlStaged(playerId) then
    MP.SendChatMessage(playerId, "[RallyMP] Only the event proposer (" .. tostring(staged.proposerName or "Proposer") .. ") can clear the staged event.")
    return
  end
  local oldName = staged.missionName or staged.missionId
  SESSION.stagedMission = nil
  if SESSION.status == "FREEROAM_STAGED" then
    SESSION.status = "FREEROAM"
  end
  broadcastCrew("NativeRally_ClearStagedNotes", {})
  syncPeerState()
  MP.SendChatMessage(-1, "[RallyMP] Cleared staged event '" .. tostring(oldName) .. "' — remaining in open Freeroam.")
end

function onUIAction(playerId, rawData)
  ensureParticipant(playerId)
  local req = decodeJson(rawData)
  local act = tostring(req.action or "")

  if act == "requestCrew" then
    local targetPid = tonumber(req.targetPlayerId)
    local reqType = tostring(req.type or "ask_copilot")
    if targetPid and targetPid ~= tonumber(playerId) then
      local fromName = MP.GetPlayerName(playerId) or ("Player " .. tostring(playerId))
      local toName = MP.GetPlayerName(targetPid) or ("Player " .. tostring(targetPid))
      SESSION.pendingCrewRequest = {
        id = tostring(nowMs()),
        type = reqType,
        fromPlayerId = tonumber(playerId),
        fromPlayerName = fromName,
        toPlayerId = targetPid,
        toPlayerName = toName,
        expiresAtEpoch = nowEpochSec() + (CONFIG.readyCheckTimeoutSec or 30)
      }
      local msg = "[RallyMP] " .. fromName
      if reqType == "ask_copilot" then
        msg = msg .. " asked to Co-Pilot for " .. toName .. "!"
      elseif reqType == "invite_copilot" then
        msg = msg .. " invited " .. toName .. " to be their Co-Pilot!"
      elseif reqType == "challenge_driver" then
        msg = msg .. " challenged " .. toName .. " to a 2-Car Rally Duel!"
      elseif reqType == "swap_roles" then
        msg = msg .. " asked to swap Driver / Co-Pilot seats with " .. toName .. "!"
      end
      MP.SendChatMessage(-1, msg)
      syncPeerState()
    end
  elseif act == "respondCrewRequest" then
    local accept = (req.accept == true)
    local cReq = SESSION.pendingCrewRequest
    if cReq and tonumber(cReq.toPlayerId) == tonumber(playerId) then
      if accept then
        if cReq.type == "ask_copilot" then
          SESSION.participants[1] = cReq.toPlayerId
          SESSION.participants[2] = cReq.fromPlayerId
          SESSION.participationMode = "codriver"
          if CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.activeMissionId then
            despawnPlayerAllServerVehicles(cReq.fromPlayerId)
            MP.TriggerClientEvent(cReq.fromPlayerId, "NativeRally_DespawnCoDriverCars", "{}")
          end
        elseif cReq.type == "invite_copilot" then
          SESSION.participants[1] = cReq.fromPlayerId
          SESSION.participants[2] = cReq.toPlayerId
          SESSION.participationMode = "codriver"
          if CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.activeMissionId then
            despawnPlayerAllServerVehicles(cReq.toPlayerId)
            MP.TriggerClientEvent(cReq.toPlayerId, "NativeRally_DespawnCoDriverCars", "{}")
          end
        elseif cReq.type == "challenge_driver" then
          SESSION.participants[1] = cReq.fromPlayerId
          SESSION.participants[2] = cReq.toPlayerId
          SESSION.participationMode = "two_car"
        elseif cReq.type == "swap_roles" and #SESSION.participants == 2 then
          SESSION.participants[1], SESSION.participants[2] = SESSION.participants[2], SESSION.participants[1]
        end
        MP.SendChatMessage(-1, "[RallyMP] Crew Paired: " .. tostring(cReq.fromPlayerName) .. " & " .. tostring(cReq.toPlayerName) .. " are now set for " .. (SESSION.participationMode == "codriver" and "Shared Co-Driver" or "2-Car Competition") .. "!")
      else
        MP.SendChatMessage(-1, "[RallyMP] " .. tostring(cReq.toPlayerName) .. " declined the crew request.")
      end
      SESSION.pendingCrewRequest = nil
      syncPeerState()
    end
  elseif act == "cancelCrewRequest" then
    if SESSION.pendingCrewRequest and tonumber(SESSION.pendingCrewRequest.fromPlayerId) == tonumber(playerId) then
      SESSION.pendingCrewRequest = nil
      syncPeerState()
    end
  elseif act == "leaveSlot" then
    local norm = tonumber(playerId)
    if SESSION.participants[1] and tonumber(SESSION.participants[1]) == norm then
      SESSION.participants[1] = SESSION.participants[2]
      SESSION.participants[2] = nil
    elseif SESSION.participants[2] and tonumber(SESSION.participants[2]) == norm then
      SESSION.participants[2] = nil
    end
    MP.SendChatMessage(-1, "[RallyMP] " .. (MP.GetPlayerName(playerId) or "Player") .. " stepped down to Paddock.")
    syncPeerState()
  elseif act == "spawnStartLine" then
    local m = tostring(req.mode or "random_rally")
    MP.TriggerClientEvent(playerId, "NativeRally_SpawnStartLine", encodeJson({ mode = m }))
    MP.SendChatMessage(playerId, "[RallyMP] Spawning at stage start line (" .. (m == "on_foot" and "On Foot" or (m == "current_car" and "Current Car" or "Random Rally Car")) .. ")...")
  elseif act == "startStagedEvent" then
    requestStartStagedEvent(playerId, req.vehicleMode)
  elseif act == "clearStagedEvent" then
    clearStagedEvent(playerId)
  elseif act == "setMode" and req.mode and CONFIG.supportBothParticipationModes then
    SESSION.participationMode = (req.mode == "codriver") and "codriver" or "two_car"
    if SESSION.participationMode == "codriver" and CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.activeMissionId and SESSION.participants[2] then
      despawnPlayerAllServerVehicles(SESSION.participants[2])
      MP.TriggerClientEvent(SESSION.participants[2], "NativeRally_DespawnCoDriverCars", "{}")
    end
    syncPeerState()
    MP.SendChatMessage(-1, "[RallyMP] Crew mode switched to: " .. (SESSION.participationMode == "codriver" and "Shared Co-Driver (AI Voicepack OFF · Passenger Roadbook Active)" or "2-Car Competition"))
  elseif act == "setLaunchMode" and req.launchMode and CONFIG.toggleableLaunchMode then
    SESSION.launchMode = (req.launchMode == "simultaneous_ghost") and "simultaneous_ghost" or "wrc_staggered"
    syncPeerState()
    MP.SendChatMessage(-1, "[RallyMP] Launch & clock rule switched to: " .. SESSION.launchMode)
  elseif act == "swapSlots" and #SESSION.participants == 2 then
    SESSION.participants[1], SESSION.participants[2] = SESSION.participants[2], SESSION.participants[1]
    syncPeerState()
    MP.SendChatMessage(-1, "[RallyMP] Swapped Slot 1 / Slot 2 crew roles.")
  elseif act == "toggleRecce" and CONFIG.unlockNativeRallyFeatures then
    SESSION.recceEnabled = req.enabled == true
    SESSION.status = SESSION.recceEnabled and "RECCE_ACTIVE" or getIdleOrStagedStatus()
    broadcastCrew("NativeRally_SyncFeature", { feature = "recce", enabled = SESSION.recceEnabled })
    syncPeerState()
    MP.SendChatMessage(-1, "[RallyMP] 2-Player Native Recce App: " .. (SESSION.recceEnabled and "ENABLED" or "OFF"))
  elseif act == "stopMission" then
    SESSION.status = "FREEROAM"
    SESSION.activeMissionId = nil
    SESSION.stagedMission = nil
    SESSION.pendingProposal = nil
    broadcastCrew("NativeRally_StopMission", { by = MP.GetPlayerName(playerId) or "Player" })
    syncPeerState()
  end
end

function onUIStartClicked(playerId, _rawData)
  SESSION.status = "LOOP_ACTIVE"
  broadcastCrew("NativeRally_StartLoopClock", { triggeredBy = MP.GetPlayerName(playerId) or "Host", serverNowMs = nowMs() })
  syncPeerState()
end

function onVoteClockSkip(playerId, rawData)
  local data = decodeJson(rawData)
  local targetEpoch = tonumber(data.targetEpoch) or 0
  SESSION.skipVotes[playerId] = targetEpoch

  if CONFIG.clockSkipPolicy == "host_authority" and SESSION.participants[1] == playerId then
    SESSION.skipVotes = {}
    broadcastCrew("NativeRally_CommitClockSkip", { targetEpoch = targetEpoch })
    return
  end

  local requiredVotes = (SESSION.participationMode == "codriver") and 1 or #SESSION.participants
  local votes = 0
  local maxTarget = targetEpoch
  for _, pid in ipairs(SESSION.participants) do
    if SESSION.skipVotes[pid] ~= nil then
      votes = votes + 1
      if SESSION.skipVotes[pid] > maxTarget then maxTarget = SESSION.skipVotes[pid] end
    end
  end

  if votes >= requiredVotes then
    SESSION.skipVotes = {}
    broadcastCrew("NativeRally_CommitClockSkip", { targetEpoch = maxTarget })
    MP.SendChatMessage(-1, "[RallyMP] Both drivers confirmed Clock Skip — advancing Rally Loop Event Clock.")
  else
    MP.SendChatMessage(-1, "[RallyMP] " .. (MP.GetPlayerName(playerId) or "Driver") .. " voted to Skip Clock (press Interact near TC/Start to confirm).")
  end
  syncPeerState()
end

function onPlayerStagedAtSS(playerId, _rawData)
  SESSION.stagedAtSS[playerId] = true
  SESSION.status = "STAGE_STAGING"
  syncPeerState()
  checkSimultaneousStageRelease()
end

function onPathnodeSplit(playerId, rawData)
  if SESSION.participationMode == "codriver" and SESSION.participants[2] == playerId then return end
  local data = decodeJson(rawData)
  local key = tostring(data.pathnodeId or data.name or "split")
  local timeSec = tonumber(data.timeSec) or 0
  SESSION.splits[playerId] = SESSION.splits[playerId] or {}
  SESSION.splits[playerId][key] = timeSec

  local deltaSec = nil
  for _, otherPid in ipairs(SESSION.participants) do
    if otherPid ~= playerId and SESSION.splits[otherPid] and SESSION.splits[otherPid][key] then
      deltaSec = timeSec - SESSION.splits[otherPid][key]
    end
  end

  broadcastCrew("NativeRally_PeerSplitBroadcast", {
    playerId = playerId,
    playerName = MP.GetPlayerName(playerId) or ("P" .. tostring(playerId)),
    splitLabel = tostring(data.name or key),
    timeSec = timeSec,
    deltaSec = deltaSec
  })
end

function onStageOrLoopResult(playerId, rawData)
  local data = decodeJson(rawData)
  local st = SESSION.standings[playerId]
  if not st then return end

  if type(data.stageTimes) == "table" then
    st.stageTimes = data.stageTimes
  elseif tonumber(data.stageTimeSec) then
    st.stageTimes[#st.stageTimes + 1] = tonumber(data.stageTimeSec)
  end
  st.penaltySec = tonumber(data.penaltySec) or st.penaltySec
  st.totalSec = tonumber(data.totalSec) or st.totalSec
  st.completed = data.completed == true

  broadcastPeerStandings()
end

function onChatMessage(playerId, playerName, message)
  local cleanMsg = tostring(message or ""):match("^%s*(.-)%s*$")
  local lowerMsg = cleanMsg:lower()

  -- Quick 1-word chat shorthands for sim-rig drivers (/start, /accept, /ready, /decline, /cancel)
  if lowerMsg == "/start" then
    requestStartStagedEvent(playerId, nil)
    return 1
  elseif lowerMsg == "/accept" or lowerMsg == "/ready" then
    onRespondProposal(playerId, '{"decision":"accept"}')
    return 1
  elseif lowerMsg == "/decline" then
    onRespondProposal(playerId, '{"decision":"decline"}')
    return 1
  elseif lowerMsg == "/cancel" then
    onRespondProposal(playerId, '{"decision":"cancel"}')
    return 1
  end

  if lowerMsg:sub(1, #CONFIG.commandPrefix) ~= CONFIG.commandPrefix:lower() then
    return 0
  end

  local args = {}
  for token in cleanMsg:gmatch("%S+") do args[#args + 1] = token end
  local sub = (args[2] or "menu"):lower()

  if sub == "menu" or sub == "open" then
    ensureParticipant(playerId)
    MP.TriggerClientEvent(playerId, "NativeRally_OpenMenu", "{}")
  elseif sub == "start" then
    requestStartStagedEvent(playerId, nil)
  elseif sub == "car" or sub == "rallycar" or sub == "respawn" then
    MP.TriggerClientEvent(playerId, "NativeRally_SpawnStartLine", '{"mode":"random_rally"}')
    MP.SendChatMessage(playerId, "[RallyMP] Spawning fresh Random Rally Car at starting line...")
  elseif sub == "foot" or sub == "walk" then
    MP.TriggerClientEvent(playerId, "NativeRally_SpawnStartLine", '{"mode":"on_foot"}')
    MP.SendChatMessage(playerId, "[RallyMP] Spawning On Foot at starting line...")
  elseif sub == "startline" or sub == "tp" then
    MP.TriggerClientEvent(playerId, "NativeRally_SpawnStartLine", '{"mode":"current_car"}')
    MP.SendChatMessage(playerId, "[RallyMP] Teleporting car to starting line...")
  elseif sub == "clearstaged" or sub == "unstage" then
    clearStagedEvent(playerId)
  elseif sub == "accept" or sub == "ready" then
    onRespondProposal(playerId, '{"decision":"accept"}')
  elseif sub == "decline" then
    onRespondProposal(playerId, '{"decision":"decline"}')
  elseif sub == "cancel" then
    onRespondProposal(playerId, '{"decision":"cancel"}')
  elseif sub == "map" and args[3] then
    createOrExecuteProposal(playerId, {
      actionType = "map",
      title = "Freeroam Map: " .. tostring(args[3]),
      levelName = tostring(args[3]):lower(),
      vehicleMode = SESSION.lastVehicleMode
    })
  elseif sub == "mode" and args[3] then
    if CONFIG.supportBothParticipationModes then
      local m = args[3]:lower()
      SESSION.participationMode = (m == "codriver") and "codriver" or "two_car"
      syncPeerState()
      MP.SendChatMessage(-1, "[RallyMP] Participation mode set to: " .. SESSION.participationMode)
    end
  elseif sub == "launchmode" and args[3] then
    if CONFIG.toggleableLaunchMode then
      local lm = args[3]:lower()
      SESSION.launchMode = (lm == "ghost" or lm == "simultaneous" or lm == "simultaneous_ghost") and "simultaneous_ghost" or "wrc_staggered"
      syncPeerState()
      MP.SendChatMessage(-1, "[RallyMP] Stage launch & clock rule set to: " .. SESSION.launchMode)
    end
  elseif sub == "copilot" and args[3] then
    local target = tonumber(args[3])
    if target then
      onUIAction(playerId, encodeJson({ action = "requestCrew", type = "ask_copilot", targetPlayerId = target }))
    end
  elseif sub == "invite" and args[3] then
    local target = tonumber(args[3])
    if target then
      onUIAction(playerId, encodeJson({ action = "requestCrew", type = "invite_copilot", targetPlayerId = target }))
    end
  elseif sub == "driver" and args[3] then
    local target = tonumber(args[3])
    if target then
      onUIAction(playerId, encodeJson({ action = "requestCrew", type = "challenge_driver", targetPlayerId = target }))
    end
  elseif sub == "leave" then
    onUIAction(playerId, encodeJson({ action = "leaveSlot" }))
  elseif sub == "recce" then
    SESSION.recceEnabled = not SESSION.recceEnabled
    SESSION.status = SESSION.recceEnabled and "RECCE_ACTIVE" or getIdleOrStagedStatus()
    broadcastCrew("NativeRally_SyncFeature", { feature = "recce", enabled = SESSION.recceEnabled })
    syncPeerState()
  elseif sub == "swap" then
    if #SESSION.participants == 2 then
      SESSION.participants[1], SESSION.participants[2] = SESSION.participants[2], SESSION.participants[1]
      syncPeerState()
      MP.SendChatMessage(-1, "[RallyMP] Swapped Slot 1 / Slot 2 roles.")
    end
  elseif sub == "stop" then
    SESSION.status = "FREEROAM"
    SESSION.activeMissionId = nil
    SESSION.stagedMission = nil
    SESSION.pendingProposal = nil
    broadcastCrew("NativeRally_StopMission", { by = playerName })
    syncPeerState()
  else
    MP.SendChatMessage(playerId, "[RallyMP] Press ESC -> click 'Rally Mode (2P)' at top of Pause Menu, or type: /start | " .. CONFIG.commandPrefix .. " | " .. CONFIG.commandPrefix .. " start | accept | decline | mode <twocar|codriver> | launchmode <staggered|ghost> | recce | swap | stop")
  end

  return 1
end

local function broadcastSpawnQueueFlush(ownerId, vehId)
  if not CONFIG.immediatePartnerSpawnFlush then return end
  MP.TriggerClientEvent(-1, "NativeRally_FlushSpawnQueue", encodeJson({
    ownerId = ownerId,
    serverVehId = tostring(ownerId) .. "-" .. tostring(vehId),
    serverNowMs = nowMs()
  }))
end

function onVehicleSpawnGuard(playerId, vehId, rawData)
  if isServerPropOrAvatarPayload(rawData) then
    print("[RallyMP] Blocked stage prop/avatar spawn from player " .. tostring(playerId) .. " (vehId=" .. tostring(vehId) .. ")")
    if MP.RemoveVehicle then pcall(MP.RemoveVehicle, playerId, vehId) end
    return 1
  end

  -- Prevent orphaned extra vehicle spawns from Slot 2 while seated in Shared Co-Driver mode during an active mission
  if SESSION.participationMode == "codriver" and CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.activeMissionId and SESSION.participants[2] and tonumber(playerId) == tonumber(SESSION.participants[2]) then
    print("[RallyMP] Despawned extra Co-Driver vehicle slot from player " .. tostring(playerId) .. " while seated in Car 1.")
    if MP.RemoveVehicle then pcall(MP.RemoveVehicle, playerId, vehId) end
    return 1
  end

  if isUnicyclePayload(rawData) then
    -- Avatar spawned/edited: let it sync, but keep the player's real car as active and do not prune anything
    return 0
  end

  SESSION.activeVehicleByPlayer[playerId] = vehId
  prunePlayerExtraVehicles(playerId, vehId)
  broadcastSpawnQueueFlush(playerId, vehId)
  syncPeerState()
  return 0
end

function onVehicleEditedGuard(playerId, vehId, rawData)
  if isServerPropOrAvatarPayload(rawData) then
    if MP.RemoveVehicle then pcall(MP.RemoveVehicle, playerId, vehId) end
    return 1
  end

  if SESSION.participationMode == "codriver" and CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.activeMissionId and SESSION.participants[2] and tonumber(playerId) == tonumber(SESSION.participants[2]) then
    if MP.RemoveVehicle then pcall(MP.RemoveVehicle, playerId, vehId) end
    return 1
  end

  if isUnicyclePayload(rawData) then
    -- Avatar spawned/edited: let it sync, but keep the player's real car as active and do not prune anything
    return 0
  end

  SESSION.activeVehicleByPlayer[playerId] = vehId
  prunePlayerExtraVehicles(playerId, vehId)
  broadcastSpawnQueueFlush(playerId, vehId)
  syncPeerState()
  return 0
end

function onActiveVehicleReported(playerId, rawData)
  ensureParticipant(playerId)
  local data = decodeJson(rawData)
  local srvId = tostring(data.serverVehId or "")
  local vid = srvId:match("^%-?%d+%-(.+)$")
  local reported = MP.GetPlayerVehicles and MP.GetPlayerVehicles(playerId) or nil
  if type(reported) == "table" and vid and (isUnicyclePayload(reported[vid]) or isUnicyclePayload(reported[tonumber(vid) or -1])) then
    return
  end
  if vid and vid ~= "" then
    SESSION.activeVehicleByPlayer[playerId] = vid
    prunePlayerExtraVehicles(playerId, vid)
    broadcastSpawnQueueFlush(playerId, vid)
    syncPeerState()
  end
end

function onDespawnCoDriverCars(playerId, _rawData)
  if CONFIG.codriverDespawnExtraCarAndLockCam and SESSION.activeMissionId then
    despawnPlayerAllServerVehicles(playerId)
    syncPeerState()
  end
end

function onRequestTrackNotes(playerId, rawData)
  local req = decodeJson(rawData)
  local rawKey = tostring(req.trackKey or SESSION.activeMissionId or (SESSION.stagedMission and SESSION.stagedMission.missionId) or SESSION.currentLevel or "")
  if rawKey == "" then return end
  local record = loadServerTrackNotes(rawKey)
  if record and type(record.notes) == "table" then
    MP.TriggerClientEvent(playerId, "NativeRally_TrackNotesData", encodeJson(record))
  end
end

function onSaveTrackNotes(playerId, rawData)
  if not CONFIG.codriverWritableTrackNotes then return end
  local req = decodeJson(rawData)
  local rawKey = tostring(req.trackKey or SESSION.activeMissionId or (SESSION.stagedMission and SESSION.stagedMission.missionId) or SESSION.currentLevel or "")
  if rawKey == "" then return end
  local authorName = MP.GetPlayerName(playerId) or ("Player " .. tostring(playerId))

  if req.resetDefault == true then
    saveServerTrackNotes(rawKey, nil)
    broadcastCrew("NativeRally_TrackNotesData", {
      trackKey = rawKey,
      resetDefault = true,
      updatedBy = authorName
    })
    MP.SendChatMessage(-1, "[RallyMP] " .. tostring(authorName) .. " reset race notes to stage defaults for '" .. tostring(rawKey) .. "'.")
    return
  end

  if type(req.notes) ~= "table" then return end
  local record = {
    trackKey = rawKey,
    updatedBy = authorName,
    updatedAtEpoch = nowEpochSec(),
    notes = req.notes
  }
  saveServerTrackNotes(rawKey, record)
  broadcastCrew("NativeRally_TrackNotesData", record)
  MP.SendChatMessage(-1, "[RallyMP] " .. tostring(authorName) .. " saved " .. tostring(#req.notes) .. " custom co-driver race notes for '" .. tostring(rawKey) .. "'.")
end

function onTriggerManualCallout(playerId, rawData)
  if not CONFIG.codriverClickToCallVoice then return end
  local req = decodeJson(rawData)
  local callText = tostring(req.callText or "")
  if callText == "" then return end
  local callerName = MP.GetPlayerName(playerId) or ("Player " .. tostring(playerId))
  broadcastCrew("NativeRally_PlayManualCallout", {
    callerId = tonumber(playerId) or playerId,
    callerName = callerName,
    noteId = tostring(req.noteId or ""),
    iconCode = tostring(req.iconCode or "CR"),
    severity = tonumber(req.severity) or 4,
    distanceM = tonumber(req.distanceM) or 0,
    callText = callText:sub(1, 220),
    nativeText = tostring(req.nativeText or ""):sub(1, 220)
  })
end

function onPlayerJoin(playerId)
  if #SESSION.participants < 2 then ensureParticipant(playerId) end
  syncPeerState()
  MP.TriggerClientEvent(playerId, "NativeRally_ScanMissions", "{}")
  MP.SendChatMessage(playerId, "[RallyMP] Ready! Press ESC and click the orange 'Rally Mode (2P)' tab at the top of the Pause Menu (or type " .. CONFIG.commandPrefix .. " in chat) to pick any Rally Loop or Stage.")
end

function onPlayerDisconnect(playerId)
  local normPid = tonumber(playerId) or playerId
  local nextList = {}
  for _, pid in ipairs(SESSION.participants) do
    if tonumber(pid) ~= tonumber(normPid) then nextList[#nextList + 1] = pid end
  end
  SESSION.participants = nextList
  SESSION.stagedAtSS[playerId] = nil
  SESSION.stagedAtSS[normPid] = nil
  SESSION.skipVotes[playerId] = nil
  SESSION.skipVotes[normPid] = nil
  SESSION.levelReadyPlayers[playerId] = nil
  SESSION.levelReadyPlayers[normPid] = nil
  SESSION.activeVehicleByPlayer[playerId] = nil
  SESSION.activeVehicleByPlayer[normPid] = nil
  if SESSION.pendingProposal and (tonumber(SESSION.pendingProposal.proposerId) == tonumber(normPid) or #SESSION.participants < 2) then
    SESSION.pendingProposal = nil
    if SESSION.status == "READY_CHECK" then SESSION.status = getIdleOrStagedStatus() end
  end
  syncPeerState()
end

-- ----------------------------------------------------------------------------
-- End of stage -> send players back to the PRE-STAGE (no reconnect needed)
-- ----------------------------------------------------------------------------
local function buildPreStagePacket()
  local mid = SESSION.activeMissionId
  local saved = loadServerTrackNotes(mid)
  return {
    missionId = mid,
    missionDir = SESSION.activeMissionDir or ("/gameplay/missions/" .. tostring(mid)),
    missionName = SESSION.activeMissionName or mid,
    missionType = SESSION.activeMissionType or "rallyStage",
    levelName = SESSION.currentLevel,
    savedNotes = (saved and type(saved.notes) == "table") and saved.notes or false
  }
end

local function finalizePreStageIfAllEnded()
  if not SESSION.activeMissionId then return end
  if #SESSION.participants == 0 then
    SESSION.activeMissionId = nil
    SESSION.endedPlayers = {}
    SESSION.status = getIdleOrStagedStatus()
    return
  end
  for _, pid in ipairs(SESSION.participants) do
    if not SESSION.endedPlayers[pid] and not SESSION.endedPlayers[tonumber(pid)] then return end
  end
  local mName = SESSION.activeMissionName or SESSION.activeMissionId
  SESSION.activeMissionId = nil
  SESSION.endedPlayers = {}
  SESSION.stagedAtSS = {}
  SESSION.skipVotes = {}
  SESSION.splits = {}
  SESSION.pendingProposal = nil
  SESSION.status = SESSION.stagedMission and "FREEROAM_STAGED" or "FREEROAM"
  syncPeerState()
  MP.SendChatMessage(-1, "[RallyMP] Stage '" .. tostring(mName) .. "' finished — everyone is back at the pre-stage. Click Start or type /start to run it again, or /rally to pick another stage.")
end

function onStageEnded(playerId, rawData)
  -- Reported by each client when its native rally mission has stopped (finish screen closed / abandoned).
  if not SESSION.activeMissionId then return end
  if SESSION.endedPlayers[playerId] then return end
  SESSION.endedPlayers[playerId] = true
  local data = decodeJson(rawData) or {}
  local st = SESSION.standings[playerId]
  if st and data.completed == true then st.completed = true end

  -- Re-stage the same mission so "Start" works again without anyone reconnecting
  if not SESSION.stagedMission then
    local pkt = buildPreStagePacket()
    SESSION.stagedMission = {
      missionId = pkt.missionId,
      missionDir = pkt.missionDir,
      missionName = pkt.missionName,
      missionType = pkt.missionType,
      levelName = SESSION.currentLevel,
      vehicleMode = SESSION.lastVehicleMode,
      userSettings = SESSION.activeUserSettings or {},
      proposerId = SESSION.participants[1],
      proposerName = SESSION.participants[1] and MP.GetPlayerName(SESSION.participants[1]) or nil
    }
  end

  local pkt = buildPreStagePacket()
  MP.TriggerClientEvent(playerId, "NativeRally_ReturnToPreStage", encodeJson(pkt))
  broadcastPeerStandings()
  finalizePreStageIfAllEnded()
end

function onNativeRallyTick()
  checkProposalExpiry(false)
  -- covers a partner disconnecting while the other player has already finished
  finalizePreStageIfAllEnded()
end


function onAutoCrewVehicle(playerId, rawData)
  ensureParticipant(playerId)
  local data = decodeJson(rawData) or {}
  local evt = tostring(data.event or "")
  if evt == "enter_car" then
    local driverPid = tonumber(data.driverPlayerId)
    local coDriverPid = tonumber(playerId)
    if driverPid and driverPid ~= coDriverPid then
      SESSION.participants[1] = driverPid
      SESSION.participants[2] = coDriverPid
      SESSION.participationMode = "codriver"
      local dName = MP.GetPlayerName(driverPid) or ("Player " .. tostring(driverPid))
      local cName = MP.GetPlayerName(coDriverPid) or ("Player " .. tostring(coDriverPid))
      MP.SendChatMessage(-1, "[RallyMP] " .. cName .. " entered " .. dName .. "'s cockpit — Shared Co-Driver mode activated automatically!")
      syncPeerState()
    end
  elseif evt == "exit_car" then
    if SESSION.participationMode == "codriver" and tonumber(SESSION.participants[2]) == tonumber(playerId) then
      SESSION.participationMode = "two_car"
      local cName = MP.GetPlayerName(playerId) or "Co-Driver"
      MP.SendChatMessage(-1, "[RallyMP] " .. cName .. " exited vehicle — 2-Car mode restored.")
      syncPeerState()
    end
  end
end

function onInit()
  if MP.Get and MP.Settings and MP.Settings.Map then
    local okM, cfgMap = pcall(MP.Get, MP.Settings.Map)
    if okM and cfgMap then
      SESSION.currentLevel = extractLevelFromMapPath(cfgMap)
    end
  end
  MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
  MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
  MP.RegisterEvent("onChatMessage", "onChatMessage")
  MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawnGuard")
  MP.RegisterEvent("onVehicleEdited", "onVehicleEditedGuard")
  MP.RegisterEvent("onNativeRallyTick", "onNativeRallyTick")
  if type(MP.CreateEventTimer) == "function" then
    pcall(MP.CreateEventTimer, "onNativeRallyTick", 1000)
  end
  -- Colon-free event names required by BeamMP MPGameNetwork.lua (^%:([^%:]+)%:(.*))
  MP.RegisterEvent("NativeRally_ActiveVehicle", "onActiveVehicleReported")
  MP.RegisterEvent("NativeRally_ClockProbe", "onClockProbe")
  MP.RegisterEvent("NativeRally_HostCatalog", "onHostCatalog")
  MP.RegisterEvent("NativeRally_ClientLevelReady", "onClientLevelReady")
  MP.RegisterEvent("NativeRally_ProposeEvent", "onProposeEvent")
  MP.RegisterEvent("NativeRally_RespondProposal", "onRespondProposal")
  MP.RegisterEvent("NativeRally_UIAction", "onUIAction")
  MP.RegisterEvent("NativeRally_UIStartClicked", "onUIStartClicked")
  MP.RegisterEvent("NativeRally_AutoCrewVehicle", "onAutoCrewVehicle")
  MP.RegisterEvent("NativeRally_VoteClockSkip", "onVoteClockSkip")
  MP.RegisterEvent("NativeRally_PlayerStagedAtSS", "onPlayerStagedAtSS")
  MP.RegisterEvent("NativeRally_PathnodeSplit", "onPathnodeSplit")
  MP.RegisterEvent("NativeRally_StageOrLoopResult", "onStageOrLoopResult")
  MP.RegisterEvent("NativeRally_StageEnded", "onStageEnded")
  MP.RegisterEvent("NativeRally_DespawnCoDriverCars", "onDespawnCoDriverCars")
  MP.RegisterEvent("NativeRally_RequestTrackNotes", "onRequestTrackNotes")
  MP.RegisterEvent("NativeRally_SaveTrackNotes", "onSaveTrackNotes")
  MP.RegisterEvent("NativeRally_TriggerManualCallout", "onTriggerManualCallout")
  print("[RallyMP] BeamNG v0.40.4+ Pause Menu Rally Selector + Shared Co-Driver Page-Flip Roadbook + No-Mic Click-to-Call + 1-Car Sync + Instant 3D Spawns Bridge loaded (boot map: " .. tostring(SESSION.currentLevel ~= "" and SESSION.currentLevel or "auto") .. ").")
end
