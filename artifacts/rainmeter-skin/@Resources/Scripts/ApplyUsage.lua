-- Rainmeter controller. Graph calculations and geometry are delegated to GraphModel / GraphView.
local Model,View,model
local values,shapeCounts={},{}
local historyRows={}
local expanded=false
local hoverKind,hoverIndex
local compact,detailHeight,detailsY=150,470,150

local function opt(m,k,v) SKIN:Bang('!SetOption',m,k,tostring(v)) end
local function vis(m,on) SKIN:Bang(on and '!ShowMeter' or '!HideMeter',m) end
local function txt(m,v) opt(m,'Text',v or '') end
local function safe(s) return tostring(s or ''):gsub('[\r\n]',' '):gsub('#',''):gsub('%[','('):gsub('%]',')') end
local function pct(v) return string.format('%.1f',v or 0):gsub('%.0$','') end
local function shapes(m,list)
  for i=1,math.max(shapeCounts[m] or 1,#list) do
    opt(m,i==1 and 'Shape' or 'Shape'..i,list[i] or 'Line 0,0,0,0 | StrokeWidth 0')
  end
  shapeCounts[m]=#list
end

local function signed(v,suffix)
  v=tonumber(v) or 0
  return (v>=0 and '+' or '')..pct(v)..(suffix or '')
end

local function paceText(c)
  local p=c and c.pace
  if not p or not p.valid then return 'Pace: collecting' end
  return 'Pace '..signed(p.delta,'%p')..'  |  '..Model.paceLabel(p.stage)..'  |  ideal '..pct(p.expected)..'%'
end

local function forecastText(c)
  if not c then return 'Forecast: unavailable' end
  if c.idle then return 'Forecast: idle / waiting for usage' end
  if c.expired then return 'Forecast: waiting for reset data' end
  local f=c.current
  if not f or not f.valid then return 'Forecast: collecting trend' end

  local etaText=nil
  local pace=c.pace
  if pace and pace.valid then
    if pace.etaSeconds~=nil then
      if pace.etaSeconds<=1 then etaText='Exhausted now'
      else etaText='ETA '..Model.duration(pace.etaSeconds) end
    elseif pace.willLastToReset then
      etaText='Lasts to reset'
    end
  end
  if not etaText then
    local remain=math.max(0,(f.crossingEpoch or model.now)-model.now)
    etaText=remain<=1 and 'Exhausted now' or ('ETA '..Model.duration(remain))
  end

  local margin=f.margin
  if margin~=nil then
    etaText=etaText..'  |  reset margin '..(margin<0 and '-' or '+')..Model.duration(math.abs(margin))
  end
  return etaText
end

local function hint()
  if not model then return end
  local c=hoverKind and model[hoverKind]
  local b=c and c.buckets[hoverIndex]
  if not b then
    txt('DetailReadout','Hover a slot for interval / cumulative usage.#CRLF#Line explanations are available from the legend tooltips.')
    return
  end
  local a=b.actualStartEpoch or b.startEpoch
  local z=b.actualEndEpoch or b.endEpoch
  if not b.observed then
    txt('DetailReadout',os.date('%m-%d %H:%M',a)..' - '..os.date('%H:%M',z)..'#CRLF#No observation in this slot.')
    return
  end
  local endShown=math.min(z,b.epoch or z)
  local first=os.date('%m-%d %H:%M',a)..' - '..os.date('%H:%M',endShown)
  local use=''
  if hoverKind=='session' then
    use=b.delta~=nil and ('+'..pct(b.delta)..'% interval; ') or 'Interval delta unknown; '
  end
  txt('DetailReadout',first..(b.partial and ' (in progress)' or '')..'#CRLF#'..use..pct(b.cumulative)..'% cumulative')
end

local function status()
  local err=values.Connected~='1'
  local warning=''
  if not err and model then
    for _,kind in ipairs({'session','weekly'}) do
      local c=model[kind];local p=c.current
      local threshold=kind=='session' and 3600 or 86400
      local percentThreshold=kind=='session' and 80 or 90
      if not c.expired and c.latest and (c.latest[kind]>=percentThreshold or (p.valid and p.margin<=threshold)) then
        local _,margin=Model.forecast(p,model.now)
        warning=(kind=='session' and 'Session' or 'Weekly')..': '..
          (margin and ('reset margin '..(margin<0 and '-' or '+')..Model.duration(math.abs(margin))) or 'usage is high')
        break
      end
    end
  end
  local lines={}
  if err then
    for i=1,3 do if values['Error'..i] and values['Error'..i]~='' then lines[#lines+1]=safe(values['Error'..i]) end end
    if #lines==0 then lines[1]='Waiting for a successful fetch' end
  end
  local height=err and (#lines*34+16) or (warning~='' and 38 or 0)
  local bg=err and '103,34,42,250' or (warning~='' and '99,62,25,250' or '24,29,36,250')
  return height,bg,lines,warning
end

function Layout()
  if not View then return end
  local sh,bg,errors,warning=status()
  detailsY=compact+sh
  local height=detailsY+(expanded and detailHeight or 0)
  opt('MeterBg','Shape','Rectangle 0,0,320,'..height..',10 | StrokeWidth 1 | Stroke Color 130,145,163,65 | Fill Color '..bg)
  vis('MeterNotice',warning~='');txt('MeterNotice',warning);opt('MeterNotice','Y',warning~='' and compact+8 or 0)
  for i=1,3 do txt('MeterError'..i,errors[i] or '');opt('MeterError'..i,'Y',errors[i] and compact+8+(i-1)*34 or 0);vis('MeterError'..i,errors[i]~=nil) end

  local offsets={
    LegendTrend=8,LegendCurrent=8,LegendPrevious=8,
    LegendIdeal=24,LegendStart=24,LegendNow=24,
    SessionLabel=46,SessionChart=70,SessionStart=158,SessionCenter=158,SessionEnd=158,
    SessionOverall=178,SessionCurrent=194,
    WeeklyLabel=226,WeeklyChart=250,WeeklyStart=338,WeeklyCenter=338,WeeklyEnd=338,
    WeeklyOverall=358,WeeklyCurrent=374,DetailReadout=406
  }
  for m,y in pairs(offsets) do opt(m,'Y',expanded and detailsY+y or 0);vis(m,expanded) end

  for _,kind in ipairs({'Session','Weekly'}) do
    local top=detailsY+(kind=='Session' and 70 or 250)
    for _,tick in ipairs({100,50}) do
      opt(kind..'Axis'..tick,'Y',expanded and top+(100-tick)*View.height/100 or 0);vis(kind..'Axis'..tick,expanded)
    end
    local hitCount=kind=='Session' and 20 or 28
    for i=1,hitCount do
      local m=kind..'Hit'..i
      opt(m,'Y',expanded and top or 0)
      vis(m,expanded)
    end
  end
  hint();SKIN:Bang('!UpdateMeter','*');SKIN:Bang('!Redraw')
end

function OpenDetails() if not expanded then expanded=true;Layout() end end
function CloseDetails() expanded=false;hoverKind=nil;hoverIndex=nil;Layout() end
function Hover(kind,index) hoverKind=kind;hoverIndex=index;hint();SKIN:Bang('!UpdateMeter','DetailReadout');SKIN:Bang('!Redraw') end
function ClearHover() hoverKind=nil;hoverIndex=nil;hint();SKIN:Bang('!UpdateMeter','DetailReadout');SKIN:Bang('!Redraw') end

local function draw()
  for _,kind in ipairs({'session','weekly'}) do
    local name=kind=='session' and 'Session' or 'Weekly'
    local c=model[kind];local v=View.chart(c)
    shapes(name..'Chart',v.shapes)
    local fmt=kind=='session' and '%H:%M' or '%m-%d %H:%M'
    local leftEpoch=c.previousStartEpoch or c.startEpoch
    txt(name..'Start',leftEpoch>0 and os.date(fmt,leftEpoch)..(c.previousObserved and ' prev' or '') or '-')
    txt(name..'Center',c.centerEpoch>0 and os.date(fmt,c.centerEpoch)..(c.idle and ' current idle' or ' current') or '-')
    txt(name..'End',c.endEpoch>0 and os.date(fmt,c.endEpoch)..' reset' or '-')
    txt(name..'Overall',paceText(c))
    txt(name..'Current',forecastText(c))

    local hitCount=name=='Session' and 20 or 28
    for i=1,hitCount do
      local hit=v.hits[i]
      if hit then
        local m=name..'Hit'..i
        opt(m,'X',View.left+hit.x);opt(m,'W',hit.w);opt(m,'H',View.height)
      end
    end
  end
end

function Initialize()
  Model=dofile(SKIN:GetVariable('@')..'Scripts\\GraphModel.lua')
  View=dofile(SKIN:GetVariable('@')..'Scripts\\GraphView.lua')
end

function Apply()
  local f=io.open(SKIN:GetVariable('@')..'Usage.inc','r')
  if f then
    local incoming={}
    for line in f:lines() do local k,v=line:match('^([%w_]+)=(.*)$');if k then incoming[k]=v:gsub('\r$','') end end
    f:close();if incoming.Connected then values=incoming end
  end
  local rows={}
  local hf=io.open(SKIN:GetVariable('@')..'UsageHistory.jsonl','r')
  if hf then for line in hf:lines() do local r=Model.parseLine(line);if r then rows[#rows+1]=r end end;hf:close() end
  historyRows=rows
  model=Model.build(historyRows,os.time())
  txt('MeterPlan',safe(values.PlanName or '-'))
  local hasUsage=values.HasUsageData~='0'
  txt('MeterPrimaryLabel','Session  '..(hasUsage and values.PrimaryPercent and pct(tonumber(values.PrimaryPercent))..'%' or '--'))
  txt('MeterSecondaryLabel','Weekly   '..(hasUsage and values.SecondaryPercent and pct(tonumber(values.SecondaryPercent))..'%' or '--'))
  for _,kind in ipairs({'Primary','Secondary'}) do
    local p=math.max(0,math.min(100,tonumber(values[kind..'Percent']) or 0))
    opt('Meter'..kind..'Fill','Shape','Rectangle 0,0,'..(288*p/100)..',6,3 | Fill Color 121,193,218 | StrokeWidth 0')
  end
  opt('MeterStatus','ToolTipText','Fetched at '..safe(values.UpdatedAt or 'never')..'#CRLF#Click to refresh')
  draw();Update();Layout()
end

function Update()
  if not Model then return 0 end
  local now=os.time();local epoch=tonumber(values.UpdatedEpoch) or 0;local age=math.max(0,now-epoch)
  if model and ((not model.session.expired and now>=model.session.currentEndEpoch) or
    (not model.weekly.expired and now>=model.weekly.currentEndEpoch)) then
    model=Model.build(historyRows,now);draw();Layout()
  end
  local ageText=age<5 and 'just now' or (age<60 and math.floor(age)..'s ago' or age<3600 and math.floor(age/60)..'m ago' or math.floor(age/3600)..'h ago')
  txt('MeterStatus',epoch>0 and 'Updated at '..ageText or 'No successful fetch yet')
  for _,pair in ipairs({{'session','Primary'},{'weekly','Secondary'}}) do
    local e=tonumber(values[pair[2]..'ResetEpoch']);local c=model and model[pair[1]]
    e=e or (c and c.currentEndEpoch)
    txt('Meter'..pair[2]..'Reset',e and e>now and Model.duration(e-now)..' to reset' or 'reset pending')
  end
  SKIN:Bang('!UpdateMeter','MeterStatus');SKIN:Bang('!UpdateMeter','MeterPrimaryReset');SKIN:Bang('!UpdateMeter','MeterSecondaryReset')
  return 0
end
