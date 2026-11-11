local RSGCore = exports['rsg-core']:GetCoreObject()
local Inventory = exports['rsg-inventory']

-- Helpers shared with the other server files
CardsServer = {}

local dbReady = false
local throttles = {}    -- [src] = { [key] = os.time() }
local pendingPacks = {} -- [src] = { cards = { itemName, ... }, revealed = { [index] = true }, left = number }
local pickups = {}      -- [citizenid] = { [itemName] = os.time() of the last pickup }

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------
function CardsServer.notify(src, description, notifyType)
    TriggerClientEvent('RSGCore:Client:Notify', src, {
        title = locale('title'),
        description = description,
        type = notifyType or 'inform',
        duration = 5000,
    })
end

function CardsServer.log(message)
    TriggerEvent('rsg-log:server:CreateLog', Config.Webhook.Name, Config.Webhook.Title, Config.Webhook.Colour, message, false)
end

function CardsServer.playerTag(Player)
    local data = Player.PlayerData
    return ('%s %s (%s)'):format(data.charinfo.firstname, data.charinfo.lastname, data.citizenid)
end

function CardsServer.isNear(src, coords, radius)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - vector3(coords.x, coords.y, coords.z)) <= radius
end

-- returns true when the action is allowed (at most once every `seconds` per player)
function CardsServer.throttle(src, key, seconds)
    local now = os.time()
    throttles[src] = throttles[src] or {}
    local last = throttles[src][key]
    if last and now - last < seconds then return false end
    throttles[src][key] = now
    return true
end

function CardsServer.itemLabel(name)
    local item = RSGCore.Shared.Items[name]
    return item and item.label or name
end

function CardsServer.itemImage(name)
    local item = RSGCore.Shared.Items[name]
    return item and item.image or (name .. '.png')
end

function CardsServer.round(value)
    return math.floor(value * 100 + 0.5) / 100
end

-- { [itemName] = amount } of every card / set the player carries
function CardsServer.countCards(src)
    local Player = RSGCore.Functions.GetPlayer(src)
    local counts = {}
    if not Player then return counts end
    for _, item in pairs(Player.PlayerData.items or {}) do
        if item and Cards.Info[item.name] then
            counts[item.name] = (counts[item.name] or 0) + (tonumber(item.amount) or 0)
        end
    end
    return counts
end

local function debugPrint(...)
    if Config.Debug then print('[rsg-cards]', ...) end
end

---------------------------------------------------------------------
-- DATABASE
---------------------------------------------------------------------
local function tableExists(name)
    local count = MySQL.scalar.await(
        'SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name })
    return (tonumber(count) or 0) > 0
end

-- Keep these statements identical to install.sql
local function ensureDatabase()
    local ok, err = pcall(function()
        -- boxes created before the resource was renamed to rsg-cards
        if tableExists('hdrp_boxes') and not tableExists('rsg_cards_boxes') then
            MySQL.query.await('RENAME TABLE `hdrp_boxes` TO `rsg_cards_boxes`')
        end

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `rsg_cards_boxes` (
                `serial`  VARCHAR(20) NOT NULL,
                `creator` VARCHAR(50) NOT NULL,
                `owner`   VARCHAR(50) NOT NULL,
                PRIMARY KEY (`serial`),
                INDEX `idx_creator` (`creator`),
                INDEX `idx_owner` (`owner`)
            )
        ]])

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `rsg_cards_collection` (
                `citizenid`   VARCHAR(50) NOT NULL,
                `card`        VARCHAR(50) NOT NULL,
                `obtained_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`, `card`)
            )
        ]])

        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS `rsg_cards_pickups` (
                `citizenid` VARCHAR(50) NOT NULL,
                `card`      VARCHAR(50) NOT NULL,
                `picked_at` INT UNSIGNED NOT NULL,
                PRIMARY KEY (`citizenid`, `card`)
            )
        ]])
    end)

    if not ok then
        print(('^1[rsg-cards] database setup failed: %s^7'):format(err))
        return false
    end
    print('^2[rsg-cards] database tables ready^7')
    return true
end

local function checkItems()
    local missing = {}
    local names = { Config.Items.Pack, Config.Items.Box }
    for name in pairs(Cards.Info) do names[#names + 1] = name end
    for _, name in ipairs(names) do
        if not RSGCore.Shared.Items[name] then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        table.sort(missing)
        print(('^1[rsg-cards] %d item(s) missing from rsg-core shared items (see installation/shared_items.lua): %s%s^7')
            :format(#missing, table.concat(missing, ', ', 1, math.min(#missing, 5)), #missing > 5 and ', ...' or ''))
    end
end

CreateThread(function()
    math.randomseed(os.time())
    checkItems()
    if Config.AutoDatabase and not ensureDatabase() then return end
    dbReady = true
end)

---------------------------------------------------------------------
-- COLLECTION (which cards a character has ever found)
---------------------------------------------------------------------
-- returns isNew, collected
local function recordCard(Player, card)
    if not dbReady then return false, nil end
    local citizenid = Player.PlayerData.citizenid
    local ok, isNew, collected = pcall(function()
        local added = MySQL.update.await(
            'INSERT IGNORE INTO `rsg_cards_collection` (`citizenid`, `card`) VALUES (?, ?)', { citizenid, card })
        if (tonumber(added) or 0) < 1 then return false, nil end
        local count = MySQL.scalar.await(
            'SELECT COUNT(*) FROM `rsg_cards_collection` WHERE `citizenid` = ?', { citizenid })
        return true, tonumber(count) or 0
    end)
    if not ok then
        debugPrint('collection update failed:', isNew)
        return false, nil
    end
    return isNew, collected
end

-- Gives one card (or complete set) and returns the data the UI needs to show it, or false.
local function grantCard(src, card, reason)
    local Player = RSGCore.Functions.GetPlayer(src)
    local info = Cards.Info[card]
    if not Player or not info then return false end

    local added = Inventory:CanAddItem(src, card, 1) and Inventory:AddItem(src, card, 1, nil, nil, reason)
    if not added then
        -- no room: drop it at the player's feet rather than losing it
        local dropped = pcall(function() Inventory:ForceDropItem(src, card, 1, nil, reason) end)
        CardsServer.notify(src, locale(dropped and 'inventory_full_dropped' or 'inventory_full'), 'error')
        if not dropped then return false end
    end

    local isNew, collected = false, nil
    if not info.deck then
        isNew, collected = recordCard(Player, card)
        if isNew and collected and collected >= Cards.Total then
            CardsServer.notify(src, locale('collection_complete'), 'success')
            CardsServer.log(('**Collection complete**\n%s has found all %d cards'):format(CardsServer.playerTag(Player), Cards.Total))
        end
    end

    return {
        item = card,
        label = CardsServer.itemLabel(card),
        image = CardsServer.itemImage(card),
        tier = info.tier,
        deck = info.deck == true,
        isNew = isNew,
        collected = collected,
        total = Cards.Total,
    }
end

---------------------------------------------------------------------
-- CARD PACKS
---------------------------------------------------------------------
local totalWeight = 0
for _, chance in ipairs(Config.Pack.Chances) do
    totalWeight = totalWeight + math.max(0, math.floor(chance.weight))
end

local function rollCard()
    if totalWeight > 0 then
        local roll = math.random(totalWeight)
        for _, chance in ipairs(Config.Pack.Chances) do
            roll = roll - math.max(0, math.floor(chance.weight))
            if roll <= 0 then
                local pool = chance.tier == 'deck' and Cards.Decks or Cards.ByTier[chance.tier]
                if pool and #pool > 0 then return pool[math.random(#pool)] end
                break
            end
        end
    end
    return Cards.List[math.random(#Cards.List)]
end

-- Gives every card the player has not turned over yet (UI closed early, disconnect, restart)
local function finishPack(src)
    local pack = pendingPacks[src]
    if not pack then return end
    pendingPacks[src] = nil
    for index, card in ipairs(pack.cards) do
        if not pack.revealed[index] then
            grantCard(src, card, 'rsg-cards:pack')
        end
    end
end

RSGCore.Functions.CreateUseableItem(Config.Items.Pack, function(source, item)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    if not CardsServer.throttle(src, 'pack', 2) then return end

    finishPack(src) -- a previous pack that was never closed

    if not Inventory:RemoveItem(src, Config.Items.Pack, 1, item and item.slot, 'rsg-cards:open-pack') then
        return CardsServer.notify(src, locale('no_pack'), 'error')
    end

    local cards = {}
    for i = 1, Config.Pack.Cards do cards[i] = rollCard() end
    pendingPacks[src] = { cards = cards, revealed = {}, left = #cards }

    debugPrint(('%s opened a pack: %s'):format(Player.PlayerData.citizenid, table.concat(cards, ', ')))
    CardsServer.log(('**Pack opened**\n%s\n%s'):format(CardsServer.playerTag(Player), table.concat(cards, ', ')))
    TriggerClientEvent('rsg-cards:client:openPack', src, #cards)
end)

-- The player turned over card `index` of the open pack
RSGCore.Functions.CreateCallback('rsg-cards:server:flipCard', function(source, cb, index)
    local pack = pendingPacks[source]
    index = tonumber(index)
    if not pack or not index or not pack.cards[index] or pack.revealed[index] then return cb(false) end

    pack.revealed[index] = true
    pack.left = pack.left - 1
    local card = pack.cards[index]
    if pack.left <= 0 then pendingPacks[source] = nil end

    cb(grantCard(source, card, 'rsg-cards:pack'))
end)

RegisterNetEvent('rsg-cards:server:closePack', function()
    finishPack(source)
end)

---------------------------------------------------------------------
-- CARDS IN THE WORLD
---------------------------------------------------------------------
local function loadPickups(citizenid)
    if pickups[citizenid] then return pickups[citizenid] end
    local list = {}
    if dbReady then
        local ok, rows = pcall(MySQL.query.await,
            'SELECT `card`, `picked_at` FROM `rsg_cards_pickups` WHERE `citizenid` = ?', { citizenid })
        if ok and rows then
            for _, row in ipairs(rows) do list[row.card] = tonumber(row.picked_at) end
        end
    end
    pickups[citizenid] = list
    return list
end

-- { [itemName] = seconds left } for every card the player still has on cooldown
RSGCore.Functions.CreateCallback('rsg-cards:server:getPickups', function(source, cb)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return cb({}) end

    local now, cooldown, remaining = os.time(), Config.Card.Cooldown * 60, {}
    for card, pickedAt in pairs(loadPickups(Player.PlayerData.citizenid)) do
        local left = cooldown - (now - pickedAt)
        if left > 0 then remaining[card] = left end
    end
    cb(remaining)
end)

RSGCore.Functions.CreateCallback('rsg-cards:server:pickupCard', function(source, cb, index)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    local point = Config.CardPoints[tonumber(index) or 0]
    if not Player or not point or not Cards.Info[point.item] then return cb(false) end
    if not CardsServer.throttle(src, 'pickup', 2) then return cb(false) end
    if not CardsServer.isNear(src, point.coords, Config.Card.PickupDistance + 3.0) then return cb(false) end

    local citizenid = Player.PlayerData.citizenid
    local list = loadPickups(citizenid)
    local now, cooldown = os.time(), Config.Card.Cooldown * 60
    local left = list[point.item] and (cooldown - (now - list[point.item])) or 0
    if left > 0 then
        CardsServer.notify(src, locale('pickup_cooldown', math.ceil(left / 60)), 'error')
        return cb({ cooldown = left })
    end

    if not Inventory:CanAddItem(src, point.item, 1) then
        CardsServer.notify(src, locale('inventory_full'), 'error')
        return cb(false)
    end

    -- set the cooldown before giving the card so a second request can't slip through
    list[point.item] = now
    local result = grantCard(src, point.item, 'rsg-cards:pickup')
    if not result then
        list[point.item] = nil
        return cb(false)
    end

    if dbReady then
        MySQL.query(
            'INSERT INTO `rsg_cards_pickups` (`citizenid`, `card`, `picked_at`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE `picked_at` = VALUES(`picked_at`)',
            { citizenid, point.item, now })
    end

    result.cooldown = cooldown
    cb(result)
end)

---------------------------------------------------------------------
-- INSPECT A CARD (use it from the inventory)
---------------------------------------------------------------------
for _, card in ipairs(Cards.List) do
    RSGCore.Functions.CreateUseableItem(card, function(source)
        if not RSGCore.Functions.GetPlayer(source) then return end
        TriggerClientEvent('rsg-cards:client:inspectCard', source, card)
    end)
end

---------------------------------------------------------------------
-- CARD STORAGE BOX
---------------------------------------------------------------------
local function generateSerial()
    return (RSGCore.Shared.RandomInt(4) .. RSGCore.Shared.RandomStr(3) .. RSGCore.Shared.RandomInt(3) .. RSGCore.Shared.RandomStr(3)):upper()
end

local function createUniqueSerial()
    for _ = 1, 10 do
        local serial = generateSerial()
        local exists = MySQL.scalar.await('SELECT 1 FROM `rsg_cards_boxes` WHERE `serial` = ? LIMIT 1', { serial })
        if not exists then return serial end
    end
end

RSGCore.Functions.CreateUseableItem(Config.Items.Box, function(source, item)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not item or not item.slot then return end
    if not CardsServer.throttle(src, 'box', 1) then return end
    if not dbReady then return CardsServer.notify(src, locale('box_error'), 'error') end

    local citizenid = Player.PlayerData.citizenid
    local info = type(item.info) == 'table' and item.info or {}
    local serial = info.serie

    if type(serial) ~= 'string' or not serial:match('^%w+$') then
        -- first use: give the box its own serial number (this is what its contents are stored under)
        local ok, newSerial = pcall(function()
            local generated = createUniqueSerial()
            if not generated then return nil end
            MySQL.insert.await('INSERT INTO `rsg_cards_boxes` (`serial`, `creator`, `owner`) VALUES (?, ?, ?)',
                { generated, citizenid, citizenid })
            return generated
        end)
        if not ok or not newSerial then return CardsServer.notify(src, locale('box_error'), 'error') end

        serial = newSerial
        info.serie = serial
        Inventory:SetItemInfo(src, item.slot, info)
        CardsServer.notify(src, locale('box_registered', serial), 'success')
        CardsServer.log(('**Box created**\n%s\nSerial: %s'):format(CardsServer.playerTag(Player), serial))
    else
        MySQL.update('UPDATE `rsg_cards_boxes` SET `owner` = ? WHERE `serial` = ?', { citizenid, serial })
    end

    Inventory:OpenInventory(src, 'box_' .. serial, {
        label = locale('box_label', serial),
        maxweight = Config.Storage.MaxWeight,
        slots = Config.Storage.MaxSlots,
    })
end)

---------------------------------------------------------------------
-- CLEANUP
---------------------------------------------------------------------
AddEventHandler('playerDropped', function()
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if Player then
        pickups[Player.PlayerData.citizenid] = nil
        finishPack(src)
    elseif pendingPacks[src] then
        print(('^3[rsg-cards] player %s left with unopened pack cards: %s^7'):format(src, table.concat(pendingPacks[src].cards, ', ')))
        pendingPacks[src] = nil
    end
    throttles[src] = nil
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for src in pairs(pendingPacks) do finishPack(src) end
end)
