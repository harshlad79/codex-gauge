-- Rainmeter Shape geometry for centered previous/current reset cycles.
local V={}
V.width=320; V.left=48; V.plotWidth=256; V.height=80

local function n(x) return string.format('%.3f',x) end
local function line(a,x1,y1,x2,y2,color,width)
  a[#a+1]='Line '..n(x1)..','..n(y1)..','..n(x2)..','..n(y2)..' | StrokeWidth '..(width or 1)..' | Stroke Color '..color
end
local function rect(a,x,y,w,h,color)
  if h<=0 then return end
  a[#a+1]='Rectangle '..n(x)..','..n(y)..','..n(w)..','..n(h)..' | StrokeWidth 0 | Fill Color '..color
end
local function point(a,x,y,color)
  a[#a+1]='Ellipse '..n(x)..','..n(y)..',2.5,2.5 | StrokeWidth 0 | Fill Color '..color
end

function V.chart(c)
  local a,hits={},{}
  local w,h=V.plotWidth,V.height
  local function y(p) return h-math.min(100,math.max(0,p or 0))*h/100 end
  local function x(t) return math.max(0,math.min(w,(t-c.startEpoch)/c.duration*w)) end

  rect(a,0,0,w,h,'0,0,0,1')
  line(a,0,0,w,0,'216,224,232,100')
  line(a,0,h/2,w,h/2,'216,224,232,45')
  line(a,0,h,w,h,'216,224,232,25')

  local function drawProjection(p,color,dashed,width,showCrossing)
    if not p or not p.valid then return end
    local begin=p.drawStartEpoch or p.startEpoch
    local finish=p.drawEndEpoch or p.endEpoch
    if not begin or not finish or finish<=begin then return end
    local x1,x2=x(begin),x(finish)
    local y1=y(p.drawStartValue~=nil and p.drawStartValue or p.startValue or 0)
    local y2=y(p.endValue)
    if x2<=x1 then return end
    if dashed then
      for q=x1,x2,8 do
        local z=math.min(q+4,x2)
        local qy=y1+(y2-y1)*(q-x1)/(x2-x1)
        local zy=y1+(y2-y1)*(z-x1)/(x2-x1)
        line(a,q,qy,z,zy,color,width or 1.5)
      end
    else
      line(a,x1,y1,x2,y2,color,width or 1.6)
    end
    if showCrossing and p.crossingEpoch and p.crossingEpoch>=begin and p.crossingEpoch<=finish then
      point(a,x(p.crossingEpoch),0,color)
    end
  end

  -- Ideal quota pace is deliberately behind the bars.  On Weekly this one line is
  -- the daily allowance guide: 0% at weekly start -> 100% at weekly reset.
  drawProjection(c.ideal,'94,209,193,145',false,1.0,false)

  local slotW=w/c.count
  for i,b in ipairs(c.buckets) do
    local bx=(i-1)*slotW+1.5
    local bw=math.max(1,slotW-3)
    hits[i]={x=(i-1)*slotW,w=slotW,observed=b.observed,bucket=b,index=i}
    if b.observed then
      if c.kind=='session' then
        if b.delta~=nil then
          local bh=b.delta>0 and math.max(1,b.delta*h/100) or 0
          rect(a,bx,h-bh,bw,bh,'119,193,220,215')
          if b.delta==0 then line(a,bx,h-1,bx+bw,h-1,'119,193,220,150') end
        else
          -- Observation exists, but no safe immediately-previous slot to attribute a delta.
          line(a,bx,h-2,bx+bw,h-2,'140,148,160,170')
        end
      else
        local total=0
        for j,l in ipairs(b.layers) do
          total=total+l.value
          local color=not l.known and '103,111,126,220' or
            (j==#b.layers and '116,194,216,225' or '65,126,153,225')
          rect(a,bx,y(total),bw,l.value*h/100,color)
        end
        for _,level in ipairs(b.boundaries) do line(a,bx,y(level),bx+bw,y(level),'213,232,235,175') end
      end
    end
  end

  -- Blue dashed long-term pace.  Previous + current observations participate in
  -- one cycle-relative fit, rendered as separate segments so reset never appears
  -- as an artificial 100 -> 0 fall.
  if c.overall and c.overall.valid then
    if c.overall.segments and #c.overall.segments>0 then
      for _,seg in ipairs(c.overall.segments) do
        drawProjection(seg,'162,177,237,235',true,1.5,false)
      end
    else
      drawProjection(c.overall,'162,177,237,235',true,1.5,false)
    end
  end

  -- Previous cycle forecast copied onto the current cycle for direct comparison.
  drawProjection(c.previousForecast,'243,191,107,90',false,1.2,false)

  -- Current-cycle 100% forecast.
  drawProjection(c.current,'243,191,107,255',false,1.6,true)

  -- Markers are drawn last so they remain visible through bars and trend lines.
  local center=x(c.centerEpoch)
  line(a,center,0,center,h,'230,235,240,125',1.2)
  if c.nowMarkerEpoch then
    local nx=x(c.nowMarkerEpoch)
    line(a,nx,0,nx,h,'239,95,139,235',1.5)
  end

  return {shapes=a,hits=hits}
end

return V
