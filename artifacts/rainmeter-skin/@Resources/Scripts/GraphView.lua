-- Build bounded Rainmeter geometry. No SKIN dependency; used by rendering tests.
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
  local function y(p) return h-math.min(100,math.max(0,p))*h/100 end
  local function x(t) return math.max(0,math.min(w,(t-c.startEpoch)/c.duration*w)) end
  -- Always include the whole plot bounds so negative/short shapes never move origin.
  rect(a,0,0,w,h,'0,0,0,1')
  line(a,0,0,w,0,'216,224,232,100')
  line(a,0,h/2,w,h/2,'216,224,232,45')
  line(a,0,h,w,h,'216,224,232,25')
  local step=w/c.count
  for i,b in ipairs(c.buckets) do
    local bx=(i-1)*step+3
    local bw=step-6
    local hit={x=(i-1)*step,w=step,observed=b.observed,bucket=b}
    hits[i]=hit
    if b.observed then
      if c.kind=='session' then
        if b.delta then
          local bh=b.delta>0 and math.max(1,b.delta*h/100) or 0
          rect(a,bx,h-bh,bw,bh,'119,193,220,215')
        else
          -- Unknown attribution is an outlined tick, never a usage bar.
          line(a,bx,h-2,bx+bw,h-2,'140,148,160,150')
        end
      else
        local total=0
        for j,l in ipairs(b.layers) do
          total=total+l.value
          local color=not l.known and '103,111,126,220' or
            (j==#b.layers and '116,194,216,225' or '65,126,153,225')
          rect(a,bx,y(total),bw,l.value*h/100,color)
        end
        -- Every retained layer top is preserved, restricted to this column's width.
        for _,level in ipairs(b.boundaries) do line(a,bx,y(level),bx+bw,y(level),'213,232,235,175') end
      end
    end
  end
  if c.latest then
    local nx=x(c.latest.epoch)
    line(a,nx,0,nx,h,'230,235,240,40')
  end
  local function trend(p,color,dashed)
    if not p.valid then return end
    local x1,x2=x(p.startEpoch),x(p.endEpoch)
    local y1,y2=y(p.startValue),y(p.endValue)
    if x2<=x1 then return end
    if dashed then
      for q=x1,x2,8 do
        local z=math.min(q+4,x2)
        line(a,q,y1+(y2-y1)*(q-x1)/(x2-x1),z,y1+(y2-y1)*(z-x1)/(x2-x1),color,1.5)
      end
    else line(a,x1,y1,x2,y2,color,1.6) end
    if p.crossingEpoch<=c.endEpoch then point(a,x2,0,color) end
  end
  trend(c.overall,'162,177,237,235',true)
  trend(c.current,'243,191,107,255',false)
  if c.latest then point(a,x(c.latest.epoch),y(c.latest[c.kind]),'245,243,230,255') end
  return {shapes=a,hits=hits}
end
return V
