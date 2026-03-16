-- drumkid for norns
-- aleatoric drum machine
-- inspired by mattybrad/drumkid
--
-- E1: tempo (BPM)
-- E2: browse parameters
-- E3: adjust selected parameter
-- K2: play / stop
-- K3 short: randomise selected param
-- K3 long:  randomise all params
-- K1+K2: save current pattern to chain
-- K1+K3: toggle chain mode
-- grid (optional): toggle steps

engine.name = 'None'

local STEPS   = 16
local VOICES  = 4
local BPM_MIN = 40
local BPM_MAX = 300

local voice_names  = { "kick", "snare", "hat", "open" }
local voice_abbr   = { "BD", "SD", "HH", "PC" }
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

-- flat param list
local all_params = { "chance", "zoom", "midpoint", "range", "pitch", "crush", "crop", "drop", "velocity", "subdiv", "reverb", "warmth" }
local param_idx  = 1

local p_vals = {
  chance   = 0.0,
  zoom     = 0.5,
  midpoint = 0.5,
  range    = 0.5,
  pitch    = 0.5,
  crush    = 1.0,
  crop     = 1.0,
  drop     = 0.5,
  swing    = 0.0,
  velocity = 0.0,
  subdiv   = 0.5,  -- 0=half time, 0.5=normal, 1=double time
  reverb   = 0.0,  -- 0=dry, 1=full reverb send
  warmth   = 0.0,  -- 0=bright/clean, 1=warm/filtered/saturated
}

-- Per-voice probability table
local voice_prob = { 100, 100, 100, 100 }

-- Pattern chain: store up to 8 patterns
local chain = {}
local chain_pos = 0
local chain_active = false
local chain_bars = 0
local chain_bars_per_pattern = 4

-- MIDI output
local midi_out   = nil
local MIDI_CH    = 10  -- standard GM drum channel
-- GM drum note numbers
local voice_midi = { 36, 38, 42, 46 }  -- kick, snare, closed hat, open hat

local bpm     = 120
local step    = 1
local playing = false
local clk_id  = nil
local k3_hold_id = nil
local K3_LONG    = 0.6

-- Screen state
local beat_phase = 0
local popup_param = nil
local popup_val = nil
local popup_time = 0
local POPUP_DURATION = 0.8
local screen_refresh_rate = 10  -- ~10fps

-- Clock IDs for cleanup
local screen_refresh_id = nil

-- ─── pattern ─────────────────────────────────────────────────────────────────

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
    for s = 1, STEPS do
      pattern[v][s] = (math.random() < 0.25)
    end
  end
  pattern[1][1] = true  -- always kick on beat 1
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
    -- weighted: 60% normal, 20% half-time, 20% double-time
    local r = math.random()
    p_vals[k] = r < 0.2 and math.random() * 0.35
             or r < 0.4 and 0.65 + math.random() * 0.35
             or            0.4 + math.random() * 0.2
  elseif k == "reverb" then
    p_vals[k] = math.random() * 0.7  -- bias towards drier
  elseif k == "warmth" then
    p_vals[k] = math.random() * 0.8
  else
    p_vals[k] = math.random()
  end
end

local function randomise_params()
  for _, k in ipairs(all_params) do
    randomise_single(k)
  end
end

-- ─── pattern chain ───────────────────────────────────────────────────────────

local function save_pattern_to_chain()
  local new_entry = {}
  for v = 1, VOICES do
    new_entry[v] = {}
    for s = 1, STEPS do
      new_entry[v][s] = pattern[v][s]
    end
  end
  table.insert(chain, new_entry)
  print("Pattern saved to chain (position " .. #chain .. ")")
end

local function load_chain_pattern(pos)
  if pos < 1 or pos > #chain then return end
  for v = 1, VOICES do
    for s = 1, STEPS do
      pattern[v][s] = chain[pos][v][s]
    end
  end
end

-- ─── softcut ─────────────────────────────────────────────────────────────────

local function init_softcut()
  audio.level_cut(1.0)
  audio.level_adc_cut(0)
  audio.rev_on()
  softcut.buffer_clear()
  for i = 1, VOICES do
    softcut.enable(i, 1)
    softcut.buffer(i, sc_buf[i])
    softcut.level(i, 1.0)
    softcut.pan(i, 0.0)
    softcut.rate(i, 1.0)
    softcut.play(i, 0)
    softcut.rec(i, 0)
    softcut.fade_time(i, 0.001)
    softcut.loop(i, 0)
    softcut.loop_start(i, sc_pos[i])
    softcut.loop_end(i, sc_pos[i] + SLOT)
    softcut.position(i, sc_pos[i])
    softcut.level_cut_cut(i, i, 0)  -- no cross-voice routing
  end
  for i = 1, VOICES do
    softcut.buffer_read_mono(sample_paths[i], 0, sc_pos[i], -1, 1, sc_buf[i])
  end
  print("drumkid: samples loading")
end

local function trigger(v, amp)
  if amp <= 0 then return end

  -- Per-voice probability gate
  if math.random(100) > voice_prob[v] then return end

  -- velocity randomisation
  if p_vals.velocity > 0 then
    local variation = (math.random() * 2 - 1) * p_vals.velocity * 0.5
    amp = util.clamp(amp + variation, 0.05, 1.0)
  end

  -- crush
  if p_vals.crush < 1.0 then
    local bits = math.max(1, math.floor(p_vals.crush * 16))
    amp = math.floor(amp * bits) / bits
  end

  -- warmth: low-pass cutoff (bright=16000Hz, warm=400Hz) + gentle saturation
  local cutoff = 16000 * (1.0 - p_vals.warmth * 0.97)
  for i = 1, VOICES do
    softcut.pre_filter_fc(i, cutoff)
    softcut.pre_filter_lp(i, p_vals.warmth)
    softcut.pre_filter_dry(i, 1.0 - p_vals.warmth * 0.5)
  end
  -- warmth also slightly boosts amp for saturation feel
  amp = util.clamp(amp * (1.0 + p_vals.warmth * 0.3), 0, 1)

  -- reverb send
  audio.level_cut_rev(p_vals.reverb * 1.5)

  -- pitch
  local rate
  if p_vals.pitch < 0.15 then
    rate = -1.0 * (1.0 - p_vals.pitch / 0.15)
    if math.abs(rate) < 0.05 then rate = -0.05 end
  else
    rate = 1.0 + ((p_vals.pitch - 0.15) / 0.85) * 2.0
  end

  local sample_dur = 0.26
  local crop_end   = sc_pos[v] + math.max(0.01, p_vals.crop * sample_dur)

  softcut.loop_end(v, crop_end)
  softcut.level(v, util.clamp(amp, 0, 1))
  softcut.rate(v, rate)
  if rate < 0 then
    softcut.position(v, crop_end - 0.001)
  else
    softcut.position(v, sc_pos[v])
  end
  softcut.play(v, 1)

  -- MIDI out
  if midi_out then
    local vel = math.floor(util.clamp(amp, 0, 1) * 127)
    midi_out:note_on(voice_midi[v], vel, MIDI_CH)
    clock.run(function()
      clock.sleep(0.05)
      if midi_out then
        midi_out:note_off(voice_midi[v], 0, MIDI_CH)
      end
    end)
  end
end

-- ─── clock / tick ────────────────────────────────────────────────────────────

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
  
  -- Handle chain advancement
  if chain_active and #chain > 0 then
    chain_bars = chain_bars + 1
    if chain_bars >= chain_bars_per_pattern then
      chain_bars = 0
      chain_pos = (chain_pos % #chain) + 1
      load_chain_pattern(chain_pos)
    end
  end
  
  grid_redraw()
  beat_phase = beat_phase + 1
end

-- subdiv counter for half/double time
local subdiv_counter = 0

local function clock_loop()
  while true do
    clock.sync(1 / 4)
    if playing then
      -- subdiv: 0=half time (tick every 2 syncs), 0.5=normal, 1=double time (tick twice)
      if p_vals.subdiv < 0.4 then
        -- half time: only tick on every other sync
        subdiv_counter = subdiv_counter + 1
        if subdiv_counter >= 2 then
          subdiv_counter = 0
          tick()
        end
      elseif p_vals.subdiv > 0.6 then
        -- double time: tick twice per sync
        tick()
        clock.sleep(60 / bpm / 4 / 2)
        tick()
      else
        -- normal
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

-- ─── grid ────────────────────────────────────────────────────────────────────

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

-- ─── UI ─────────────────────────────────────────────────────────────────────

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
      k2_down = false  -- always clear on release
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
        -- K2+K3: cancel K2 transport action, randomise selected param
        if k2_hold_id then
          clock.cancel(k2_hold_id)
          k2_hold_id = nil
        end
        randomise_single(all_params[param_idx])
        popup_param = all_params[param_idx]
        popup_val = p_vals[popup_param]
        popup_time = POPUP_DURATION
        beat_phase = beat_phase + 1
      else
        -- start K3 hold timer
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
      -- K3 released
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
    popup_val = bpm
    popup_time = POPUP_DURATION
  elseif n == 2 then
    param_idx = util.clamp(param_idx + d, 1, #all_params)
  elseif n == 3 then
    local k = all_params[param_idx]
    p_vals[k] = util.clamp(p_vals[k] + d * 0.01, 0.0, 1.0)
    popup_param = k
    popup_val = p_vals[k]
    popup_time = POPUP_DURATION
  end
  beat_phase = beat_phase + 1
end

-- ─── screen redesign: zone-based layout ───────────────────────────────────────

local function draw_status_strip()
  -- STATUS STRIP (y 0-8)
  screen.level(4)
  screen.font_size(8)
  screen.move(2, 7)
  screen.text("DRUMKID")
  
  -- Current pattern chain position (right side)
  if chain_active and #chain > 0 then
    local chain_str = ""
    for i = 1, #chain do
      if i == chain_pos then
        screen.level(10)
        chain_str = chain_str .. (string.char(64 + i))  -- A, B, C, ...
      else
        screen.level(6)
        chain_str = chain_str .. (string.char(64 + i))
      end
    end
    screen.level(6)
    screen.move(90, 7)
    screen.text(chain_str)
  end
  
  -- Beat pulse dot (playhead indicator)
  if playing then
    screen.level(15)
    screen.circle(124, 4, 1)
    screen.fill()
  end
end

local function draw_live_zone()
  -- LIVE ZONE (y 9-52): TR-style grid
  local grid_x = 2
  local grid_y = 10
  local cell_w = 7
  local cell_h = 8
  local cell_gap = 1
  
  -- Voice labels on the left
  for v = 1, VOICES do
    screen.level(5)
    screen.font_size(8)
    screen.move(grid_x - 8, grid_y + (v - 1) * (cell_h + cell_gap) + cell_h - 1)
    screen.text(voice_abbr[v])
  end
  
  -- Grid cells
  for v = 1, VOICES do
    for s = 1, STEPS do
      local x = grid_x + (s - 1) * (cell_w + cell_gap)
      local y = grid_y + (v - 1) * (cell_h + cell_gap)
      local hit = pattern[v][s]
      local is_playhead = (s == step and playing)
      
      local brightness = 1  -- faint grid default
      if hit then
        brightness = 12  -- full brightness for hit
      else
        -- Probability-based brightness: if we can infer a prob value
        -- For now, use static prob; could be per-step in future
        local prob_factor = voice_prob[v] / 100
        if prob_factor < 1.0 then
          brightness = math.floor(4 + prob_factor * 8)
        else
          brightness = 4  -- dim for non-hit grid
        end
      end
      
      -- Playhead boost
      if is_playhead then
        brightness = math.min(15, brightness + 3)
      end
      
      screen.level(brightness)
      screen.rect(x, y, cell_w, cell_h)
      if brightness >= 10 then
        screen.fill()
      else
        screen.stroke()
      end
    end
  end
end

local function draw_chain_preview()
  -- PATTERN CHAIN PREVIEW (below grid)
  if chain_active and #chain > 1 then
    screen.level(4)
    screen.font_size(8)
    screen.move(2, 53)
    local current = string.char(64 + chain_pos)  -- current pattern letter
    local next_pos = (chain_pos % #chain) + 1
    local next_chr = string.char(64 + next_pos)
    screen.text(current)
    screen.level(10)
    screen.move(12, 53)
    screen.text(">" .. next_chr)
  end
end

local function draw_context_bar()
  -- CONTEXT BAR (y 53-58)
  local y = 54
  screen.font_size(7)
  
  -- BPM
  screen.level(8)
  screen.move(2, y + 6)
  screen.text(string.format("BPM:%d", bpm))
  
  -- Swing %
  screen.level(6)
  screen.move(35, y + 6)
  screen.text(string.format("SW:%.0f%%", p_vals.swing * 100))
  
  -- Zoom level
  screen.level(5)
  screen.move(65, y + 6)
  screen.text(string.format("Z:%.1f", p_vals.zoom))
  
  -- MIDI channel
  screen.level(4)
  screen.move(95, y + 6)
  screen.text("CH:" .. MIDI_CH)
end

local function draw_transient_popup()
  -- TRANSIENT PARAMETER POPUP (0.8s duration)
  if popup_time > 0 then
    popup_time = popup_time - (1 / screen_refresh_rate)
    
    -- Semi-transparent background
    screen.level(2)
    screen.rect(40, 25, 48, 20)
    screen.fill()
    
    -- Border
    screen.level(15)
    screen.rect(40, 25, 48, 20)
    screen.stroke()
    
    -- Parameter name
    screen.level(15)
    screen.font_size(8)
    screen.move(44, 33)
    screen.text(popup_param)
    
    -- Value display
    screen.level(12)
    screen.move(44, 41)
    screen.text(string.format("%.3f", popup_val))
  end
end

local function draw_param_strip()
  -- Parameter display: 4 visible at a time, window follows selection
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

  -- page indicator dots
  for p = 0, n_pages - 1 do
    screen.level(p == page and 12 or 4)
    screen.rect(116 + p * 6, py, 4, 4)
    screen.fill()
  end
end

local function draw_help_footer()
  -- Help text footer
  screen.level(3)
  screen.font_size(7)
  screen.move(2, 64)
  screen.text("e3:adj k3:pat k2+k3:rnd1 k3L:all")
end

function redraw()
  screen.clear()
  
  draw_status_strip()
  draw_live_zone()
  draw_chain_preview()
  draw_context_bar()
  draw_param_strip()
  draw_transient_popup()
  draw_help_footer()
  
  screen.update()
end

-- Screen refresh clock (~10 fps)
local function screen_refresh_loop()
  while true do
    clock.sleep(1 / screen_refresh_rate)
    redraw()
  end
end

-- ─── init ────────────────────────────────────────────────────────────────────

function init()
  math.randomseed(os.time())
  default_pattern()
  set_bpm(bpm)
  -- MIDI output: connect to first available device
  midi_out = midi.connect(1)
  print("drumkid: midi out connected to device 1")
  clock.run(function()
    clock.sleep(1.0)
    init_softcut()
    clock.sleep(2.0)
    print("drumkid: ready")
  end)
  clk_id = clock.run(clock_loop)
  screen_refresh_id = clock.run(screen_refresh_loop)
  redraw()
  grid_redraw()
end

function cleanup()
  if clk_id then clock.cancel(clk_id) end
  if screen_refresh_id then clock.cancel(screen_refresh_id) end
  if midi_out then
    for v = 1, VOICES do
      midi_out:cc(123, 0, MIDI_CH)  -- all notes off for this channel
    end
  end
  clock.cancel_all()
end
