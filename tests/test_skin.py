"""Run the real Lua controller against a mocked Rainmeter API; render its emitted geometry.
PNG files are OFFSCREEN previews, not screenshots of Rainmeter.
"""
import copy, configparser, json, math, pathlib, re, shutil, sys, tempfile, unittest, time
from PIL import Image, ImageDraw, ImageFont
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/".testdeps"))
from lupa.lua51 import LuaRuntime
SKIN=ROOT/"artifacts/rainmeter-skin"
INI=configparser.RawConfigParser(interpolation=None,strict=True)
INI.optionxform=str
INI.read(SKIN/"CodexGauge.ini",encoding="utf-8")

def create_runtime(resources, now):
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.globals().resource=str(resources).replace("\\","/")+"/"
    lua.globals().testNow=now
    lua.globals().meterNames=lua.table_from({s:True for s in INI.sections()})
    lua.execute("""
        savedTime=os.time
        os.time=function(t) if t then return savedTime(t) else return testNow end end
        options={}; hidden={}
        SKIN={}
        function SKIN:GetVariable(k) if k=='@' then return resource end end
        function SKIN:Bang(cmd,m,k,v)
          if cmd=='!SetOption' then
            assert(meterNames[m], 'Unknown meter '..m)
            options[m]=options[m] or {}; options[m][k]=v
          elseif cmd=='!HideMeter' then hidden[m]=true
          elseif cmd=='!ShowMeter' then hidden[m]=false end
        end
    """)
    lua.execute((SKIN/"@Resources/Scripts/ApplyUsage.lua").read_text(encoding="utf-8"))
    lua.globals().Initialize()
    lua.globals().Apply()
    return lua

def meter_options(lua,section):
    o={}
    source=INI[section]
    for style in source.get("MeterStyle","").split("|"):
        style=style.strip()
        if style and style in INI:
            o.update(dict(INI[style]))
    o.update(dict(source))
    if lua.globals().options[section]:
        o.update({k:v for k,v in lua.globals().options[section].items()})
    h=lua.globals().hidden[section]
    o["Hidden"]=str(int(h)) if h is not None else o.get("Hidden","0")
    return o

def render(lua,path):
    bg=meter_options(lua,"MeterBg")["Shape"]
    height=math.ceil(float(bg.split("|")[0].split(",")[3]))+2
    scale=2
    im=Image.new("RGB",(322*scale,height*scale),(18,22,28))
    d=ImageDraw.Draw(im)
    def col(text):
        nums=[int(x.strip()) for x in text.split(",")]
        return tuple(nums[:3])
    def drawshape(shape,ox,oy):
        parts=[x.strip() for x in shape.split("|")]
        name,args=parts[0].split(" ",1); p=[float(x) for x in args.split(",")]
        props={x.rsplit(" ",1)[0]:x.rsplit(" ",1)[1] for x in parts[1:]}
        def prop(prefix,default):
            return next((x[len(prefix):] for x in parts[1:] if x.startswith(prefix)),default)
        fill=col(prop("Fill Color ","0,0,0"))
        stroke=col(prop("Stroke Color ","234,239,245"))
        width=float(prop("StrokeWidth ","1"))
        p=[v*scale for v in p]; ox*=scale;oy*=scale
        if name=="Rectangle":
            x,y,w,h=p[:4]
            if w<=0 or h<=0: return
            # Invisible geometry is only a bounds sentinel.
            if prop("Fill Color ","").endswith(",1"): return
            box=(ox+x,oy+y,ox+x+w,oy+y+h)
            if len(p)>4:d.rounded_rectangle(box,radius=p[4],fill=fill)
            else:d.rectangle(box,fill=fill)
        elif name=="Line" and width>0:
            d.line((ox+p[0],oy+p[1],ox+p[2],oy+p[3]),fill=stroke,width=max(1,round(width*scale)))
        elif name=="Ellipse":
            d.ellipse((ox+p[0]-p[2],oy+p[1]-p[3],ox+p[0]+p[2],oy+p[1]+p[3]),fill=fill)
    for s in INI.sections():
        if "Meter" not in INI[s]:continue
        o=meter_options(lua,s)
        if o.get("Hidden")=="1":continue
        x,y=float(o.get("X",0)),float(o.get("Y",0))
        if o["Meter"]=="Shape":
            for key in sorted((k for k in o if re.fullmatch(r"Shape\d*",k)),key=lambda k:int(k[5:] or 1)):
                drawshape(o[key],x,y)
        elif o["Meter"]=="String":
            text=o.get("Text","").replace("#CRLF#","\n")
            color=o.get("FontColor","234,239,245").replace("#Muted#","158,172,189").replace("#Text#","234,239,245")
            font=ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf",round(float(o.get("FontSize",9))*96/72*scale))
            align=o.get("StringAlign","Left")
            anchor="rm" if align=="RightCenter" else "ra" if align=="Right" else "la"
            d.multiline_text((x*scale,y*scale),text,font=font,fill=col(color),anchor=anchor,spacing=2)
    path.parent.mkdir(parents=True,exist_ok=True);im.save(path)

class SkinTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="CodexGauge-tests-")
        self.resources=pathlib.Path(self.temp.name)
        shutil.copytree(SKIN/"@Resources/Scripts",self.resources/"Scripts")
        self.start=1788884820;self.now=self.start+3*43200
        rows=[]
        # Weekly exact 0,10,25,31 plus current Session exact 0,10,25,31.
        for i,v in enumerate([0,10,25,31]):
            rows.append(dict(epoch=self.start+i*43200,session=0,weekly=v,sessionReset=self.start+i*43200+18000,weeklyReset=self.start+604800))
        ss=self.now-5400
        for i,v in enumerate([0,10,25,31]):
            rows.append(dict(epoch=ss+i*1800,session=v,weekly=31,sessionReset=ss+18000,weeklyReset=self.start+604800))
        # Avoid conflicting observations at same final second.
        rows=[r for r in rows if not (r["epoch"]==self.now and r["session"]==0)]
        rows.sort(key=lambda r:r["epoch"])
        (self.resources/"UsageHistory.jsonl").write_text("\n".join(json.dumps(r) for r in rows),encoding="utf-8")
        self.base="Connected=1\nHasUsageData=1\nPlanName=plus\nPrimaryPercent=31\nSecondaryPercent=31\nUpdatedEpoch="+str(self.now)+"\nUpdatedAt=2026-09-09 22:00:00\n"
        (self.resources/"Usage.inc").write_text("[Variables]\n"+self.base,encoding="utf-8")
        self.lua=create_runtime(self.resources,self.now)
    def tearDown(self):self.temp.cleanup()
    def test_all_options_target_real_meters(self):
        self.lua.globals().OpenDetails()
        self.assertTrue(self.lua.globals().options["WeeklyChart"])
    def test_cold_fetch_failure_does_not_claim_zero_usage(self):
        (self.resources/"Usage.inc").write_text("[Variables]\nConnected=0\nHasUsageData=0\nPrimaryPercent=0\nSecondaryPercent=0\n")
        self.lua.globals().Apply()
        self.assertEqual(self.lua.globals().options.MeterPrimaryLabel.Text,"Session  --")
        self.assertEqual(self.lua.globals().options.MeterSecondaryLabel.Text,"Weekly   --")
    def test_compact_expansion_and_full_error_recovery(self):
        self.lua.globals().OpenDetails()
        self.assertFalse(self.lua.globals().hidden["WeeklyChart"])
        self.lua.globals().CloseDetails()
        self.assertTrue(self.lua.globals().hidden["WeeklyChart"])
        (self.resources/"Usage.inc").write_text("[Variables]\n"+self.base.replace("Connected=1","Connected=0")+"\nError1=One\nError2=Two\nError3=Three\n")
        self.lua.globals().Apply()
        red=self.lua.globals().options.MeterBg.Shape
        self.assertIn("103,34,42",red)
        self.assertFalse(self.lua.globals().hidden.MeterError3)
        (self.resources/"Usage.inc").write_text("[Variables]\n"+self.base)
        self.lua.globals().Apply()
        self.assertTrue(self.lua.globals().hidden.MeterError3)
        self.assertNotIn("103,34,42",self.lua.globals().options.MeterBg.Shape)
    def test_hidden_details_cannot_extend_compact_window(self):
        self.lua.globals().OpenDetails();self.lua.globals().CloseDetails()
        # Rainmeter computes bounds from GetY()+GetH(); hidden GetH()=0, not Y=0.
        for name in INI.sections():
            if "Meter" in INI[name]:
                opts=meter_options(self.lua,name)
                if opts.get("Hidden")=="1":
                    self.assertEqual(float(opts.get("Y",0)),0,name)
    def test_reset_boundary_expires_forecast_without_next_fetch(self):
        self.lua.globals().OpenDetails()
        self.lua.globals().testNow=self.now+12600
        self.lua.globals().Update()
        self.assertIn("waiting for reset data",self.lua.globals().options.SessionCurrent.Text)
    def test_axes_and_hover_hitboxes(self):
        self.lua.globals().OpenDetails()
        y=float(self.lua.globals().options.SessionChart.Y)
        self.assertEqual(float(self.lua.globals().options.SessionAxis100.Y),y)
        self.assertEqual(float(self.lua.globals().options.SessionAxis50.Y),y+40)
        self.assertTrue(self.lua.globals().hidden.SessionHit4)
        self.lua.globals().Hover("session",3)
        self.assertIn("+6%",self.lua.globals().options.DetailReadout.Text)
        self.assertIn("31% cumulative",self.lua.globals().options.DetailReadout.Text)
    def test_persistent_edges_are_inside_column_three(self):
        self.lua.globals().OpenDetails()
        options=self.lua.globals().options.WeeklyChart
        lines=[v for k,v in options.items() if "213,232,235,175" in v]
        x=2*256/14+3
        found=[s for s in lines if s.startswith("Line %.3f,"%x)]
        self.assertEqual(len(found),2)
        self.assertTrue(any(",72.000," in s for s in found)) # 10%
        self.assertTrue(any(",60.000," in s for s in found)) # 25%
    def test_offscreen_previews(self):
        out=ROOT/"verification/redesign"
        self.lua.globals().CloseDetails();render(self.lua,out/"fixture-compact.png")
        self.lua.globals().OpenDetails();self.lua.globals().Hover("weekly",3)
        render(self.lua,out/"fixture-expanded.png")
        self.assertTrue((out/"fixture-expanded.png").exists())
    def test_no_nonfinite_geometry(self):
        self.lua.globals().OpenDetails()
        for meter,opts in self.lua.globals().options.items():
            for key,val in opts.items():
                if key.startswith("Shape"):
                    self.assertNotRegex(val,r"(?i)\b(nan|inf)\b")

if __name__=="__main__":unittest.main()
