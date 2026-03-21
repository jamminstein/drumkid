-- drumkid for norns
-- aleatoric drum machine
-- inspired by mattybrad/drumkid
-- powered by Supertonic engine (schollz)
--
-- REQUIRES: supertonic script installed
-- (uses its Engine_Supertonic — no local copy needed)
--
-- E1: tempo (BPM)
-- E2: browse parameters (or history when in history mode)
-- E3: adjust selected parameter (or scroll history when in history mode)
-- K2: play / stop (release to confirm)
-- K3 short: randomise pattern
-- K3 long:  randomise pattern + all params
-- K2+K3: randomise selected param
-- KEY2 (in history): load selected randomization
-- KEY3 (in history): return to live mode
-- grid (optional): toggle steps (rows 1-4 = kick/snare/hat/open)
--
-- HISTORY BROWSER:
-- E2 in history: scroll through 50 saved randomizations
-- E3 in history: adjust details / preview volume
-- K2 in history: load the selected randomization state
-- K3 in history: return to live mode
--
-- PARAMS MENU: per-voice Supertonic synthesis controls
--   each voice has oscFreq, oscDcy, mix, distAmt, level,
--   modAmt, nFilFrq, nEnvDcy + a RANDOMIZE trigger

engine.name = 'Supertonic'

local STEPS   = 16
local VOICES  = 4
local BPM_MIN = 40
local BPM_MAX = 300

local voice_names  = { "kick", "snare", "hat", "open" }
local voice_colors = { 15, 10, 6, 4 }

--------------------------------------------------------------------------------
-- SUPERTONIC PATCH DEFINITIONS
-- Each voice gets a base synthesis patch; drumkid params morph these in realtime
-- These are the DEFAULTS -- params menu overrides them
--------------------------------------------------------------------------------

local default_patches = {
  -- KICK: sine osc, pitch-drop mod, low mix (osc-heavy), punchy, LOUD
  {
    distAmt = 8, eQFreq = 120, eQGain = 6, level = 2, mix = 8,
    modAmt = 30, modMode = 0, modRate = 280,
    nEnvAtk = 0, nEnvDcy = 80, nEnvMod = 0,
    nFilFrq = 300, nFilMod = 0, nFilQ = 1.2, nStereo = 0,
    oscAtk = 0, oscDcy = 600, oscFreq = 48, oscWave = 0,
    oscVel = 100, nVel = 100, modVel = 100,
  },
  -- SNARE: mid osc + noise, HP noise filter, snappy
  {
    distAmt = 10, eQFreq = 900, eQGain = 0, level = 0, mix = 55,
    modAmt = 10, modMode = 0, modRate = 220,
    nEnvAtk = 0, nEnvDcy = 200, nEnvMod = 0,
    nFilFrq = 3200, nFilMod = 2, nFilQ = 1.6, nStereo = 1,
    oscAtk = 0, oscDcy = 140, oscFreq = 190, oscWave = 0,
    oscVel = 100, nVel = 100, modVel = 80,
  },
  -- CLOSED HI-HAT: noise-heavy, tight, high filter
  {
    distAmt = 0, eQFreq = 5000, eQGain = 3, level = -2, mix = 92,
    modAmt = 0, modMode = 2, modRate = 7000,
    nEnvAtk = 0, nEnvDcy = 55, nEnvMod = 0,
    nFilFrq = 7500, nFilMod = 2, nFilQ = 2.2, nStereo = 1,
    oscAtk = 0, oscDcy = 25, oscFreq = 380, oscWave = 0,
    oscVel = 60, nVel = 100, modVel = 50,
  },
  -- OPEN HI-HAT: noise-heavy, longer tail, band-pass
  {
    distAmt = 0, eQFreq = 4500, eQGain = 2, level = -3, mix = 88,
    modAmt = 0, modMode = 2, modRate = 6000,
    nEnvAtk = 2, nEnvDcy = 350, nEnvMod = 0,
    nFilFrq = 5800, nFilMod = 1, nFilQ = 2.0, nStereo = 1,
    oscAtk = 0, oscDcy = 40, oscFreq = 380, oscWave = 0,
    oscVel = 60, nVel = 100, modVel = 50,
  },
}

-- Live patches (will be populated from params in init)
local patches = {}

--------------------------------------------------------------------------------
-- VOICE PARAM DEFINITIONS
-- These appear in the norns params menu for per-voice tweaking
--------------------------------------------------------------------------------

local voice_param_defs = {
  { id = "oscFreq",  name = "osc freq",     min = 20,   max = 12000, default_key = "oscFreq",  fmt = "Hz" },
  { id = "oscDcy",   name = "osc decay",    min = 5,    max = 2000,  default_key = "oscDcy",   fmt = "ms" },
  { id = "oscWave",  name = "osc wave",     min = 0,    max = 2,     default_key = "oscWave",  fmt = "",   options = {"sine", "tri", "saw"} },
  { id = "mix",      name = "osc/noise",    min = 0,    max = 100,   default_key = "mix",      fmt = "%" },
  { id = "distAmt",  name = "distortion",   min = 0,    max = 100,   default_key = "distAmt",  fmt = "" },
  { id = "level",    name = "level",        min = -20,  max = 12,    default_key = "level",    fmt = "dB" },
  { id = "modAmt",   name = "pitch mod",    min = 0,    max = 60,    default_key = "modAmt",   fmt = "" },
  { id = "modMode",  name = "mod mode",     min = 0,    max = 2,     default_key = "modMode",  fmt = "",   options = {"decay", "sine", "noise"} },
  { id = "modRate",  name = "mod rate",     min = 1,    max = 12000, default_key = "modRate",  fmt = "Hz" },
  { id = "nFilFrq",  name = "noise freq",   min = 20,   max = 16000, default_key = "nFilFrq",  fmt = "Hz" },
  { id = "nFilMod",  name = "noise filt",   min = 0,    max = 2,     default_key = "nFilMod",  fmt = "",   options = {"LP", "BP", "HP"} },
  { id = "nFilQ",    name = "noise Q",      min = 0.1,  max = 10,    default_key = "nFilQ",    fmt = "" },
  { id = "nEnvDcy",  name = "noise decay",  min = 5,    max = 2000,  default_key = "nEnvDcy",  fmt = "ms" },
  { id = "nEnvMod",  name = "noise env",    min = 0,    max = 2,     default_key = "nEnvMod",  fmt = "",   options = {"exp", "lin", "clap"} },
  { id = "nStereo",  name = "stereo",       min = 0,    max = 1,     default_key = "nStereo",  fmt = "",   options = {"off", "on"} },
  { id = "eQFreq",   name = "EQ freq",      min = 20,   max = 16000, default_key = "eQFreq",   fmt = "Hz" },
  { id = "eQGain",   name = "EQ gain",      min = -20,  max = 20,    default_key = "eQGain",   fmt = "dB" },
}

-- Build a param id for a given voice + param
local function vpid(v, pid)
  return voice_names[v] .. "_" .. pid
end

-- Read the current patch for a voice from params
local function read_patch(v)
  local p = {}
  for _, def in ipairs(voice_param_defs) do
    if def.options then
      -- Option params are 1-indexed in norns, engine expects 0-indexed
      p[def.id] = params:get(vpid(v, def.id)) - 1
    else
      p[def.id] = params:get(vpid(v, def.id))
    end
  end
  -- Fixed params not exposed in menu
  p.oscAtk  = default_patches[v].oscAtk
  p.nEnvAtk = default_patches[v].nEnvAtk
  p.oscVel  = default_patches[v].oscVel
  p.nVel    = default_patches[v].nVel
  p.modVel  = default_patches[v].modVel
  return p
end

-- Randomize a single voice's patch with musically sensible ranges
local function randomise_voice_patch(v)
  local bp = default_patches[v]
  for _, def in ipairs(voice_param_defs) do
    local lo, hi = def.min, def.max
    -- Keep randomisation musically useful (don't go fully wild)
    local base = bp[def.default_key] or 0
    local spread = (hi - lo) * 0.4
    local new_val = base + (math.random() * 2 - 1) * spread
    new_val = util.clamp(new_val, lo, hi)
    -- Integer params
    if def.options then
      new_val = math.floor(new_val + 0.5)
      new_val = util.clamp(new_val, lo, hi)
    end
    params:set(vpid(v, def.id), new_val)
  end
end

-- Reset a voice to its default patch
local function reset_voice_patch(v)
  local bp = default_patches[v]
  for _, def in ipairs(voice_param_defs) do
    params:set(vpid(v, def.id), bp[def.default_key] or 0)
  end
end

-- Apply a stored patch to a voice (for history recall)
local function apply_patch(v, p)
  for _, def in ipairs(voice_param_defs) do
    if def.options then
      -- Option params are 1-indexed in norns, stored as 0-indexed
      params:set(vpid(v, def.id), p[def.id] + 1)
    else
      params:set(vpid(v, def.id), p[def.id])
    end
  end
end

--------------------------------------------------------------------------------
-- DRUMKID PARAMETERS (aleatoric controls shown on screen)
--------------------------------------------------------------------------------

local all_params = {
  "chance", "zoom", "midpoint", "range",
  "pitch", "crush", "crop", "drop",
  "velocity", "subdiv", "warmth", "reverb",
  "prob_amt", "swing",
  "midi_ch_k", "midi_ch_s", "midi_ch_h",
}
local param_idx = 1

local p_vals = {
  chance   = 0.0, zoom    = 0.5, midpoint = 0.5, range = 0.5,
  pitch    = 0.5, crush   = 1.0, crop     = 1.0, drop  = 0.5,
  swing    = 0.0, velocity = 0.0, subdiv  = 0.5,
  reverb   = 0.0, warmth  = 0.0,
  prob_amt = 1.0,
  midi_ch_k = 10, midi_ch_s = 10, midi_ch_h = 10,
}

-- Per-hit probability table
local probability = {}
for v = 1, VOICES do
  probability[v] = {}
  for s = 1, STEPS do probability[v][s] = 1.0 end
end

-- Fill state
local fill_active  = false
local fill_counter = 0

local midi_out   = nil
local voice_midi = { 36, 38, 42, 46 }

local function get_midi_channel(voice)
  if voice == 1 then return math.floor(util.clamp(p_vals.midi_ch_k, 1, 16))
  elseif voice == 2 then return math.floor(util.clamp(p_vals.midi_ch_s, 1, 16))
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

--------------------------------------------------------------------------------
-- HISTORY SYSTEM
-- Stores the last 50 randomization snapshots
--------------------------------------------------------------------------------

local history = {}
local history_max = 50
local history_write_idx = 0  -- circular write position
local history_count = 0      -- actual number of entries
local browsing_history = false
local history_browse_idx = 1  -- which entry we're currently viewing (1-indexed)

-- Create a deep copy of all current state for the history snapshot
local function create_snapshot()
  local snapshot = {}
  
  -- Copy pattern
  snapshot.pattern = {}
  for v = 1, VOICES do
    snapshot.pattern[v] = {}
    for s = 1, STEPS do
      snapshot.pattern[v][s] = pattern[v][s]
    end
  end
  
  -- Copy p_vals
  snapshot.p_vals = {}
  for k, v in pairs(p_vals) do
    snapshot.p_vals[k] = v
  end
  
  -- Copy probability table
  snapshot.probability = {}
  for v = 1, VOICES do
    snapshot.probability[v] = {}
    for s = 1, STEPS do
      snapshot.probability[v][s] = probability[v][s]
    end
  end
  
  -- Copy all voice patches
  snapshot.patches = {}
  for v = 1, VOICES do
    snapshot.patches[v] = read_patch(v)
  end
  
  return snapshot
end

-- Save the current state to history buffer (circular)
local function save_to_history()
  history_write_idx = (history_write_idx % history_max) + 1
  history[history_write_idx] = create_snapshot()
  if history_count < history_max then
    history_count = history_count + 1
  end
end

-- Load a snapshot from history by circular index (1 to history_count)
local function load_from_history(idx)
  if idx < 1 or idx > history_count then return end
  
  -- Map 1-based index to circular buffer position
  local oldest_idx = history_count < history_max and 1 or (history_write_idx % history_max) + 1
  local circular_idx = ((oldest_idx - 1 + (idx - 1)) % history_max) + 1
  
  local snapshot = history[circular_idx]
  if not snapshot then return end
  
  -- Restore pattern
  for v = 1, VOICES do
    for s = 1, STEPS do
      pattern[v][s] = snapshot.pattern[v][s]
    end
  end
  
  -- Restore p_vals
  for k, v in pairs(snapshot.p_vals) do
    p_vals[k] = v
  end
  
  -- Restore probability
  for v = 1, VOICES do
    for s = 1, STEPS do
      probability[v][s] = snapshot.probability[v][s]
    end
  end
  
  -- Restore patches
  for v = 1, VOICES do
    apply_patch(v, snapshot.patches[v])
  end
end

--------------------------------------------------------------------------------
-- PATTERN HELPERS
--------------------------------------------------------------------------------

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
  if k == "pitch" then
    p_vals[k] = 0.2 + math.random() * 0.6
  elseif k == "crush" or k == "crop" then
    p_vals[k] = 0.4 + math.random() * 0.6
  elseif k == "drop" then
    p_vals[k] = 0.2 + math.random() * 0.6
  elseif k == "chance" then
    p_vals[k] = 0.2 + math.random() * 0.7
  elseif k == "range" then
    p_vals[k] = 0.3 + math.random() * 0.5
  elseif k == "velocity" then
    p_vals[k] = math.random() * 0.6
  elseif k == "subdiv" then
    local r = math.random()
    p_vals[k] = r < 0.2 and math.random() * 0.35
      or r < 0.4 and 0.65 + math.random() * 0.35
      or 0.4 + math.random() * 0.2
  elseif k == "reverb" then
    p_vals[k] = math.random() * 0.7
  elseif k == "warmth" then
    p_vals[k] = math.random() * 0.8
  elseif k == "prob_amt" then
    p_vals[k] = 0.5 + math.random() * 0.5
  elseif k == "swing" then
    p_vals[k] = math.random() * 0.5
  elseif k == "midi_ch_k" or k == "midi_ch_s" or k == "midi_ch_h" then
    p_vals[k] = math.floor(math.random() * 16) + 1
  else
    p_vals[k] = math.random()
  end
end

local function randomise_params()
  for _, k in ipairs(all_params) do randomise_single(k) end
end

--------------------------------------------------------------------------------
-- SUPERTONIC TRIGGER
-- Reads live patch from params, applies drumkid modifiers, fires engine
--------------------------------------------------------------------------------

local function trigger(v, amp)
  if amp <= 0 then return end

  -- Fill boost
  if fill_active then amp = amp * 1.2 end

  -- Velocity humanisation
  if p_vals.velocity > 0 then
    local variation = (math.random() * 2 - 1) * p_vals.velocity * 0.5
    amp = util.clamp(amp + variation, 0.05, 1.0)
  end

  -- Read current patch from params
  local p = read_patch(v)

  -- PITCH: 0.5 = base freq, 0 = half, 1 = double
  local pitch_mult = 0.5 + p_vals.pitch * 1.5
  p.oscFreq = p.oscFreq * pitch_mult

  -- CRUSH -> distortion boost (1.0 = no extra, 0 = heavy)
  p.distAmt = p.distAmt + (1.0 - p_vals.crush) * 60

  -- CROP -> envelope decay scaling (1.0 = full, 0 = super short)
  local crop_scale = math.max(0.05, p_vals.crop)
  p.oscDcy  = p.oscDcy  * crop_scale
  p.nEnvDcy = p.nEnvDcy * crop_scale

  -- WARMTH -> global low-pass filter (0 = wide open, 1 = dark)
  local lpf_freq = 20000 * (1.0 - p_vals.warmth * 0.97)
  local lpf_rq   = 1.0 - p_vals.warmth * 0.4

  -- LEVEL: combine patch level with amplitude
  local level_offset = (1.0 - amp) * -12
  p.level = p.level + level_offset

  -- REVERB (norns built-in)
  audio.level_rev_dac(p_vals.reverb * 1.2)

  -- Fire the engine!
  engine.supertonic(
    p.distAmt,
    p.eQFreq,
    p.eQGain,
    p.level,
    p.mix,
    p.modAmt,
    p.modMode,
    p.modRate,
    p.nEnvAtk,
    p.nEnvDcy,
    p.nEnvMod,
    p.nFilFrq,
    p.nFilMod,
    p.nFilQ,
    p.nStereo,
    p.oscAtk,
    p.oscDcy,
    p.oscFreq,
    p.oscWave,
    p.oscVel,
    p.nVel,
    p.modVel,
    lpf_freq,
    lpf_rq,
    v  -- voice id (integer, 1-indexed)
  )

  -- Optional MIDI out
  if midi_out then
    local vel = math.floor(util.clamp(amp, 0, 1) * 127)
    local midi_ch = get_midi_channel(v)
    midi_out:note_on(voice_midi[v], vel, midi_ch)
    clock.run(function()
      clock.sleep(0.05)
      midi_out:note_off(voice_midi[v], 0, midi_ch)
    end)
  end
end

--------------------------------------------------------------------------------
-- PATTERN / SEQUENCER LOGIC
--------------------------------------------------------------------------------

local function roll(prob) return math.random() < prob end

local function zoom_steps()
  local z = p_vals.zoom
  if     z < 0.2 then return {1}
  elseif z < 0.4 then return {1, 9}
  elseif z < 0.6 then return {1, 5, 9, 13}
  elseif z < 0.8 then return {1, 3, 5, 7, 9, 11, 13, 15}
  else
    local all = {}
    for s = 1, 16 do all[s] = s end
    return all
  end
end

local function voice_dropped(v)
  local d = p_vals.drop
  if     d < 0.1 then return v ~= 1
  elseif d < 0.3 then return v == 3 or v == 4
  elseif d < 0.7 then return false
  elseif d < 0.9 then return v == 1
  else return v ~= 3 end
end

local function tick()
  local zsteps = {}
  for _, s in ipairs(zoom_steps()) do zsteps[s] = true end
  for v = 1, VOICES do
    if not voice_dropped(v) then
      local fired = false
      if pattern[v][step] then
        local prob = probability[v][step] * p_vals.prob_amt
        if math.random() < prob then trigger(v, 1.0); fired = true end
      end
      if not fired and zsteps[step] then
        local low  = p_vals.midpoint - p_vals.range * 0.5
        local high = p_vals.midpoint + p_vals.range * 0.5
        local pos  = (step - 1) / (STEPS - 1)
        if pos >= low and pos <= high and roll(p_vals.chance) then
          local prob = probability[v][step] * p_vals.prob_amt
          if math.random() < prob then trigger(v, 0.8) end
        end
      end
    end
  end
  -- Fill counter
  if fill_active then
    fill_counter = fill_counter - 1
    if fill_counter <= 0 then fill_active = false end
  end
  step = (step % STEPS) + 1
  grid_redraw(); redraw()
end

local subdiv_counter = 0

local function clock_loop()
  while true do
    clock.sync(1/4)
    if playing then
      if p_vals.subdiv < 0.4 then
        subdiv_counter = subdiv_counter + 1
        if subdiv_counter >= 2 then subdiv_counter = 0; tick() end
      elseif p_vals.subdiv > 0.6 then
        tick()
        if p_vals.swing > 0 then
          local beat_dur = 60 / bpm / 4
          local swing_delay = p_vals.swing * beat_dur / 2
          clock.sleep(beat_dur / 2 + swing_delay)
        else
          clock.sleep(60 / bpm / 4 / 2)
        end
        tick()
      else
        subdiv_counter = 0; tick()
      end
    end
  end
end

local function set_bpm(b)
  bpm = util.clamp(b, BPM_MIN, BPM_MAX)
  params:set("clock_tempo", bpm)
end

--------------------------------------------------------------------------------
-- GRID
--------------------------------------------------------------------------------

local g = grid.connect()

function grid_redraw()
  if not g.device then return end
  g:all(0)
  for v = 1, VOICES do
    for s = 1, STEPS do
      local lv = 0
      if pattern[v][s] then lv = 5 end
      if s == step and playing then lv = math.min(15, lv + 6) end
      g:led(s, v, lv)
    end
  end
  g:refresh()
end

g.key = function(x, y, z)
  if y >= 1 and y <= VOICES and x >= 1 and x <= STEPS and z == 1 then
    pattern[y][x] = not pattern[y][x]
    grid_redraw(); redraw()
  end
end

--------------------------------------------------------------------------------
-- KEYS / ENCODERS
--------------------------------------------------------------------------------

local k2_down    = false
local k2_hold_id = nil

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_down = true
      if browsing_history then
        -- In history mode: K2 loads the selected randomization
        load_from_history(history_browse_idx)
        browsing_history = false
        redraw()
      else
        -- Normal mode: K2 play/stop
        k2_hold_id = clock.run(function() clock.sleep(K3_LONG); k2_hold_id = nil end)
      end
    else
      k2_down = false
      if k2_hold_id then
        clock.cancel(k2_hold_id); k2_hold_id = nil
        if not browsing_history then
          playing = not playing
          if playing then step = 1 end
          redraw()
        end
      end
    end
  elseif n == 3 then
    if z == 1 then
      if browsing_history then
        -- In history mode: K3 returns to live
        browsing_history = false
        redraw()
      elseif k2_down then
        if k2_hold_id then clock.cancel(k2_hold_id); k2_hold_id = nil end
        randomise_single(all_params[param_idx])
        save_to_history()
        redraw()
      else
        k3_hold_id = clock.run(function()
          clock.sleep(K3_LONG)
          randomise_params(); randomise_pattern()
          save_to_history()
          k3_hold_id = nil; redraw(); grid_redraw()
        end)
      end
    else
      if k3_hold_id then
        clock.cancel(k3_hold_id); k3_hold_id = nil
        randomise_pattern()
        save_to_history()
        redraw(); grid_redraw()
      elseif not browsing_history then
        fill_active  = true
        fill_counter = 4
        redraw()
      end
    end
  end
end

function enc(n, d)
  if n == 1 then
    set_bpm(bpm + d)
  elseif n == 2 then
    if browsing_history then
      -- E2 in history: scroll through history
      history_browse_idx = util.clamp(history_browse_idx + d, 1, history_count)
    else
      -- E2 normal: browse parameters
      param_idx = util.clamp(param_idx + d, 1, #all_params)
    end
  elseif n == 3 then
    if browsing_history then
      -- E3 in history: could add preview volume control or details
      -- For now, just allow returning to live
    else
      -- E3 normal: adjust selected parameter
      local k = all_params[param_idx]
      if k == "midi_ch_k" or k == "midi_ch_s" or k == "midi_ch_h" then
        p_vals[k] = util.clamp(p_vals[k] + d, 1, 16)
      else
        p_vals[k] = util.clamp(p_vals[k] + d * 0.01, 0.0, 1.0)
      end
    end
  end
  redraw()
end

--------------------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------------------

function redraw()
  screen.clear()
  screen.level(15); screen.font_size(8)
  
  if browsing_history then
    -- HISTORY BROWSER PAGE
    screen.move(2, 8); screen.text("HISTORY")
    screen.level(12)
    screen.move(58, 8); screen.text(string.format("%d/%d", history_browse_idx, history_count))
    
    if history_count == 0 then
      screen.level(5)
      screen.move(2, 30); screen.text("(no history yet)")
    else
      -- Show the selected snapshot's pattern
      local gx, gy = 2, 14
      local sw, sh  = 7, 5
      local snapshot = nil
      
      -- Map 1-based index to circular buffer
      local oldest_idx = history_count < history_max and 1 or (history_write_idx % history_max) + 1
      local circular_idx = ((oldest_idx - 1 + (history_browse_idx - 1)) % history_max) + 1
      snapshot = history[circular_idx]
      
      if snapshot then
        for v = 1, VOICES do
          for s = 1, STEPS do
            local x = gx + (s - 1) * (sw + 1)
            local y = gy + (v - 1) * (sh + 2)
            if snapshot.pattern[v][s] then
              screen.level(voice_colors[v]); screen.rect(x, y, sw, sh); screen.fill()
            else
              screen.level(2); screen.rect(x, y, sw, sh); screen.stroke()
            end
          end
          screen.level(voice_colors[v])
          screen.move(gx + STEPS * (sw + 1) + 1, gy + (v - 1) * (sh + 2) + sh)
          screen.text(voice_names[v])
        end
        
        -- Show some key params from this snapshot
        screen.level(5)
        screen.move(2, 50); screen.text("pitch: " .. string.format("%.2f", snapshot.p_vals.pitch))
        screen.move(35, 50); screen.text("crush: " .. string.format("%.2f", snapshot.p_vals.crush))
        screen.move(2, 58); screen.text("K2:load K3:live")
      end
    end
  else
    -- NORMAL LIVE PAGE
    screen.move(2, 8); screen.text("drumkid")
    screen.level(playing and 15 or 4)
    local fill_indicator = fill_active and " FILL" or ""
    screen.move(58, 8); screen.text((playing and ">" or "|") .. " " .. bpm .. " bpm" .. fill_indicator)

    local gx, gy = 2, 14
    local sw, sh  = 7, 5
    for v = 1, VOICES do
      for s = 1, STEPS do
        local x = gx + (s - 1) * (sw + 1)
        local y = gy + (v - 1) * (sh + 2)
        if s == step and playing then
          screen.level(15); screen.rect(x, y, sw, sh); screen.fill()
        elseif pattern[v][s] then
          screen.level(voice_colors[v]); screen.rect(x, y, sw, sh); screen.fill()
        else
          screen.level(2); screen.rect(x, y, sw, sh); screen.stroke()
        end
      end
      screen.level(voice_colors[v])
      screen.move(gx + STEPS * (sw + 1) + 1, gy + (v - 1) * (sh + 2) + sh)
      screen.text(voice_names[v])
    end

    local py    = 50
    local page  = math.floor((param_idx - 1) / 4)
    local start_i = page * 4 + 1
    local n_pages = math.ceil(#all_params / 4)
    for i = start_i, math.min(start_i + 3, #all_params) do
      local k   = all_params[i]
      local val = p_vals[k]
      local sel = (i == param_idx)
      local col = (i - start_i)
      local x   = 2 + col * 31
      screen.level(sel and 15 or 5); screen.move(x, py); screen.text(k:sub(1, 4))
      if k == "midi_ch_k" or k == "midi_ch_s" or k == "midi_ch_h" then
        local bar_width = math.floor((val / 16) * 28)
        screen.level(sel and 12 or 3); screen.rect(x, py + 3, bar_width, 3); screen.fill()
        if sel then screen.level(6); screen.move(x, py + 13); screen.text(string.format("%d", val)) end
      else
        screen.level(sel and 12 or 3); screen.rect(x, py + 3, math.floor(val * 28), 3); screen.fill()
        if sel then screen.level(6); screen.move(x, py + 13); screen.text(string.format("%.2f", val)) end
      end
      screen.level(sel and 5 or 2); screen.rect(x, py + 3, 28, 3); screen.stroke()
    end

    for p = 0, n_pages - 1 do
      screen.level(p == page and 12 or 4); screen.rect(116 + p * 6, py, 4, 4); screen.fill()
    end

    -- History browser button indicator
    screen.level(history_count > 0 and 8 or 3)
    screen.move(2, 64); screen.text("e2:hist e3:adj k3:pat/fill")
    if history_count > 0 then
      screen.level(8)
      screen.move(110, 64); screen.text("[" .. history_count .. "]")
    end
  end
  
  screen.update()
end

--------------------------------------------------------------------------------
-- INIT / CLEANUP
--------------------------------------------------------------------------------

local function build_params()
  -- Per-voice Supertonic synthesis params
  for v = 1, VOICES do
    params:add_separator(voice_names[v] .. " synth")
    local bp = default_patches[v]

    for _, def in ipairs(voice_param_defs) do
      local pid = vpid(v, def.id)
      local default_val = bp[def.default_key] or 0

      if def.options then
        -- Option param (oscWave, modMode, nFilMod, nEnvMod, nStereo)
        params:add_option(pid, def.name, def.options, default_val + 1)
        -- Store as 0-indexed for engine
        params:set_action(pid, function(val) end)
      else
        local cs = controlspec.new(def.min, def.max, 'lin', 0, default_val, def.fmt)
        params:add_control(pid, def.name, cs)
      end
    end

    -- Randomize trigger for this voice
    params:add_trigger(vpid(v, "randomize"), ">> RANDOMIZE " .. voice_names[v])
    params:set_action(vpid(v, "randomize"), function()
      randomise_voice_patch(v)
    end)

    -- Reset trigger
    params:add_trigger(vpid(v, "reset"), ">> RESET " .. voice_names[v])
    params:set_action(vpid(v, "reset"), function()
      reset_voice_patch(v)
    end)
  end

  -- Global controls
  params:add_separator("global")
  params:add_trigger("randomize_all_voices", ">> RANDOMIZE ALL VOICES")
  params:set_action("randomize_all_voices", function()
    for v = 1, VOICES do randomise_voice_patch(v) end
  end)
  params:add_trigger("reset_all_voices", ">> RESET ALL VOICES")
  params:set_action("reset_all_voices", function()
    for v = 1, VOICES do reset_voice_patch(v) end
  end)
end

function init()
  math.randomseed(os.time())

  -- Build norns params for voice tweaking
  build_params()

  default_pattern()
  set_bpm(bpm)
  midi_out = midi.connect(1)

  -- Norns reverb
  audio.rev_on()
  audio.level_rev_dac(0)

  -- Start the clock
  clk_id = clock.run(clock_loop)
  redraw(); grid_redraw()
end

function cleanup()
  -- Send all-notes-off before cancelling clocks
  if midi_out then
    for ch = 1, 16 do
      midi_out:cc(123, 0, ch)
    end
  end
  if clk_id then clock.cancel(clk_id) end
end
