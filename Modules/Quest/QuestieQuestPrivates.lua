---@type QuestieQuest
local QuestieQuest = QuestieLoader:ImportModule("QuestieQuest")
local _QuestieQuest = QuestieQuest.private

---@type QuestieDB
local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
---@type QuestieDBZone
local QuestieDBZone = QuestieLoader:ImportModule("QuestieDBZone")
---@type QuestiePlayer
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
---@type QuestieToolTips
local QuestieTooltips = QuestieLoader:ImportModule("QuestieTooltips")


_QuestieQuest.objectiveSpawnListCallTable = {
    ["monster"] = function(id, Objective)
        local npc = QuestieDB:GetNPC(id)
        if not npc then
            -- todo: log this
            return nil
        end
        local ret = {}
        local mon = {};

        mon.Name = npc.name
        mon.Spawns = npc.spawns
        mon.Icon = ICON_TYPE_SLAY
        mon.Id = id
        mon.GetIconScale = function() return Questie.db.global.monsterScale or 1 end
        mon.IconScale = mon:GetIconScale();
        mon.TooltipKey = "m_" .. id -- todo: use ID based keys

        ret[id] = mon;
        return ret
    end,
    ["object"] = function(id, Objective)
        local object = QuestieDB:GetObject(id)
        if not object then
            -- todo: log this
            return nil
        end
        local ret = {}
        local obj = {}

        obj.Name = object.name
        obj.Spawns = object.spawns
        obj.Icon = ICON_TYPE_LOOT
        obj.GetIconScale = function() return Questie.db.global.objectScale or 1 end
        obj.IconScale = obj:GetIconScale()
        obj.TooltipKey = "o_" .. id
        obj.Id = id

        ret[id] = obj
        return ret
    end,
    ["event"] = function(id, Objective)
        local ret = {}
        ret[1] = {};
        ret[1].Name = Objective.Description or "Event Trigger";
        ret[1].Icon = ICON_TYPE_EVENT
        ret[1].GetIconScale = function() return Questie.db.global.eventScale or 1.35 end
        ret[1].IconScale = ret[1]:GetIconScale();
        ret[1].Id = id or 0
        if Objective.Coordinates then
            ret[1].Spawns = Objective.Coordinates
        elseif Objective.Description then-- we need to fall back to old questie data, some events are missing in the new DB
            ret[1].Spawns = {}
            local questie2data = TEMP_Questie2Events[Objective.Description];
            if questie2data and questie2data["locations"] then
                for i, spawn in pairs(questie2data["locations"]) do
                    local zid = Questie2ZoneTableInverse[spawn[1]];
                    if zid then
                        zid = QuestieDBZone:GetAreaIdByUIMapID(zid)
                        if zid then
                            if not ret[1].Spawns[zid] then
                                ret[1].Spawns[zid] = {};
                            end
                            local x = spawn[2] * 100;
                            local y = spawn[3] * 100;
                            tinsert(ret[1].Spawns[zid], {x, y});
                        end
                    end
                end
            end
        end
        return ret
    end,
    ["item"] = function(id, Objective)
        local ret = {};
        local item = QuestieDB:GetItem(id);
        if item ~= nil and item.Sources ~= nil then
            for _, source in pairs(item.Sources) do
                if _QuestieQuest.objectiveSpawnListCallTable[source.Type] and source.Type ~= "item" then -- anti-recursive-loop check, should never be possible but would be bad if it was
                    local sourceList = _QuestieQuest.objectiveSpawnListCallTable[source.Type](source.Id, Objective);
                    if sourceList == nil then
                        -- log this
                    else
                        for id, sourceData in pairs(sourceList) do
                            if not ret[id] then
                                ret[id] = {};
                                ret[id].Name = sourceData.Name;
                                ret[id].Spawns = {};
                                if source.Type == "object" then
                                    ret[id].Icon = ICON_TYPE_OBJECT
                                    ret[id].GetIconScale = function() return Questie.db.global.objectScale or 1 end
                                    ret[id].IconScale = ret[id]:GetIconScale()
                                else
                                    ret[id].Icon = ICON_TYPE_LOOT
                                    ret[id].GetIconScale = function() return Questie.db.global.lootScale or 1 end
                                    ret[id].IconScale = ret[id]:GetIconScale()
                                end
                                ret[id].TooltipKey = sourceData.TooltipKey
                                ret[id].Id = id
                            end
                            if sourceData.Spawns and not item.Hidden then
                                for zone, spawns in pairs(sourceData.Spawns) do
                                    if not ret[id].Spawns[zone] then
                                        ret[id].Spawns[zone] = {};
                                    end
                                    for _, spawn in pairs(spawns) do
                                        tinsert(ret[id].Spawns[zone], spawn);
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return ret
    end
}

function _QuestieQuest:LevelRequirementsFulfilled(quest, playerLevel, minLevel, maxLevel)
    return (quest.level >= minLevel or Questie.db.char.lowlevel) and quest.level <= maxLevel and quest.requiredLevel <= playerLevel
end

-- We always want to show a quest if it is a childQuest and its parent is in the quest log
function _QuestieQuest:IsParentQuestActive(parentID)
    if parentID == nil or parentID == 0 then
        return false
    end
    if QuestiePlayer.currentQuestlog[parentID] then
        return true
    end
    return false
end

-- initialize the AlreadySpawned entry in a Quest or Objective
function _QuestieQuest:InitAlreadySpawned(QuestOrObjective)
    if not QuestOrObjective.AlreadySpawned then
        QuestOrObjective.AlreadySpawned = {}
    end
end

-- If the icon limit is enabled, get that value, otherwise return a default
function _QuestieQuest:GetMaxPerType()
    if Questie.db.global.enableIconLimit then
        return Questie.db.global.iconLimit
    end
    return 300
end

-- Initialize the Objective spawnlist using the call table
function _QuestieQuest:InitObjectiveSpawnlist(Objective)
    if _QuestieQuest.objectiveSpawnListCallTable[Objective.Type] and (not Objective.spawnList) then
        Objective.spawnList = _QuestieQuest.objectiveSpawnListCallTable[Objective.Type](Objective.Id, Objective);
    end
end

-- Register the tool tip for the objective, if it is of type item.
function _QuestieQuest:RegisterItemTooltips(Objective, BlockItemTooltips, Quest)
    if (not Objective.registeredItemTooltips) and Objective.Type == "item" and (not BlockItemTooltips) and Objective.Id then -- register item tooltip (special case)
        local item = QuestieDB:GetItem(Objective.Id);
        if item and item.name then
            QuestieTooltips:RegisterTooltip(Quest.Id, "i_" .. item.Id, Objective);
        end
        Objective.registeredItemTooltips = true
    end
end

-- Generate the list of icons to draw, using spawnData
function _QuestieQuest:UpdateIconsToDraw(iconsToDraw, Quest, spawnData, data)
    for zone, spawns in pairs(spawnData.Spawns) do
        for _, spawn in pairs(spawns) do
            if(spawn[1] and spawn[2]) then
                local drawIcon = {};
                drawIcon.AlreadySpawnedId = id;
                drawIcon.data = data;
                drawIcon.zone = zone;
                drawIcon.areaId = zone;
                drawIcon.UIMapId = ZoneDataAreaIDToUiMapID[zone];
                drawIcon.x = spawn[1];
                drawIcon.y = spawn[2];
                local x, y, instance = HBD:GetWorldCoordinatesFromZone(drawIcon.x/100, drawIcon.y/100, ZoneDataAreaIDToUiMapID[zone])
                -- There are instances when X and Y are not in the same map such as in dungeons etc, we default to 0 if it is not set
                -- This will create a distance of 0 but it doesn't matter.
                local distance = QuestieLib:Euclid(closestStarter[Quest.Id].x or 0, closestStarter[Quest.Id].y or 0, x or 0, y or 0);
                drawIcon.distance = distance or 0;
                iconsToDraw[Quest.Id][floor(distance)] = drawIcon;
            end
            --maxCount = maxCount + 1
            --if maxPerType > 0 and maxCount > maxPerType then break; end
        end
        --if maxPerType > 0 and maxCount > maxPerType then break; end
    end
end

-- Build the data object which will be used by the drawIcon
function _QuestieQuest:BuildData(Quest, ObjectiveIndex, Objective, spawnData)
    local data = {}
    data.Id = Quest.Id
    data.ObjectiveIndex = ObjectiveIndex
    data.QuestData = Quest
    data.ObjectiveData = Objective
    data.Icon = spawnData.Icon
    data.IconColor = Quest.Color
    data.GetIconScale = function() return spawnData:GetIconScale() or 1 end
    data.IconScale = data:GetIconScale()
    data.Name = spawnData.Name
    data.Type = Objective.Type
    data.ObjectiveTargetId = spawnData.Id
    return data
end

-- set the Objective.AlreadySpawned properties for a given objective spawn, and update the icons to draw
function _QuestieQuest:SpawnObjective(Quest, Objective, ObjectiveIndex, spawnData, iconsToDraw)
    if Questie.db.global.enableObjectives then
        -- temporary fix for "special objectives" to not double-spawn (we need to fix the objective detection logic)
        Quest.AlreadySpawned[Objective.Type .. tostring(ObjectiveIndex)][spawnData.Id] = true
        local maxCount = 0
        if(not iconsToDraw[Quest.Id]) then
            iconsToDraw[Quest.Id] = {}
        end
        local data = _QuestieQuest:BuildData(Quest, ObjectiveIndex, Objective, spawnData)

        Objective.AlreadySpawned[id] = {};
        Objective.AlreadySpawned[id].data = data;
        Objective.AlreadySpawned[id].minimapRefs = {};
        Objective.AlreadySpawned[id].mapRefs = {};

        _QuestieQuest:UpdateIconsToDraw(iconsToDraw, Quest, spawnData, data);
    end
end

-- Despawn icons for completed objectives
function _QuestieQuest:DespawnCompleted(Objective)
    for id, spawn in pairs(Objective.AlreadySpawned) do
        for _, note in pairs(spawn.mapRefs) do
            note:Unload();
        end
        for _, note in pairs(spawn.minimapRefs) do
            note:Unload();
        end
        spawn.mapRefs = {}
        spawn.minimapRefs = {}
    end
end

-- generate the ordered list of icons, and return its length
function _QuestieQuest:GenerateIconOrderedList(icons, tkeys, spawnedIcons, questId, maxPerType)
    local iconCount = 0
    local orderedList = {}
    -- use the keys to retrieve the values in the sorted order
    for _, distance in ipairs(tkeys) do
        if(spawnedIcons[questId] > maxPerType) then
            Questie:Debug(DEBUG_DEVELOP, "[QuestieQuest]", "Too many icons for quest:", questId)
            break;
        end
        iconCount = iconCount + 1;
        tinsert(orderedList, icons[distance]);
    end
    return orderedList, iconCount;
end

-- Spawn all icons in a hotzone
function _QuestieQuest:SpawnIconByHotzone(hotzones, spawnedIcons, Objective, questId, maxPerType)
    for index, hotzone in pairs(hotzones or {}) do
        if(spawnedIcons[questId] > maxPerType) then
            Questie:Debug(DEBUG_DEVELOP, "[QuestieQuest]", "Too many icons for quest:", questId)
            break;
        end
        --Any icondata will do because they are all the same
        local icon = hotzone[1];
        local midPoint = QuestieMap.utils:CenterPoint(hotzone);
        --Disable old clustering.
        icon.data.ClusterId = nil;
        local iconMap, iconMini = QuestieMap:DrawWorldIcon(icon.data, icon.zone, midPoint.x, midPoint.y) -- clustering code takes care of duplicates as long as mindist is more than 0
        if iconMap and iconMini then
            tinsert(Objective.AlreadySpawned[icon.AlreadySpawnedId].mapRefs, iconMap);
            tinsert(Objective.AlreadySpawned[icon.AlreadySpawnedId].minimapRefs, iconMini);
        end
        spawnedIcons[questId] = spawnedIcons[questId] + 1;
    end
end

-- Spawn icons for the objective
function _QuestieQuest:SpawnObjectiveIcons(iconsToDraw, Objective, maxPerType)
    local spawnedIcons = {}
    for questId, icons in pairs(iconsToDraw) do
        if(not spawnedIcons[questId]) then
            spawnedIcons[questId] = 0;
        end
        --This can be used to make distance ordered list..
        local tkeys = {}
        -- populate the table that holds the keys
        for k in pairs(icons) do tinsert(tkeys, k) end
        table.sort(tkeys)
        local orderedList, iconCount = _QuestieQuest:GenerateIconOrderedList(icons, tkeys, spawnedIcons, questId, maxPerType)
        local range = QUESTIE_CLUSTER_DISTANCE
        if orderedList and orderedList[1] and orderedList[1].Icon == ICON_TYPE_OBJECT then -- new clustering / limit code should prevent problems, always show all object notes
            range = range * 0.2;  -- Only use 20% of the default range.
        end
        local hotzones = QuestieMap.utils:CalcHotzones(orderedList, range, iconCount);
        _QuestieQuest:SpawnIconByHotzone(hotzones, spawnedIcons, Objective, questId, maxPerType)
    end
end

-- update waypoints for finishers in the current zone
function _QuestieQuest:UpdateWaypointsThisZone(data, finisher, finisherZone, coords)
    --QuestieMap:DrawWorldIcon(data, Zone, coords[1], coords[2])
    local x = coords[1];
    local y = coords[2];

    -- Calculate mid point if waypoints exist, we need to do this before drawing the lines
    -- as we need the icon handle for the lines.
    if(finisher.waypoints and finisher.waypoints[finisherZone]) then
        local midX, midY = QuestieLib:CalculateWaypointMidPoint(finisher.waypoints[finisherZone]);
        x = midX or x;
        y = midY or y;
        -- The above code should do the same... remove this after testing it.
        --if(midX and midY) then
        --    x = midX;
        --    y = midY;
        --end
    end

    local icon, _ = QuestieMap:DrawWorldIcon(data, finisherZone, x, y)
    if(finisher.waypoints and finisher.waypoints[finisherZone]) then
        QuestieMap:DrawWaypoints(icon, finisher.waypoints[finisherZone], finisherZone, x, y)
    end
end

-- update waypoints for finishers in another zone
function _QuestieQuest:UpdateWaypointsOtherZone(data, finisher, finisherZone)
    if(InstanceLocations[finisherZone] ~= nil) then
        for _, value in ipairs(InstanceLocations[finisherZone]) do
            --QuestieMap:DrawWorldIcon(data, value[1], value[2], value[3])
            --Questie:Debug(DEBUG_SPAM, "Conv:", Zone, "To:", ZoneDataAreaIDToUiMapID[value[1]])
            --local icon, minimapIcon = QuestieMap:DrawWorldIcon(data, value[1], value[2], value[3])
            local zone = value[1];
            local x = value[2];
            local y = value[3];
            -- Calculate mid point if waypoints exist, we need to do this before drawing the lines
            -- as we need the icon handle for the lines.
            if(finisher.waypoints and finisher.waypoints[zone]) then
                local midX, midY = QuestieLib:CalculateWaypointMidPoint(finisher.waypoints[zone]);
                x = midX or x;
                y = midY or y;
                -- The above code should do the same... remove this after testing it.
                --if(midX and midY) then
                --    x = midX;
                --    y = midY;
                --end
            end

            local icon, _ = QuestieMap:DrawWorldIcon(data, zone, x, y)

            if(finisher.waypoints and finisher.waypoints[zone]) then
                QuestieMap:DrawWaypoints(icon, finisher.waypoints[zone], zone, x, y)
            end
        end
    end
end