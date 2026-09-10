-- Pure Lua 5.1. Percent values are percentage POINTS of the account window.
local M = {}
local function number(line,key)
  return tonumber(line:match('"'..key..'"%s*:%s*([^,%}%s]+)'))
end
local function utc(s)
  local y,m,d,h,mi,se=s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  y,m,d,h,mi,se=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(mi),tonumber(se)
  if m<1 or m>12 or d<1 or d>31 or h>23 or mi>59 or se>59 then return nil end
  -- Gregorian days from civil date; independent of Windows timezone / DST.
  y=y-(m<=2 and 1 or 0)
  local era=math.floor(y/400)
  local yo=y-era*400
  local mp=m+(m>2 and -3 or 9)
  local doy=math.floor((153*mp+2)/5)+d-1
  local days=era*146097+yo*365+math.floor(yo/4)-math.floor(yo/100)+doy-719468
  local sign,oh,om=s:match('([%+%-])(%d%d):(%d%d)$')
  local offset=0
  if sign then
    oh,om=tonumber(oh),tonumber(om)
    if oh>23 or om>59 then return nil end
    offset=(oh*3600+om*60)*(sign=='+' and 1 or -1)
  end
  return days*86400+h*3600+mi*60+se-offset
end
function M.parseLine(line)
  local ts=line:match('"timestamp"%s*:%s*"([^"]+)"')
  local r={epoch=number(line,'epoch') or (ts and utc(ts)), timestamp=ts,
    session=number(line,'session'), weekly=number(line,'weekly'),
    sessionReset=number(line,'sessionReset'),weeklyReset=number(line,'weeklyReset')}
  if not r.epoch or not r.session or not r.weekly or not r.sessionReset or not r.weeklyReset then return nil end
  if r.session<0 or r.session>100 or r.weekly<0 or r.weekly>100 then return nil end
  return r
end
local function median(a)
  table.sort(a); local n=#a
  if n==0 then return nil end
  return n%2==1 and a[(n+1)/2] or (a[n/2]+a[n/2+1])/2
end
local function fit(rows,key,start)
  -- At most one vote per minute, latest poll wins.
  local byMinute={}
  for _,r in ipairs(rows) do byMinute[math.floor((r.epoch-start)/60)]=r end
  local pts={}
  for _,r in pairs(byMinute) do pts[#pts+1]={x=r.epoch-start,y=r[key]} end
  table.sort(pts,function(a,b) return a.x<b.x end)
  if #pts<2 or pts[#pts].x-pts[1].x<60 then return nil end
  local mx,my=0,0
  for _,p in ipairs(pts) do mx=mx+p.x; my=my+p.y end
  mx,my=mx/#pts,my/#pts
  local xx,xy=0,0
  for _,p in ipairs(pts) do xx=xx+(p.x-mx)^2; xy=xy+(p.x-mx)*(p.y-my) end
  if xx<=0 then return nil end
  return math.max(0,xy/xx)
end
local function projection(rate,latest,key,start,finish,now,count)
  local p={valid=false,slope=rate or 0,cycles=count or 0}
  if not latest or not rate or rate<=0 or now>=finish then return p end
  p.valid=true
  p.intercept=latest[key]-rate*(latest.epoch-start)
  p.crossingEpoch=latest.epoch+(100-latest[key])/rate
  p.margin=p.crossingEpoch-finish
  p.startEpoch=math.max(start,start-p.intercept/rate)
  p.endEpoch=math.min(finish,p.crossingEpoch)
  p.startValue=math.max(0,p.intercept+rate*(p.startEpoch-start))
  p.endValue=math.min(100,p.intercept+rate*(p.endEpoch-start))
  return p
end
local function chart(rows,now,key,duration,count)
  local resetKey=key..'Reset'
  local latest=rows[#rows]
  local finish=latest and latest[resetKey] or 0
  local start=finish-duration
  local c={kind=key,startEpoch=start,endEpoch=finish,duration=duration,count=count,
    buckets={},current={valid=false},overall={valid=false},expired=now>=finish}
  local groups={}
  -- Servers may jitter reset_at by a second. Use bounded, non-transitive clusters;
  -- retain the latest reported end for the active window and never rewrite raw history.
  local endpoints,seen,canonical={}, {}, {}
  for _,r in ipairs(rows) do
    local e=r[resetKey]
    if not seen[e] then endpoints[#endpoints+1]=e;seen[e]=true end
  end
  table.sort(endpoints)
  local anchor
  for _,e in ipairs(endpoints) do
    if math.abs(e-finish)<=60 then canonical[e]=finish
    else
      if not anchor or e-anchor>60 then anchor=e end
      canonical[e]=anchor
    end
  end
  for _,r in ipairs(rows) do
    local raw=r[resetKey];local e=canonical[raw]
    if raw>0 and r.epoch>=raw-duration and r.epoch<=raw then
      groups[e]=groups[e] or {}; table.insert(groups[e],r)
    end
  end
  local current=groups[finish] or {}
  local tail=current[#current]
  c.latest=tail
  local rates={}
  for e,group in pairs(groups) do
    -- A decrease within the same reset is a correction, not negative consumption.
    local clean={}
    for _,r in ipairs(group) do
      if #clean>0 and r[key]<clean[#clean][key] then clean={} end
      clean[#clean+1]=r
    end
    local rate=fit(clean,key,e-duration)
    -- Idle zero-only rolling windows are not consumed reset cycles. Counting them
    -- as independent zero-rate histories would drown out every real usage cycle.
    if rate and clean[#clean][key]>0 then rates[#rates+1]=rate end
    if e==finish then c.current=projection(rate,tail,key,start,finish,now,1) end
  end
  c.overall=projection(median(rates),tail,key,start,finish,now,#rates)
  local step=duration/count
  local index=1
  local baseline
  while current[index] and current[index].epoch<=start do baseline=current[index];index=index+1 end
  -- A real zero soon after reset proves no earlier usage; reset change alone does not.
  if not baseline and current[index] and current[index].epoch<=start+300 and current[index][key]==0 then
    baseline=current[index]
  end
  local layers={}
  local previous=baseline
  for i=1,count do
    local a,b=start+(i-1)*step,start+i*step
    local bucket={observed=false,startEpoch=a,endEpoch=b,partial=now<b,layers={},boundaries={}}
    c.buckets[i]=bucket
    if a<now then
      local limit=math.min(b,now)
      local selected
      while current[index] and current[index].epoch<=limit do selected=current[index];index=index+1 end
      if selected then
        bucket.observed=true
        bucket.epoch=selected.epoch
        bucket.cumulative=selected[key]
        bucket.timestamp=selected.timestamp
        -- Older cumulative readings alone cannot prove which missing interval used quota.
        local completeBase=previous and math.abs(previous.epoch-a)<=300
        if completeBase and selected[key]>=previous[key] then
          bucket.delta=selected[key]-previous[key]
        end
        if key=='weekly' then
          local sum=0
          for _,l in ipairs(layers) do sum=sum+l.value end
          if selected[key]<sum then
            layers={{value=selected[key],known=false,source=i,correction=true}}
            bucket.corrected=true
          elseif #layers==0 then
            layers[1]={value=selected[key],known=not not completeBase,source=i}
          else
            layers[#layers+1]={value=selected[key]-sum,known=not not completeBase,source=i}
          end
          local cumulative=0
          for j,l in ipairs(layers) do
            bucket.layers[j]={value=l.value,known=l.known,source=l.source,correction=l.correction}
            cumulative=cumulative+l.value
            if cumulative>0 and cumulative<selected[key] and
               bucket.boundaries[#bucket.boundaries]~=cumulative then
              bucket.boundaries[#bucket.boundaries+1]=cumulative
            end
          end
        end
        previous=selected
      end
    end
  end
  return c
end
function M.build(input,now)
  local rows={}
  for _,r in ipairs(input) do
    if r.epoch and r.epoch<=now and r.epoch>=now-60*86400 then rows[#rows+1]=r end
  end
  table.sort(rows,function(a,b) return a.epoch<b.epoch end)
  return {session=chart(rows,now,'session',18000,10),weekly=chart(rows,now,'weekly',604800,14),now=now}
end
function M.duration(s)
  s=math.max(0,math.floor(s or 0))
  if s>=86400 then return math.floor(s/86400)..'d '..math.floor(s%86400/3600)..'h' end
  if s>=3600 then return math.floor(s/3600)..'h '..math.floor(s%3600/60)..'m' end
  if s>=60 then return math.floor(s/60)..'m' end
  return s..'s'
end
function M.forecast(p,now)
  if not p.valid then return 'Collecting trend',nil end
  local margin=p.margin
  return '100% ~'..os.date('%m-%d %H:%M',p.crossingEpoch)..' ('..
    (margin<0 and '-' or '+')..M.duration(math.abs(margin))..')',margin
end
return M
