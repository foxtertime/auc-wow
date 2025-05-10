-- AuctionStats.lua

-- В AuctionStats.toc:
-- ## SavedVariables: AuctionStatsDB

AuctionStatsDB = AuctionStatsDB or {
    storedAuctions = {},
    history        = {},    -- [itemID] = { { time=..., quantity=..., rawBuyout=..., buyout=..., durationCode=..., operation=... }, ... }
}

local tinsert  = table.insert
local strlower = string.lower
local format   = string.format
local date     = date
local print    = print

local AuctionStats = {
    dbAuctions       = {},
    lastSyncTime     = nil,

    -- summary UI
    summaryFrame       = nil,
    summarySearch      = nil,
    summaryActiveLabel = nil,
    summaryActiveHdr   = nil,
    summaryActiveScroll= nil,
    summaryActiveContent={},
    summaryActiveLines = {},
    summaryInactiveLabel = nil,
    summaryInactiveHdr   = nil,
    summaryInactiveScroll= nil,
    summaryInactiveContent={},
    summaryInactiveLines = {},
    summaryStats       = nil,

    -- detail UI
    detailFrame      = nil,
    detailSearch     = nil,
    detailContent    = nil,
    detailLines      = {},
    historyContent   = nil,
    historyLines     = {},
    detailStats      = nil,
    detailData       = {},
}

-- sizes
local W, H         = 1000, 650
local ROW_H, HDR_H = 20, 20
local ICON_SIZE    = 14

-- summary columns
local POS_NUM, POS_ID, POS_ICON, POS_NAME = 0, 40, 100, 140
local NAME_W                              = 400
local POS_QTY   = POS_NAME + NAME_W + 10
local POS_MIN   = POS_QTY  + 60
local POS_MAX   = POS_MIN  + 120
local POS_TOTAL = POS_MAX  + 120

-- detail columns
local D_POS_NUM, D_POS_ID, D_POS_ICON, D_POS_NAME = 0,40,100,140
local D_NAME_W = 400
local D_POS_LEVEL = D_POS_NAME + D_NAME_W + 10
local D_POS_QTY   = D_POS_LEVEL + 60
local D_POS_TIME  = D_POS_QTY + 60
local D_POS_BUY   = D_POS_TIME + 120
local D_POS_BID   = D_POS_BUY + 120

-- history columns
local H_POS_NUM       = 0
local H_POS_TIME      = 40
local H_POS_QTY       = 260
local H_POS_PRICE     = 340
local H_POS_DUR       = 480
local H_POS_OPERATION = H_POS_DUR + 80

local DurationHours = { [1]=12, [2]=24, [3]=48 }

local function FormatMoney(c)
    local g=math.floor(c/10000); local s=math.floor((c%10000)/100); local k=c%100
    local parts={}
    if g>0 then tinsert(parts, g.."|TInterface\\MoneyFrame\\UI-GoldIcon:14:14|t") end
    if s>0 then tinsert(parts, s.."|TInterface\\MoneyFrame\\UI-SilverIcon:14:14|t") end
    tinsert(parts, k.."|TInterface\\MoneyFrame\\UI-CopperIcon:14:14|t")
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
    local m=math.floor(sec/60) if m<60 then return m.."m" end
    local h=math.floor(m/60) if h<24 then return h.."h" end
    return math.floor(h/24).."d"
end

function AuctionStats:RecordHistory(itemKey, quantity, rawBuyout, durationCode, operation)
    local id = itemKey and itemKey.itemID or 0
    if id<=0 then return end
    AuctionStatsDB.history[id] = AuctionStatsDB.history[id] or {}
    tinsert(AuctionStatsDB.history[id], {
        time         = date("%Y-%m-%d %H:%M:%S", GetServerTime()),
        quantity     = quantity,
        rawBuyout    = rawBuyout,
        buyout       = rawBuyout>0 and FormatMoney(rawBuyout) or "-",
        durationCode = durationCode,
        operation    = operation,
    })
    print(format("AuctionStats: History recorded for %d x%d op=%s", id, quantity, operation))
end

hooksecurefunc(C_AuctionHouse, "PostCommodity", function(itemLocation, duration, quantity, unitPrice)
    local key = C_AuctionHouse.GetItemKeyFromItem(itemLocation)
    AuctionStats:RecordHistory(key, quantity or 0, unitPrice or 0, duration, "выставление на продажу")
end)
hooksecurefunc(C_AuctionHouse, "PostItem", function(itemLocation, duration, quantity, bidAmount, buyoutAmount)
    local key = C_AuctionHouse.GetItemKeyFromItem(itemLocation)
    AuctionStats:RecordHistory(key, quantity or 0, buyoutAmount or 0, duration, "выставление на продажу")
end)

function AuctionStats:CacheAuctions()
    print("AuctionStats Debug: CacheAuctions start")
    local rawAPI = C_AuctionHouse.GetOwnedAuctions()
    local src    = (rawAPI and #rawAPI>0) and rawAPI or AuctionStatsDB.storedAuctions

    self.dbAuctions = {}
    for _,info in ipairs(src) do
        local key=info.itemKey or {}; local id=key.itemID or 0; local lvl=key.itemLevel or 0
        local link=info.itemLink or ("item:"..id)
        local name,_,q,_,_,_,_,_,_,tex=GetItemInfo(link)
        if not name then GetItemInfo(link) end
        tinsert(self.dbAuctions, {
            itemID=id, itemLevel=lvl, icon=tex or"", name=name or("Item#"..id),
            link=link, quality=q or 1, quantity=info.quantity or 0,
            timeLeft= info.timeLeftSeconds and SecsToShort(info.timeLeftSeconds)
                      or TimeBands[info.timeLeft or info.duration] or "?",
            rawBuyout=info.buyoutAmount or 0,
            buyout=(info.buyoutAmount or 0)>0 and FormatMoney(info.buyoutAmount) or "-",
            rawBid=info.bidAmount or 0,
            bid=(info.bidAmount or 0)>0 and FormatMoney(info.bidAmount) or "-",
        })
    end

    AuctionStatsDB.storedAuctions = {}
    for _,a in ipairs(self.dbAuctions) do tinsert(AuctionStatsDB.storedAuctions,a) end

    self.lastSyncTime = date("%Y-%m-%d %H:%M:%S", GetServerTime())
    print(format("AuctionStats Debug: CacheAuctions end — %d lots, %s",#self.dbAuctions,self.lastSyncTime))
end

function AuctionStats:GroupAuctions()
    local groups={}
    for _,a in ipairs(self.dbAuctions) do
        local id=a.itemID
        if not groups[id] then
            groups[id]={ itemID=id, icon=a.icon, name=a.name, link=a.link, quality=a.quality,
                         count=0, min_price=nil, max_price=nil, total=0, rawGroup={} }
        end
        local g=groups[id]
        g.count=g.count+a.quantity
        g.total=g.total+(a.rawBuyout*a.quantity)
        if not g.min_price or a.rawBuyout<g.min_price then g.min_price=a.rawBuyout end
        if not g.max_price or a.rawBuyout>g.max_price then g.max_price=a.rawBuyout end
        tinsert(g.rawGroup,a)
    end
    for id,_ in pairs(AuctionStatsDB.history) do
        if not groups[id] then
            local name,link,q,_,_,_,_,_,_,tex=GetItemInfo("item:"..id)
            groups[id]={ itemID=id, icon=tex or"", name=name or("Item#"..id), link=link or("item:"..id), quality=q or 1,
                         count=0, min_price=nil, max_price=nil, total=0, rawGroup={} }
        end
    end
    local list={}
    for _,g in pairs(groups) do tinsert(list,g) end
    table.sort(list,function(a,b) return a.itemID<b.itemID end)
    return list
end

function AuctionStats:CreateSummaryWindow()
    if self.summaryFrame then return end
    local f=CreateFrame("Frame","AuctionStatsSummaryFrame",UIParent,"BackdropTemplate")
    f:SetSize(W,H); f:SetPoint("CENTER"); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart",f.StartMoving); f:SetScript("OnDragStop",f.StopMovingOrSizing)
    f:SetBackdrop{ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=32,edgeSize=32,insets={left=8,right=8,top=8,bottom=8} }
    f.title=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge"); f.title:SetPoint("TOP",0,-8); f.title:SetText("AuctionStats: Summary")
    CreateFrame("Button",nil,f,"UIPanelCloseButton"):SetPoint("TOPRIGHT",-6,-6)

    local sb=CreateFrame("EditBox","AuctionStatsSummarySearchBox",f,"SearchBoxTemplate")
    sb:SetSize(200,20); sb:SetPoint("TOPLEFT",20,-40); sb:SetAutoFocus(false)
    if sb.SetPromptText then sb:SetPromptText("Поиск") end
    sb:SetScript("OnTextChanged",function() AuctionStats:DrawSummary() end)
    self.summarySearch=sb

    local half=(H-160)/2

    local al=f:CreateFontString(nil,"OVERLAY","GameFontHighlight"); al:SetPoint("TOPLEFT",sb,"BOTTOMLEFT",0,-10); al:SetText("Active Groups")
    self.summaryActiveLabel=al
    local ah=CreateFrame("Frame",nil,f); ah:SetSize(W-60,HDR_H); ah:SetPoint("TOPLEFT",al,"BOTTOMLEFT",0,-2)
    for _,c in ipairs({{x=POS_NUM,t="#"},{x=POS_ID,t="ID"},{x=POS_ICON,t="",w=ICON_SIZE},
        {x=POS_NAME,t="Name",w=NAME_W},{x=POS_QTY,t="Count"},{x=POS_MIN,t="Min"},{x=POS_MAX,t="Max"},{x=POS_TOTAL,t="Total"}}) do
        local fs=ah:CreateFontString(nil,"OVERLAY","GameFontHighlight"); fs:SetPoint("LEFT",ah,"LEFT",c.x,0); fs:SetText(c.t)
    end
    self.summaryActiveHdr=ah
    local asc=CreateFrame("ScrollFrame","AuctionStatsActiveScroll",f,"UIPanelScrollFrameTemplate")
    asc:SetPoint("TOPLEFT",ah,"BOTTOMLEFT",0,-4); asc:SetSize(W-60,half)
    local act=CreateFrame("Frame",nil,asc); act:SetPoint("TOPLEFT",asc,"TOPLEFT",0,0); act:SetSize(W-60,ROW_H)
    asc:SetScrollChild(act); self.summaryActiveScroll=asc; self.summaryActiveContent=act

    local il=f:CreateFontString(nil,"OVERLAY","GameFontHighlight"); il:SetPoint("TOPLEFT",asc,"BOTTOMLEFT",0,-10); il:SetText("Inactive Groups")
    self.summaryInactiveLabel=il
    local ih=CreateFrame("Frame",nil,f); ih:SetSize(W-60,HDR_H); ih:SetPoint("TOPLEFT",il,"BOTTOMLEFT",0,-2)
    for _,c in ipairs({{x=POS_NUM,t="#"},{x=POS_ID,t="ID"},{x=POS_ICON,t="",w=ICON_SIZE},
        {x=POS_NAME,t="Name",w=NAME_W},{x=POS_QTY,t="Count"},{x=POS_MIN,t="Min"},{x=POS_MAX,t="Max"},{x=POS_TOTAL,t="Total"}}) do
        local fs=ih:CreateFontString(nil,"OVERLAY","GameFontHighlight"); fs:SetPoint("LEFT",ih,"LEFT",c.x,0); fs:SetText(c.t)
    end
    self.summaryInactiveHdr=ih
    local isc=CreateFrame("ScrollFrame","AuctionStatsInactiveScroll",f,"UIPanelScrollFrameTemplate")
    isc:SetPoint("TOPLEFT",ih,"BOTTOMLEFT",0,-4); isc:SetSize(W-60,half)
    local ict=CreateFrame("Frame",nil,isc); ict:SetPoint("TOPLEFT",isc,"TOPLEFT",0,0); ict:SetSize(W-60,ROW_H)
    isc:SetScrollChild(ict); self.summaryInactiveScroll=isc; self.summaryInactiveContent=ict

    self.summaryStats=f:CreateFontString(nil,"OVERLAY","GameFontNormal"); self.summaryStats:SetPoint("BOTTOMLEFT",20,20)
    self.summaryFrame=f
end

function AuctionStats:DrawSummary()
    local groups=self:GroupAuctions(); local filter=strlower(self.summarySearch:GetText() or "")
    local active,inactive={},{}
    for _,g in ipairs(groups) do
        if g.count>0 then
            if filter=="" or strlower(g.name):find(filter,1,true) then tinsert(active,g) end
        else
            if filter=="" or strlower(g.name):find(filter,1,true) then tinsert(inactive,g) end
        end
    end

    local function drawList(list,content,lines)
        content:SetSize(W-60,#list*ROW_H)
        for _,ln in ipairs(lines) do ln:Hide() end
        for i,g in ipairs(list) do
            local ln=lines[i]
            if not ln then
                ln=CreateFrame("Button",nil,content,"BackdropTemplate"); ln:SetSize(W-60,ROW_H)
                ln.num=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.id=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.icon=ln:CreateTexture(nil,"ARTWORK"); ln.icon:SetSize(ICON_SIZE,ICON_SIZE)
                ln.name=ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.name:SetWidth(NAME_W); ln.name:SetJustifyH("LEFT")
                ln.count=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.min=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.max=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.total=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
                ln.num:SetPoint("LEFT",POS_NUM,0); ln.id:SetPoint("LEFT",POS_ID,0)
                ln.icon:SetPoint("LEFT",POS_ICON,0); ln.name:SetPoint("LEFT",POS_NAME,0)
                ln.count:SetPoint("LEFT",POS_QTY,0); ln.min:SetPoint("LEFT",POS_MIN,0)
                ln.max:SetPoint("LEFT",POS_MAX,0); ln.total:SetPoint("LEFT",POS_TOTAL,0)
                lines[i]=ln
            end
            ln:SetPoint("TOPLEFT",content,"TOPLEFT",0,-(i-1)*ROW_H)
            ln.num:SetText(i); ln.id:SetText(g.itemID); ln.icon:SetTexture(g.icon)
            ln.name:SetText(g.name); local r,gc,b= C_Item.GetItemQualityColor(g.quality); ln.name:SetTextColor(r,gc,b)
            ln.count:SetText(g.count); ln.min:SetText(FormatMoney(g.min_price or 0))
            ln.max:SetText(FormatMoney(g.max_price or 0)); ln.total:SetText(FormatMoney(g.total or 0))
            ln:Show()
            ln:SetScript("OnMouseUp",function(_,btn) if btn=="LeftButton" then AuctionStats:ShowDetail(g) end end)
            ln:SetScript("OnEnter",function(self) GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetHyperlink(g.link); GameTooltip:Show() end)
            ln:SetScript("OnLeave",function() GameTooltip:Hide() end)
        end
    end

    drawList(active,   self.summaryActiveContent,   self.summaryActiveLines)
    drawList(inactive, self.summaryInactiveContent, self.summaryInactiveLines)

    local totG=#active+#inactive; local totI,totC=0,0
    for _,g in ipairs(active)   do totI=totI+g.count; totC=totC+g.total end
    for _,g in ipairs(inactive) do totI=totI+g.count; totC=totC+g.total end

    self.summaryStats:SetText(format("Groups: %d   Items: %d   Total: %s   Last Sync: %s",
        totG,totI,FormatMoney(totC),self.lastSyncTime or "N/A"))
    self.summaryFrame:Show()
end

function AuctionStats:CreateDetailWindow()
    if self.detailFrame then return end
    local f=CreateFrame("Frame","AuctionStatsDetailFrame",UIParent,"BackdropTemplate")
    f:SetSize(W,H); f:SetPoint("CENTER",30,0); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart",f.StartMoving); f:SetScript("OnDragStop",f.StopMovingOrSizing)
    -- НИЖЕ ИМЕННО ТОТ ЖЕ BACKGROUND, ЧТО И В SUMMARY:
    f:SetBackdrop{ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=32,edgeSize=32,insets={left=8,right=8,top=8,bottom=8} }
    f.title=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge"); f.title:SetPoint("TOP",0,-8); f.title:SetText("Details")
    CreateFrame("Button",nil,f,"UIPanelCloseButton"):SetPoint("TOPRIGHT",-6,-6)

    local sb=CreateFrame("EditBox","AuctionStatsDetailSearchBox",f,"SearchBoxTemplate")
    sb:SetSize(200,20); sb:SetPoint("TOPLEFT",20,-40); sb:SetAutoFocus(false)
    if sb.SetPromptText then sb:SetPromptText("Поиск") end
    sb:SetScript("OnTextChanged",function() AuctionStats:DrawDetail() end)
    self.detailSearch=sb

    local hdr=CreateFrame("Frame",nil,f); hdr:SetSize(W-60,HDR_H); hdr:SetPoint("TOPLEFT",20,-70)
    for _,c in ipairs({{x=D_POS_NUM,t="#"},{x=D_POS_ID,t="ID"},{x=D_POS_ICON,t="",w=ICON_SIZE},
        {x=D_POS_NAME,t="Name",w=D_NAME_W},{x=D_POS_LEVEL,t="Level"},{x=D_POS_QTY,t="Qty"},
        {x=D_POS_TIME,t="Time"},{x=D_POS_BUY,t="Buyout"},{x=D_POS_BID,t="Bid"},}) do
        local fs=hdr:CreateFontString(nil,"OVERLAY","GameFontHighlight"); fs:SetPoint("LEFT",hdr,"LEFT",c.x,0); fs:SetText(c.t)
    end

    local half=(H-140)/2
    local sc=CreateFrame("ScrollFrame","AuctionStatsDetailScrollFrame",f,"UIPanelScrollFrameTemplate")
    sc:SetPoint("TOPLEFT",hdr,"BOTTOMLEFT",0,-4); sc:SetSize(W-60,half)
    local ct=CreateFrame("Frame",nil,sc); ct:SetPoint("TOPLEFT",sc,"TOPLEFT",0,0); ct:SetSize(W-60,ROW_H)
    sc:SetScrollChild(ct); self.detailContent=ct

    local hh=f:CreateFontString(nil,"OVERLAY","GameFontHighlight"); hh:SetPoint("TOPLEFT",sc,"BOTTOMLEFT",0,-10); hh:SetText("History")
    local hhdr=CreateFrame("Frame",nil,f); hhdr:SetSize(W-60,HDR_H); hhdr:SetPoint("TOPLEFT",hh,"BOTTOMLEFT",0,-2)
    for _,c in ipairs({{x=H_POS_NUM,t="#"},{x=H_POS_TIME,t="Date"},{x=H_POS_QTY,t="Qty"},
        {x=H_POS_PRICE,t="Price"},{x=H_POS_DUR,t="Dur"},{x=H_POS_OPERATION,t="Operation"},}) do
        local fs=hhdr:CreateFontString(nil,"OVERLAY","GameFontHighlight"); fs:SetPoint("LEFT",hhdr,"LEFT",c.x,0); fs:SetText(c.t)
    end

    local hsc=CreateFrame("ScrollFrame","AuctionStatsHistoryScrollFrame",f,"UIPanelScrollFrameTemplate")
    hsc:SetPoint("TOPLEFT",hhdr,"BOTTOMLEFT",0,-4); hsc:SetSize(W-60,half-(HDR_H+10))
    local hct=CreateFrame("Frame",nil,hsc); hct:SetPoint("TOPLEFT",hsc,"TOPLEFT",0,0); hct:SetSize(W-60,ROW_H)
    hsc:SetScrollChild(hct); self.historyContent=hct

    self.detailStats=f:CreateFontString(nil,"OVERLAY","GameFontNormal"); self.detailStats:SetPoint("BOTTOMLEFT",20,20)
    self.detailFrame=f
end

-- 8) UI: рисуем Detail + History
function AuctionStats:DrawDetail()
    local list=self.detailData or {} local filter=strlower(self.detailSearch:GetText() or "") local filtered={}
    for _,a in ipairs(list) do if filter=="" or strlower(a.name):find(filter,1,true) then tinsert(filtered,a) end end

    local ct=self.detailContent; ct:SetSize(W-60,#filtered*ROW_H)
    for _,ln in ipairs(self.detailLines) do ln:Hide() end
    for i,a in ipairs(filtered) do
        local ln=self.detailLines[i]
        if not ln then
            ln=CreateFrame("Frame",nil,ct); ln:SetSize(W-60,ROW_H)
            ln.num=ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.id=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.icon=ln:CreateTexture(nil,"ARTWORK"); ln.icon:SetSize(ICON_SIZE,ICON_SIZE)
            ln.name=ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.name:SetWidth(D_NAME_W); ln.name:SetJustifyH("LEFT")
            ln.level=ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.qty=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.tl=ln:CreateFontString(nil,"OVERLAY","GameFontNormal"); ln.bo=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.bd=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.num:SetPoint("LEFT",D_POS_NUM,0); ln.id:SetPoint("LEFT",D_POS_ID,0)
            ln.icon:SetPoint("LEFT",D_POS_ICON,0); ln.name:SetPoint("LEFT",D_POS_NAME,0)
            ln.level:SetPoint("LEFT",D_POS_LEVEL,0); ln.qty:SetPoint("LEFT",D_POS_QTY,0)
            ln.tl:SetPoint("LEFT",D_POS_TIME,0); ln.bo:SetPoint("LEFT",D_POS_BUY,0); ln.bd:SetPoint("LEFT",D_POS_BID,0)
            self.detailLines[i]=ln
        end
        ln:SetPoint("TOPLEFT",ct,"TOPLEFT",0,-(i-1)*ROW_H)
        ln.num:SetText(i); ln.id:SetText(a.itemID); ln.icon:SetTexture(a.icon)
        ln.name:SetText(a.name); local r,gc,b=GetItemQualityColor(a.quality); ln.name:SetTextColor(r,gc,b)
        ln.level:SetText(a.itemLevel or ""); ln.qty:SetText(a.quantity); ln.tl:SetText(a.timeLeft)
        ln.bo:SetText(a.buyout); ln.bd:SetText(a.bid); ln:Show()
        ln:SetScript("OnEnter",function(self) GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetHyperlink(a.link); GameTooltip:Show() end)
        ln:SetScript("OnLeave",function() GameTooltip:Hide() end)
    end

    local title=self.detailFrame.title:GetText() or "" local id=tonumber(title:match("%[(%d+)%]"))
    local hist=(id and AuctionStatsDB.history[id]) or {}
    local hct=self.historyContent; hct:SetSize(W-60,#hist*ROW_H)
    for _,ln in ipairs(self.historyLines) do ln:Hide() end
    for i,e in ipairs(hist) do
        local ln=self.historyLines[i]
        if not ln then
            ln=CreateFrame("Frame",nil,hct); ln:SetSize(W-60,ROW_H)
            ln.num=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.time=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.qty=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.price=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.dur=ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.op= ln:CreateFontString(nil,"OVERLAY","GameFontNormal")
            ln.num:SetPoint("LEFT",H_POS_NUM,0)
            ln.time:SetPoint("LEFT",H_POS_TIME,0)
            ln.qty:SetPoint("LEFT",H_POS_QTY,0)
            ln.price:SetPoint("LEFT",H_POS_PRICE,0)
            ln.dur:SetPoint("LEFT",H_POS_DUR,0)
            ln.op:SetPoint("LEFT",H_POS_OPERATION,0)
            self.historyLines[i]=ln
        end
        ln:SetPoint("TOPLEFT",hct,"TOPLEFT",0,-(i-1)*ROW_H)
        ln.num:SetText(i); ln.time:SetText(e.time); ln.qty:SetText(e.quantity); ln.price:SetText(e.buyout)
        local code=e.durationCode or e.duration; local hrs=DurationHours[code] or code or 0
        ln.dur:SetText(hrs.."h"); ln.op:SetText(e.operation or ""); ln:Show()
    end

    local cnt,cost=0,0 for _,a in ipairs(filtered) do cnt=cnt+a.quantity; cost=cost+(a.rawBuyout*a.quantity) end
    self.detailStats:SetText(format("Items: %d   Total: %s   Last Sync: %s",cnt,FormatMoney(cost),self.lastSyncTime or "N/A"))
    self.detailFrame:Show()
end

-- 9) ShowDetail
function AuctionStats:ShowDetail(group)
    self:CreateDetailWindow()
    self.detailFrame.title:SetText(format("Details: %s [%d]",group.name,group.itemID))
    self.detailData={} for _,a in ipairs(group.rawGroup) do tinsert(self.detailData,a) end
    AuctionStats:DrawDetail()
end

-- 10) Events
local handler=CreateFrame("Frame")
handler:RegisterEvent("ADDON_LOADED"); handler:RegisterEvent("AUCTION_HOUSE_SHOW"); handler:RegisterEvent("OWNED_AUCTIONS_UPDATED")
handler:SetScript("OnEvent",function(_,e,arg1)
    print("AuctionStats Debug: Event:",e,arg1 or"")
    if e=="ADDON_LOADED" and arg1=="AuctionStats" then
        AuctionStatsDB.history=AuctionStatsDB.history or{}
        if AuctionStatsDB.storedAuctions and #AuctionStatsDB.storedAuctions>0 then
            AuctionStats.dbAuctions=AuctionStatsDB.storedAuctions
        end
    elseif e=="AUCTION_HOUSE_SHOW" then
        C_AuctionHouse.QueryOwnedAuctions({})
    elseif e=="OWNED_AUCTIONS_UPDATED" then
        AuctionStats:CacheAuctions()
        if AuctionStats.summaryFrame and AuctionStats.summaryFrame:IsShown() then AuctionStats:DrawSummary() end
        if AuctionStats.detailFrame and AuctionStats.detailFrame:IsShown() then AuctionStats:DrawDetail() end
    end
end)

-- 11) Slash
SLASH_AUCTIONSTATS1="/astat"
SlashCmdList["AUCTIONSTATS"]=function() AuctionStats:CreateSummaryWindow(); AuctionStats:DrawSummary() end
