-- ============================================================================
-- BG3Access Server Bootstrap
--
-- Handles server-side operations that the client cannot perform
-- directly due to BG3's client/server architecture split.
--
-- Currently: template data lookup for entity classification.
-- Templates (GameObjectTemplate / ItemTemplate / CharacterTemplate)
-- are loaded into the server's template banks (root, local, cache)
-- when a level loads.  The client only has access to root templates
-- via Ext.Template.GetRootTemplate, but level-local templates
-- (which most in-world entities use) are server-only.  This script
-- bridges that gap by looking up templates on the server and
-- sending the classification-relevant fields to the client.
-- ============================================================================

local CHANNEL_REQUEST  = "BG3Access_ClassifyRequest"
local CHANNEL_RESPONSE = "BG3Access_ClassifyResponse"

_P("BG3Access: BootstrapServer.lua loaded")

--- Handle a classification request from the client.
--- Payload is a JSON array of entity UUID strings.
--- For each UUID, the server:
---   1. Gets the entity via Ext.Entity.Get(uuid)
---   2. Checks key components (InventoryOwner, CanBeLooted, etc.)
---   3. Gets the template via OriginalTemplate -> GetTemplate
---   4. Reads template + stats fields
--- Response is keyed by UUID with all classification signals.
Ext.RegisterNetListener(CHANNEL_REQUEST, function(channel, payload, userId)
    local ok, uuids = pcall(Ext.Json.Parse, payload)
    if not ok or type(uuids) ~= "table" then
        _P("BG3Access Server: bad classify request payload")
        return
    end

    local results = {}
    for _, uuid in ipairs(uuids) do
        local uuidStr = tostring(uuid)
        local entry = {}

        -- Step 1: Get the entity and check components.
        local okEntity, entity = pcall(Ext.Entity.Get, uuidStr)
        if okEntity and entity then
            -- Component presence checks.  These are the
            -- AUTHORITATIVE signals for classification.
            -- Get ALL components via GetAllComponents (proven to
            -- work in the entity dump diagnostic).  Then check
            -- for the presence of classification-relevant ones.
            -- The keys in the returned table are ExtComponentType
            -- values; tostring() gives us the component name.
            local okComps, allComponents = pcall(
                entity.GetAllComponents, entity, false)
            if okComps and allComponents then
                local componentSet = {}
                for componentType, _ in pairs(allComponents) do
                    componentSet[tostring(componentType)] = true
                end
                -- Check classification-relevant components.
                local wantedComponents = {
                    "InventoryOwner",
                    "CanBeLooted",
                    "CanBeInInventory",
                    "IsCharacter",
                    "IsDoor",
                    "Health",
                    "Use",
                    "Death",
                    "DeathState",
                    "CanBeWielded",
                    "Equipable",
                    "Weapon",
                    "ObjectInteraction",
                    "HasGeneratedTreasure",
                }
                for _, compName in ipairs(wantedComponents) do
                    if componentSet[compName] then
                        entry["has_" .. compName] = true
                    end
                end
            end

            -- Get template GUID from entity.
            local templateGuid = nil
            pcall(function()
                local tmplComp = entity.OriginalTemplate
                if tmplComp then
                    templateGuid = tostring(
                        tmplComp.OriginalTemplate)
                end
            end)

            -- Step 2: Get the template.
            local template = nil
            if templateGuid and templateGuid ~= ""
                and templateGuid ~= "nil" then
                local okTmpl, tmpl = pcall(
                    Ext.Template.GetTemplate, templateGuid)
                if okTmpl and tmpl then
                    template = tmpl
                end
            end

            if not template then
                results[uuidStr] = entry
            else
            -- Read classification fields into the EXISTING entry
            -- (which already has has_* component signals from
            -- the GetAllComponents check above).  Do NOT re-declare
            -- entry here — that was a variable shadowing bug that
            -- wiped out all component signals.

            -- Boolean fields: read and force to true/false.
            local boolFields = {
                "CanBePickedUp", "StoryItem", "IsKey", "IsPortal",
                "IsTrap", "Hostile", "TreasureOnDestroy",
                "IsSourceContainer",
            }
            for _, fieldName in ipairs(boolFields) do
                local okF, fv = pcall(function()
                    return template[fieldName]
                end)
                if okF and fv == true then
                    entry[fieldName] = true
                end
            end

            -- String/enum fields: force tostring, skip empty.
            local stringFields = { "InventoryType", "BookType" }
            for _, fieldName in ipairs(stringFields) do
                local okF, fv = pcall(function()
                    return template[fieldName]
                end)
                if okF and fv ~= nil then
                    local s = tostring(fv)
                    if s ~= "" and s ~= "nil" then
                        entry[fieldName] = s
                    end
                end
            end

            -- InventoryList: send the count, not the full list.
            local okIL, il = pcall(function()
                return template.InventoryList
            end)
            if okIL and il then
                local okLen, len = pcall(function() return #il end)
                if okLen and type(len) == "number" then
                    entry.InventoryListCount = len
                end
            end

            -- Stats entry name from the template.
            local okStats, statsVal = pcall(function()
                return template.Stats
            end)
            if okStats and statsVal ~= nil then
                local s = tostring(statsVal)
                if s ~= "" and s ~= "nil" then
                    entry.Stats = s
                end
            end

            -- OnUsePeaceActions: send the count as a signal that
            -- the entity has interaction actions (Open, Use, etc.).
            local okActions, actions = pcall(function()
                return template.OnUsePeaceActions
            end)
            if okActions and actions then
                local okALen, aLen = pcall(function()
                    return #actions
                end)
                if okALen and type(aLen) == "number" then
                    entry.UseActionCount = aLen
                end
            end

            -- Entity component signals: probe the ENTITY (not the
            -- template) for components that definitively classify
            -- it.  These are server-only components the client
            -- cannot see.
            --
            -- InventoryOwner: THE container signal.  Every
            -- lootable container (chests, corpses, pods, barrels)
            -- has it.  Nothing else does.
            --
            -- CanBeInInventory: pickable items the player can
            -- carry.  CanBeLooted: the entity presents a loot UI.
            local entityForGuid = nil
            pcall(function()
                -- Look up the actual entity on the server by UUID
                -- so we can check its components directly.
                -- The template GUID and the entity UUID are
                -- different — we need the entity's Uuid component.
                -- For now, we check the template-level signals
                -- (already captured above) and add entity-level
                -- signals via a secondary lookup if available.
            end)

            -- Since we receive TEMPLATE GUIDs (not entity UUIDs),
            -- we can't directly look up the entity here.  Instead,
            -- we'll add the entity component signals in a separate
            -- channel.  For now, mark which template fields serve
            -- as container proxies.

            -- Template type name: force tostring, skip nil.
            local okType, typeName = pcall(function()
                return template.TemplateName
            end)
            if okType and typeName ~= nil then
                local s = tostring(typeName)
                if s ~= "" and s ~= "nil" then
                    entry.TemplateName = s
                end
            end

            -- Stats classification: if the template has a Stats
            -- field, look up the stats entry and read the game's
            -- own InventoryTab / ObjectCategory / ItemUseType.
            -- These are the AUTHORITATIVE classification signals
            -- that BG3 uses to decide which UI tab an item
            -- belongs to.  Reading stats on the server avoids the
            -- debug-build se_assert crash that happens on the
            -- client when accessing attributes on stats entries
            -- whose ModifierList doesn't include the field.
            if entry.Stats and entry.Stats ~= "" then
                local okStat, statEntry = pcall(
                    Ext.Stats.Get, entry.Stats)
                if okStat and statEntry then
                    -- ModifierList: safe first-class property
                    -- (P_FREE_GETTER, not a stats attribute).
                    -- Reading it never triggers se_assert.
                    local modifierList = ""
                    local okML, ml = pcall(function()
                        return statEntry.ModifierList
                    end)
                    if okML and ml then
                        modifierList = tostring(ml)
                        if modifierList ~= "" and modifierList ~= "nil" then
                            entry.StatsModifierList = modifierList
                        end
                    end

                    -- CRITICAL: InventoryTab, ObjectCategory, and
                    -- ItemUseType are ONLY valid on Object-type
                    -- stats entries.  Reading them on Character,
                    -- Weapon, or Armor entries triggers se_assert
                    -- -> abort() in debug builds.  pcall does NOT
                    -- catch abort().  Gate ALL schema-specific
                    -- reads behind the ModifierList check.
                    if modifierList == "Object" then
                        local okIT, it = pcall(function()
                            return statEntry.InventoryTab
                        end)
                        if okIT and it ~= nil then
                            local s = tostring(it)
                            if s ~= "" and s ~= "nil" then
                                entry.StatsInventoryTab = s
                            end
                        end

                        local okOC, oc = pcall(function()
                            return statEntry.ObjectCategory
                        end)
                        if okOC and oc ~= nil then
                            local s = tostring(oc)
                            if s ~= "" and s ~= "nil" then
                                entry.StatsObjectCategory = s
                            end
                        end

                        local okIUT, iut = pcall(function()
                            return statEntry.ItemUseType
                        end)
                        if okIUT and iut ~= nil then
                            local s = tostring(iut)
                            if s ~= "" and s ~= "nil" then
                                entry.StatsItemUseType = s
                            end
                        end
                    end
                end
            end

            results[uuidStr] = entry
            end -- if template
        end -- if entity
    end -- for each uuid

    -- Send the response back to the requesting client.
    -- BroadcastMessage sends to all clients; in single-player
    -- there is only one client so this is equivalent to a
    -- targeted send without needing the userId/peerId lookup.
    local responsePayload = Ext.Json.Stringify(results)
    Ext.ServerNet.BroadcastMessage(CHANNEL_RESPONSE, responsePayload)
end)

_P("BG3Access: Server classify listener registered on '"
    .. CHANNEL_REQUEST .. "'")
