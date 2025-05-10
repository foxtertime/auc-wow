-- AuctionStats.lua  – сводка и детали лотов с поиском, статистикой, Total и подсветкой по качеству
-- Всегда полный скрипт!

-- В AuctionStats.toc:
-- ## SavedVariables: AuctionStatsDB

AuctionStatsDB = AuctionStatsDB or {}

local tinsert = table.insert
local strlower = string.lower
local format   = string.format

local AuctionStats = {
    dbAuctions     = {},
    summaryFrame   = nil,
    summaryContent = nil,
    summaryLines   = {},
    summarySearch  = nil,
    summaryStats   = nil,
    detailFrame    = nil,
    detailContent  = nil,
    detailLines    = {},
    detailSearch   = nil,
    detailStats    = nil,
    detailData     = {},
}

-- размеры окна и строк
local W, H = 1000, 650
local ROW_H, HDR_H, ICON_SIZE = 20, 20, 14

-- позиции колонок Summary
local POS_NUM    =   0
local POS_ID     =  40
local POS_ICON   = 100
local POS_NAME   = 140
local NAME_W     = 400
local POS_QTY    = POS_NAME + NAME_W + 10   -- 550
local POS_MIN    = POS_QTY  + 60            -- 610
local POS_MAX    = POS_MIN  + 120           -- 730
local POS_TOTAL  = POS_MAX  + 120           -- 850

-- позиции колонок Detail
local D_POS_NUM   =   0
local D_POS_ID    =  40
local D_POS_ICON  = 100
local D_POS_NAME  = 140
local D_NAME_W    = 400
local D_POS_LEVEL = D_POS_NAME + D_NAME_W + 10  -- 550
local D_POS_QTY   = D_POS_LEVEL + 60            -- 610
local D_POS_TIME  = D_POS_QTY + 60              -- 670
local D_POS_BUY   = D_POS_TIME + 120            -- 790
local D_POS_BID   = D_POS_BUY + 120             -- 910

-- утилиты форматирования
local function FormatMoney(c)
    local g = math.floor(c/10000)
    local s = math.floor((c%10000)/100)
    local k = c%100
    local parts = {}
    if g>0 then parts[#parts+1] = g.."|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:0:0|t" end
    if s>0 then parts[#parts+1] = s.."|TInterface\\MoneyFrame\\UI-SilverIcon:14:14:0:0|t" end
    parts[#parts+1] = k.."|TInterface\\MoneyFrame\\UI-CopperIcon:14:14:0:0|t"
    return table.concat(parts," ")
end

local TimeBands = {
    [Enum.AuctionHouseTimeLeftBand.Short]    = "30m",
    [Enum.AuctionHouseTimeLeftBand.Medium]   = "2h",
    [Enum.AuctionHouseTimeLeftBand.Long]     = "12h",
    [Enum.AuctionHouseTimeLeftBand.VeryLong] = "48h",
}
local function SecsToShort(sec)
    if not sec or sec<=0 then return "?" end
    local m = math.floor(sec/60)
    if m<60 then return m.."m" end
    local h = math.floor(m/60)
    if h<24 then return h.."h" end
    return math.floor(h/24).."d"
end

-- 1) Кэш лотов
function AuctionStats:CacheAuctions()
    self.dbAuctions = {}
    for _,info in ipairs(C_AuctionHouse.GetOwnedAuctions() or {}) do
        local key   = info.itemKey or {}
        local id    = key.itemID or 0
        local lvl   = key.itemLevel or 0
        local link  = info.itemLink or ("item:"..id)
        local name, _, quality, _, _, _, _, _, _, tex = GetItemInfo(link)
        if not name then GetItemInfo(link) end
        tinsert(self.dbAuctions, {
            itemID    = id,
            itemLevel = lvl,
            icon      = tex or "",
            name      = name or ("Item#"..id),
            link      = link,
            quality   = quality or 1,
            quantity  = info.quantity or 0,
            timeLeft  = info.timeLeftSeconds and SecsToShort(info.timeLeftSeconds)
                       or TimeBands[info.timeLeft or info.duration] or "?",
            rawBuyout = info.buyoutAmount or 0,
            buyout    = (info.buyoutAmount or 0)>0 and FormatMoney(info.buyoutAmount) or "-",
            rawBid    = info.bidAmount or 0,
            bid       = (info.bidAmount or 0)>0 and FormatMoney(info.bidAmount) or "-",
        })
    end
end

-- 2) Группировка по ID + подсчет Total
function AuctionStats:GroupAuctions()
    local groups = {}
    for _,a in ipairs(self.dbAuctions) do
        local id = a.itemID
        if not groups[id] then
            groups[id] = {
                itemID    = id,
                icon      = a.icon,
                name      = a.name,
                link      = a.link,
                quality   = a.quality,
                count     = 0,
                min_price = nil,
                max_price = nil,
                total     = 0,
                rawGroup  = {},
            }
        end
        local g = groups[id]
        g.count = g.count + 1
        g.total = g.total + a.rawBuyout
        if not g.min_price or a.rawBuyout < g.min_price then g.min_price = a.rawBuyout end
        if not g.max_price or a.rawBuyout > g.max_price then g.max_price = a.rawBuyout end
        tinsert(g.rawGroup, a)
    end
    local list = {}
    for _,g in pairs(groups) do tinsert(list,g) end
    table.sort(list, function(a,b) return a.itemID < b.itemID end)
    return list
end

-- 3) Создание окна Summary
function AuctionStats:CreateSummaryWindow()
    if self.summaryFrame then return end
    local f = CreateFrame("Frame","AuctionStatsSummaryFrame",UIParent,"BackdropTemplate")
    f:SetSize(W,H)
    f:SetPoint("CENTER")
    f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop{
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=8, right=8, top=8, bottom=8 },
    }
    -- заголовок
    f.title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    f.title:SetPoint("TOP",0,-8)
    f.title:SetText("AuctionStats: Summary")
    CreateFrame("Button",nil,f,"UIPanelCloseButton"):SetPoint("TOPRIGHT",-6,-6)

    -- поле поиска
    local sb = CreateFrame("EditBox","AuctionStatsSummarySearchBox",f,"SearchBoxTemplate")
    sb:SetSize(200,20)
    sb:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -40)
    sb:SetAutoFocus(false)
    if sb.SetPromptText then sb:SetPromptText("Поиск") end
    sb:SetScript("OnTextChanged", function(self) AuctionStats:DrawSummary() end)
    self.summarySearch = sb

    -- заголовки колонок
    local hdr = CreateFrame("Frame",nil,f)
    hdr:SetSize(W-60,HDR_H)
    hdr:SetPoint("TOPLEFT",20,-70)
    local cols = {
        {x=POS_NUM,   t="#"},
        {x=POS_ID,    t="ID"},
        {x=POS_ICON,  t="",        w=ICON_SIZE},
        {x=POS_NAME,  t="Name",    w=NAME_W},
        {x=POS_QTY,   t="Count"},
        {x=POS_MIN,   t="Min Price"},
        {x=POS_MAX,   t="Max Price"},
        {x=POS_TOTAL, t="Total"},
    }
    for _,c in ipairs(cols) do
        local fs = hdr:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        fs:SetPoint("LEFT", hdr, "LEFT", c.x, 0)
        fs:SetText(c.t)
    end

    -- scroll-контейнер
    local sc = CreateFrame("ScrollFrame","AuctionStatsSummaryScrollFrame",f,"UIPanelScrollFrameTemplate")
    sc:SetPoint("TOPLEFT",hdr,"BOTTOMLEFT",0,-4)
    sc:SetSize(W-60,H-140)
    local ct = CreateFrame("Frame",nil,sc)
    ct:SetPoint("TOPLEFT",sc,"TOPLEFT",0,0)
    ct:SetSize(W-60,ROW_H)
    sc:SetScrollChild(ct)

    -- блок статистики
    local stats = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    stats:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    self.summaryStats = stats

    self.summaryFrame   = f
    self.summaryContent = ct
end

-- 4) Рисуем Summary с фильтром и статистикой
function AuctionStats:DrawSummary()
    self:CacheAuctions()
    local groups = self:GroupAuctions()

    -- фильтрация
    local filter = strlower(self.summarySearch:GetText() or "")
    local filtered = {}
    for _,grp in ipairs(groups) do
        if filter == "" or strlower(grp.name):find(filter,1,true) then
            tinsert(filtered, grp)
        end
    end

    local ct = self.summaryContent
    ct:SetSize(W-60, #filtered * ROW_H)
    for _,ln in ipairs(self.summaryLines) do ln:Hide() end

    for i,grp in ipairs(filtered) do
        local ln = self.summaryLines[i]
        if not ln then
            ln = CreateFrame("Button",nil,ct,"BackdropTemplate")
            ln:SetSize(W-60,ROW_H)
            ln:EnableMouse(true); ln:RegisterForClicks("LeftButtonUp")
            ln.num    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.id     = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.icon   = ln:CreateTexture(nil,"ARTWORK"); ln.icon:SetSize(ICON_SIZE,ICON_SIZE)
            ln.name   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.name:SetWidth(NAME_W); ln.name:SetJustifyH("LEFT")
            ln.count  = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.min    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.max    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.total  = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.num   :SetPoint("LEFT",POS_NUM,   0)
            ln.id    :SetPoint("LEFT",POS_ID,    0)
            ln.icon  :SetPoint("LEFT",POS_ICON,  0)
            ln.name  :SetPoint("LEFT",POS_NAME,  0)
            ln.count :SetPoint("LEFT",POS_QTY,   0)
            ln.min   :SetPoint("LEFT",POS_MIN,   0)
            ln.max   :SetPoint("LEFT",POS_MAX,   0)
            ln.total :SetPoint("LEFT",POS_TOTAL, 0)
            self.summaryLines[i] = ln
        end

        ln:SetPoint("TOPLEFT", ct, "TOPLEFT", 0, -(i-1)*ROW_H)
        ln.num   :SetText(i)
        ln.id    :SetText(grp.itemID)
        ln.icon  :SetTexture(grp.icon)
        ln.name  :SetText(grp.name)
        local r,g,b = GetItemQualityColor(grp.quality)
        ln.name:SetTextColor(r,g,b)
        ln.count :SetText(grp.count)
        ln.min   :SetText(FormatMoney(grp.min_price or 0))
        ln.max   :SetText(FormatMoney(grp.max_price or 0))
        ln.total :SetText(FormatMoney(grp.total or 0))
        ln:Show()

        ln:SetScript("OnMouseUp", function(self,btn)
            if btn=="LeftButton" then AuctionStats:ShowDetail(grp) end
        end)
        ln:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(grp.link)
            GameTooltip:Show()
        end)
        ln:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- статистика
    local totalGroups = #filtered
    local totalItems  = 0
    local totalCost   = 0
    for _,g in ipairs(filtered) do
        totalItems = totalItems + g.count
        totalCost  = totalCost  + g.total
    end
    self.summaryStats:SetText(
        format("Groups: %d   Items: %d   Total: %s",
        totalGroups, totalItems, FormatMoney(totalCost))
    )

    self.summaryFrame:Show()
end

-- 5) Создание окна Detail
function AuctionStats:CreateDetailWindow()
    if self.detailFrame then return end
    local f = CreateFrame("Frame","AuctionStatsDetailFrame",UIParent,"BackdropTemplate")
    f:SetSize(W,H)
    f:SetPoint("CENTER",30,0)
    f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop{
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=8, right=8, top=8, bottom=8 },
    }
    -- заголовок
    f.title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    f.title:SetPoint("TOP",0,-8)
    f.title:SetText("Details")
    CreateFrame("Button",nil,f,"UIPanelCloseButton"):SetPoint("TOPRIGHT",-6,-6)

    -- поле поиска
    local sb = CreateFrame("EditBox","AuctionStatsDetailSearchBox",f,"SearchBoxTemplate")
    sb:SetSize(200,20)
    sb:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -40)
    sb:SetAutoFocus(false)
    if sb.SetPromptText then sb:SetPromptText("Поиск") end
    sb:SetScript("OnTextChanged", function(self) AuctionStats:DrawDetail() end)
    self.detailSearch = sb

    -- заголовки колонок
    local hdr = CreateFrame("Frame",nil,f)
    hdr:SetSize(W-60,HDR_H)
    hdr:SetPoint("TOPLEFT",20,-70)
    local cols = {
        {x=D_POS_NUM,   t="#"},
        {x=D_POS_ID,    t="ID"},
        {x=D_POS_ICON,  t="",     w=ICON_SIZE},
        {x=D_POS_NAME,  t="Name", w=D_NAME_W},
        {x=D_POS_LEVEL, t="Level"},
        {x=D_POS_QTY,   t="Qty"},
        {x=D_POS_TIME,  t="Time"},
        {x=D_POS_BUY,   t="Buyout"},
        {x=D_POS_BID,   t="Bid"},
    }
    for _,c in ipairs(cols) do
        local fs = hdr:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        fs:SetPoint("LEFT", hdr, "LEFT", c.x, 0)
        fs:SetText(c.t)
    end

    -- scroll-контейнер
    local sc = CreateFrame("ScrollFrame","AuctionStatsDetailScrollFrame",f,"UIPanelScrollFrameTemplate")
    sc:SetPoint("TOPLEFT",hdr,"BOTTOMLEFT",0,-4)
    sc:SetSize(W-60,H-140)
    local ct = CreateFrame("Frame",nil,sc)
    ct:SetPoint("TOPLEFT",sc,"TOPLEFT",0,0)
    ct:SetSize(W-60,ROW_H)
    sc:SetScrollChild(ct)

    -- блок статистики
    local stats = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    stats:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    self.detailStats = stats

    self.detailFrame   = f
    self.detailContent = ct
end

-- 6) Рисуем Detail с фильтром и статистикой
function AuctionStats:DrawDetail()
    -- применяем данные
    local list = self.detailData or {}

    -- фильтрация
    local filter = strlower(self.detailSearch:GetText() or "")
    local filtered = {}
    for _,a in ipairs(list) do
        if filter == "" or strlower(a.name):find(filter,1,true) then
            tinsert(filtered, a)
        end
    end

    local ct = self.detailContent
    ct:SetSize(W-60, #filtered * ROW_H)
    for _,ln in ipairs(self.detailLines) do ln:Hide() end

    for i,a in ipairs(filtered) do
        local ln = self.detailLines[i]
        if not ln then
            ln = CreateFrame("Frame",nil,ct)
            ln:SetSize(W-60,ROW_H)
            ln.num   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.id    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.icon  = ln:CreateTexture(nil,"ARTWORK"); ln.icon:SetSize(ICON_SIZE,ICON_SIZE)
            ln.name  = ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.name:SetWidth(D_NAME_W); ln.name:SetJustifyH("LEFT")
            ln.level = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.qty   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.tl    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.bo    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.bd    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.num  :SetPoint("LEFT",D_POS_NUM,   0)
            ln.id   :SetPoint("LEFT",D_POS_ID,    0)
            ln.icon :SetPoint("LEFT",D_POS_ICON,  0)
            ln.name :SetPoint("LEFT",D_POS_NAME,  0)
            ln.level:SetPoint("LEFT",D_POS_LEVEL,0)
            ln.qty  :SetPoint("LEFT",D_POS_QTY,   0)
            ln.tl   :SetPoint("LEFT",D_POS_TIME,  0)
            ln.bo   :SetPoint("LEFT",D_POS_BUY,   0)
            ln.bd   :SetPoint("LEFT",D_POS_BID,   0)
            self.detailLines[i] = ln
        end

        ln:SetPoint("TOPLEFT", ct, "TOPLEFT", 0, -(i-1)*ROW_H)
        ln.num  :SetText(i)
        ln.id   :SetText(a.itemID)
        ln.icon :SetTexture(a.icon)
        ln.name :SetText(a.name)
        local r,g,b = GetItemQualityColor(a.quality)
        ln.name:SetTextColor(r,g,b)
        ln.level:SetText(a.itemLevel or "")
        ln.qty  :SetText(a.quantity)
        ln.tl   :SetText(a.timeLeft)
        ln.bo   :SetText(a.buyout)
        ln.bd   :SetText(a.bid)
        ln:Show()

        local link = a.link
        ln:EnableMouse(true)
        ln:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
        end)
        ln:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- статистика
    local itemCount = #filtered
    local totalCost = 0
    for _,a in ipairs(filtered) do totalCost = totalCost + a.rawBuyout end
    self.detailStats:SetText(
        format("Items: %d   Total: %s", itemCount, FormatMoney(totalCost))
    )

    self.detailFrame:Show()
end

-- 7) Открыть Detail
function AuctionStats:ShowDetail(group)
    self:CreateDetailWindow()
    self.detailFrame.title:SetText("Details: "..group.name)
    self.detailData = {}
    for _,a in ipairs(group.rawGroup) do
        tinsert(self.detailData, a)
    end
    self:DrawDetail()
end

-- 8) События
local handler = CreateFrame("Frame")
handler:RegisterEvent("AUCTION_HOUSE_SHOW")
handler:RegisterEvent("OWNED_AUCTIONS_UPDATED")
handler:SetScript("OnEvent", function(_, e)
    if e=="AUCTION_HOUSE_SHOW" then
        C_AuctionHouse.QueryOwnedAuctions({})
    elseif e=="OWNED_AUCTIONS_UPDATED" then
        if AuctionStats.summaryFrame and AuctionStats.summaryFrame:IsShown() then
            AuctionStats:DrawSummary()
        end
        if AuctionStats.detailFrame and AuctionStats.detailFrame:IsShown() then
            AuctionStats:DrawDetail()
        end
    end
end)

-- 9) Slash-команда
SLASH_AUCTIONSTATS1 = "/astat"
SlashCmdList["AUCTIONSTATS"] = function()
    AuctionStats:CreateSummaryWindow()
    AuctionStats:DrawSummary()
end
