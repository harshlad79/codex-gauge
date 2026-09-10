-- Read-only runtime diagnostics. Run inside the live Rainmeter Lua measure.
return function(phase)
  assert(phase:match('^[%w_-]+$'))
  local path='O:/Work/CodexGauge/verification/redesign/runtime-'..phase..'.txt'
  local f=assert(io.open(path,'w'))
  f:write('Captured=',os.date('%Y-%m-%d %H:%M:%S'),'\n')
  f:write('Window=',SKIN:GetVariable('CURRENTCONFIGWIDTH','?'),'x',SKIN:GetVariable('CURRENTCONFIGHEIGHT','?'),'\n')
  for _,name in ipairs({'MeterBg','MeterStatus','MeterPrimaryLabel','MeterSecondaryLabel','MeterNotice',
    'MeterError1','MeterError2','MeterError3','SessionChart','SessionAxis100','SessionAxis50',
    'WeeklyChart','WeeklyAxis100','WeeklyAxis50','SessionOverall','SessionCurrent',
    'WeeklyOverall','WeeklyCurrent','DetailReadout','SessionHit1','SessionHit10','WeeklyHit1','WeeklyHit14'}) do
    local m=assert(SKIN:GetMeter(name),name)
    local value=m:GetOption('Text',''):gsub('[\r\n]',' / ')
    f:write(name,'=',m:GetX(),',',m:GetY(),',',m:GetW(),',',m:GetH(),' | ',value,'\n')
    if name=='MeterBg' then f:write('Background=',m:GetOption('Shape'),'\n') end
  end
  f:write('Fetch=',SKIN:GetMeasure('MeasureFetch'):GetStringValue(),'\n')
  f:close()
end
