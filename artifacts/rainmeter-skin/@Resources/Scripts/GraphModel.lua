-- Pure Lua 5.1. Percent values are percentage points of a quota window.
-- Cycles are reconstructed from stable reset endpoints observed while usage > 0.
-- This avoids treating drifting reset_at values during idle / zero usage as new cycles.
local M = {}

local function number(line,key)
  return tonumber(line:match('"'..key..'"%s*:%s*([^,%}%s]+)'))
end

local function utc(s)
  local y,m,d,h,mi,se=s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  y,m,d,h,mi,se=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(mi),tonumber(se)
  if m<1 or m>12 or d<1 or d>31 or h>23 or mi>59 or se>59 then return nil end
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
    sessionReset=number(line,'sessionReset'), weeklyReset=number(line,'weeklyReset')}
  if not r.epoch or r.session==nil or r.weekly==nil or not r.sessionReset or not r.weeklyReset then return nil end
  if r.session<0 or r.session>100 or r.weekly<0 or r.weekly>100 then return nil end
  return r
end

-- Trend 1 regression: y = rate*x, constrained through the current quota-window origin (0,0).
local function fitOrigin(points)
  local xx,xy,used=0,0,0
  for _,p in ipairs(points or {}) do
    if p.x and p.x>0 and p.y and p.y>=0 then
      xx=xx+p.x*p.x
      xy=xy+p.x*p.y
      used=used+1
    end
  end
  if used<1 or xx<=0 then return nil,used end
  local rate=xy/xx
  if rate<=0 then return nil,used end
  return rate,used
end

-- CodexBar-compatible pace classification.  Delta is percentage points:
-- actual cumulative usage - ideal time-proportional usage.
function M.paceStage(delta)
  local d=tonumber(delta) or 0
  local a=math.abs(d)
  if a<=2 then return 'on_track' end
  if a<=6 then return d>=0 and 'slightly_ahead' or 'slightly_behind' end
  if a<=12 then return d>=0 and 'ahead' or 'behind' end
  return d>=0 and 'far_ahead' or 'far_behind'
end

function M.paceLabel(stage)
  local labels={
    on_track='on pace',
    slightly_ahead='slightly fast',ahead='fast',far_ahead='very fast',
    slightly_behind='slightly slow',behind='slow',far_behind='very slow'
  }
  return labels[stage] or tostring(stage or '-')
end

local function clamp(v,lo,hi)
  if v<lo then return lo end
  if v>hi then return hi end
  return v
end

local function paceSnapshot(latest,key,now,start,finish)
  local p={valid=false,actual=0,expected=0,delta=0,stage='on_track',
    etaSeconds=nil,willLastToReset=false}
  if not latest or latest[key]==nil or not start or not finish or finish<=start then return p end
  local duration=finish-start
  local timeUntilReset=finish-now
  if timeUntilReset<=0 or timeUntilReset>duration then return p end
  local elapsed=clamp(now-start,0,duration)
  local actual=clamp(latest[key],0,100)
  if elapsed==0 and actual>0 then return p end
  local expected=clamp((elapsed/duration)*100,0,100)
  local delta=actual-expected

  p.valid=true
  p.actual=actual
  p.expected=expected
  p.delta=delta
  p.stage=M.paceStage(delta)
  p.elapsed=elapsed
  p.timeUntilReset=timeUntilReset

  if elapsed>0 and actual>0 then
    local rate=actual/elapsed
    if rate>0 then
      local remaining=math.max(0,100-actual)
      local candidate=remaining/rate
      if candidate>=timeUntilReset then
        p.willLastToReset=true
      else
        p.etaSeconds=candidate
      end
    end
  elseif elapsed>0 and actual==0 then
    p.willLastToReset=true
  end
  return p
end

local function projectionOrigin(rate,start,finish,cycles,samples)
  local p={valid=false,slope=rate or 0,intercept=0,cycles=cycles or 0,samples=samples or 0,
    startEpoch=start,startValue=0,drawStartEpoch=start,drawStartValue=0}
  if not rate or rate<=0 or not start or not finish or finish<=start then return p end
  p.valid=true
  p.crossingEpoch=start+100/rate
  p.margin=p.crossingEpoch-finish
  p.endEpoch=math.min(finish,p.crossingEpoch)
  p.drawEndEpoch=p.endEpoch
  p.endValue=math.min(100,math.max(0,rate*(p.drawEndEpoch-start)))
  return p
end

-- Copy a completed previous-cycle forecast onto the current cycle's time origin.
-- Only the origin shifts; its pace / slope is preserved exactly.
local function shiftedForecast(source,sourceStart,targetStart,targetFinish)
  local q={valid=false,slope=0,intercept=0,samples=source and source.samples or 0,
    startEpoch=targetStart,startValue=0,drawStartEpoch=targetStart,drawStartValue=0}
  if not source or not source.valid or not sourceStart or not targetStart or not targetFinish then return q end
  local relCross=source.crossingEpoch-sourceStart
  if relCross<=0 then return q end
  q.valid=true
  q.slope=source.slope
  q.sourceCrossingEpoch=source.crossingEpoch
  q.crossingEpoch=targetStart+relCross
  q.margin=q.crossingEpoch-targetFinish
  q.endEpoch=math.min(targetFinish,q.crossingEpoch)
  q.drawEndEpoch=q.endEpoch
  q.endValue=math.min(100,math.max(0,q.slope*(q.drawEndEpoch-targetStart)))
  return q
end

local function medianWeighted(values,counts)
  local total=0
  for _,v in ipairs(values) do total=total+(counts[v] or 0) end
  if total<=0 then return nil end
  local target=math.floor((total+1)/2)
  local acc=0
  for _,v in ipairs(values) do
    acc=acc+(counts[v] or 0)
    if acc>=target then return v end
  end
  return values[#values]
end

local function nearestCycle(cycles,reset,tolerance)
  if not reset or #cycles==0 then return nil end
  local lo,hi=1,#cycles
  while lo<=hi do
    local mid=math.floor((lo+hi)/2)
    if cycles[mid].finish<reset then lo=mid+1 else hi=mid-1 end
  end
  local best,bestDiff=nil,nil
  for _,i in ipairs({lo-1,lo}) do
    if i>=1 and i<=#cycles then
      local d=math.abs(cycles[i].finish-reset)
      if d<=tolerance and (not bestDiff or d<bestDiff) then best,bestDiff=cycles[i],d end
    end
  end
  return best
end

-- Stable reset_at values while usage > 0 are the strongest cycle identifier in the
-- observed API data. Idle rows can report a moving reset_at (roughly now+window), so
-- zero rows do not create cycle endpoints.
local function buildCycles(rows,key,duration)
  local resetKey=key..'Reset'
  local endpointCounts={}
  for _,r in ipairs(rows) do
    local reset=r[resetKey]
    local remaining=reset and (reset-r.epoch) or nil
    if r[key]>0 and reset and reset>0 and remaining and remaining>=-120 and remaining<=duration+600 then
      endpointCounts[reset]=(endpointCounts[reset] or 0)+1
    end
  end

  local unique={}
  for e,_ in pairs(endpointCounts) do unique[#unique+1]=e end
  table.sort(unique)

  -- Positive-usage endpoints in the real history jitter by only a few seconds.
  -- Five seconds merges that jitter without merging distinct windows.
  local groups,current={},{}
  for _,e in ipairs(unique) do
    if #current==0 or e-current[#current]<=5 then
      current[#current+1]=e
    else
      groups[#groups+1]=current
      current={e}
    end
  end
  if #current>0 then groups[#groups+1]=current end

  local cycles={}
  for _,g in ipairs(groups) do
    local finish=medianWeighted(g,endpointCounts)
    if finish then
      cycles[#cycles+1]={finish=finish,start=finish-duration,rows={},positiveCount=0}
      for _,e in ipairs(g) do cycles[#cycles].positiveCount=cycles[#cycles].positiveCount+(endpointCounts[e] or 0) end
    end
  end
  table.sort(cycles,function(a,b) return a.finish<b.finish end)

  -- Assign all compatible rows, including observed zeros, to the nearest stable cycle.
  -- The wider 120 s assignment tolerance keeps harmless reset jitter but rejects the
  -- multi-hour/day moving reset_at values that caused the old graph to fragment.
  for _,r in ipairs(rows) do
    local c=nearestCycle(cycles,r[resetKey],120)
    if c and r.epoch>=c.start-120 and r.epoch<=c.finish+120 then
      c.rows[#c.rows+1]=r
    end
  end
  for _,c in ipairs(cycles) do
    table.sort(c.rows,function(a,b) return a.epoch<b.epoch end)
    if #c.rows>0 then
      c.firstEpoch=c.rows[1].epoch
      c.lastEpoch=c.rows[#c.rows].epoch
    end
  end
  return cycles
end

local function lastPerSlot(group,key,cycleStart,cycleFinish,count,now,isCurrent)
  local slots={}
  local step=(cycleFinish-cycleStart)/count
  for _,r in ipairs(group or {}) do
    if r.epoch>=cycleStart-120 and r.epoch<=cycleFinish+1 and (not isCurrent or r.epoch<=now) then
      local i=math.floor((r.epoch-cycleStart)/step)+1
      if i<1 then i=1 elseif i>count then i=count end
      if not slots[i] or r.epoch>=slots[i].epoch then slots[i]=r end
    end
  end
  return slots
end

local function copyLayers(src)
  local out={}
  for i,l in ipairs(src or {}) do
    out[i]={value=l.value,known=l.known,source=l.source,correction=l.correction}
  end
  return out
end

local function buildCycleBuckets(group,key,actualStart,actualFinish,displayStart,count,now,isCurrent)
  local step=(actualFinish-actualStart)/count
  local selected=lastPerSlot(group,key,actualStart,actualFinish,count,now,isCurrent)
  local out={}
  local layerState={}
  local lastObserved=nil

  for i=1,count do
    local actualA=actualStart+(i-1)*step
    local actualB=actualStart+i*step
    local b={observed=false,startEpoch=displayStart+(i-1)*step,endEpoch=displayStart+i*step,
      actualStartEpoch=actualA,actualEndEpoch=actualB,partial=isCurrent and now<actualB,
      layers={},boundaries={}}
    local s=selected[i]
    if s then
      b.observed=true;b.epoch=s.epoch;b.timestamp=s.timestamp;b.cumulative=s[key]
      if key=='session' then
        -- Session bars are interval usage. Slot 1 uses its cumulative last observation;
        -- later slots require the immediately preceding slot to have been observed.
        if i==1 then
          b.delta=s[key]
        else
          local prev=selected[i-1]
          if prev and s[key]>=prev[key] then b.delta=s[key]-prev[key] end
        end
      else
        -- Weekly remains cumulative, with layers preserving where increments were seen.
        if i==1 then
          layerState={{value=s[key],known=true,source=i}}
        else
          local prev=selected[i-1]
          if prev and s[key]>=prev[key] then
            local nextState=copyLayers(layerState)
            local d=s[key]-prev[key]
            if d>0 then nextState[#nextState+1]={value=d,known=true,source=i} end
            layerState=nextState
          elseif lastObserved and s[key]>=lastObserved.cumulative then
            local nextState=copyLayers(layerState)
            local d=s[key]-lastObserved.cumulative
            if d>0 then nextState[#nextState+1]={value=d,known=false,source=i} end
            layerState=nextState
          else
            layerState={{value=s[key],known=false,source=i,correction=true}}
            b.corrected=true
          end
        end
        local total=0
        for j,l in ipairs(layerState) do
          b.layers[j]={value=l.value,known=l.known,source=l.source,correction=l.correction}
          total=total+l.value
          if j<#layerState and total>0 and total<s[key] then b.boundaries[#b.boundaries+1]=total end
        end
      end
      lastObserved=b
    end
    out[i]=b
  end
  return out
end

local function emptyBuckets(displayStart,actualStart,duration,count,now,isCurrent)
  local out={}
  local step=duration/count
  for i=1,count do
    out[i]={observed=false,startEpoch=displayStart+(i-1)*step,endEpoch=displayStart+i*step,
      actualStartEpoch=actualStart+(i-1)*step,actualEndEpoch=actualStart+i*step,
      partial=isCurrent and now<(actualStart+i*step),layers={},boundaries={}}
  end
  return out
end

-- Gold line: 100% exhaustion forecast for the CURRENT cycle.
--
-- Bars and forecast intentionally mean different things:
--   Session bars = interval usage (delta)
--   Weekly bars  = cumulative usage
--   Gold line    = average cumulative usage pace since the current cycle started
--
-- Average pace = latest cumulative percentage / elapsed time.
-- This is equivalent to the arithmetic mean interval usage when the observed
-- intervals are complete and equally sized:
--   50% + 30% over two 30-minute slots => 80 / 2 = 40% per slot.
--
-- A partial final slot is naturally handled because elapsed time is partial too.
-- If cumulative usage is already 100%, the predicted crossing is at/before the
-- latest observation rather than in the future.
local function currentForecast(buckets,cycleStart,cycleFinish,step)
  local latest=nil
  local samples=0
  for _,b in ipairs(buckets or {}) do
    if b.observed and b.cumulative~=nil and b.epoch and b.epoch>=cycleStart then
      samples=samples+1
      if not latest or b.epoch>latest.epoch then latest=b end
    end
  end

  local p={valid=false,slope=0,intercept=0,samples=samples,
    startEpoch=cycleStart,startValue=0,drawStartEpoch=cycleStart,drawStartValue=0}

  if not latest or latest.cumulative<=0 then return p end

  local elapsed=latest.epoch-cycleStart
  if elapsed<=0 then return p end

  local rate=latest.cumulative/elapsed -- percentage points per second
  if rate<=0 then return p end

  local crossing=cycleStart+100/rate
  -- With a clamped cumulative value of 100%, floating / timestamp jitter must
  -- never push the forecast into the future beyond the actual latest observation.
  if latest.cumulative>=100 and crossing>latest.epoch then crossing=latest.epoch end

  p.valid=true
  p.slope=rate
  p.latestEpoch=latest.epoch
  p.latestValue=latest.cumulative
  p.averagePerSlot=rate*step
  p.crossingEpoch=crossing
  p.margin=crossing-cycleFinish

  -- Keep drawing after the latest observation.  Stop only at 100% or at the
  -- visible reset boundary when 100% would occur after reset.
  local drawEnd=math.min(cycleFinish,crossing)
  if drawEnd<cycleStart then drawEnd=cycleStart end
  p.endEpoch=drawEnd
  p.drawEndEpoch=drawEnd
  p.endValue=math.min(100,math.max(0,rate*(drawEnd-cycleStart)))
  return p
end

-- Blue dashed long-term trend.
-- Previous + current cumulative observations are pooled by elapsed time WITHIN
-- their own cycle.  Reset is therefore never modeled as a false 100 -> 0 drop.
-- The regression is constrained through (0,0), because each quota cycle starts
-- at zero cumulative usage.  The fitted pace is then drawn separately on the
-- previous and current halves of the chart.
local function pooledCycleFit(left,right,step)
  local pts={}
  local function addCycle(buckets)
    for i,b in ipairs(buckets or {}) do
      if b.observed and b.cumulative~=nil and b.cumulative>=0 then
        -- Use the visible slot center so the trend corresponds to the displayed bars.
        pts[#pts+1]={x=(i-0.5)*step,y=b.cumulative}
      end
    end
  end
  addCycle(left)
  addCycle(right)
  local rate,samples=fitOrigin(pts)
  return rate,samples
end

local function rowsBetween(rows,a,b)
  local out={}
  for _,r in ipairs(rows) do
    if r.epoch>=a-120 and r.epoch<=b then out[#out+1]=r end
  end
  return out
end

local function chooseCurrent(rows,cycles,key,duration,now)
  local resetKey=key..'Reset'
  local latest=rows[#rows]
  if not latest then return nil,nil,nil,false end

  local mapped=nearestCycle(cycles,latest[resetKey],120)
  if mapped and latest.epoch>=mapped.start-120 and latest.epoch<=mapped.finish+120 then
    local idx=nil
    for i,c in ipairs(cycles) do if c==mapped then idx=i break end end
    return mapped,idx,nil,false
  end

  -- No stable active endpoint: this is an idle / not-yet-anchored current window.
  -- Keep the last real cycle on the left and use its reset boundary as the center
  -- when the reset happened naturally; for an early reset, use the observed change.
  local previous=cycles[#cycles]
  local start=nil
  if previous then
    local boundary=nil
    local lastEpoch=previous.lastEpoch or previous.finish
    for _,r in ipairs(rows) do
      if r.epoch>lastEpoch and r[key]<=5 then
        local m=nearestCycle(cycles,r[resetKey],120)
        if m~=previous then boundary=r;break end
      end
    end
    if boundary then
      if math.abs(previous.finish-boundary.epoch)<=600 then start=previous.finish else start=boundary.epoch end
    elseif now>=previous.finish then
      start=previous.finish
    end
  end
  if not start then start=latest.epoch end

  -- After a completely idle nominal window, there is still no anchored session;
  -- slide the empty placeholder to the latest observation rather than showing an
  -- already-expired right half forever.
  if now-start>duration then start=latest.epoch end
  local placeholder={start=start,finish=start+duration,rows=rowsBetween(rows,start,start+duration),placeholder=true}
  if #placeholder.rows>0 then
    placeholder.firstEpoch=placeholder.rows[1].epoch
    placeholder.lastEpoch=placeholder.rows[#placeholder.rows].epoch
  end
  return placeholder,nil,previous,true
end

local function chart(rows,now,key,duration,count)
  local cycles=buildCycles(rows,key,duration)
  local current,currentIndex,placeholderPrevious,isPlaceholder=chooseCurrent(rows,cycles,key,duration,now)

  local previous=nil
  if isPlaceholder then
    previous=placeholderPrevious
  elseif currentIndex and currentIndex>1 then
    previous=cycles[currentIndex-1]
  end

  local currentStart=current and current.start or now
  local currentFinish=current and current.finish or (currentStart+duration)
  local viewStart=currentStart-duration
  local viewEnd=currentFinish
  local step=duration/count
  local c={kind=key,startEpoch=viewStart,endEpoch=viewEnd,centerEpoch=currentStart,
    currentStartEpoch=currentStart,currentEndEpoch=currentFinish,duration=duration*2,cycleDuration=duration,
    count=count*2,cycleCount=count,buckets={},current={valid=false},previousForecast={valid=false},
    ideal={valid=false},overall={valid=false,segments={}},pace={valid=false},
    expired=now>=currentFinish,idle=isPlaceholder,cycles=#cycles}

  local left
  if previous then
    left=buildCycleBuckets(previous.rows,key,previous.start,previous.finish,viewStart,count,now,false)
    c.previousObserved=true
    c.previousStartEpoch=previous.start
    c.previousFinishEpoch=previous.finish
  else
    left=emptyBuckets(viewStart,viewStart,duration,count,now,false)
    c.previousObserved=false
  end

  local right
  if current then
    right=buildCycleBuckets(current.rows,key,currentStart,currentFinish,currentStart,count,now,true)
  else
    right=emptyBuckets(currentStart,currentStart,duration,count,now,true)
  end
  for i=1,count do c.buckets[i]=left[i] end
  for i=1,count do c.buckets[count+i]=right[i] end

  if current and current.rows and #current.rows>0 then c.latest=current.rows[#current.rows] end

  -- Current-cycle forecast (gold).
  c.current=currentForecast(right,currentStart,currentFinish,step)

  -- Previous cycle's forecast copied onto the current cycle (faint reference line).
  c.previousForecast={valid=false}
  if previous then
    local previousRaw=currentForecast(left,previous.start,previous.finish,step)
    c.previousForecast=shiftedForecast(previousRaw,previous.start,currentStart,currentFinish)
  end

  -- Ideal quota pace: one straight line from 0% at current cycle start to
  -- 100% at reset.  On Weekly this is the daily-allocation guide (~14.3%/day).
  c.ideal=projectionOrigin(100/duration,currentStart,currentFinish,1,2)

  -- Long-term blue trend: pool previous + current visible cumulative observations
  -- in cycle-relative time, then render the same fitted pace on both halves.
  local historyRate,historySamples=pooledCycleFit(left,right,step)
  c.overall={valid=false,slope=historyRate or 0,samples=historySamples or 0,segments={}}
  if historyRate and historyRate>0 then
    c.overall.valid=true
    if c.previousObserved then
      c.overall.segments[#c.overall.segments+1]=projectionOrigin(historyRate,viewStart,currentStart,1,historySamples)
    end
    c.overall.segments[#c.overall.segments+1]=projectionOrigin(historyRate,currentStart,currentFinish,1,historySamples)
  end

  -- CodexBar-compatible actual-vs-ideal pace numbers.  The UI wording is ours;
  -- only the underlying delta/stage/ETA calculation mirrors CodexBar.
  c.pace=paceSnapshot(c.latest,key,now,currentStart,currentFinish)

  -- Current-time marker: always the CENTER of the currently active slot.
  -- It is deliberately categorical/slot-centered rather than a raw poll timestamp.
  if now>=currentStart and now<currentFinish then
    local slot=math.floor((now-currentStart)/step)+1
    if slot<1 then slot=1 elseif slot>count then slot=count end
    c.currentSlotIndex=slot
    c.nowMarkerEpoch=currentStart+(slot-0.5)*step
  end

  return c
end

function M.build(input,now)
  local rows={}
  for _,r in ipairs(input or {}) do if r.epoch and r.epoch<=now then rows[#rows+1]=r end end
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
  if not p or not p.valid then return 'Collecting trend',nil end
  local margin=p.margin
  return '100% ~'..os.date('%m-%d %H:%M',p.crossingEpoch)..' ('..
    (margin<0 and '-' or '+')..M.duration(math.abs(margin))..')',margin
end

return M
