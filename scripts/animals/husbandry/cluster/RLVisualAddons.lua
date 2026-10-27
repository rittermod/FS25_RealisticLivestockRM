--[[
    RLVisualAddons.lua
    Links ear tags, monitor, nose ring, bum id and spray marker onto the bones of the base-game animal
    models listed in MODEL_SPECS (Brahman, the Highland adult and the four alpaca models), at runtime. A
    placement may clone another add-on file than its slot's, so alpacas carry the sheep marker in the
    marker slot. Every other model keeps the node-path lookup in VisualAnimal, where the parts are baked
    into the model file.
]]

RLVisualAddons = {}

local modDirectory = g_currentModDirectory

RLVisualAddons.ADDON_FILES = {
    earTagLeft = "animals/domesticated/earTags.i3d",
    earTagRight = "animals/domesticated/earTagsRight.i3d",
    monitor = "animals/domesticated/monitor.i3d",
    noseRing = "animals/domesticated/bullRing.i3d",
    bumId = "animals/domesticated/bumId.i3d",
    marker = "animals/domesticated/sprayedMarker_cattle.i3d",
    markerSheep = "animals/domesticated/sprayedMarker_sheep.i3d"
}

RLVisualAddons.BASE = "dataS/character/animals/domesticated/"
RLVisualAddons.CATTLE_ADULT_SCALE = { 0.171093, 0.171093, 0.171093 }


--- Build one placement: node slot, bone name, translation, rotation in degrees, scale, optional add-on file.
---@param key string node slot, also the ADDON_FILES key cloned unless addon is given
---@param bone string bone node name in the model
---@param t table translation {x, y, z}
---@param r table rotation in degrees {x, y, z}
---@param s table scale {x, y, z}
---@param addon string|nil ADDON_FILES key to clone in place of key's file
---@return table placement
local function place(key, bone, t, r, s, addon)
    return { key = key, bone = bone, t = t, r = r, s = s, addon = addon }
end

local BRAHMAN_ADULT = {
    place("earTagLeft", "cow_ear_L_skin_jnt_02", { 0.00274658, 0.0959778, 0.0658913 }, { -74.6584, 28.837, 73.5176 },
        { 1, 0.9, 0.9 }),
    place("monitor", "cow_ear_L_skin_jnt_02", { -0.0333862, 0.0633142, -0.0137482 }, { 0, -2.70115, 76.2512 },
        { 1, 0.5, 0.5 }),
    place("earTagRight", "cow_ear_R_skin_jnt_02", { 0.00280762, 0.095932, -0.0658874 },
        { 74.6584, -28.837, -286.482 }, { 1, 0.9, 0.9 }),
    place("noseRing", "cow_head_skin_jnt", { -0.00408936, -0.253422, 0.430099 }, { 75.0831, 0.634556, 0.517395 },
        { 0.5, 0.5, 0.5 }),
    place("bumId", "cow_spine_skin_jnt_01", { -0.217125, 0.0904121, 0.062439 }, { -179.669, -3.87791, -177.846 },
        { 1, 1, 1 }),
    place("marker", "cow_spine_skin_jnt_01", { 0.323662, 0.472286, -0.00109863 }, { 10, 90, 0 },
        RLVisualAddons.CATTLE_ADULT_SCALE)
}

local HIGHLAND_ADULT = {
    place("earTagLeft", "cow_ear_L_skin_jnt_02", { -0.00958252, 0.000411987, 0.0720215 },
        { -91.6249, 24.1963, 88.1322 }, { 1, 0.9, 0.9 }),
    place("monitor", "cow_ear_L_skin_jnt_02", { -0.0268555, -0.0137177, -0.00170898 }, { 0, -2.70115, 76.2512 },
        { 1, 0.5, 0.5 }),
    place("earTagRight", "cow_ear_R_skin_jnt_02", { -0.0161743, 0.0158386, -0.0774078 },
        { -252.924, -42.5706, 63.5213 }, { 1, 0.9, 0.9 }),
    place("noseRing", "cow_head_skin_jnt", { 0.003, -0.175, 0.43 }, { 60.0824, 0.746844, 0.335526 },
        { 0.5, 0.5, 0.5 }),
    place("bumId", "cow_spine_skin_jnt_01", { -0.207106, 0.0704122, 0.0423419 }, { -179.669, -3.87791, -177.846 },
        { 1, 1, 1 }),
    place("marker", "cow_spine_skin_jnt_01", { 0.173706, 0.507286, -0.000976563 }, { 0, 90, 0 },
        RLVisualAddons.CATTLE_ADULT_SCALE)
}

--- Build a calf placement list: left tag, monitor, right tag, marker.
---@param left table left ear tag {t, r}
---@param monitor table monitor {t, r}
---@param right table right ear tag {t, r}
---@param marker table spray marker {t, r, scale}
---@return table placements ordered list of placements
local function calfPlacements(left, monitor, right, marker)
    return {
        place("earTagLeft", "calf_ear_L_skin_jnt_02", left[1], left[2], { 1, 0.9, 0.9 }),
        place("monitor", "calf_ear_L_skin_jnt_02", monitor[1], monitor[2], { 1, 0.5, 0.5 }),
        place("earTagRight", "calf_ear_R_skin_jnt_02", right[1], right[2], { 1, 0.9, 0.9 }),
        place("marker", "calf_spine_skin_jnt_01", marker[1], marker[2], { marker[3], marker[3], marker[3] })
    }
end

local CALF_LEFT = { { 0.11058, -0.00616455, 0.0335045 }, { -112.467, 58.0542, -17.9195 } }
local CALF_MONITOR = { { 0.0316162, -0.0308838, -0.00554848 }, { -128.324, -88.2186, 125.249 } }
local CALF_RIGHT = { { 0.11058, -0.00610352, -0.0335236 }, { 112.467, -58.0542, -17.9195 } }
local CALF_MARKER = { { 0.263672, 0.293598, 0.0184326 }, { 93.1997, 87.3871, 84.3253 }, 0.1 }
local CALF_BABY_LEFT = { { 0.0892334, -0.0057373, 0.0273705 }, { -111.28, 53.1263, -16.4217 } }
local CALF_BABY_MONITOR = { { 0.0228269, -0.0222981, -0.004006 }, { -128.324, -88.2186, 125.249 } }
local CALF_BABY_RIGHT = { { 0.0892639, -0.00561523, -0.0273743 }, { 111.28, -53.1263, -16.4217 } }
local CALF_BABY_MARKER = { { 0.190371, 0.211978, 0.0133083 }, { 93.1997, 87.3871, 84.3253 }, 0.08 }

--- Build an alpaca placement list: left tag, monitor, right tag on the ear bones, sheep marker on its own bone.
---@param left table left ear tag {t, r, s}
---@param monitor table monitor {t, r, s}
---@param right table right ear tag {t, r, s}
---@param markerBone string bone the spray marker links to
---@param marker table spray marker {t, r, s}
---@return table placements ordered list of placements
local function alpacaPlacements(left, monitor, right, markerBone, marker)
    return {
        place("earTagLeft", "ear_l_02_jnt", left[1], left[2], left[3]),
        place("monitor", "ear_l_02_jnt", monitor[1], monitor[2], monitor[3]),
        place("earTagRight", "ear_r_02_jnt", right[1], right[2], right[3]),
        place("marker", markerBone, marker[1], marker[2], marker[3], "markerSheep")
    }
end

local ALPACA_ADULT = alpacaPlacements(
    { { -0.0241699, -0.0639877, -0.00738525 }, { -3.01975, -4.44359, -26.7001 }, { 1, 0.65, 0.65 } },
    { { 0.0243683, 0.0177994, -0.0125732 }, { 59.5007, 21.1548, -65.6593 }, { 1, 0.5, 0.5 } },
    { { 0.0447998, 0.0521851, -0.00115967 }, { -170.14, 11.9232, -35.0316 }, { 1, 0.65, 0.65 } },
    "spine_02_jnt", { { -0.0117798, 0.205759, 0 }, { -1.58136, 90, 0 }, { 0.15, 0.15, 0.15 } })
local ALPACA_SHEARED = alpacaPlacements(
    { { -0.0241699, -0.0639877, -0.00738525 }, { -3.01975, -4.44359, -26.7001 }, { 1, 0.65, 0.65 } },
    { { 0.0243683, 0.0177994, -0.0125732 }, { 59.5007, 21.1548, -65.6593 }, { 1, 0.5, 0.5 } },
    { { 0.0447998, 0.0521851, -0.00115967 }, { -170.14, 11.9232, -35.0316 }, { 1, 0.65, 0.65 } },
    "l_legBack_Leg_jnt",
    { { 0.00764465, -0.00854492, -0.166687 }, { -100.816, 15.4246, -14.6337 }, { 0.13, 0.15, 0.13 } })
local ALPACA_KID = alpacaPlacements(
    { { -0.0349121, -0.0389404, 0.019104 }, { -132.755, -57.0829, 77.018 }, { 1, 0.65, 0.65 } },
    { { 0.0262146, -0.00177002, -0.00344849 }, { 86.04, -54.4548, -87.3821 }, { 0.72, 0.36, 0.36 } },
    { { 0.0348911, 0.0389404, -0.019165 }, { 132.755, 57.0829, -102.982 }, { 1, 0.65, 0.65 } },
    "spine_02_jnt",
    { { -0.00500488, 0.189999, -3.05176e-05 }, { 0, 90, 0 }, { 0.0940744, 0.225914, 0.0940744 } })
local ALPACA_BABY = alpacaPlacements(
    { { -0.0451965, -0.0291138, 0.0236664 }, { -75.8978, -65.7063, 13.8464 }, { 0.7, 0.455, 0.455 } },
    { { 0.0191594, -0.00129365, -0.00252039 }, { 86.04, -54.4548, -87.3821 }, { 0.526224, 0.263112, 0.263112 } },
    { { 0.0452423, 0.0291138, -0.0236206 }, { 75.8978, 65.7063, -166.154 }, { 0.7, 0.455, 0.455 } },
    "spine_02_jnt",
    { { -0.0036579, 0.138864, -2.23043e-05 }, { 0, 90, 0 }, { 0.0687559, 0.165113, 0.0687559 } })

-- Keyed by the base model path tail; the "dataS/" prefix keeps a mod's own copy of a model from matching.
RLVisualAddons.MODEL_SPECS = {
    [RLVisualAddons.BASE .. "cow/brahman/cattleBrahman.i3d"] = { placements = BRAHMAN_ADULT },
    [RLVisualAddons.BASE .. "cow/brahman/brahmanCalf.i3d"] = {
        placements = calfPlacements(CALF_LEFT, CALF_MONITOR, CALF_RIGHT, CALF_MARKER)
    },
    [RLVisualAddons.BASE .. "cow/brahman/brahmanCalfBaby.i3d"] = {
        placements = calfPlacements(CALF_BABY_LEFT, CALF_BABY_MONITOR, CALF_BABY_RIGHT, CALF_BABY_MARKER)
    },
    [RLVisualAddons.BASE .. "cow/highland/cattleHighland.i3d"] = { placements = HIGHLAND_ADULT },
    [RLVisualAddons.BASE .. "alpaca/baby/alpacaBaby.i3d"] = { placements = ALPACA_BABY },
    [RLVisualAddons.BASE .. "alpaca/kid/alpacaKid.i3d"] = { placements = ALPACA_KID },
    [RLVisualAddons.BASE .. "alpaca/adult/alpaca.i3d"] = { placements = ALPACA_ADULT },
    [RLVisualAddons.BASE .. "alpaca/adult/alpacaSheared.i3d"] = { placements = ALPACA_SHEARED }
}

RLVisualAddons.templateRoots = {}
RLVisualAddons.templates = {}
RLVisualAddons.failedTemplates = {}
RLVisualAddons.warnedMissingBones = {}


--- Find the runtime-attach spec for a visual's model, or nil when the visual keeps the node-path lookup.
---@param visualData table|nil visual entry from AnimalSystem:getVisualByAge
---@return table|nil spec entry of MODEL_SPECS
---@return string|nil modelKey the matching MODEL_SPECS key
function RLVisualAddons.getModelSpec(visualData)
    if visualData == nil or visualData.visualAnimal == nil then
        Log:trace("VisualAddons: getModelSpec - no visual or no visualAnimal")
        return nil, nil
    end
    local filename = visualData.visualAnimal.filename
    if filename == nil then
        Log:trace("VisualAddons: getModelSpec - visualAnimal has no filename")
        return nil, nil
    end
    for modelKey, spec in pairs(RLVisualAddons.MODEL_SPECS) do
        if string.endsWith(filename, modelKey) then
            return spec, modelKey
        end
    end
    Log:trace("VisualAddons: no spec for model '%s' - node path mode", filename)
    return nil, nil
end


--- Return the shared template node for one add-on, loading its i3d on first use.
---@param key string add-on key from ADDON_FILES
---@return number|nil template node to clone, nil when the i3d failed to load
function RLVisualAddons.getTemplate(key)
    local template = RLVisualAddons.templates[key]
    if template ~= nil then
        Log:trace("VisualAddons: template '%s' from cache", key)
        return template
    end
    if RLVisualAddons.failedTemplates[key] then
        Log:trace("VisualAddons: template '%s' failed earlier this session - skipped", key)
        return nil
    end
    local filename = modDirectory .. RLVisualAddons.ADDON_FILES[key]
    local root = g_i3DManager:loadI3DFile(filename, false, false)
    if root == nil or root == 0 then
        RLVisualAddons.failedTemplates[key] = true
        Log:warning("VisualAddons: failed to load add-on '%s' from '%s'", key, filename)
        return nil
    end
    table.insert(RLVisualAddons.templateRoots, root)
    if getNumOfChildren(root) == 0 then
        RLVisualAddons.failedTemplates[key] = true
        Log:warning("VisualAddons: add-on '%s' from '%s' has no child node", key, filename)
        return nil
    end
    template = getChildAt(root, 0)
    RLVisualAddons.templates[key] = template
    Log:debug("VisualAddons: loaded template '%s' (%s) from '%s'", key, getName(template), filename)
    return template
end


--- Map each wanted bone name to its node under the animal root, in one recursive pass.
---@param rootNode number animal root node
---@param placements table ordered placement list
---@return table bones name -> node
local function findBones(rootNode, placements)
    local wanted = {}
    for _, placement in ipairs(placements) do
        wanted[placement.bone] = true
    end
    local bones = {}
    I3DUtil.iterateRecursively(rootNode, function(node)
        local name = getName(node)
        if wanted[name] and bones[name] == nil then
            bones[name] = node
        end
    end)
    return bones
end


--- Unhide every node between the used bones and the root; some models ship the skeleton hidden.
---@param rootNode number animal root node
---@param bones table bone name -> node, as returned by findBones
---@return table unhidden names of the nodes made visible
local function unhideAncestors(rootNode, bones)
    local unhidden = {}
    for _, bone in pairs(bones) do
        local node = bone
        while node ~= nil and node ~= 0 and node ~= rootNode do
            if not getVisibility(node) then
                setVisibility(node, true)
                table.insert(unhidden, getName(node))
                Log:trace("VisualAddons: unhid ancestor '%s' node=%d under root=%d", getName(node), node, rootNode)
            end
            node = getParent(node)
        end
    end
    return unhidden
end


--- Set a placement's translation, rotation (degrees) and scale on a linked add-on node.
---@param node number linked add-on node
---@param placement table entry of a placement list
function RLVisualAddons.applyPlacement(node, placement)
    setTranslation(node, placement.t[1], placement.t[2], placement.t[3])
    setRotation(node, math.rad(placement.r[1]), math.rad(placement.r[2]), math.rad(placement.r[3]))
    setScale(node, placement.s[1], placement.s[2], placement.s[3])
end


--- Clone every add-on of a spec onto its bone under the animal root.
---@param rootNode number animal root node
---@param spec table entry of MODEL_SPECS, or any table with a placements list
---@param modelKey string the MODEL_SPECS key, for logging
---@param farmId string|nil animal farm id, for logging
---@param uniqueId string|nil animal unique id, for logging
---@return table attached add-on key -> linked node
function RLVisualAddons.attach(rootNode, spec, modelKey, farmId, uniqueId)
    local startTime = getTimeSec()
    local attached = {}

    local bones = findBones(rootNode, spec.placements)
    for _, placement in ipairs(spec.placements) do
        local bone = bones[placement.bone]
        if bone == nil then
            local warnKey = modelKey .. "|" .. placement.bone
            if not RLVisualAddons.warnedMissingBones[warnKey] then
                RLVisualAddons.warnedMissingBones[warnKey] = true
                Log:warning("VisualAddons: bone '%s' not found on '%s' - '%s' not attached",
                    placement.bone, modelKey, placement.key)
            end
        else
            local addonKey = placement.addon or placement.key
            local template = RLVisualAddons.getTemplate(addonKey)
            if template ~= nil then
                local node = clone(template, false, false, false)
                link(bone, node)
                RLVisualAddons.applyPlacement(node, placement)
                attached[placement.key] = node
                Log:trace("VisualAddons: attached '%s' (file '%s') to '%s' node=%d", placement.key, addonKey,
                    placement.bone, node)
            end
        end
    end

    local unhidden = unhideAncestors(rootNode, bones)

    local count = 0
    for _ in pairs(attached) do
        count = count + 1
    end
    Log:debug("VisualAddons: attach farmId=%s uniqueId=%s model=%s root=%d attached=%d/%d unhid={%s} took=%.3fms",
        tostring(farmId), tostring(uniqueId), modelKey, rootNode, count, #spec.placements,
        table.concat(unhidden, ","), (getTimeSec() - startTime) * 1000)
    return attached
end


--- Delete attached add-ons that still exist; removing the animal instance usually deleted them already.
---@param attached table add-on key -> node, as returned by attach
---@param farmId string|nil animal farm id, for logging
---@param uniqueId string|nil animal unique id, for logging
function RLVisualAddons.detach(attached, farmId, uniqueId)
    local total, existing = 0, 0
    for key, node in pairs(attached) do
        total = total + 1
        if entityExists(node) then
            existing = existing + 1
            Log:trace("VisualAddons: detach '%s' node=%d still exists - deleting", key, node)
            delete(node)
        end
    end
    Log:debug("VisualAddons: detach farmId=%s uniqueId=%s attached=%d stillExisting=%d",
        tostring(farmId), tostring(uniqueId), total, existing)
end


--- Release the template i3ds and the per-session caches.
function RLVisualAddons.deleteMap()
    local released = 0
    for _, root in ipairs(RLVisualAddons.templateRoots) do
        if entityExists(root) then
            delete(root)
            released = released + 1
        end
    end
    Log:debug("VisualAddons: deleteMap released %d of %d template root(s)", released, #RLVisualAddons.templateRoots)
    RLVisualAddons.templateRoots = {}
    RLVisualAddons.templates = {}
    RLVisualAddons.failedTemplates = {}
    RLVisualAddons.warnedMissingBones = {}
end
