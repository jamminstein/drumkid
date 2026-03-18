-- drumkid for norns
-- aleatoric drum machine
-- inspired by mattybrad/drumkid
--
-- E1: tempo (BPM)
-- E2: browse parameters
-- E3: adjust selected parameter
-- K2: play / stop (release to confirm)
-- K3 short: randomise pattern
-- K3 long:  randomise pattern + all params
-- K2+K3: randomise selected param
-- grid (optional): toggle steps (rows 1-4 = kick/snare/hat/open)

engine.name = 'None'

local STEPS   = 16
local VOICES  = 4
local BPM_MIN = 40
local BPM_MAX = 300

local voice_names  = { "kick", "snare", "hat", "open" }
local voice_colors = { 15, 10, 6, 4 }

local sample_paths = {
  "/home/we/dust/audio/808-BD.wav",
  "/home/we/dust/audio/808-SD.wav",
  "/home/we/dust/audio/808-CH.wav",
  "/home/we/dust/audio/808-OH.wav",
}

local SLOT   = 1.0
local sc_buf = { 1, 1, 2, 2 }
local sc_pos = { 0.0, SLOT, 0.0, SLOT }

local all_params = { "chance","zoom","midpoint","range","pitch","crush","crop","drop","velocity","subdiv","reverb","warmth","prob_amt","swing","midi_ch_k","midi_ch_s","midi_ch_h" }
local param_idx  = 1

local p_vals = {
  chance=0.0, zoom=0.5, midpoint=0.5, range=0.5,
  pitch=0.5, crush=1.0, crop=1.0, drop=0.5,
  swing=0.0, velocity=0.0, subdiv=0.5,
  reverb=0.0, warmth=0.0,
  prob_amt=1.0, swing=0.0, midi_ch_k=10, midi_ch_s=10, midi_ch_h=10,
}

-- Per-hit probability table: probability[voice][step]
local probability = {}
for v = 1, VOICES do
  probability[v] = {}
  for s = 1, STEPS do probability[v][s] = 1.0 end
end

-- Fill state tracking
local fill_active = false
local fill_counter = 0
local fill_duration = 4  -- ticks in a 16th note pattern (4 ticks = 1 bar at default subdiv)

local midi_out   = nil
local voice_midi = { 36, 38, 42, 46 }

-- Get MIDI channel for voice (1-indexed voice, return 1-indexed channel)
local function get_midi_channel(voice)
  if voice == 1 then return math.floor(util.clamp(p_vals.midi_ch_k, 1, 16))
  elseif voice == 2 then return math.floor(util.clamp(p_vals.midi_ch_s, 1, 16))
  elseif voice == 3 then return math.floor(util.clamp(p_vals.midi_ch_h, 1, 16))
  else return math.floor(util.clamp(p_vals.midi_ch_h, 1, 16)) end
end

local bpm     = 120
local step    = 1
local playing = false
local clk_id  = nil
local k3_hold_id = nil
local K3_LONG    = 0.6

local pattern = {}
for v = 1, VOICES do
  pattern[v] = {}
  for s = 1, STEPS do pattern[v][s] = false end
end

local function default_pattern()
  for v = 1, VOICES do
    for s = 1, STEPS do pattern[v][s] = false end
  end
  for _, s in ipairs({1,5,9,13}) do pattern[1][s] = true end
  for _, s in ipairs({5,13})     do pattern[2][s] = true end
  for s = 1, 16, 2              do pattern[3][s] = true end
end

local function randomise_pattern()
  for v = 1, VOICES do
    for s = 1, STEPS do pattern[v][s] = (math.random() < 0.25) end
  end
  pattern[1][1] = true
end

local function randomise_single(k)
  if k=="pitch" then
    p_vals[k] = math.random()<0.1 and (math.random()*0.14) or (0.15+math.random()*0.85)
  elseif k=="crush" or k=="crop" then p_vals[k] = 0.4+math.random()*0.6
  elseif k=="drop" then p_vals[k] = 0.2+math.random()*0.6
  elseif k=="chance" then p_vals[k] = 0.2+math.random()*0.7
  elseif k=="range" then p_vals[k] = 0.3+math.random()*0.5
  elseif k=="velocity" then p_vals[k] = math.random()*0.6
  elseif k=="subdiv" then
    local r = math.random()
    p_vals[k] = r<0.2 and math.random()*0.35 or r<0.4 and 0.65+math.random()*0.35 or 0.4+math.random()*0.2
  elseif k=="reverb" then p_vals[k] = math.random()*0.7
  elseif k=="warmth" then p_vals[k] = math.random()*0.8
  elseif k=="prob_amt" then p_vals[k] = 0.5+math.random()*0.5
  elseif k=="swing" then p_vals[k] = math.random()*0.5
  elseif k=="midi_ch_k" or k=="midi_ch_s" or k=="midi_ch_h" then p_vals[k] = math.floor(math.random()*16)+1
  else p_vals[k] = math.random() end
end

local function randomise_params()
  for _, k in ipairs(all_params) do randomise_single(k) end
end

local function init_softcut()
  audio.level_cut(1.0); audio.level_adc_cut(0); audio.rev_on()
  softcut.buffer_clear()
  for i = 1, VOICES do
    softcut.enable(i,1); softcut.buffer(i,sc_buf[i])
    softcut.level(i,1.0); softcut.pan(i,0.0); softcut.rate(i,1.0)
    softcut.play(i,0); softcut.rec(i,0); softcut.fade_time(i,0.001)
    softcut.loop(i,0)
    softcut.loop_start(i,sc_pos[i]); softcut.loop_end(i,sc_pos[i]+SLOT)
    softcut.position(i,sc_pos[i])
    softcut.level_cut_cut(i,i,0)
  end
  for i = 1, VOICES do
    softcut.buffer_read_mono(sample_paths[i],0,sc_pos[i],-1,1,sc_buf[i])
  end
  print("drumkid: samples loading")
end

local function trigger(v, amp)
  if amp <= 0 then return end
  -- Apply fill humanization (50% increased density, 20% velocity boost)
  if fill_active then
    amp = amp * 1.2
  end
  if p_vals.velocity > 0 then
    local variation = (math.random()*2-1)*p_vals.velocity*0.5
    amp = util.clamp(amp+variation, 0.05, 1.0)
  end
  if p_vals.crush < 1.0 then
    local bits = math.max(1,math.floor(p_vals.crush*16))
    amp = math.floor(amp*bits)/bits
  end
  local cutoff = 16000*(1.0-p_vals.warmth*0.97)
  for i = 1, VOICES do
    softcut.pre_filter_fc(i,cutoff)
    softcut.pre_filter_lp(i,p_vals.warmth)
    softcut.pre_filter_dry(i,1.0-p_vals.warmth*0.5)
  end
  amp = util.clamp(amp*(1.0+p_vals.warmth*0.3), 0, 1)
  audio.level_cut_rev(p_vals.reverb*1.5)
  local rate
  if p_vals.pitch < 0.15 then
    rate = -1.0*(1.0-p_vals.pitch/0.15)
    if math.abs(rate) < 0.05 then rate = -0.05 end
  else
    rate = 1.0+((p_vals.pitch-0.15)/0.85)*2.0
  end
  local sample_dur = 0.26
  local crop_end = sc_pos[v]+math.max(0.01,p_vals.crop*sample_dur)
  softcut.loop_end(v,crop_end); softcut.level(v,util.clamp(amp,0,1))
  softcut.rate(v,rate)
  if rate < 0 then softcut.position(v,crop_end-0.001)
  else softcut.position(v,sc_pos[v]) end
  softcut.play(v,1)
  if midi_out then
    local vel = math.floor(util.clamp(amp,0,1)*127)
    local midi_ch = get_midi_channel(v)
    midi_out:note_on(voice_midi[v],vel,midi_ch)
    clock.run(function() clock.sleep(0.05); midi_out:note_off(voice_midi[v],0,midi_ch) end)
  end
end

local function roll(prob) return math.random() < prob end

local function zoom_steps()
  local z = p_vals.zoom
  if z<0.2 then return {1}
  elseif z<0.4 then return {1,9}
  elseif z<0.6 then return {1,5,9,13}
  elseif z<0.8 then return {1,3,5,7,9,11,13,15}
  else local all={}; for s=1,16 do all[s]=s end; return all end
end

local function voice_dropped(v)
  local d = p_vals.drop
  if d<0.1 then return v~=1
  elseif d<0.3 then return v==3 or v==4
  elseif d<0.7 then return false
  elseif d<0.9 then return v==1
  else return v~=3 end
end

local function tick()
  local zsteps = {}
  for _, s in ipairs(zoom_steps()) do zsteps[s]=true end
  for v = 1, VOICES do
    if not voice_dropped(v) then
      local fired = false
      -- Check per-hit probability before triggering pattern note
      if pattern[v][step] then
        local prob = probability[v][step] * p_vals.prob_amt
        if math.random() < prob then trigger(v,1.0); fired=true end
      end
      if not fired and zsteps[step] then
        local low  = p_vals.midpoint-p_vals.range*0.5
        local high = p_vals.midpoint+p_vals.range*0.5
        local pos  = (step-1)/(STEPS-1)
        if pos>=low and pos<=high and roll(p_vals.chance) then
          -- Also apply per-hit probability to chance hits
          local prob = probability[v][step] * p_vals.prob_amt
          if math.random() < prob then trigger(v,0.8) end
        end
      end
    end
  end
  -- Decrement fill counter
  if fill_active then
    fill_counter = fill_counter - 1
    if fill_counter <= 0 then fill_active = false end
  end
  step = (step%STEPS)+1
  grid_redraw(); redraw()
end

local subdiv_counter = 0

local function clock_loop()
  while true do
    clock.sync(1/4)
    if playing then
      if p_vals.subdiv < 0.4 then
        subdiv_counter = subdiv_counter+1
        if subdiv_counter >= 2 then subdiv_counter=0; tick() end
      elseif p_vals.subdiv > 0.6 then
        -- Swing humanization: delay even 16th notes
        tick()
        if p_vals.swing > 0 then
          local beat_dur = 60/bpm/4  -- duration of a 16th note in seconds
          local swing_delay = p_vals.swing * beat_dur / 2
          clock.sleep(beat_dur/2 + swing_delay)
        else
          clock.sleep(60/bpm/4/2)
        end
        tick()
      else
        subdiv_counter=0; tick()
      end
    end
  end
end

local function set_bpm(b)
  bpm = util.clamp(b, BPM_MIN, BPM_MAX)
  params:set("clock_tempo", bpm)
end

local g = grid.connect()

function grid_redraw()
  if not g.device then return end
  g:all(0)
  for v = 1, VOICES do
    for s = 1, STEPS do
      local lv = 0
      if pattern[v][s] then lv=5 end
      if s==step and playing then lv=math.min(15,lv+6) end
      g:led(s,v,lv)
    end
  end
  g:refresh()
end

g.key = function(x,y,z)
  if y>=1 and y<=VOICES and x>=1 and x<=STEPS and z==1 then
    pattern[y][x] = not pattern[y][x]
    grid_redraw(); redraw()
  end
end

local k2_down    = false
local k2_hold_id = nil

function key(n, z)
  if n==2 then
    if z==1 then
      k2_down=true
      k2_hold_id = clock.run(function() clock.sleep(K3_LONG); k2_hold_id=nil end)
    else
      k2_down=false
      if k2_hold_id then
        clock.cancel(k2_hold_id); k2_hold_id=nil
        playing = not playing
        if playing then step=1 end
        redraw()
      end
    end
  elseif n==3 then
    if z==1 then
      if k2_down then
        if k2_hold_id then clock.cancel(k2_hold_id); k2_hold_id=nil end
        randomise_single(all_params[param_idx]); redraw()
      else
        k3_hold_id = clock.run(function()
          clock.sleep(K3_LONG)
          randomise_params(); randomise_pattern()
          k3_hold_id=nil; redraw(); grid_redraw()
        end)
      end
    else
      if k3_hold_id then
        clock.cancel(k3_hold_id); k3_hold_id=nil
        randomise_pattern(); redraw(); grid_redraw()
      else
        -- Short K3 press (not held): trigger fill
        fill_active = true
        fill_counter = 4  -- 1 bar fill (4 x 16th notes at default)
        redraw()
      end
    end
  end
end

function enc(n, d)
  if n==1 then set_bpm(bpm+d)
  elseif n==2 then param_idx=util.clamp(param_idx+d,1,#all_params)
  elseif n==3 then
    local k = all_params[param_idx]
    -- Handle integer parameters (MIDI channels, 1-16)
    if k=="midi_ch_k" or k=="midi_ch_s" or k=="midi_ch_h" then
      p_vals[k] = util.clamp(p_vals[k]+d, 1, 16)
    else
      p_vals[k] = util.clamp(p_vals[k]+d*0.01, 0.0, 1.0)
    end
  end
  redraw()
end

function redraw()
  screen.clear()
  screen.level(15); screen.font_size(8); screen.move(2,8); screen.text("drumkid")
  screen.level(playing and 15 or 4)
  local fill_indicator = fill_active and " FILL" or ""
  screen.move(58,8); screen.text((playing and ">" or "|").." "..bpm.." bpm"..fill_indicator)
  local gx,gy = 2,14
  local sw,sh = 7,5
  for v = 1, VOICES do
    for s = 1, STEPS do
      local x = gx+(s-1)*(sw+1)
      local y = gy+(v-1)*(sh+2)
      if s==step and playing then
        screen.level(15); screen.rect(x,y,sw,sh); screen.fill()
      elseif pattern[v][s] then
        screen.level(voice_colors[v]); screen.rect(x,y,sw,sh); screen.fill()
      else
        screen.level(2); screen.rect(x,y,sw,sh); screen.stroke()
      end
    end
    screen.level(voice_colors[v])
    screen.move(gx+STEPS*(sw+1)+1, gy+(v-1)*(sh+2)+sh)
    screen.text(voice_names[v])
  end
  local py = 50
  local page = math.floor((param_idx-1)/4)
  local start_i = page*4+1
  local n_pages = math.ceil(#all_params/4)
  for i = start_i, math.min(start_i+3,#all_params) do
    local k=all_params[i]; local val=p_vals[k]; local sel=(i==param_idx)
    local col=(i-start_i); local x=2+col*31
    screen.level(sel and 15 or 5); screen.move(x,py); screen.text(k:sub(1,4))
    -- For integer MIDI channel params, display as 0-1 bar
    if k=="midi_ch_k" or k=="midi_ch_s" or k=="midi_ch_h" then
      local bar_width = math.floor((val/16)*28)
      screen.level(sel and 12 or 3); screen.rect(x,py+3,bar_width,3); screen.fill()
      if sel then screen.level(6); screen.move(x,py+13); screen.text(string.format("%d",val)) end
    else
      screen.level(sel and 12 or 3); screen.rect(x,py+3,math.floor(val*28),3); screen.fill()
      if sel then screen.level(6); screen.move(x,py+13); screen.text(string.format("%.2f",val)) end
    end
    screen.level(sel and 5 or 2); screen.rect(x,py+3,28,3); screen.stroke()
  end
  for p = 0, n_pages-1 do
    screen.level(p==page and 12 or 4); screen.rect(116+p*6,py,4,4); screen.fill()
  end
  screen.level(3); screen.move(2,64); screen.text("e3:adj k3:pat/fill k2+k3:rnd")
  screen.update()
end

function init()
  math.randomseed(os.time())
  default_pattern()
  set_bpm(bpm)
  midi_out = midi.connect(1)
  clock.run(function()
    clock.sleep(1.0); init_softcut()
    clock.sleep(2.0); print("drumkid: ready")
  end)
  clk_id = clock.run(clock_loop)
  redraw(); grid_redraw()
end

function cleanup()
  if clk_id then clock.cancel(clk_id) end
end