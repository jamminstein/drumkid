-- drumkid for norns
-- aleatoric drum machine
-- inspired by mattybrad/drumkid
-- v2.0 — powered by Supertonic (Microtonic-style synthesis)
--
-- E1: tempo (BPM)
-- E2: browse parameters
-- E3: adjust selected parameter
-- K2: play / stop
-- K3 short: randomise pattern
-- K3 long:  randomise all params + pattern
-- K2+K3: randomise selected param only
-- K1+K2: save current pattern to chain
-- K1+K3: toggle chain mode
-- grid (optional): toggle steps

engine.name = 'Supertonic'

local STEPS   = 16
local VOICES  = 4
local BPM_MIN = 40
local BPM_MAX = 300

local voice_names = { "kick", "snare", "hat", "open" }
local voice_abbr  = { "BD",   "SD",    "HH",  "OH"   }

-- ─── Supertonic synthesis patches ────────────────────────────────────────────
-- Each patch is a set of Microtonic-style synthesis params for one voice.
-- Global params (pitch, warmth, crush, crop, reverb, velocity) modify
-- these at trigger time — they are not stored here.
--
-- Key params:
--   mix     0-100   0=all noise, 100=all oscillator
--   oscFreq Hz      base oscillator frequency (engine adds 5 internally)
--   oscWave 0/1/2   0=sine, 1=triangle, 2=sawtooth
--   oscDcy  ms      oscillator decay
--   modMode 0/1/2   pitch mod: 0=decay sweep, 1=sine LFO, 2=random
--   modRate Hz/ms   pitch mod rate
--   modAmt  semi    pitch mod depth
--   nEnvDcy ms      noise envelope decay
--   nFilFrq Hz      noise filter cutoff
--   nFilMod 0/1/2   noise filter: 0=lowpass, 1=bandpass, 2=highpass
--   distAmt 0-100   SineShaper distortion drive
--   level   dB      output level

local voice_patches = {

  -- KICK: oscillator-dominant, deep pitch-swept sine, thud + click
  {
    oscFreq = 50,    oscWave = 0,   oscAtk = 0,    oscDcy = 420,
    modMode = 0,     modRate = 180, modAmt = 18,
    nEnvAtk = 3,    nEnvDcy = 55,  nEnvMod = 0,
    nFilFrq = 350,  nFilMod = 0,   nFilQ   = 1.5, nStereo = 0,
    mix     = 92,   distAmt = 14,  level   = -2,
    eQFreq  = 75,   eQGain  = 4,
    oscVel  = 100,  nVel    = 80,  modVel  = 100,
  },

  -- SNARE: balanced osc+noise, bandpass crack, punchy body
  {
    oscFreq = 155,  oscWave = 0,   oscAtk = 0,    oscDcy = 75,
    modMode = 0,    modRate = 110, modAmt = 8,
    nEnvAtk = 1,   nEnvDcy = 145, nEnvMod = 0,
    nFilFrq = 3800, nFilMod = 1,  nFilQ   = 2.2, nStereo = 1,
    mix     = 44,  distAmt = 26,  level   = -4,
    eQFreq  = 2200, eQGain = 4,
    oscVel  = 100,  nVel   = 100, modVel  = 80,
  },

  -- CLOSED HAT: almost pure noise, highpass, very short
  {
    oscFreq = 380,  oscWave = 0,   oscAtk = 0,    oscDcy = 25,
    modMode = 0,    modRate = 100, modAmt = 1,
    nEnvAtk = 0,   nEnvDcy = 50,  nEnvMod = 0,
    nFilFrq = 9500, nFilMod = 2,  nFilQ   = 1.1, nStereo = 1,
    mix     = 5,   distAmt = 9,   level   = -6,
    eQFreq  = 9000, eQGain = 2,
    oscVel  = 70,   nVel   = 100, modVel  = 70,
  },

  -- OPEN HAT: noise, highpass, longer tail, wide stereo
  {
    oscFreq = 380,  oscWave = 0,   oscAtk = 0,    oscDcy = 55,
    modMode = 0,    modRate = 100, modAmt = 1,
    nEnvAtk = 2,   nEnvDcy = 290, nEnvMod = 0,
    nFilFrq = 7200, nFilMod = 2,  nFilQ   = 0.9, nStereo = 1,
    mix     = 5,   distAmt = 7,   level   = -5,
    eQFreq  = 8000, eQGain = 1,
    oscVel  = 70,   nVel   = 100, modVel  = 70,
  },
}

-- ─── params ───────────────────────────────────────────────────────────────────

local all_params = {
  "chance", "zoom", "midpoint", "range",
  "pitch",  "crush", "crop",   "drop",
  "velocity", "subdiv", "reverb", "warmth",
}
local param_idx = 1

local p_vals = {
  chance   = 0.0,
  zoom     = 0.5,
  midpoint = 0.5,
  range    = 0.5,
  pitch    = 0.5,   -- 0=half freq, 0.5=default, 1=2x freq
  crush    = 1.0,   -- 1=clean, 0=maximum distortion
  crop     = 1.0,   -- 1=full tail, 0=very short
  drop     = 0.5,
  swing    = 0.0,
  velocity = 0.0,
  subdiv   = 0.5,   -- 0=half time, 0.5=normal, 1=double time
  reverb   = 0.0,
  warmth   = 0.0,   -- 0=bright, 1=warm/filtered
}

local voice_prob = { 100, 100, 100, 100 }

-- ─── pattern chain ────────────────────────────────────────────────────────────

local chain                 = {}
local chain_pos             = 0
local chain_active          = false
local chain_bars            = 0
local chain_bars_per_pattern = 4

-- ─── MIDI output ──────────────────────────────────────────────────────────────

local midi_out   = nil
local MIDI_CH    = 10
local voice_midi = { 36, 38, 42, 46 }  -- GM: kick, snare, closed hat, open hat

-- ─── clock state ──────────────────────────────────────────────────────────────

local bpm     = 120
local step    = 1
local playing = false
local clk_id  = nil
local k3_hold_id = nil
local K3_LONG    = 0.6

-- ─── screen state ─────────────────────────────────────────────────────────────

local beat_phase        = 0
local popup_param       = nil
local popup_val         = nil
local popup_time        = 0
local POPUP_DURATION    = 0.8
local screen_refresh_rate = 10
local screen_refresh_id = nil

-- ─── pattern ──────────────────────────────────────────────────────────────────

local pattern = {}
for v = 1, VOICES do
  pattern[v] = {}
  for s = 1, STEPS do pattern[v][s] = false end
end

local function default_pattern()
  for v = 1, VOICES do
    for s = 1, STEPS do pattern[v][s] = false end
  end
  for _, s in ipairs({1, 5, 9, 13}) do pattern[1][s] = true end
  for _, s in ipairs({5, 13})       do pattern[2][s] = true end
  for s = 1, 16, 2                  do pattern[3][s] = true end
end

local function randomise_pattern()
  for v = 1, VOICES do
    for s = 1, STEPS do pattern[v][s] = (math.random() < 0.25) end
  end
  pattern[1][1] = true
end

local function randomise_single(k)
  if k == "pitch" then
    p_vals[k] = math.random() < 0.1
      and (math.random() * 0.14)
      or  (0.15 + math.random() * 0.85)
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
             or            0.4 + math.random() * 0.2
  elseif k == "reverb" then
    p_vals[k] = math.random() * 0.7
  elseif k == "warmth" then
    p_vals[k] = math.random() * 0.8
  else
    p_vals[k] = math.random()
  end
end

local function randomise_params()
  for _, k in ipairs(all_params) do randomise_single(k) end
end

-- ─── pattern chain helpers ────────────────────────────────────────────────────

local function save_pattern_to_chain()
  local e = {}
  for v = 1, VOICES do
    e[v] = {}
    for s = 1, STEPS do e[v][s] = pattern[v][s] end
  end
  table.insert(chain, e)
  print("drumkid: pattern saved to chain (" .. #chain .. ")")
end

local function load_chain_pattern(pos)
  if pos < 1 or pos > #chain then return end
  for v = 1, VOICES do
    for s = 1, STEPS do pattern[v][s] = chain[pos][v][s] end
  end
end

-- ─── trigger (Supertonic engine) ──────────────────────────────────────────────

local function trigger(v, amp)
  if amp <= 0 then return end
  if math.random(100) > voice_prob[v] then return end

  -- Velocity randomisation
  if p_vals.velocity > 0 then
    local jitter = (math.random() * 2 - 1) * p_vals.velocity * 0.5
    amp = util.clamp(amp + jitter, 0.05, 1.0)
  end

  local patch = voice_patches[v]

  -- pitch: exponential scaling so pitch=0.5 is always the "default" timbre
  -- range: half-freq (pitch=0) → 2x-freq (pitch=1), one octave either side
  local pitch_mult = math.exp((p_vals.pitch - 0.5) * 1.386)
  local osc_freq   = util.clamp(patch.oscFreq * pitch_mult, 20, 12000)

  -- crop: scales both oscillator and noise decay tails
  -- crop=1.0 → full patch decay, crop=0.0 → 10% of decay (tight, snappy)
  local tail    = 0.1 + p_vals.crop * 0.9
  local osc_dcy = patch.oscDcy * tail
  local n_dcy   = patch.nEnvDcy * tail

  -- warmth: lowers noise filter cutoff + applies a global LPF
  -- warmth=0 → bright (patch default), warmth=1 → heavily filtered
  local noise_filter = util.clamp(patch.nFilFrq * (1.0 - p_vals.warmth * 0.78), 300, 20000)
  local global_lpf   = util.clamp(20000 * (1.0 - p_vals.warmth * 0.87), 400, 20000)

  -- crush: inverted → distortion (crush=1 clean, crush=0 full drive)
  -- adds to the patch's base distortion, max 100
  local dist = util.clamp(patch.distAmt + (1.0 - p_vals.crush) * 58, 0, 100)

  -- amplitude → level in dB (amp=1.0 → patch default, amp=0.5 → -6dB)
  local level_db = patch.level + 20 * math.log(util.clamp(amp, 0.01, 1.0)) / math.log(10)

  -- reverb send (norns built-in reverb)
  audio.level_eng_rev(p_vals.reverb * 0.9)

  -- Fire Supertonic. Format: "ffffffffffffffffffffffffi" (24 floats + 1 int)
  -- The final integer is parsed but unused by the engine body; send 0.
  engine.supertonic(
    dist,            -- [1]  distAmt        (0-100)
    patch.eQFreq,    -- [2]  eQFreq         (Hz)
    patch.eQGain,    -- [3]  eQGain         (dB)
    level_db,        -- [4]  level          (dB)
    patch.mix,       -- [5]  mix            (0=noise, 100=osc)
    patch.modAmt,    -- [6]  modAmt         (semitones)
    patch.modMode,   -- [7]  modMode        (0=decay, 1=sine, 2=random)
    patch.modRate,   -- [8]  modRate        (Hz or ms depending on mode)
    patch.nEnvAtk,   -- [9]  nEnvAtk       (ms)
    n_dcy,           -- [10] nEnvDcy       (ms, scaled by crop)
    patch.nEnvMod,   -- [11] nEnvMod       (0=exp, 1=linear, 2=clap)
    noise_filter,    -- [12] nFilFrq       (Hz, scaled by warmth)
    patch.nFilMod,   -- [13] nFilMod       (0=LP, 1=BP, 2=HP)
    patch.nFilQ,     -- [14] nFilQ
    patch.nStereo,   -- [15] nStereo       (0=mono, 1=stereo)
    patch.oscAtk,    -- [16] oscAtk        (ms)
    osc_dcy,         -- [17] oscDcy        (ms, scaled by crop)
    osc_freq,        -- [18] oscFreq       (Hz, scaled by pitch)
    patch.oscWave,   -- [19] oscWave       (0=sine, 1=tri, 2=saw)
    patch.oscVel,    -- [20] oscVel        (0-200)
    patch.nVel,      -- [21] nVel          (0-200)
    patch.modVel,    -- [22] modVel        (0-200)
    global_lpf,      -- [23] fx_lowpass_freq (Hz)
    1.0,             -- [24] fx_lowpass_rq
    0                -- [25] (integer, format req., unused by engine body)
  )

  -- MIDI out
  if midi_out then
    local vel_midi = math.floor(util.clamp(amp, 0, 1) * 127)
    midi_out:note_on(voice_midi[v], vel_midi, MIDI_CH)
    clock.run(function()
      clock.sleep(0.05)
      if midi_out then midi_out:note_off(voice_midi[v], 0, MIDI_CH) end
    end)
  end
end

-- ─── clock / tick ─────────────────────────────────────────────────────────────

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
  else                return v ~= 3
  end
end

local function tick()
  local zsteps = {}
  for _, s in ipairs(zoom_steps()) do zsteps[s] = true end

  for v = 1, VOICES do
    if not voice_dropped(v) then
      local fired = false
      if pattern[v][step] then
        trigger(v, 1.0)
        fired = true
      end
      if not fired and zsteps[step] then
        local low  = p_vals.midpoint - p_vals.range * 0.5
        local high = p_vals.midpoint + p_vals.range * 0.5
        local pos  = (step - 1) / (STEPS - 1)
        if pos >= low and pos <= high and roll(p_vals.chance) then
          trigger(v, 0.8)
        end
      end
    end
  end

  step = (step % STEPS) + 1

  if chain_active and #chain > 0 then
    chain_bars = chain_bars + 1
    if chain_bars >= chain_bars_per_pattern then
      chain_bars = 0
      chain_pos  = (chain_pos % #chain) + 1
      load_chain_pattern(chain_pos)
    end
  end

  grid_redraw()
  beat_phase = beat_phase + 1
end

local subdiv_counter = 0

local function clock_loop()
  while true do
    clock.sync(1 / 4)
    if playing then
      if p_vals.subdiv < 0.4 then
        subdiv_counter = subdiv_counter + 1
        if subdiv_counter >= 2 then
          subdiv_counter = 0
          tick()
        end
      elseif p_vals.subdiv > 0.6 then
        tick()
        clock.sleep(60 / bpm / 4 / 2)
        tick()
      else
        subdiv_counter = 0
        tick()
      end
    end
  end
end

local function set_bpm(b)
  bpm = util.clamp(b, BPM_MIN, BPM_MAX)
  params:set("clock_tempo", bpm)
end

-- ─── grid ─────────────────────────────────────────────────────────────────────

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
    grid_redraw()
    beat_phase = beat_phase + 1
  end
end

-- ─── input handlers ───────────────────────────────────────────────────────────

local k2_down    = false
local k2_hold_id = nil

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_down    = true
      k2_hold_id = clock.run(function()
        clock.sleep(K3_LONG)
        k2_hold_id = nil
      end)
    else
      k2_down = false
      if k2_hold_id then
        clock.cancel(k2_hold_id)
        k2_hold_id = nil
        playing = not playing
        if playing then step = 1 end
        beat_phase = beat_phase + 1
      end
    end
  elseif n == 3 then
    if z == 1 then
      if k2_down then
        if k2_hold_id then
          clock.cancel(k2_hold_id)
          k2_hold_id = nil
        end
        randomise_single(all_params[param_idx])
        popup_param = all_params[param_idx]
        popup_val   = p_vals[popup_param]
        popup_time  = POPUP_DURATION
        beat_phase  = beat_phase + 1
      else
        k3_hold_id = clock.run(function()
          clock.sleep(K3_LONG)
          randomise_params()
          randomise_pattern()
          k3_hold_id = nil
          beat_phase = beat_phase + 1
          grid_redraw()
        end)
      end
    else
      if k3_hold_id then
        clock.cancel(k3_hold_id)
        k3_hold_id = nil
        randomise_pattern()
        beat_phase = beat_phase + 1
        grid_redraw()
      end
    end
  end
end

function enc(n, d)
  if n == 1 then
    set_bpm(bpm + d)
    popup_param = "BPM"
    popup_val   = bpm
    popup_time  = POPUP_DURATION
  elseif n == 2 then
    param_idx = util.clamp(param_idx + d, 1, #all_params)
  elseif n == 3 then
    local k = all_params[param_idx]
    p_vals[k] = util.clamp(p_vals[k] + d * 0.01, 0.0, 1.0)
    popup_param = k
    popup_val   = p_vals[k]
    popup_time  = POPUP_DURATION
  end
  beat_phase = beat_phase + 1
end

-- ─── screen ───────────────────────────────────────────────────────────────────

local function draw_status_strip()
  screen.level(4)
  screen.font_size(8)
  screen.move(2, 7)
  screen.text("DRUMKID")

  if chain_active and #chain > 0 then
    screen.level(6)
    screen.move(90, 7)
    local s = ""
    for i = 1, #chain do s = s .. string.char(64 + i) end
    screen.text(s)
  end

  if playing then
    screen.level(15)
    screen.circle(124, 4, 1)
    screen.fill()
  end
end

local function draw_live_zone()
  local gx    = 2
  local gy    = 10
  local cw    = 7
  local ch    = 8
  local gap   = 1

  for v = 1, VOICES do
    screen.level(5)
    screen.font_size(8)
    screen.move(gx - 8, gy + (v - 1) * (ch + gap) + ch - 1)
    screen.text(voice_abbr[v])
  end

  for v = 1, VOICES do
    for s = 1, STEPS do
      local x  = gx + (s - 1) * (cw + gap)
      local y  = gy + (v - 1) * (ch + gap)
      local hit = pattern[v][s]
      local is_playhead = (s == step and playing)

      local bright = hit and 12 or 4
      if is_playhead then bright = math.min(15, bright + 3) end

      screen.level(bright)
      screen.rect(x, y, cw, ch)
      if bright >= 10 then screen.fill() else screen.stroke() end
    end
  end
end

local function draw_chain_preview()
  if chain_active and #chain > 1 then
    screen.level(4)
    screen.font_size(8)
    screen.move(2, 53)
    screen.text(string.char(64 + chain_pos))
    screen.level(10)
    screen.move(12, 53)
    screen.text(">" .. string.char(64 + (chain_pos % #chain) + 1))
  end
end

local function draw_context_bar()
  local y = 54
  screen.font_size(7)
  screen.level(8)
  screen.move(2, y + 6)
  screen.text(string.format("BPM:%d", bpm))
  screen.level(5)
  screen.move(45, y + 6)
  screen.text(string.format("Z:%.1f", p_vals.zoom))
  screen.level(4)
  screen.move(80, y + 6)
  screen.text("CH:" .. MIDI_CH)
end

local function draw_param_strip()
  local py      = 46
  local page    = math.floor((param_idx - 1) / 4)
  local start_i = page * 4 + 1
  local n_pages = math.ceil(#all_params / 4)

  for i = start_i, math.min(start_i + 3, #all_params) do
    local k   = all_params[i]
    local val = p_vals[k]
    local sel = (i == param_idx)
    local col = (i - start_i)
    local x   = 2 + col * 31

    screen.level(sel and 15 or 5)
    screen.font_size(8)
    screen.move(x, py)
    screen.text(k:sub(1, 4))
    screen.level(sel and 12 or 3)
    screen.rect(x, py + 3, math.floor(val * 28), 3)
    screen.fill()
    screen.level(sel and 5 or 2)
    screen.rect(x, py + 3, 28, 3)
    screen.stroke()
    if sel then
      screen.level(6)
      screen.move(x, py + 13)
      screen.text(string.format("%.2f", val))
    end
  end

  for p = 0, n_pages - 1 do
    screen.level(p == page and 12 or 4)
    screen.rect(116 + p * 6, py, 4, 4)
    screen.fill()
  end
end

local function draw_popup()
  if popup_time <= 0 then return end
  popup_time = popup_time - (1 / screen_refresh_rate)
  screen.level(2)
  screen.rect(40, 25, 48, 20)
  screen.fill()
  screen.level(15)
  screen.rect(40, 25, 48, 20)
  screen.stroke()
  screen.level(15)
  screen.font_size(8)
  screen.move(44, 33)
  screen.text(popup_param)
  screen.level(12)
  screen.move(44, 41)
  if type(popup_val) == "number" and popup_val == math.floor(popup_val) then
    screen.text(tostring(popup_val))
  else
    screen.text(string.format("%.2f", popup_val))
  end
end

function redraw()
  screen.clear()
  draw_status_strip()
  draw_live_zone()
  draw_chain_preview()
  draw_context_bar()
  draw_param_strip()
  draw_popup()
  screen.update()
end

local function screen_refresh_loop()
  while true do
    clock.sleep(1 / screen_refresh_rate)
    redraw()
  end
end

-- ─── init ─────────────────────────────────────────────────────────────────────

function init()
  math.randomseed(os.time())
  default_pattern()
  set_bpm(bpm)

  -- Enable norns reverb for engine audio
  audio.rev_on()
  audio.level_eng_rev(0.0)  -- start dry; reverb param controls this at trigger time

  -- MIDI out
  midi_out = midi.connect(1)
  print("drumkid: MIDI out connected to device 1")

  clk_id            = clock.run(clock_loop)
  screen_refresh_id = clock.run(screen_refresh_loop)

  redraw()
  grid_redraw()
  print("drumkid: Supertonic engine ready — no samples needed")
end

-- ─── cleanup ──────────────────────────────────────────────────────────────────

function cleanup()
  if clk_id            then clock.cancel(clk_id)            end
  if screen_refresh_id  then clock.cancel(screen_refresh_id) end
  if midi_out then
    for v = 1, VOICES do midi_out:cc(123, 0, MIDI_CH) end
  end
  clock.cancel_all()
end
