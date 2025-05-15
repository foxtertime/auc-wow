-- AuctionStats.lua – полный код аддона, с сохранением LastSync между сессиями,
-- столбцами Type/Subtype, обработкой почты и статистикой в детализации

-- В AuctionStats.toc:
-- ## SavedVariables: AuctionStatsDB

AuctionStatsDB = AuctionStatsDB or {
    storedAuctions  = {},
    history         = {},
    lastSyncTime    = nil,
    processedMails  = {},
}

local tinsert  = table.insert
local strlower = string.lower
local format   = string.format
local date     = date
local print    = print

local AuctionStats = {
    dbAuctions       = {},
    lastSyncTime     = AuctionStatsDB.lastSyncTime,

    -- summary UI
    summaryFrame         = nil,
    summarySearch        = nil,
    summaryActiveLabel   = nil,
    summaryActiveHdr     = nil,
    summaryActiveScroll  = nil,
    summaryActiveContent = nil,
    summaryActiveLines   = {},
    summaryInactiveLabel   = nil,
    summaryInactiveHdr     = nil,
    summaryInactiveScroll  = nil,
    summaryInactiveContent = nil,
    summaryInactiveLines   = {},
    summaryStats         = nil,

    -- detail UI
    detailFrame      = nil,
    detailSearch     = nil,
    detailContent    = nil,
    detailLines      = {},
    historyContent   = nil,
    historyLines     = {},
    historyStats     = nil,
    detailStats      = nil,
    detailData       = {},
}

-- размеры окна и строк
local W, H         = 1000, 650
local ROW_H, HDR_H = 20, 20
local ICON_SIZE    = 14

-- позиции колонок Summary
local POS_NUM, POS_ID, POS_ICON, POS_NAME = 0, 40, 100, 140
local NAME_W                              = 400
local POS_TYPE    = POS_NAME + NAME_W + 10
local TYPE_W      = 100
local POS_SUBTYPE = POS_TYPE + TYPE_W + 10
local POS_QTY     = POS_SUBTYPE + TYPE_W + 10
local POS_MIN     = POS_QTY  + 60
local POS_MAX     = POS_MIN  + 120
local POS_TOTAL   = POS_MAX  + 120

-- позиции колонок Detail
local D_POS_NUM, D_POS_ID, D_POS_ICON, D_POS_NAME = 0,40,100,140
local D_NAME_W = 400
local D_POS_LEVEL = D_POS_NAME + D_NAME_W + 10
local D_POS_QTY   = D_POS_LEVEL + 60
local D_POS_TIME  = D_POS_QTY + 60
local D_POS_BUY   = D_POS_TIME + 120
local D_POS_BID   = D_POS_BUY + 120

-- позиции колонок History
local H_POS_NUM       = 0
local H_POS_TIME      = 40
local H_POS_QTY       = 260
local H_POS_PRICE     = 340
local H_POS_DUR       = 480
local H_POS_STATUS    = H_POS_DUR + 80

-- маппинг длительности в часы
local DurationHours = { [1]=12, [2]=24, [3]=48 }

-- утилиты форматирования денег
local function FormatMoney(c)
    local g = math.floor(c/10000)
    local s = math.floor((c%10000)/100)
    local k = c%100
    local parts = {}
    if g>0 then tinsert(parts, g.."|TInterface\\MoneyFrame\\UI-GoldIcon:14:14|t") end
    if s>0 then tinsert(parts, s.."|TInterface\\MoneyFrame\\UI-SilverIcon:14:14|t") end
    tinsert(parts, k.."|TInterface\\MoneyFrame\\UI-CopperIcon:14:14|t")
    return table.concat(parts," ")
end

-- утилиты форматирования времени
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

-- 1) Запись истории операций
function AuctionStats:RecordHistory(itemKey, quantity, rawBuyout, durationCode, status)
    local id = itemKey and itemKey.itemID or 0
    if id<=0 then return end
    AuctionStatsDB.history[id] = AuctionStatsDB.history[id] or {}
    tinsert(AuctionStatsDB.history[id], {
        time         = date("%Y-%m-%d %H:%M:%S", GetServerTime()),
        quantity     = quantity,
        rawBuyout    = rawBuyout,
        buyout       = rawBuyout>0 and FormatMoney(rawBuyout) or "-",
        durationCode = durationCode,
        status       = status,
    })
    print(format("AuctionStats: History recorded for %d x%d status=%s", id, quantity, status))
end

-- 2) Хуки Auction House API
hooksecurefunc(C_AuctionHouse, "PostCommodity", function(itemLocation, duration, quantity, unitPrice)
    local key = C_AuctionHouse.GetItemKeyFromItem(itemLocation)
    AuctionStats:RecordHistory(key, quantity or 0, unitPrice or 0, duration, "аукцион объявлен")
end)
hooksecurefunc(C_AuctionHouse, "PostItem", function(itemLocation, duration, quantity, bidAmount, buyoutAmount)
    local key = C_AuctionHouse.GetItemKeyFromItem(itemLocation)
    AuctionStats:RecordHistory(key, quantity or 0, buyoutAmount or 0, duration, "аукцион объявлен")
end)

-- 3) Кэш лотов (сохранение LastSyncTime + Type/Subtype)
function AuctionStats:CacheAuctions()
    print("AuctionStats Debug: CacheAuctions start")
    local rawAPI = C_AuctionHouse.GetOwnedAuctions()
    local src = (rawAPI and #rawAPI > 0) and rawAPI or AuctionStatsDB.storedAuctions
    if type(src) ~= "table" then src = {} end

    self.dbAuctions = {}
    for _, info in ipairs(src) do
        local key      = info.itemKey or {}
        local id       = key.itemID or 0
        local lvl      = key.itemLevel or 0
        local link     = info.itemLink or ("item:"..id)
        local name,_,q,_,_,itemType,itemSubType,_,_,tex = GetItemInfo(link)
        if not name then GetItemInfo(link) end
        tinsert(self.dbAuctions, {
            itemID      = id,
            itemLevel   = lvl,
            icon        = tex or "",
            name        = name or ("Item#"..id),
            itemType    = itemType or "",
            itemSubType = itemSubType or "",
            link        = link,
            quality     = q or 1,
            quantity    = info.quantity or 0,
            timeLeft    = info.timeLeftSeconds and SecsToShort(info.timeLeftSeconds)
                          or TimeBands[info.timeLeft or info.duration] or "?",
            rawBuyout   = info.buyoutAmount or 0,
            buyout      = (info.buyoutAmount or 0)>0 and FormatMoney(info.buyoutAmount) or "-",
            rawBid      = info.bidAmount or 0,
            bid         = (info.bidAmount or 0)>0 and FormatMoney(info.bidAmount) or "-",
        })
    end

    AuctionStatsDB.storedAuctions = {}
    for _,a in ipairs(self.dbAuctions) do tinsert(AuctionStatsDB.storedAuctions, a) end

    self.lastSyncTime = date("%Y-%m-%d %H:%M:%S", GetServerTime())
    AuctionStatsDB.lastSyncTime = self.lastSyncTime
    print(format("AuctionStats Debug: CacheAuctions end — %d lots, %s", #self.dbAuctions, self.lastSyncTime))
end

-- 4) Группировка по ID + включение history-only групп + Type/Subtype
function AuctionStats:GroupAuctions()
    local groups = {}
    for _,a in ipairs(self.dbAuctions) do
        local id = a.itemID
        if not groups[id] then
            groups[id] = {
                itemID      = id,
                icon        = a.icon,
                name        = a.name,
                itemType    = a.itemType,
                itemSubType = a.itemSubType,
                link        = a.link,
                quality     = a.quality,
                count       = 0,
                min_price   = nil,
                max_price   = nil,
                total       = 0,
                rawGroup    = {},
            }
        end
        local g = groups[id]
        g.count = g.count + a.quantity
        g.total = g.total + (a.rawBuyout * a.quantity)
        if not g.min_price or a.rawBuyout < g.min_price then g.min_price = a.rawBuyout end
        if not g.max_price or a.rawBuyout > g.max_price then g.max_price = a.rawBuyout end
        tinsert(g.rawGroup, a)
    end

    -- добавить группы, у которых только история
    for id,_ in pairs(AuctionStatsDB.history) do
        if not groups[id] then
            local name,_,q,_,_,itemType,itemSubType,_,_,tex = GetItemInfo("item:"..id)
            groups[id] = {
                itemID      = id,
                icon        = tex or "",
                name        = name or ("Item#"..id),
                itemType    = itemType or "",
                itemSubType = itemSubType or "",
                link        = "item:"..id,
                quality     = q or 1,
                count       = 0,
                min_price   = nil,
                max_price   = nil,
                total       = 0,
                rawGroup    = {},
            }
        end
    end

    local list = {}
    for _,g in pairs(groups) do tinsert(list,g) end
    table.sort(list, function(a,b) return a.itemID < b.itemID end)
    return list
end

-- 5) Создание окна Summary
function AuctionStats:CreateSummaryWindow()
    if self.summaryFrame then return end
    local f = CreateFrame("Frame","AuctionStatsSummaryFrame",UIParent,"BackdropTemplate")
    f:SetSize(W,H); f:SetPoint("CENTER"); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart",f.StartMoving); f:SetScript("OnDragStop",f.StopMovingOrSizing)
    f:SetBackdrop{
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=8, right=8, top=8, bottom=8 },
    }
    f:SetBackdropColor(0, 0, 0, 1)
    f.title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    f.title:SetPoint("TOP",0,-8); f.title:SetText("AuctionStats: Summary")
    CreateFrame("Button",nil,f,"UIPanelCloseButton"):SetPoint("TOPRIGHT",-6,-6)

    local sb = CreateFrame("EditBox","AuctionStatsSummarySearchBox",f,"SearchBoxTemplate")
    sb:SetSize(200,20); sb:SetPoint("TOPLEFT",20,-40); sb:SetAutoFocus(false)
    if sb.SetPromptText then sb:SetPromptText("Search") end
    sb:SetScript("OnTextChanged",function() AuctionStats:DrawSummary() end)
    self.summarySearch = sb

    local half = (H-160)/2

    local al = f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    al:SetPoint("TOPLEFT",sb,"BOTTOMLEFT",0,-10); al:SetText("Active Groups")
    self.summaryActiveLabel = al

    local ah = CreateFrame("Frame",nil,f)
    ah:SetSize(W-60,HDR_H); ah:SetPoint("TOPLEFT",al,"BOTTOMLEFT",0,-2)
    for _,c in ipairs({
        {x=POS_NUM,     t="#"},
        {x=POS_ID,      t="ID"},
        {x=POS_ICON,    t="", w=ICON_SIZE},
        {x=POS_NAME,    t="Name", w=NAME_W},
        {x=POS_TYPE,    t="Type",   w=TYPE_W},
        {x=POS_SUBTYPE, t="Subtype",w=TYPE_W},
        {x=POS_QTY,     t="Count"},
        {x=POS_MIN,     t="Min"},
        {x=POS_MAX,     t="Max"},
        {x=POS_TOTAL,   t="Total"},
    }) do
        local fs = ah:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        fs:SetPoint("LEFT",ah,"LEFT",c.x,0); fs:SetText(c.t)
    end
    self.summaryActiveHdr = ah

    local asc = CreateFrame("ScrollFrame","AuctionStatsActiveScroll",f,"UIPanelScrollFrameTemplate")
    asc:SetPoint("TOPLEFT",ah,"BOTTOMLEFT",0,-4); asc:SetSize(W-60,half)
    local act = CreateFrame("Frame",nil,asc)
    act:SetPoint("TOPLEFT",asc,"TOPLEFT",0,0); act:SetSize(W-60,ROW_H)
    asc:SetScrollChild(act)
    self.summaryActiveScroll  = asc
    self.summaryActiveContent = act

    local il = f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    il:SetPoint("TOPLEFT",asc,"BOTTOMLEFT",0,-10); il:SetText("Inactive Groups")
    self.summaryInactiveLabel = il

    local ih = CreateFrame("Frame",nil,f)
    ih:SetSize(W-60,HDR_H); ih:SetPoint("TOPLEFT",il,"BOTTOMLEFT",0,-2)
    for _,c in ipairs({
        {x=POS_NUM,     t="#"},
        {x=POS_ID,      t="ID"},
        {x=POS_ICON,    t="", w=ICON_SIZE},
        {x=POS_NAME,    t="Name", w=NAME_W},
        {x=POS_TYPE,    t="Type",   w=TYPE_W},
        {x=POS_SUBTYPE, t="Subtype",w=TYPE_W},
        {x=POS_QTY,     t="Count"},
        {x=POS_MIN,     t="Min"},
        {x=POS_MAX,     t="Max"},
        {x=POS_TOTAL,   t="Total"},
    }) do
        local fs = ih:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        fs:SetPoint("LEFT",ih,"LEFT",c.x,0); fs:SetText(c.t)
    end
    self.summaryInactiveHdr = ih

    local isc = CreateFrame("ScrollFrame","AuctionStatsInactiveScroll",f,"UIPanelScrollFrameTemplate")
    isc:SetPoint("TOPLEFT",ih,"BOTTOMLEFT",0,-4); isc:SetSize(W-60,half)
    local ict = CreateFrame("Frame",nil,isc)
    ict:SetPoint("TOPLEFT",isc,"TOPLEFT",0,0); ict:SetSize(W-60,ROW_H)
    isc:SetScrollChild(ict)
    self.summaryInactiveScroll  = isc
    self.summaryInactiveContent = ict

    self.summaryStats = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    self.summaryStats:SetPoint("BOTTOMLEFT",20,20)

    self.summaryFrame = f
end

-- 6) Рисуем Summary
function AuctionStats:DrawSummary()
    local groups = self:GroupAuctions()
    local filter = strlower(self.summarySearch:GetText() or "")
    local active, inactive = {},{}
    for _,g in ipairs(groups) do
        if g.count>0 then
            if filter=="" or strlower(g.name):find(filter,1,true) then tinsert(active,g) end
        else
            if filter=="" or strlower(g.name):find(filter,1,true) then tinsert(inactive,g) end
        end
    end

    local function drawList(list, content, lines)
        content:SetSize(W-60, #list*ROW_H)
        for _,ln in ipairs(lines) do ln:Hide() end
        for i,g in ipairs(list) do
            local ln = lines[i]
            if not ln then
                ln = CreateFrame("Button",nil,content,"BackdropTemplate")
                ln:SetSize(W-60,ROW_H)
                ln.num     = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.id      = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.icon    = ln:CreateTexture(nil,"ARTWORK"); ln.icon:SetSize(ICON_SIZE,ICON_SIZE)
                ln.name    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.name:SetWidth(NAME_W); ln.name:SetJustifyH("LEFT")
                ln.typ     = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.subtype = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.count   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.min     = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.max     = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.total   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.num:SetPoint("LEFT", ln, "LEFT", POS_NUM, 0)
                ln.id:SetPoint("LEFT", ln, "LEFT", POS_ID, 0)
                ln.icon:SetPoint("LEFT", ln, "LEFT", POS_ICON, 0)
                ln.name:SetPoint("LEFT", ln, "LEFT", POS_NAME, 0)
                ln.typ:SetPoint("LEFT", ln, "LEFT", POS_TYPE, 0)
                ln.subtype:SetPoint("LEFT", ln, "LEFT", POS_SUBTYPE, 0)
                ln.count:SetPoint("LEFT", ln, "LEFT", POS_QTY, 0)
                ln.min:SetPoint("LEFT", ln, "LEFT", POS_MIN, 0)
                ln.max:SetPoint("LEFT", ln, "LEFT", POS_MAX, 0)
                ln.total:SetPoint("LEFT", ln, "LEFT", POS_TOTAL, 0)
                lines[i] = ln
            end

            ln:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i-1)*ROW_H)
            ln.num:SetText(i)
            ln.id:SetText(g.itemID)
            ln.icon:SetTexture(g.icon)
            ln.name:SetText(g.name)
            local r,gg,b = C_Item.GetItemQualityColor(g.quality)
            ln.name:SetTextColor(r,gg,b)
            ln.typ:SetText(g.itemType or "")
            ln.subtype:SetText(g.itemSubType or "")
            ln.count:SetText(g.count)
            ln.min:SetText(FormatMoney(g.min_price or 0))
            ln.max:SetText(FormatMoney(g.max_price or 0))
            ln.total:SetText(FormatMoney(g.total or 0))
            ln:Show()

            ln:SetScript("OnMouseUp", function(_,btn)
                if btn=="LeftButton" then AuctionStats:ShowDetail(g) end
            end)
            ln:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(g.link)
                GameTooltip:Show()
            end)
            ln:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    drawList(active,   self.summaryActiveContent,   self.summaryActiveLines)
    drawList(inactive, self.summaryInactiveContent, self.summaryInactiveLines)

    local totG = #active + #inactive
    local totI, totC = 0, 0
    for _,g in ipairs(active)   do totI = totI + g.count; totC = totC + g.total end
    for _,g in ipairs(inactive) do totI = totI + g.count; totC = totC + g.total end

    self.summaryStats:SetText(format(
        "Groups: %d   Items: %d   Total: %s   Last Sync: %s",
        totG, totI, FormatMoney(totC), self.lastSyncTime or "N/A"
    ))
    self.summaryFrame:Show()
end

-- 7) Создание окна Detail и History
function AuctionStats:CreateDetailWindow()
    if self.detailFrame then return end
    local f = CreateFrame("Frame","AuctionStatsDetailFrame",UIParent,"BackdropTemplate")
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel((AuctionStats.summaryFrame and AuctionStats.summaryFrame:GetFrameLevel() or 0) + 1)
    f:SetSize(W,H); f:SetPoint("CENTER",30,0); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart",f.StartMoving); f:SetScript("OnDragStop",f.StopMovingOrSizing)
    f:SetBackdrop{
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=8, right=8, top=8, bottom=8 },
    }
    f:SetBackdropColor(0, 0, 0, 1)
    f.title = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    f.title:SetPoint("TOP",0,-8); f.title:SetText("Details")
    CreateFrame("Button",nil,f,"UIPanelCloseButton"):SetPoint("TOPRIGHT",-6,-6)

    local sb = CreateFrame("EditBox","AuctionStatsDetailSearchBox",f,"SearchBoxTemplate")
    sb:SetSize(200,20); sb:SetPoint("TOPLEFT",20,-40); sb:SetAutoFocus(false)
    if sb.SetPromptText then sb:SetPromptText("Search") end
    sb:SetScript("OnTextChanged", function() AuctionStats:DrawDetail() end)
    self.detailSearch = sb

    local hdr = CreateFrame("Frame",nil,f)
    hdr:SetSize(W-60,HDR_H); hdr:SetPoint("TOPLEFT",20,-70)
    for _,c in ipairs({
        {x=D_POS_NUM,  t="#"},  {x=D_POS_ID,   t="ID"},  {x=D_POS_ICON, t="", w=ICON_SIZE},
        {x=D_POS_NAME, t="Name", w=D_NAME_W}, {x=D_POS_LEVEL, t="Level"},
        {x=D_POS_QTY,  t="Qty"},{x=D_POS_TIME, t="Time"},{x=D_POS_BUY, t="Buyout"},{x=D_POS_BID, t="Bid"},
    }) do
        local fs = hdr:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        fs:SetPoint("LEFT",hdr,"LEFT",c.x,0); fs:SetText(c.t)
    end

    local half = (H-140)/2
    local sc = CreateFrame("ScrollFrame","AuctionStatsDetailScrollFrame",f,"UIPanelScrollFrameTemplate")
    sc:SetPoint("TOPLEFT",hdr,"BOTTOMLEFT",0,-4); sc:SetSize(W-60,half)
    local ct = CreateFrame("Frame",nil,sc)
    ct:SetPoint("TOPLEFT",sc,"TOPLEFT",0,0); ct:SetSize(W-60,ROW_H)
    sc:SetScrollChild(ct)
    self.detailContent = ct

    local hh = f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    hh:SetPoint("TOPLEFT",sc,"BOTTOMLEFT",0,-10); hh:SetText("History")
    local hhdr = CreateFrame("Frame",nil,f)
    hhdr:SetSize(W-60,HDR_H); hhdr:SetPoint("TOPLEFT",hh,"BOTTOMLEFT",0,-2)
    for _,c in ipairs({
        {x=H_POS_NUM,       t="#"},
        {x=H_POS_TIME,      t="Date"},
        {x=H_POS_QTY,       t="Qty"},
        {x=H_POS_PRICE,     t="Price"},
        {x=H_POS_DUR,       t="Dur"},
        {x=H_POS_STATUS,    t="Status"},
    }) do
        local fs = hhdr:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        fs:SetPoint("LEFT",hhdr,"LEFT",c.x,0); fs:SetText(c.t)
    end

    local hsc = CreateFrame("ScrollFrame","AuctionStatsHistoryScrollFrame",f,"UIPanelScrollFrameTemplate")
    hsc:SetPoint("TOPLEFT",hhdr,"BOTTOMLEFT",0,-4); hsc:SetSize(W-60,half-(HDR_H+10))
    local hct = CreateFrame("Frame",nil,hsc)
    hct:SetPoint("TOPLEFT",hsc,"TOPLEFT",0,0); hct:SetSize(W-60,ROW_H)
    hsc:SetScrollChild(hct)
    self.historyContent = hct

    self.historyStats = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    self.historyStats:SetPoint("LEFT", hsc, "BOTTOMLEFT", 0, -20)

    self.detailStats = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    self.detailStats:SetPoint("BOTTOMLEFT",20,20)

    self.detailFrame = f
end

-- 8) Рисуем Detail + History + Stats
function AuctionStats:DrawDetail()
    local list   = self.detailData or {}
    local filter = strlower(self.detailSearch:GetText() or "")
    local filtered = {}
    for _,a in ipairs(list) do
        if filter=="" or strlower(a.name):find(filter,1,true) then
            tinsert(filtered, a)
        end
    end

    -- DETAIL ROWS
    local ct = self.detailContent
    ct:SetSize(W-60, #filtered * ROW_H)
    for _,ln in ipairs(self.detailLines) do ln:Hide() end

    for i,a in ipairs(filtered) do
        local ln = self.detailLines[i]
        if not ln then
            ln = CreateFrame("Frame", nil, ct)
            ln:SetSize(W-60, ROW_H)

            ln.num   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.id    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.icon  = ln:CreateTexture(nil,"ARTWORK"); ln.icon:SetSize(ICON_SIZE,ICON_SIZE)
            ln.name  = ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.name:SetWidth(D_NAME_W); ln.name:SetJustifyH("LEFT")
            ln.level = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.qty   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.tl    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.bo    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.bd    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")

            ln.num:SetPoint("LEFT", D_POS_NUM,  0)
            ln.id:SetPoint("LEFT",  D_POS_ID,   0)
            ln.icon:SetPoint("LEFT",D_POS_ICON, 0)
            ln.name:SetPoint("LEFT",D_POS_NAME, 0)
            ln.level:SetPoint("LEFT",D_POS_LEVEL,0)
            ln.qty:SetPoint("LEFT", D_POS_QTY,  0)
            ln.tl:SetPoint("LEFT",  D_POS_TIME, 0)
            ln.bo:SetPoint("LEFT",  D_POS_BUY,  0)
            ln.bd:SetPoint("LEFT",  D_POS_BID,  0)

            ln:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(a.link)
                GameTooltip:Show()
            end)
            ln:SetScript("OnLeave", function() GameTooltip:Hide() end)

            self.detailLines[i] = ln
        end

        ln:SetPoint("TOPLEFT", ct, "TOPLEFT", 0, -(i-1)*ROW_H)
        ln.num:SetText(i)
        ln.id:SetText(a.itemID)
        ln.icon:SetTexture(a.icon)
        ln.name:SetText(a.name)
        local r,gg,b = C_Item.GetItemQualityColor(a.quality)
        ln.name:SetTextColor(r,gg,b)
        ln.level:SetText(a.itemLevel or "")
        ln.qty:SetText(a.quantity)
        ln.tl:SetText(a.timeLeft)
        ln.bo:SetText(a.buyout)
        ln.bd:SetText(a.bid)
        ln:Show()
    end

    -- HISTORY ROWS
    local title = self.detailFrame.title:GetText() or ""
    local id    = tonumber(title:match("%[(%d+)%]"))
    local hist  = (id and AuctionStatsDB.history[id]) or {}
    local hct   = self.historyContent
    hct:SetSize(W-60, #hist * ROW_H)
    for _,ln in ipairs(self.historyLines) do ln:Hide() end

    for i,e in ipairs(hist) do
        local ln = self.historyLines[i]
        if not ln then
            ln = CreateFrame("Frame", nil, hct)
            ln:SetSize(W-60, ROW_H)

            ln.num    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.time   = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.qty    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.price  = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.dur    = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.status = ln:CreateFontString(nil,"OVERLAY","GameFontNormal")

            ln.num:SetPoint("LEFT", H_POS_NUM,    0)
            ln.time:SetPoint("LEFT",H_POS_TIME,   0)
            ln.qty:SetPoint("LEFT", H_POS_QTY,    0)
            ln.price:SetPoint("LEFT",H_POS_PRICE,  0)
            ln.dur:SetPoint("LEFT", H_POS_DUR,    0)
            ln.status:SetPoint("LEFT",H_POS_STATUS,0)

            self.historyLines[i] = ln
        end

        ln:SetPoint("TOPLEFT", hct, "TOPLEFT", 0, -(i-1)*ROW_H)
        ln.num:SetText(i)
        ln.time:SetText(e.time)
        ln.qty:SetText(e.quantity)
        ln.price:SetText(e.buyout)
        local hrs = DurationHours[e.durationCode or e.duration] or 0
        ln.dur:SetText(hrs.."h")
        ln.status:SetText(e.status or "")
        ln:Show()
    end

    -- STATS для Detail (без изменений)
    local cnt, cost = 0, 0
    for _,a in ipairs(filtered) do
        cnt  = cnt + a.quantity
        cost = cost + (a.rawBuyout * a.quantity)
    end
    self.detailStats:SetText(format(
        "Items: %d   Total: %s   Last Sync: %s",
        cnt, FormatMoney(cost), self.lastSyncTime or "N/A"
    ))

    -- STATS для History: считаем только "аукцион состоялся"
    local totalQty, totalGold = 0, 0
    for _,e in ipairs(hist) do
        if e.status == "аукцион состоялся" then
            totalQty  = totalQty  + (e.quantity or 0)
            totalGold = totalGold + (e.rawBuyout or 0)
        end
    end
    self.historyStats:SetText(format(
        "History sold: %d   Total gold: %s",
        totalQty, FormatMoney(totalGold)
    ))

    self.detailFrame:Show()
end

-- 9) ShowDetail
function AuctionStats:ShowDetail(group)
    self:CreateDetailWindow()
    self.detailFrame:Raise()
    self.detailFrame.title:SetText(format("Details: %s [%d]",group.name,group.itemID))
    self.detailData = {}
    for _,a in ipairs(group.rawGroup) do tinsert(self.detailData,a) end
    AuctionStats:DrawDetail()
end

-- 10) Обработка почты
function AuctionStats:ProcessMail()
    local n = GetInboxNumItems()
    print("AuctionStats: ProcessMail start — inbox items =", n)

    for i = 1, n do
        local _, _, sender, subject, money, _, _, hasItem, _, _, textCreated = GetInboxHeaderInfo(i)
        subject = subject or ""
        local cleanSubj = subject
            :gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")
            :match("^%s*(.-)%s*$")

        local isSale   = cleanSubj:match("^Аукцион состоялся")
        local isFailed = cleanSubj:match("^Аукцион не состоялся")

        local itemName, count
        if isSale or isFailed then
            local after = cleanSubj:match("^[^:]+:%s*(.+)$")
            if after then
                local name, num = after:match("^(.-)%s*%((%d+)%)$")
                if name then
                    itemName = name
                    count    = tonumber(num)
                else
                    itemName = after
                    count    = 1
                end
            end
        end

        if not itemName then
            print("  AuctionStats: skip mail, subject =", cleanSubj)
        else
            local status = isSale  and "аукцион состоялся"
                          or isFailed and "аукцион не состоялся"
            local mailKey = sender.."|"..cleanSubj.."|"..tostring(textCreated)

            if AuctionStatsDB.processedMails[mailKey] then
                print("  AuctionStats: already processed:", mailKey)
            else
                print("  AuctionStats:", status, itemName, "count="..count)

                local itemLink
                if hasItem then
                    for slot = 1, ATTACHMENTS_MAX_RECEIVE do
                        local link = GetInboxItemLink(i, slot)
                        if link then itemLink = link; break end
                    end
                end

                local itemID
                if itemLink then
                    itemID = tonumber(itemLink:match("item:(%d+)"))
                else
                    local lname = itemName:lower()
                    for _, a in ipairs(self.dbAuctions) do
                        if a.name and a.name:lower() == lname then
                            itemID = a.itemID
                            break
                        end
                    end
                end

                if itemID then
                    local totalPrice = isSale and (money or 0) or 0
                    self:RecordHistory({ itemID = itemID }, count, totalPrice, nil, status)
                    AuctionStatsDB.processedMails[mailKey] = true
                    print("   → Marked processed:", mailKey)
                else
                    print("   !!! AuctionStats: не удалось определить itemID для", itemName)
                end
            end
        end
    end

    print("AuctionStats: ProcessMail end")
end

-- 11) Обработчик событий
local handler = CreateFrame("Frame")
handler:RegisterEvent("ADDON_LOADED")
handler:RegisterEvent("AUCTION_HOUSE_SHOW")
handler:RegisterEvent("OWNED_AUCTIONS_UPDATED")
handler:RegisterEvent("MAIL_SHOW")
handler:RegisterEvent("MAIL_INBOX_UPDATE")

handler:SetScript("OnEvent", function(_, e, arg1)
    print("AuctionStats Event:", e, arg1 or "")

    if e=="ADDON_LOADED" and arg1=="AuctionStats" then
        AuctionStatsDB.history = AuctionStatsDB.history or {}
        AuctionStatsDB.processedMails = AuctionStatsDB.processedMails or {}
        if AuctionStatsDB.storedAuctions and #AuctionStatsDB.storedAuctions>0 then
            AuctionStats.dbAuctions = AuctionStatsDB.storedAuctions
        end
        if AuctionStatsDB.lastSyncTime then
            AuctionStats.lastSyncTime = AuctionStatsDB.lastSyncTime
        end

    elseif e=="AUCTION_HOUSE_SHOW" then
        C_AuctionHouse.QueryOwnedAuctions({})

    elseif e=="OWNED_AUCTIONS_UPDATED" then
        AuctionStats:CacheAuctions()
        if AuctionStats.summaryFrame and AuctionStats.summaryFrame:IsShown() then AuctionStats:DrawSummary() end
        if AuctionStats.detailFrame and AuctionStats.detailFrame:IsShown() then AuctionStats:DrawDetail() end

    elseif e=="MAIL_SHOW" or e=="MAIL_INBOX_UPDATE" then
        AuctionStats:ProcessMail()
    end
end)

-- 12) Slash-команда
SLASH_AUCTIONSTATS1 = "/astat"
SlashCmdList["AUCTIONSTATS"] = function()
    AuctionStats:CreateSummaryWindow()
    AuctionStats:DrawSummary()
end

-- Minimap-кнопка
local button = CreateFrame("Button", "AuctionStatsMinimapButton", Minimap)
button:SetSize(32,32)
button:SetFrameStrata("MEDIUM")
button.icon = button:CreateTexture(nil,"BACKGROUND")
button.icon:SetAllPoints()
button.icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
button.highlight = button:CreateTexture(nil,"HIGHLIGHT")
button.highlight:SetAllPoints()
button.highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)
button:RegisterForDrag("LeftButton"); button:SetMovable(true)
button:SetScript("OnDragStart", function(self) self:StartMoving() end)
button:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
button:SetScript("OnClick", function(self)
    if AuctionStats.summaryFrame and AuctionStats.summaryFrame:IsShown() then
        AuctionStats.summaryFrame:Hide()
    else
        AuctionStats:CreateSummaryWindow()
        AuctionStats:DrawSummary()
    end
end)
button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("AuctionStats", 1,1,1)
    GameTooltip:AddLine("Click to toggle AuctionStats window", .8,.8,.8)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

--------------------------------------------------------------------------------
-- ▼▼▼  БЛОК ТУЛТИПОВ: «Выставлено …» (свитки + продукт)  ▼▼▼ ------------------
--  Ставьте ЭТОТ блок В САМЫЙ КОНЕЦ AuctionStats.lua, заменив старый.          --
--------------------------------------------------------------------------------

----------------------------- 1. Список префиксов рецептов ---------------------
local RECIPE_PREFIXES = {
    -- enUS
    recipe   = true, formula  = true, pattern = true, plans  = true,
    schematic= true, design   = true, manual  = true, technique = true,
    -- ruRU
    ["рецепт"] = true, ["формула"] = true, ["схема"]  = true,
    ["чертёж"] = true, ["чертеж"]  = true, ["план"]   = true,
    ["планы"]  = true, ["инструкция"] = true, ["выкройка"] = true,
    ["эскиз"] = true,
    -- другие языки добавляйте при необходимости
}

local function IsScrollByName(itemName)
    local prefix = itemName:match("^([^:]+):")
    if not prefix then return false end
    prefix = prefix:gsub("^%s+",""):gsub("%s+$",""):lower()
    return RECIPE_PREFIXES[prefix] or false
end

----------------------------- 2. Считаем количество лотов ----------------------
function AuctionStats:GetOwnedCountByItemID(id)
    local n = 0
    for _, lot in ipairs(self.dbAuctions or {}) do
        if lot.itemID == id then n = n + (lot.quantity or 0) end
    end
    return n
end

function AuctionStats:GetOwnedCountByExactName(name)
    if not name then return 0 end
    local target, n = name:lower(), 0
    for _, lot in ipairs(self.dbAuctions or {}) do
        if lot.name and lot.name:lower() == target then
            n = n + (lot.quantity or 0)
        end
    end
    return n
end

function AuctionStats:GetScrollCountForProduct(productName)
    if not productName then return 0 end
    local suffix = ": "..productName:lower()
    local n = 0
    for _, lot in ipairs(self.dbAuctions or {}) do
        if lot.name and lot.name:lower():sub(-#suffix) == suffix then
            n = n + (lot.quantity or 0)
        end
    end
    return n
end

----------------------------- 3. Добавляем строки в тултип ---------------------
function AddAuctionStatsToTooltip(tt)
    local _, link = tt:GetItem(); if not link then return end
    local itemID  = tonumber(link:match("item:(%d+)")); if not itemID then return end

    local itemName = GetItemInfo(itemID); if not itemName then return end

    local productCount, scrollCount, dualShown = 0, 0, false

    if IsScrollByName(itemName) then
        --------------------------------------------------------------------
        -- Это действительно свиток-рецепт
        --------------------------------------------------------------------
        local productName = itemName:match("^.-:%s*(.+)$") or itemName
        scrollCount  = AuctionStats:GetOwnedCountByItemID(itemID)
        productCount = AuctionStats:GetOwnedCountByExactName(productName)

        if productCount > 0 then
            tt:AddLine("|cff00ff00Выставлено продукта :|r "..productCount, 1,1,1)
            dualShown = true
        end
        if scrollCount > 0 then
            tt:AddLine("|cff00ff00Выставлено свитков  :|r "..scrollCount, 1,1,1)
            dualShown = true
        end
    else
        --------------------------------------------------------------------
        -- Обычный предмет
        --------------------------------------------------------------------
        productCount = AuctionStats:GetOwnedCountByItemID(itemID)
        scrollCount  = AuctionStats:GetScrollCountForProduct(itemName)

        if scrollCount > 0 then
            tt:AddLine("|cff00ff00Выставлено свитков  :|r "..scrollCount, 1,1,1)
            dualShown = true
        end
        if productCount > 0 then
            tt:AddLine("|cff00ff00Выставлено предметов:|r "..productCount, 1,1,1)
            dualShown = true
        end
    end

    if dualShown then tt:Show() end
end

----------------------------- 4. Безопасный hooksecurefunc ----------------------
local function SafeHook(tip, method)
    if type(tip[method]) == "function" then
        hooksecurefunc(tip, method, AddAuctionStatsToTooltip)
    end
end

----------------------------- 5. Хуки, доступные сразу -------------------------
SafeHook(GameTooltip,      "SetBagItem")         -- сумки
SafeHook(GameTooltip,      "SetInventoryItem")   -- экип/банк
SafeHook(GameTooltip,      "SetHyperlink")       -- чат-ссылки
SafeHook(ShoppingTooltip1, "SetHyperlink")       -- список аукциона
SafeHook(ShoppingTooltip2, "SetHyperlink")

-- Профессии
SafeHook(GameTooltip, "SetRecipeReagentItem")
SafeHook(GameTooltip, "SetRecipeResultItem")
SafeHook(GameTooltip, "SetCraftedItemByID")
SafeHook(GameTooltip, "SetTradeSkillItem")

----------------------------- 6. Хуки для Blizzard_AuctionHouseUI -------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, addon)
    if addon == "Blizzard_AuctionHouseUI" then
        SafeHook(GameTooltip, "SetAuctionItem")      -- browse / owner / bidder
        SafeHook(GameTooltip, "SetAuctionSellItem")  -- слот продажи
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

--------------------------------------------------------------------------------
-- ▲▲▲  КОНЕЦ БЛОКА ТУЛТИПОВ  ▲▲▲ ---------------------------------------------





-- конец файла
