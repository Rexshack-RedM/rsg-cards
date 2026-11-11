local RSGCore = exports['rsg-core']:GetCoreObject()
local Inventory = exports['rsg-inventory']

local SHOP_NAME = 'cardcollect'

local function getLocation(src, id)
    for _, location in ipairs(Config.Shop.Locations) do
        if location.id == id then
            return CardsServer.isNear(src, location.coords, Config.Shop.InteractDistance) and location or nil
        end
    end
end

-- everything the player carries that the vendor buys, in set order
local function sellableItems(src)
    local list = {}
    for name, amount in pairs(CardsServer.countCards(src)) do
        if amount > 0 then
            local info = Cards.Info[name]
            list[#list + 1] = {
                name = name,
                label = CardsServer.itemLabel(name),
                image = CardsServer.itemImage(name),
                amount = amount,
                price = info.price,
                order = info.order,
            }
        end
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

local function pay(Player, total, reason)
    Player.Functions.AddMoney(Config.Shop.Payment, total, reason)
end

RSGCore.Functions.CreateCallback('rsg-cards:server:getVendor', function(source, cb, shopId)
    if not RSGCore.Functions.GetPlayer(source) or not getLocation(source, shopId) then return cb(false) end
    cb({ items = sellableItems(source) })
end)

RSGCore.Functions.CreateCallback('rsg-cards:server:sell', function(source, cb, shopId, name, amount)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not getLocation(src, shopId) then return cb(false) end
    if not CardsServer.throttle(src, 'sell', 1) then return cb(false) end

    local info = type(name) == 'string' and Cards.Info[name]
    amount = tonumber(amount)
    if not info or not amount or amount < 1 or amount ~= math.floor(amount) then return cb(false) end
    amount = math.floor(amount)

    local owned = CardsServer.countCards(src)[name] or 0
    if amount > owned or not Inventory:RemoveItem(src, name, amount, nil, 'rsg-cards:sell') then
        return cb({ message = locale('sell_not_enough'), type = 'error', items = sellableItems(src) })
    end

    local total = CardsServer.round(info.price * amount)
    pay(Player, total, 'rsg-cards:sell')
    CardsServer.log(('**Cards sold**\n%s\n%dx %s for $%.2f'):format(CardsServer.playerTag(Player), amount, name, total))

    cb({
        message = locale('sell_success', amount, CardsServer.itemLabel(name), ('%.2f'):format(total)),
        type = 'success',
        items = sellableItems(src),
    })
end)

RSGCore.Functions.CreateCallback('rsg-cards:server:sellAll', function(source, cb, shopId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not getLocation(src, shopId) then return cb(false) end
    if not CardsServer.throttle(src, 'sell', 1) then return cb(false) end

    local total, sold = 0, 0
    for name, amount in pairs(CardsServer.countCards(src)) do
        if amount > 0 and Inventory:RemoveItem(src, name, amount, nil, 'rsg-cards:sell-all') then
            total = total + Cards.Info[name].price * amount
            sold = sold + amount
        end
    end

    if sold == 0 then
        return cb({ message = locale('sell_nothing'), type = 'error', items = sellableItems(src) })
    end

    total = CardsServer.round(total)
    pay(Player, total, 'rsg-cards:sell-all')
    CardsServer.log(('**Cards sold (all)**\n%s\n%d items for $%.2f'):format(CardsServer.playerTag(Player), sold, total))

    cb({
        message = locale('sell_all_success', sold, ('%.2f'):format(total)),
        type = 'success',
        items = sellableItems(src),
    })
end)

---------------------------------------------------------------------
-- BUY (rsg-inventory shop)
---------------------------------------------------------------------
CreateThread(function()
    Inventory:CreateShop({
        name = SHOP_NAME,
        label = locale('vendor_title'),
        slots = #Config.Shop.Items,
        items = Config.Shop.Items,
        persistentStock = Config.Shop.PersistStock,
    })
end)

RegisterNetEvent('rsg-cards:server:openShop', function(shopId)
    local src = source
    if not RSGCore.Functions.GetPlayer(src) or not getLocation(src, shopId) then return end
    Inventory:OpenShop(src, SHOP_NAME)
end)
